param(
    [Parameter(Mandatory = $true)] [string] $SourceGameRoot,
    [string] $ProjectRoot = '',
    [string] $PackageRoot = '',
    [switch] $VerifySuspended,
    [string] $AuthorizedKey = $env:TH09_TEST_SIDE_KEY
)
# Exercise real Windows PowerShell JSON -> startup INI generation in an owned
# game/package copy. -PrepareOnly never starts a game or injects a DLL.
$ErrorActionPreference = 'Stop'
if (-not $ProjectRoot) { $ProjectRoot = Split-Path -Parent $PSScriptRoot }
$project = [IO.Path]::GetFullPath($ProjectRoot)
if (-not $PackageRoot) { $PackageRoot = Join-Path $project 'dist\TH09-AI' }
$fixture = Join-Path $project ('work\ai-side-launcher-' + [Guid]::NewGuid().ToString('N'))
$game = Join-Path $fixture '[game copy]'
$package = Join-Path $game '[AI package]'
$runtime = Join-Path $package 'runtime'
$ai = Join-Path $package 'ai'
foreach ($path in @($runtime, $ai)) { [void][IO.Directory]::CreateDirectory($path) }
$originalConfig = [IO.File]::ReadAllBytes((Join-Path $SourceGameRoot 'th09.cfg'))
$originalExeHash = (Get-FileHash -LiteralPath (Join-Path $SourceGameRoot 'th09.exe')).Hash
[IO.File]::Copy((Join-Path $SourceGameRoot 'th09.exe'), (Join-Path $game 'th09.exe'))
if ($VerifySuspended) {
    foreach ($dependency in [IO.Directory]::GetFiles($SourceGameRoot, '*.dll')) {
        [IO.File]::Copy($dependency, (Join-Path $game ([IO.Path]::GetFileName($dependency))))
    }
}
$fixtureConfig = [byte[]]$originalConfig.Clone()
$fixtureConfig[0xB7] = 2
$fixtureConfig[0xB8] = 3
[IO.File]::WriteAllBytes((Join-Path $game 'th09.cfg'), $fixtureConfig)
foreach ($name in @('inject.dll','window_support.dll','th09ai-launcher.exe')) {
    [IO.File]::Copy((Join-Path $PackageRoot ('runtime\' + $name)), (Join-Path $runtime $name))
}
foreach ($name in @('prepare-input.ps1','prepare-and-start.ps1')) {
    $source = if ($PSBoundParameters.ContainsKey('PackageRoot')) { Join-Path $PackageRoot $name } else { Join-Path $project ('src\launcher\' + $name) }
    [IO.File]::WriteAllText((Join-Path $package $name), [IO.File]::ReadAllText($source), (New-Object Text.UTF8Encoding($true)))
}
[IO.File]::Copy((Join-Path $PackageRoot 'ai\main.lua'), (Join-Path $ai 'main.lua'))
$settingsPath = Join-Path $package 'launcher-settings.json'
$iniPath = Join-Path $runtime 'ka_ai_duka.ini'
$luaPath = Join-Path $ai 'runtime-settings.lua'
$windowsPowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$checks = 0
$runs = 0
$verifiedSides = @{}
$hasAuthorizedKey = -not [string]::IsNullOrEmpty($AuthorizedKey)
function Check([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
    $script:checks++
}
function Bytes([string] $Path) { return [Convert]::ToBase64String([IO.File]::ReadAllBytes($Path)) }
function New-Settings {
    return ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $PackageRoot 'launcher-settings.json')))
}
function Run-Prepare($Settings) {
    $script:runs++
    $log = Join-Path $fixture ('prepare-' + $script:runs + '.log')
    $old = $ErrorActionPreference
    try {
        [IO.File]::WriteAllText($settingsPath, ($Settings | ConvertTo-Json -Depth 50), (New-Object Text.UTF8Encoding($true)))
        $before = Bytes $settingsPath
        $ErrorActionPreference = 'Continue'
        & $windowsPowerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $package 'prepare-and-start.ps1') -GameRootOverride $game -PrepareOnly *> $log
        $code = $LASTEXITCODE
        $ErrorActionPreference = $old
        Check ((Bytes $settingsPath) -eq $before) 'Preparing must not rewrite user JSON.'
        Check ((Bytes (Join-Path $game 'th09.cfg')) -eq [Convert]::ToBase64String($fixtureConfig)) 'Selecting AI side changed keyboard configuration.'
        $script:lastPrepareLog = [IO.File]::ReadAllText($log)
        foreach ($outputPath in @($log, $iniPath, $luaPath)) {
            if (-not [IO.File]::Exists($outputPath)) { continue }
            $content = [IO.File]::ReadAllText($outputPath)
            if ($hasAuthorizedKey -and $content.Contains($AuthorizedKey)) {
                [IO.File]::WriteAllText($outputPath, $content.Replace($AuthorizedKey, '[REDACTED]'), (New-Object Text.UTF8Encoding($false)))
                throw 'Authorized key appeared in generated output; output was redacted.'
            }
            Check ($content -notmatch 'side_key') 'Side key field leaked into generated output.'
        }
    } finally {
        $ErrorActionPreference = $old
        $cleanupFailed = $false
        # Scrub the owned JSON first, without parsing it again: an unexpected
        # parse failure in PS5.1 could echo a private value. A later log I/O
        # failure must not prevent this step from running.
        if ([IO.File]::Exists($settingsPath)) {
            try {
                [IO.File]::WriteAllText($settingsPath, '{}', (New-Object Text.UTF8Encoding($false)))
            } catch {
                try { [IO.File]::Delete($settingsPath) }
                catch { $cleanupFailed = $true }
            }
        }
        # Redact independently of assertions, so even a failing test cannot
        # leave the private authorized value in diagnostic/generated files.
        # Attempt every file even if another output cannot be read or written.
        foreach ($outputPath in @($log, $iniPath, $luaPath)) {
            try {
                if (-not [IO.File]::Exists($outputPath)) { continue }
                $content = [IO.File]::ReadAllText($outputPath)
                if ($hasAuthorizedKey -and $content.Contains($AuthorizedKey)) {
                    [IO.File]::WriteAllText($outputPath, $content.Replace($AuthorizedKey, '[REDACTED]'), (New-Object Text.UTF8Encoding($false)))
                }
            } catch { $cleanupFailed = $true }
        }
        if ($cleanupFailed) { throw 'Private fixture cleanup failed; inspect the owned test directory before continuing.' }
    }
    return $code
}
function Read-Ini {
    $result = @{}
    $section = ''
    foreach ($line in ([IO.File]::ReadAllText($iniPath) -split '\r?\n')) {
        if ($line -match '^\[([^\]]+)\]$') { $section = $Matches[1]; $result[$section] = @{} }
        elseif ($line -match '^([^=]+)=(.*)$') { $result[$section][$Matches[1]] = $Matches[2] }
    }
    return $result
}
function Expect-Side([int] $Side, [int] $NoDamage, [int] $Invincible) {
    $ini = Read-Ini
    $other = 3 - $Side
    Check ($ini[($Side.ToString() + 'P')].enabled -eq 'true') 'Selected AI side not enabled.'
    Check ($ini[($other.ToString() + 'P')].enabled -eq 'false') 'Human side must remain disabled.'
    Check ($ini[($Side.ToString() + 'P')].script_path -eq (Join-Path $ai 'main.lua')) 'Script was assigned to the wrong side.'
    Check ($ini[($other.ToString() + 'P')].script_path -eq '') 'Human side must have no AI script.'
    Check ($ini.practice.player1_no_damage -eq $NoDamage.ToString()) 'Wrong effective 1P no-damage setting.'
    Check ($ini.practice.player1_invincible -eq $Invincible.ToString()) 'Wrong effective 1P invincibility setting.'
    Check ($ini.common.exe_path -eq (Join-Path $game 'th09.exe')) 'Relocated game path was lost.'
    Check ($ini.common.run_while_replay -eq 'false') 'Replay handling changed.'
}

# Older 3.3 settings have no side option: retain the original 2P behavior.
$settings = New-Settings
$settings.ai.PSObject.Properties.Remove('side')
Check ((Run-Prepare $settings) -eq 0) 'Old settings without side were rejected.'
Expect-Side 2 0 0
$settings.PSObject.Properties.Remove('ai')
Check ((Run-Prepare $settings) -eq 0) 'Old settings without ai were rejected.'
Expect-Side 2 0 0

# Missing/wrong/type-invalid keys fall back before practice and INI derivation.
# These values are public test sentinels, never the actual authorized value.
foreach ($candidate in @('', 'incorrect-test-key', '  ', 1, $true, $false, $null, @(1,2), @{ value='test' })) {
    foreach ($side in @(1,2)) {
        $settings = New-Settings
        $settings.ai | Add-Member -NotePropertyName side -NotePropertyValue $side -Force
        $settings.ai | Add-Member -NotePropertyName side_key -NotePropertyValue $candidate -Force
        $settings.practice.player1_no_damage = $true
        $settings.practice.player1_invincible = $true
        Check ((Run-Prepare $settings) -eq 0) 'Invalid/missing side key should use 2P, not reject startup.'
        Expect-Side 2 1 1
        Check (($lastPrepareLog -match '1P接管key未通过') -eq ($side -eq 1)) 'Key fallback hint did not match requested side.'
    }
}
$settings = New-Settings
$settings.ai.side = 1
$settings.ai.PSObject.Properties.Remove('side_key')
$settings.practice.player1_no_damage = $true
Check ((Run-Prepare $settings) -eq 0) 'Missing side key should use 2P.'
Expect-Side 2 1 0
Check ($lastPrepareLog -match '1P接管key未通过') 'Missing side key did not explain fallback.'

# Round-trip switches prove there is no stale binding left in the previous side.
# Without private test authorization these requests must consistently use 2P.
foreach ($side in @(1,2,1,2)) {
    foreach ($practice in @(@($false,$false),@($true,$false),@($false,$true),@($true,$true))) {
        $settings = New-Settings
        $settings.ai | Add-Member -NotePropertyName side -NotePropertyValue $side -Force
        if ($hasAuthorizedKey) { $settings.ai | Add-Member -NotePropertyName side_key -NotePropertyValue $AuthorizedKey -Force }
        $settings.ai | Add-Member -NotePropertyName enabled -NotePropertyValue $false -Force
        $settings.ai.difficulty = 'human300'
        $settings.ai.vision_radius = 180
        $settings.practice.player1_no_damage = $practice[0]
        $settings.practice.player1_invincible = $practice[1]
        Check ((Run-Prepare $settings) -eq 0) 'Valid side/practice combination rejected.'
        $effectiveSide = if ($side -eq 1 -and $hasAuthorizedKey) { 1 } else { 2 }
        $damage = if ($effectiveSide -eq 2) { [int]$practice[0] } else { 0 }
        $invincible = if ($effectiveSide -eq 2) { [int]$practice[1] } else { 0 }
        Expect-Side $effectiveSide $damage $invincible
        $lua = [IO.File]::ReadAllText($luaPath)
        Check ($lua -match 'difficulty\s*=\s*"human300"' -and $lua -match 'vision_radius\s*=\s*180\b') 'Side selection changed ability settings.'
        Check ($lua -match 'enabled\s*=\s*false') 'Attention enabled flag was confused with AI takeover.'
        if ($VerifySuspended -and -not $verifiedSides.ContainsKey($effectiveSide) -and $practice[0] -and $practice[1]) {
            # Connect the real JSON-generated INI to the real compiled native
            # launcher. It must never resume this owned game copy's main thread.
            $output = & (Join-Path $runtime 'th09ai-launcher.exe') (Join-Path $game 'th09.exe') --verify-suspended
            Check ($LASTEXITCODE -eq 0) 'Native launcher rejected generated side configuration.'
            Check (($output -join '\n') -match ('PASS: AI=' + $effectiveSide + 'P suspended-only')) 'Native launcher selected a different side than JSON.'
            $verifiedSides[$effectiveSide] = $true
        }
    }
}

# Exact matching: whitespace and case changes are not normalized or accepted.
if ($hasAuthorizedKey) {
    # Preserve the saved side=1 request while effective ownership follows
    # valid -> invalid -> valid authorization, with no stale practice/INI state.
    foreach ($attempt in @(
        @{ value=$AuthorizedKey; effective=1 },
        @{ value='incorrect-test-key'; effective=2 },
        @{ value=$AuthorizedKey; effective=1 }
    )) {
        $settings = New-Settings
        $settings.ai.side = 1
        $settings.ai | Add-Member -NotePropertyName side_key -NotePropertyValue $attempt.value -Force
        $settings.practice.player1_no_damage = $true
        $settings.practice.player1_invincible = $true
        Check ((Run-Prepare $settings) -eq 0) 'Valid/invalid/valid key sequence rejected startup.'
        $protection = if ($attempt.effective -eq 2) { 1 } else { 0 }
        Expect-Side $attempt.effective $protection $protection
        Check (($lastPrepareLog -match '1P接管key未通过') -eq ($attempt.effective -eq 2)) 'Key sequence fallback hint does not match effective side.'
        Check ($settings.ai.side -eq 1 -and $settings.practice.player1_no_damage -and $settings.practice.player1_invincible) 'Key sequence changed saved request/protection fields.'
    }
    $variants = @((' ' + $AuthorizedKey), ($AuthorizedKey + ' '), ($AuthorizedKey + "`n"))
    if ($AuthorizedKey.ToUpperInvariant() -cne $AuthorizedKey) { $variants += $AuthorizedKey.ToUpperInvariant() }
    if ($AuthorizedKey.ToLowerInvariant() -cne $AuthorizedKey) { $variants += $AuthorizedKey.ToLowerInvariant() }
    foreach ($variant in $variants) {
        $settings = New-Settings
        $settings.ai.side = 1
        $settings.ai | Add-Member -NotePropertyName side_key -NotePropertyValue $variant -Force
        Check ((Run-Prepare $settings) -eq 0) 'Non-exact key should use 2P.'
        Expect-Side 2 0 0
        Check ($lastPrepareLog -match '1P接管key未通过') 'Non-exact key did not explain fallback.'
    }
}

# Reject malformed selection before either previously valid generated file changes.
$invalid = @(0,3,-1,1.5,'1','2','1P',$true,$false,$null,@(1,2),@{value=1})
foreach ($value in $invalid) {
    $settings = New-Settings
    $settings.ai | Add-Member -NotePropertyName side -NotePropertyValue $value -Force
    $oldIni = Bytes $iniPath
    $oldLua = Bytes $luaPath
    Check ((Run-Prepare $settings) -ne 0) 'Invalid AI side was accepted.'
    Check ((Bytes $iniPath) -eq $oldIni) 'Rejected selection overwrote last valid INI.'
    Check ((Bytes $luaPath) -eq $oldLua) 'Rejected selection overwrote last valid Lua settings.'
}
# PS5.1's raw JSON exception echoes unquoted primitive values. The launcher
# must report a generic syntax error without exposing a key-shaped value.
$syntaxSentinel = 'unquoted_private_test_sentinel'
$badJson = '{"ai":{"side":1,"side_key":' + $syntaxSentinel + '}}'
$oldIni = Bytes $iniPath
$oldLua = Bytes $luaPath
$syntaxLog = Join-Path $fixture 'malformed-settings.log'
try {
    $runs++
    [IO.File]::WriteAllText($settingsPath, $badJson, (New-Object Text.UTF8Encoding($false)))
    $oldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $windowsPowerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $package 'prepare-and-start.ps1') -GameRootOverride $game -PrepareOnly *> $syntaxLog
        $syntaxCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $oldPreference }
    $syntaxOutput = [IO.File]::ReadAllText($syntaxLog)
    Check ($syntaxCode -eq 14) 'Malformed JSON was not rejected.'
    Check (-not $syntaxOutput.Contains($syntaxSentinel)) 'JSON parse error exposed a private value.'
    Check ($syntaxOutput -notmatch 'side_key') 'JSON parse error exposed a field-level exception.'
    Check ((Bytes $iniPath) -eq $oldIni -and (Bytes $luaPath) -eq $oldLua) 'Malformed JSON changed generated settings.'
} finally {
    [IO.File]::WriteAllText($settingsPath, '{}', (New-Object Text.UTF8Encoding($false)))
}
Check ((Bytes (Join-Path $SourceGameRoot 'th09.cfg')) -eq [Convert]::ToBase64String($originalConfig)) 'Original game config changed.'
Check ((Get-FileHash -LiteralPath (Join-Path $SourceGameRoot 'th09.exe')).Hash -eq $originalExeHash) 'Original game executable changed.'
if ($VerifySuspended) {
    $expectedSides = if ($hasAuthorizedKey) { 2 } else { 1 }
    Check ($verifiedSides.Count -eq $expectedSides) 'All authorized effective sides must reach native initialization.'
}
Check ([IO.File]::ReadAllText($settingsPath) -notmatch 'side_key') 'Temporary side key was left in fixture JSON.'
Write-Output "PASS: $checks AI-side launcher checks in $runs real PS5.1 preparation runs; $($verifiedSides.Count) suspended native checks; no playable game launched."
if (-not $hasAuthorizedKey) { Write-Output 'SKIP: authorized-key cases require -AuthorizedKey or TH09_TEST_SIDE_KEY; fallback cases passed.' }
Write-Output "Evidence: $fixture"
