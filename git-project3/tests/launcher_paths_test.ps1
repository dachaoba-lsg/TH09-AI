param(
    [Parameter(Mandatory = $true)] [string] $SourceGame,
    [Parameter(Mandatory = $true)] [string] $SourceConfig,
    [string] $ProjectRoot = '',
    [string] $PackageRoot = ''
)
# PS5.1 migration regression. Only disposable work/ fixtures are writable;
# every launch is PrepareOnly, so no TH09 executable is ever started.
$ErrorActionPreference = 'Stop'
if (-not $ProjectRoot) { $ProjectRoot = Split-Path -Parent $PSScriptRoot }
$project = [IO.Path]::GetFullPath($ProjectRoot)
if (-not $PackageRoot) { $PackageRoot = Join-Path $project 'dist\TH09-AI' }
$sourceGamePath = (Resolve-Path -LiteralPath $SourceGame).ProviderPath
$sourceConfigPath = (Resolve-Path -LiteralPath $SourceConfig).ProviderPath
$originalConfig = [IO.File]::ReadAllBytes($sourceConfigPath)
if ($originalConfig.Length -ne 0xCC) { throw 'SourceConfig must be the supported 204-byte TH09 config.' }
$configBytes = [byte[]]$originalConfig.Clone()
$configBytes[0xB7] = 2
$configBytes[0xB8] = 3
$fixtureRoot = Join-Path $project ('work\launcher-paths-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixtureRoot)
$utf8Bom = New-Object Text.UTF8Encoding($true)
$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$sourceCmd = @(Get-ChildItem -LiteralPath (Join-Path $project 'src\launcher') -Filter '*.cmd' -File)
if ($sourceCmd.Count -ne 1) { throw 'Expected exactly one launcher CMD source.' }
$script:assertions = 0

function Assert-Test([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw ('FAIL: ' + $Message) }
    $script:assertions++
}
function Same-Bytes([byte[]] $Left, [byte[]] $Right) {
    if ($Left.Length -ne $Right.Length) { return $false }
    for ($index = 0; $index -lt $Left.Length; $index++) {
        if ($Left[$index] -ne $Right[$index]) { return $false }
    }
    return $true
}
function New-Game([string] $Directory, [switch] $InvalidExe) {
    [void][IO.Directory]::CreateDirectory($Directory)
    if ($InvalidExe) {
        [IO.File]::WriteAllBytes((Join-Path $Directory 'th09.exe'), [byte[]]@(0x4D, 0x5A, 0, 0))
    } else {
        [IO.File]::Copy($sourceGamePath, (Join-Path $Directory 'th09.exe'))
    }
    [IO.File]::WriteAllBytes((Join-Path $Directory 'th09.cfg'), $configBytes)
    return $Directory
}
function New-Package([string] $Directory) {
    [void][IO.Directory]::CreateDirectory((Join-Path $Directory 'runtime'))
    [void][IO.Directory]::CreateDirectory((Join-Path $Directory 'ai'))
    foreach ($name in @('prepare-and-start.ps1', 'prepare-input.ps1')) {
        $text = [IO.File]::ReadAllText((Join-Path $project ('src\launcher\' + $name))) -replace '\r?\n', "`r`n"
        [IO.File]::WriteAllText((Join-Path $Directory $name), $text, $utf8Bom)
    }
    $cmdText = [IO.File]::ReadAllText($sourceCmd[0].FullName) -replace '\r?\n', "`r`n"
    [IO.File]::WriteAllText((Join-Path $Directory $sourceCmd[0].Name), $cmdText, [Text.Encoding]::ASCII)
    foreach ($name in @('th09ai-launcher.exe', 'window_support.dll')) {
        [IO.File]::Copy((Join-Path $PackageRoot ('runtime\' + $name)), (Join-Path $Directory ('runtime\' + $name)))
    }
    [IO.File]::Copy((Join-Path $project 'vendor\release\ka_ai_duka\inject.dll'), (Join-Path $Directory 'runtime\inject.dll'))
    [IO.File]::Copy((Join-Path $project 'src\ai\main.lua'), (Join-Path $Directory 'ai\main.lua'))
    [IO.File]::Copy((Join-Path $PackageRoot 'launcher-settings.json'), (Join-Path $Directory 'launcher-settings.json'))
    return $Directory
}
function Run-Prepare([string] $Package, [string] $WorkingDirectory, [bool] $ViaCmd, [string] $Override = '') {
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.WorkingDirectory = $WorkingDirectory
    if ($ViaCmd) {
        if ($Override) { throw 'CMD fixture uses automatic game discovery only.' }
        $start.FileName = $env:ComSpec
        $cmdPath = Join-Path $Package $sourceCmd[0].Name
        $start.Arguments = '/d /s /c ""' + $cmdPath + '" -PrepareOnly"'
    } else {
        $start.FileName = $windowsPowerShell
        $start.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + (Join-Path $Package 'prepare-and-start.ps1') + '" -PrepareOnly'
        if ($Override) { $start.Arguments += ' -GameRootOverride "' + $Override + '"' }
    }
    $child = New-Object Diagnostics.Process
    $child.StartInfo = $start
    try {
        [void]$child.Start()
        # Closing stdin also prevents an unexpected CMD failure's pause from
        # hanging this test. Expected failure cases use direct PowerShell.
        $child.StandardInput.Close()
        $stdout = $child.StandardOutput.ReadToEndAsync()
        $stderr = $child.StandardError.ReadToEndAsync()
        if (-not $child.WaitForExit(30000)) {
            $child.Kill()
            throw 'PrepareOnly fixture timed out after 30 seconds.'
        }
        return [pscustomobject]@{
            ExitCode = $child.ExitCode
            Output = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
        }
    } finally { $child.Dispose() }
}
function Assert-Prepared([string] $Package, [string] $ExpectedGame, [string] $WorkingDirectory, [bool] $ViaCmd = $true, [string] $Override = '', [string] $OldRoot = '') {
    $config = Join-Path $ExpectedGame 'th09.cfg'
    $before = [IO.File]::ReadAllBytes($config)
    $result = Run-Prepare $Package $WorkingDirectory $ViaCmd $Override
    Assert-Test ($result.ExitCode -eq 0) ('PrepareOnly succeeds: ' + $result.Output)
    Assert-Test (Same-Bytes $before ([IO.File]::ReadAllBytes($config))) 'PrepareOnly preserves selected game config'
    $ini = [IO.File]::ReadAllText((Join-Path $Package 'runtime\ka_ai_duka.ini'), [Text.Encoding]::Default)
    $exePaths = [regex]::Matches($ini, '(?m)^exe_path=(?<value>[^\r\n]*)\r?$')
    $scriptPaths = [regex]::Matches($ini, '(?m)^script_path=(?<value>[^\r\n]*)\r?$')
    Assert-Test ($exePaths.Count -eq 1) 'INI has exactly one game path'
    Assert-Test ($exePaths[0].Groups['value'].Value -ceq (Join-Path $ExpectedGame 'th09.exe')) 'INI game path is the selected current fixture'
    Assert-Test ($scriptPaths.Count -eq 2 -and $scriptPaths[0].Groups['value'].Value -eq '') 'INI keeps 1P script empty'
    Assert-Test ($scriptPaths[1].Groups['value'].Value -ceq (Join-Path $Package 'ai\main.lua')) 'INI AI path follows the current package directory'
    Assert-Test (-not $ini.Contains($sourceGamePath)) 'INI contains no historical source game path'
    if ($OldRoot) { Assert-Test (-not $ini.Contains($OldRoot)) 'INI contains no pre-move fixture path' }
    Assert-Test ([IO.File]::Exists((Join-Path $Package 'ai\runtime-settings.lua'))) 'Runtime settings stay beside current AI script'
}
function Assert-Rejected([string] $Package, [string] $WorkingDirectory, [int] $ExpectedExit, [string] $Override = '') {
    $iniPath = Join-Path $Package 'runtime\ka_ai_duka.ini'
    $luaPath = Join-Path $Package 'ai\runtime-settings.lua'
    [IO.File]::WriteAllText($iniPath, 'preserve existing INI after failed discovery', [Text.Encoding]::ASCII)
    [IO.File]::WriteAllText($luaPath, 'return { seconds = 321 }', [Text.Encoding]::ASCII)
    $iniBefore = [IO.File]::ReadAllBytes($iniPath)
    $luaBefore = [IO.File]::ReadAllBytes($luaPath)
    $result = Run-Prepare $Package $WorkingDirectory $false $Override
    Assert-Test ($result.ExitCode -eq $ExpectedExit) ('Expected exit ' + $ExpectedExit + ': ' + $result.Output)
    Assert-Test (Same-Bytes $iniBefore ([IO.File]::ReadAllBytes($iniPath))) 'Failed discovery/version check preserves existing INI'
    Assert-Test (Same-Bytes $luaBefore ([IO.File]::ReadAllBytes($luaPath))) 'Failed discovery/version check preserves existing Lua settings'
}

try {
    # Build Chinese names without non-ASCII source bytes, keeping this test
    # directly readable by Windows PowerShell 5.1 without a required BOM.
    $chineseMoved = [string][char]0x8FC1 + [char]0x79FB + [char]0x76EE + [char]0x5F55
    $chineseCwd = [string][char]0x65E0 + [char]0x5173 + [char]0x76EE + [char]0x5F55
    $unrelatedCwd = Join-Path $fixtureRoot ($chineseCwd + ' [unrelated cwd]')
    [void][IO.Directory]::CreateDirectory($unrelatedCwd)
    [IO.File]::WriteAllBytes((Join-Path $unrelatedCwd 'th09.exe'), [byte[]]@(0x4D, 0x5A))

    $directGame = New-Game (Join-Path $fixtureRoot '[direct] game')
    $directPackage = New-Package (Join-Path $directGame 'TH09-AI')
    Assert-Prepared $directPackage $directGame $unrelatedCwd

    $oneWrapGame = New-Game (Join-Path $fixtureRoot '[one wrapper] game')
    $oneWrapPackage = New-Package (Join-Path $oneWrapGame 'TH09-AI-v0.1.5-test\TH09-AI')
    Assert-Prepared $oneWrapPackage $oneWrapGame $unrelatedCwd

    $twoWrapGame = New-Game (Join-Path $fixtureRoot '[two wrappers] old game')
    $twoWrapRelative = 'download archive\TH09-AI-v0.1.5-test\TH09-AI'
    $twoWrapPackage = New-Package (Join-Path $twoWrapGame $twoWrapRelative)
    Assert-Prepared $twoWrapPackage $twoWrapGame $unrelatedCwd
    $movedGame = Join-Path $fixtureRoot ($chineseMoved + ' [moved] renamed game')
    # The only directory move is of our exact disposable fixture. Resolve and
    # verify both absolute targets remain strictly inside this unique work dir.
    $fixturePrefix = [IO.Path]::GetFullPath($fixtureRoot).TrimEnd('\') + '\'
    foreach ($target in @($twoWrapGame, $movedGame)) {
        Assert-Test ([IO.Path]::GetFullPath($target).StartsWith($fixturePrefix, [StringComparison]::OrdinalIgnoreCase)) 'Move target is within this disposable fixture root'
    }
    Assert-Test (-not [IO.Directory]::Exists($movedGame)) 'Move destination does not overwrite any directory'
    [IO.Directory]::Move($twoWrapGame, $movedGame)
    Assert-Test (-not [IO.Directory]::Exists($twoWrapGame)) 'Old fixture directory no longer exists after actual move'
    $movedPackage = Join-Path $movedGame $twoWrapRelative
    Assert-Prepared $movedPackage $movedGame $unrelatedCwd $true '' $twoWrapGame

    # No file exists on this package's ancestor chain. A game placed in a
    # descendant must not be found by recursive search or a historical fallback.
    $missingRoot = Join-Path $fixtureRoot '[missing ancestor]'
    $missingPackage = New-Package (Join-Path $missingRoot 'TH09-AI')
    $descendantGame = New-Game (Join-Path $missingRoot 'other child game')
    $ancestor = [IO.Directory]::GetParent($missingPackage)
    while ($null -ne $ancestor) {
        Assert-Test (-not [IO.File]::Exists((Join-Path $ancestor.FullName 'th09.exe'))) 'Missing-game fixture has no ancestor executable'
        $ancestor = $ancestor.Parent
    }
    Assert-Rejected $missingPackage $unrelatedCwd 2

    # The nearest existing executable is authoritative, even if invalid; a
    # valid higher ancestor must not silently take its place.
    $higherGame = New-Game (Join-Path $fixtureRoot '[valid higher game]')
    $nearestInvalid = New-Game (Join-Path $higherGame '[invalid nearest game]') -InvalidExe
    $nearestPackage = New-Package (Join-Path $nearestInvalid 'TH09-AI')
    Assert-Rejected $nearestPackage $unrelatedCwd 6

    # Explicit override wins over automatic discovery, including the invalid
    # nearest executable. Missing/invalid overrides must fail rather than heal.
    $overrideGame = New-Game (Join-Path $fixtureRoot '[explicit override] game')
    Assert-Prepared $nearestPackage $overrideGame $unrelatedCwd $false $overrideGame
    $missingOverride = Join-Path $directGame '[missing explicit override]'
    [void][IO.Directory]::CreateDirectory($missingOverride)
    Assert-Rejected $directPackage $unrelatedCwd 2 $missingOverride
    Assert-Rejected $directPackage $unrelatedCwd 6 $nearestInvalid

    Assert-Test (Same-Bytes $originalConfig ([IO.File]::ReadAllBytes($sourceConfigPath))) 'User game config was never changed'
    Write-Output ('PASS: {0} assertions; parent/wrapped/moved paths, unrelated CMD cwd, nearest executable and explicit override; no game launched.' -f $script:assertions)
    Write-Output ('Fixtures retained for inspection: ' + $fixtureRoot)
} catch {
    Write-Output ('Fixtures retained for inspection: ' + $fixtureRoot)
    throw
}
