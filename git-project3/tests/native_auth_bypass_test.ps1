param(
    [Parameter(Mandatory = $true)] [string] $SourceGameRoot,
    [string] $ProjectRoot = '',
    [string] $PackageRoot = '',
    [string] $CompilerPath = '',
    [string] $AuthorizedKey = $env:TH09_TEST_SIDE_KEY,
    [string] $RetiredKey = $env:TH09_TEST_RETIRED_SIDE_KEY
)
# Security integration regression. Every process uses an owned copy and
# --verify-suspended. This test never starts a playable game or changes a user
# installation. Private keys arrive only through the caller's environment.
$ErrorActionPreference = 'Stop'
if (-not $ProjectRoot) { $ProjectRoot = Split-Path -Parent $PSScriptRoot }
$project = [IO.Path]::GetFullPath($ProjectRoot)
if (-not $PackageRoot) { $PackageRoot = Join-Path $project 'dist\TH09-AI' }
if (-not $CompilerPath) { $CompilerPath = Join-Path $project 'work\win32-toolchain\tcc\tcc.exe' }
if ([string]::IsNullOrEmpty($AuthorizedKey) -or [string]::IsNullOrEmpty($RetiredKey)) {
    throw 'This test requires TH09_TEST_SIDE_KEY and TH09_TEST_RETIRED_SIDE_KEY in the caller environment.'
}
if ($AuthorizedKey -ceq $RetiredKey) { throw 'Current and retired test keys must differ.' }
$fixture = Join-Path $project ('work\native-auth-bypass-' + [Guid]::NewGuid().ToString('N'))
$game = Join-Path $fixture 'game'
$package = Join-Path $game 'AI-package'
$runtime = Join-Path $package 'runtime'
$ai = Join-Path $package 'ai'
$build = Join-Path $fixture 'parent-bypass-build'
foreach ($path in @($runtime, $ai, $build)) { [void][IO.Directory]::CreateDirectory($path) }
$SourceGameRoot = (Resolve-Path -LiteralPath $SourceGameRoot).ProviderPath
$testGame = Join-Path $game 'th09.exe'
$originalExeHash = (Get-FileHash -LiteralPath (Join-Path $SourceGameRoot 'th09.exe')).Hash
$originalConfig = [IO.File]::ReadAllBytes((Join-Path $SourceGameRoot 'th09.cfg'))
[IO.File]::Copy((Join-Path $SourceGameRoot 'th09.exe'), $testGame)
[IO.File]::WriteAllBytes((Join-Path $game 'th09.cfg'), $originalConfig)
foreach ($dependency in [IO.Directory]::GetFiles($SourceGameRoot, '*.dll')) {
    [IO.File]::Copy($dependency, (Join-Path $game ([IO.Path]::GetFileName($dependency))))
}
foreach ($name in @('inject.dll', 'window_support.dll', 'th09ai-launcher.exe')) {
    [IO.File]::Copy((Join-Path $PackageRoot ('runtime\' + $name)), (Join-Path $runtime $name))
}
[IO.File]::Copy((Join-Path $PackageRoot 'ai\main.lua'), (Join-Path $ai 'main.lua'))
$launcherSource = if ($PSBoundParameters.ContainsKey('PackageRoot')) { Join-Path $PackageRoot 'prepare-and-start.ps1' } else { Join-Path $project 'src\launcher\prepare-and-start.ps1' }
$inputSource = if ($PSBoundParameters.ContainsKey('PackageRoot')) { Join-Path $PackageRoot 'prepare-input.ps1' } else { Join-Path $project 'src\launcher\prepare-input.ps1' }
[IO.File]::Copy($inputSource, (Join-Path $package 'prepare-input.ps1'))
$settingsTemplate = [IO.File]::ReadAllText((Join-Path $PackageRoot 'launcher-settings.json'))
$launcherText = [IO.File]::ReadAllText($launcherSource)
$launcherPath = Join-Path $package 'prepare-and-start.ps1'
$settingsPath = Join-Path $package 'launcher-settings.json'
$iniPath = Join-Path $runtime 'ka_ai_duka.ini'
$luaSettings = Join-Path $ai 'runtime-settings.lua'
$nativeLog = Join-Path $runtime 'native-window.log'
$nativeExe = Join-Path $runtime 'th09ai-launcher.exe'
$windowsPowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$checks = 0
$runs = 0
$privateValues = @($AuthorizedKey, $RetiredKey, (' ' + $AuthorizedKey), ($AuthorizedKey + ' '), $AuthorizedKey.ToUpperInvariant(), $AuthorizedKey.ToLowerInvariant()) | Select-Object -Unique
$priorEnvironment = @{}
foreach ($name in @('TH09_AI_SIDE_KEY', 'TH09_AI_SIDE_AUTHORIZED', 'TH09_AI_1P_AUTHORIZED')) {
    $priorEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
function Check([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
    $script:checks++
}
function Read-IfPresent([string] $Path) {
    if ([IO.File]::Exists($Path)) { return [IO.File]::ReadAllText($Path) }
    return ''
}
function Clear-PrivateFixtures {
    # Always overwrite settings first. Never parse potentially private invalid
    # JSON during cleanup, because PowerShell errors may echo its input.
    if ([IO.File]::Exists($settingsPath)) {
        try { [IO.File]::WriteAllText($settingsPath, '{}', (New-Object Text.UTF8Encoding($false))) }
        catch { [IO.File]::Delete($settingsPath) }
    }
    $leaked = $false
    foreach ($file in @(Get-ChildItem -LiteralPath $fixture -Recurse -File | Where-Object { $_.Extension -in @('.log', '.ini', '.json', '.lua', '.ps1', '.c', '.h') })) {
        $content = [IO.File]::ReadAllText($file.FullName)
        $original = $content
        foreach ($candidate in $privateValues) {
            if ($candidate.Length -ge 4 -and $content.Contains($candidate)) {
                $content = $content.Replace($candidate, '[REDACTED]')
                $leaked = $true
            }
        }
        if ($content -cne $original) { [IO.File]::WriteAllText($file.FullName, $content, (New-Object Text.UTF8Encoding($true))) }
    }
    if ($leaked) { throw 'A private key appeared in test output; the owned output was redacted.' }
}
function Check-NoOwnedGame {
    $remaining = @(Get-Process -Name th09 -ErrorAction SilentlyContinue | Where-Object { $_.Path -ieq $testGame })
    foreach ($process in $remaining) { Stop-Process -Id $process.Id -ErrorAction SilentlyContinue }
    Check ($remaining.Count -eq 0) 'Owned suspended test process was left behind.'
}
function Invoke-Owned([string] $Name, [string] $Executable, [string[]] $Arguments, [int] $ExpectedExit, [string] $NativeKey = '') {
    $script:runs++
    $stdout = Join-Path $fixture ($Name + '-stdout.log')
    $stderr = Join-Path $fixture ($Name + '-stderr.log')
    $oldKey = [Environment]::GetEnvironmentVariable('TH09_AI_SIDE_KEY', 'Process')
    try {
        [Environment]::SetEnvironmentVariable('TH09_AI_SIDE_KEY', $NativeKey, 'Process')
        $process = Start-Process -FilePath $Executable -ArgumentList $Arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    } finally { [Environment]::SetEnvironmentVariable('TH09_AI_SIDE_KEY', $oldKey, 'Process') }
    $null = $process.Handle
    if (-not $process.WaitForExit(45000)) {
        Stop-Process -Id $process.Id -ErrorAction SilentlyContinue
        foreach ($child in @(Get-Process -Name th09 -ErrorAction SilentlyContinue | Where-Object { $_.Path -ieq $testGame })) {
            Stop-Process -Id $child.Id -ErrorAction SilentlyContinue
        }
        throw "Owned suspended test timed out: $Name"
    }
    $process.Refresh()
    # Do not echo process output on failure; it is scanned and sanitized below.
    Check ($process.ExitCode -eq $ExpectedExit) "Unexpected exit for ${Name}: $($process.ExitCode); expected $ExpectedExit. Inspect the sanitized fixture logs."
    $script:lastOutput = (Read-IfPresent $stdout) + (Read-IfPresent $stderr)
    Check-NoOwnedGame
}
function Write-Ini([int] $Side, [switch] $Forged) {
    $enabled1 = if ($Side -eq 1) { 'true' } else { 'false' }
    $enabled2 = if ($Side -eq 2) { 'true' } else { 'false' }
    $script1 = if ($Side -eq 1) { Join-Path $ai 'main.lua' } else { '' }
    $script2 = if ($Side -eq 2) { Join-Path $ai 'main.lua' } else { '' }
    $extra = if ($Forged) { "`r`nauthorized=true`r`nside_key_authorized=1`r`n1p_authorized=true" } else { '' }
    $ini = "[common]`r`nexe_path=$testGame`r`nsnapshot=false$extra`r`n[1P]`r`nenabled=$enabled1`r`nscript_path=$script1$extra`r`n[2P]`r`nenabled=$enabled2`r`nscript_path=$script2`r`n[practice]`r`nplayer1_no_damage=0`r`nplayer1_invincible=0`r`n[window]`r`nenabled=0`r`n"
    [IO.File]::WriteAllText($iniPath, $ini, [Text.Encoding]::Default)
}
function Invoke-Native([string] $Name, [int] $ExpectedExit, [string] $Key = '') {
    $before = Read-IfPresent $nativeLog
    Invoke-Owned $Name $nativeExe @(('"{0}"' -f $testGame), '--verify-suspended') $ExpectedExit $Key
    if ($ExpectedExit -eq 15) {
        Check ($lastOutput -match '1P native authorization failed') 'Native rejection reason was missing.'
        Check ((Read-IfPresent $nativeLog) -ceq $before) 'Rejected parent reached support initialization.'
    }
}
function Invoke-FullScript([string] $Name, [int] $Side, [string] $Key, [int] $ExpectedExit, [int] $ExpectedSide, [switch] $BypassScript) {
    $text = $script:suspendedLauncher
    if ($BypassScript) {
        $tokens = $null; $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$parseErrors)
        $functions = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Test-AiSideKey' }, $true))
        Check ($parseErrors.Count -eq 0 -and $functions.Count -eq 1) 'Cannot isolate the owned script key verifier.'
        $extent = $functions[0].Extent
        $text = $text.Substring(0, $extent.StartOffset) + 'function Test-AiSideKey($candidate) { return $true }' + $text.Substring($extent.EndOffset)
    }
    [IO.File]::WriteAllText($launcherPath, $text, (New-Object Text.UTF8Encoding($true)))
    $settings = ConvertFrom-Json $settingsTemplate
    $settings.ai | Add-Member -NotePropertyName side -NotePropertyValue $Side -Force
    $settings.ai | Add-Member -NotePropertyName side_key -NotePropertyValue $Key -Force
    $settings.window.enabled = $false
    [IO.File]::WriteAllText($settingsPath, ($settings | ConvertTo-Json -Depth 50), (New-Object Text.UTF8Encoding($true)))
    try {
        Invoke-Owned $Name $windowsPowerShell @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $launcherPath), '-GameRootOverride', ('"{0}"' -f $game)) $ExpectedExit
        if ($ExpectedExit -eq 0) { Check ($lastOutput -match ('PASS: AI=' + $ExpectedSide + 'P suspended-only')) 'Full script did not deliver the expected native side.' }
        else { Check ($lastOutput -match '1P native authorization failed') 'Forged script did not reach independent native rejection.' }
        $generated = (Read-IfPresent $iniPath) + (Read-IfPresent $luaSettings)
        Check ($generated -notmatch 'side_key|authorized') 'Generated runtime files contained an authorization field.'
    } finally { Clear-PrivateFixtures }
}
try {
    Check ([IO.File]::Exists($CompilerPath)) 'TinyCC is required for the independent support rejection fixture.'
    $invocationPattern = '(?m)^[ \t]*& \$launcherExe \$gameExe[ \t]*\r?$'
    Check ([regex]::Matches($launcherText, $invocationPattern).Count -eq 1) 'Expected exactly one real native invocation in startup script.'
    # Only this owned copy adds the non-playing verification argument. All
    # configuration, key checks, environment delivery and native calls remain.
    $script:suspendedLauncher = [regex]::Replace($launcherText, $invocationPattern, '  & $launcherExe $gameExe --verify-suspended')
    $recordMatch = [regex]::Match($launcherText, "(?m)^\s*\`$record = '([^']+)'\s*\r?$")
    Check $recordMatch.Success 'Public verifier record not found.'
    $publicRecord = $recordMatch.Groups[1].Value
    $publicVerifier = $publicRecord.Split([char]'$')[4]
    $publicVerifierHex = [BitConverter]::ToString([Convert]::FromBase64String($publicVerifier)).Replace('-', '')

    Write-Ini 1
    foreach ($case in @(
        @{ name='direct-missing'; key='' },
        @{ name='direct-wrong'; key='incorrect-public-test-key' },
        @{ name='direct-retired'; key=$RetiredKey },
        @{ name='direct-public-record'; key=$publicRecord },
        @{ name='direct-public-verifier'; key=$publicVerifier },
        @{ name='direct-public-verifier-hex'; key=$publicVerifierHex },
        @{ name='direct-key-leading-space'; key=(' ' + $AuthorizedKey) },
        @{ name='direct-key-trailing-space'; key=($AuthorizedKey + ' ') }
    )) { Invoke-Native $case.name 15 $case.key }
    Write-Ini 1 -Forged
    [Environment]::SetEnvironmentVariable('TH09_AI_SIDE_AUTHORIZED', '1', 'Process')
    [Environment]::SetEnvironmentVariable('TH09_AI_1P_AUTHORIZED', 'true', 'Process')
    Invoke-Native 'forged-authorization-flags' 15
    [Environment]::SetEnvironmentVariable('TH09_AI_SIDE_AUTHORIZED', $null, 'Process')
    [Environment]::SetEnvironmentVariable('TH09_AI_1P_AUTHORIZED', $null, 'Process')
    Write-Ini 1
    Invoke-Native 'direct-authorized-1p' 0 $AuthorizedKey
    Check ($lastOutput -match 'PASS: AI=1P suspended-only') 'Correct key did not authorize 1P.'
    Write-Ini 2
    Invoke-Native 'direct-unkeyed-2p' 0
    Check ($lastOutput -match 'PASS: AI=2P suspended-only') '2P unexpectedly required a key.'

    Invoke-FullScript 'script-authorized-1p' 1 $AuthorizedKey 0 1
    Invoke-FullScript 'script-unkeyed-2p' 2 '' 0 2
    Invoke-FullScript 'script-wrong-fallback-2p' 1 'incorrect-public-test-key' 0 2
    Invoke-FullScript 'script-retired-fallback-2p' 1 $RetiredKey 0 2
    Invoke-FullScript 'forged-script-missing' 1 '' 15 0 -BypassScript
    Invoke-FullScript 'forged-script-wrong' 1 'incorrect-public-test-key' 15 0 -BypassScript
    Invoke-FullScript 'forged-script-retired' 1 $RetiredKey 15 0 -BypassScript
    Invoke-FullScript 'forged-script-public-verifier' 1 $publicVerifier 15 0 -BypassScript

    # A test-only executable deliberately skips the PARENT verifier. The real,
    # unchanged support DLL must still independently deny missing/wrong keys.
    # This fixture additionally removes ResumeThread, even if mis-invoked.
    $nativeSource = if ($PSBoundParameters.ContainsKey('PackageRoot')) { Join-Path $PackageRoot 'source\src\native' } else { Join-Path $project 'src\native' }
    $parentSource = [IO.File]::ReadAllText((Join-Path $nativeSource 'launcher.c'))
    $gate = 'if (!Th09AuthorizeSideFromEnvironment(ai_side, FALSE))'
    $resume = 'if (ResumeThread(process.hThread) == (DWORD)-1) goto cleanup;'
    Check ([regex]::Matches($parentSource, [regex]::Escape($gate)).Count -eq 1) 'Native parent verifier location changed.'
    Check ([regex]::Matches($parentSource, [regex]::Escape($resume)).Count -eq 1) 'Native resume location changed.'
    $parentSource = $parentSource.Replace($gate, 'if (0) /* TEST ONLY: support must still reject */').Replace($resume, 'goto cleanup; /* TEST ONLY: never resume under any arguments */')
    $bypassSource = Join-Path $build 'launcher_parent_bypass.c'
    [IO.File]::WriteAllText($bypassSource, $parentSource, (New-Object Text.UTF8Encoding($false)))
    $bypassExe = Join-Path $build 'test-parent-bypass.exe'
    $compileLog = Join-Path $fixture 'compile-parent-bypass.log'
    & $CompilerPath -Wall -Werror ('-I' + $nativeSource) $bypassSource (Join-Path $nativeSource 'side_key_auth.c') -o $bypassExe -lshell32 -luser32 *> $compileLog
    Check ($LASTEXITCODE -eq 0) 'Test-only parent-bypass compilation failed.'
    [IO.File]::Copy($bypassExe, $nativeExe, $true)
    Write-Ini 1
    foreach ($case in @(
        @{ name='support-missing'; key='' },
        @{ name='support-wrong'; key='incorrect-public-test-key' },
        @{ name='support-retired'; key=$RetiredKey },
        @{ name='support-public-verifier'; key=$publicVerifier }
    )) {
        $before = Read-IfPresent $nativeLog
        Invoke-Native $case.name 10 $case.key
        $newLog = (Read-IfPresent $nativeLog).Substring($before.Length)
        Check ($newLog -match 'authorization.*(failed|FAILED)|auth.*(failed|FAILED)') 'Independent support rejection was not logged.'
        Check ($lastOutput -match 'initialization failed or timed out') 'Parent bypass did not fail at support initialization.'
    }
    Invoke-Native 'support-authorized-1p' 0 $AuthorizedKey
    Check ($lastOutput -match 'PASS: AI=1P suspended-only') 'Independent support verifier rejected the correct key.'
    Write-Ini 2
    Invoke-Native 'support-unkeyed-2p' 0
    Check ($lastOutput -match 'PASS: AI=2P suspended-only') 'Support changed unkeyed 2P behavior.'
    # Leave the owned fixture with production runtime, never a permissive test
    # launcher that could be mistaken for a release artifact.
    [IO.File]::Copy((Join-Path $PackageRoot 'runtime\th09ai-launcher.exe'), $nativeExe, $true)
    Check ((Get-FileHash -LiteralPath (Join-Path $SourceGameRoot 'th09.exe')).Hash -eq $originalExeHash) 'Source game executable changed.'
    Check ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $SourceGameRoot 'th09.cfg'))) -ceq [Convert]::ToBase64String($originalConfig)) 'Source game configuration changed.'
    Clear-PrivateFixtures
    Check ([IO.File]::ReadAllText($settingsPath) -ceq '{}') 'Owned JSON retained private settings.'
    Write-Output "PASS: $checks native-authorization bypass checks in $runs real process runs; suspended copies only, no playable game launched."
    Write-Output "Evidence: $fixture"
} finally {
    foreach ($name in $priorEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $priorEnvironment[$name], 'Process') }
    if ([IO.File]::Exists($nativeExe)) { [IO.File]::Copy((Join-Path $PackageRoot 'runtime\th09ai-launcher.exe'), $nativeExe, $true) }
    foreach ($child in @(Get-Process -Name th09 -ErrorAction SilentlyContinue | Where-Object { $_.Path -ieq $testGame })) {
        Stop-Process -Id $child.Id -ErrorAction SilentlyContinue
    }
    Clear-PrivateFixtures
}
