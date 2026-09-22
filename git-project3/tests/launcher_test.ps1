param(
    [Parameter(Mandatory = $true)] [string] $SourceConfig,
    [string] $ProjectRoot = '',
    [string] $PackageRoot = '',
    [string] $SourceGame = ''
)
# Run with Windows PowerShell 5.1. Only disposable fixture copies are modified.
# This test never starts TH09 and never writes to the user's game directory.
$ErrorActionPreference = 'Stop'
if (-not $ProjectRoot) { $ProjectRoot = Split-Path -Parent $PSScriptRoot }
$project = [IO.Path]::GetFullPath($ProjectRoot)
$helper = Join-Path $project 'src\launcher\prepare-input.ps1'
$source = [IO.Path]::GetFullPath($SourceConfig)
$original = [IO.File]::ReadAllBytes($source)
if ($original.Length -ne 0xCC) { throw 'SourceConfig must be the supported 204-byte TH09 config.' }
$fixtureRoot = Join-Path $project ('work\launcher-tests-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixtureRoot)
$script:assertions = 0

function Assert-Test([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw ('FAIL: ' + $Message) }
    $script:assertions++
}
function Same-Bytes([byte[]] $Left, [byte[]] $Right) {
    if ($Left.Length -ne $Right.Length) { return $false }
    for ($offset = 0; $offset -lt $Left.Length; $offset++) {
        if ($Left[$offset] -ne $Right[$offset]) { return $false }
    }
    return $true
}
function New-Fixture([string] $Name, [byte[]] $Bytes) {
    $directory = Join-Path $fixtureRoot ('[' + $Name + '] game copy')
    [void][IO.Directory]::CreateDirectory($directory)
    [IO.File]::WriteAllBytes((Join-Path $directory 'th09.cfg'), $Bytes)
    return $directory
}
function Get-Backups([string] $Directory) {
    return @(Get-ChildItem -LiteralPath $Directory -File |
        Where-Object { $_.Name -like 'th09.cfg.before-ai-input-v014-*.bak' })
}
function Expect-Rejection([string] $Directory, [string] $ExpectedText, [bool] $CheckOnly = $false) {
    $config = Join-Path $Directory 'th09.cfg'
    $before = [IO.File]::ReadAllBytes($config)
    $rejected = $false
    try { & $helper -GameRoot $Directory -CheckOnly:$CheckOnly | Out-Null }
    catch {
        $rejected = $true
        Assert-Test ($_.Exception.Message -like ('*' + $ExpectedText + '*')) 'Clear rejection reason'
    }
    Assert-Test $rejected 'Unsupported input configuration must be rejected'
    Assert-Test (Same-Bytes $before ([IO.File]::ReadAllBytes($config))) 'Rejected config remains unchanged'
    Assert-Test (@(Get-Backups $Directory).Count -eq 0) 'Rejected config creates no backup'
}

try {
    # Preserve actual config bytes except explicit mode fixture preconditions.
    # Obsolete VK/DIK arrays may contain arbitrary values and must survive.
    $baseline = [byte[]]$original.Clone()
    $baseline[0xB7] = 2
    foreach ($oldP2Type in @(0, 1, 2, 4)) {
        $before = [byte[]]$baseline.Clone()
        $before[0xB8] = $oldP2Type
        $directory = New-Fixture ('P2 type ' + $oldP2Type) $before
        $config = Join-Path $directory 'th09.cfg'
        & $helper -GameRoot $directory -CheckOnly | Out-Null
        Assert-Test (Same-Bytes $before ([IO.File]::ReadAllBytes($config))) 'CheckOnly never writes config'
        Assert-Test (@(Get-Backups $directory).Count -eq 0) 'CheckOnly creates no backup'
        & $helper -GameRoot $directory | Out-Null
        $changed = [IO.File]::ReadAllBytes($config)
        Assert-Test ($changed.Length -eq 0xCC) 'Length preserved'
        Assert-Test ($changed[0xB7] -eq 2) '1P remains FULL'
        Assert-Test ($changed[0xB8] -eq 3) '2P becomes LEFT for native remapping'
        $differences = @()
        for ($offset = 0; $offset -lt $before.Length; $offset++) {
            if ($before[$offset] -ne $changed[$offset]) { $differences += $offset }
        }
        Assert-Test ($differences.Count -eq 1 -and $differences[0] -eq 0xB8) 'Only cfg[0xB8] changes'
        $backups = @(Get-Backups $directory)
        Assert-Test ($backups.Count -eq 1) 'Exactly one backup after first change'
        Assert-Test (Same-Bytes $before ([IO.File]::ReadAllBytes($backups[0].FullName))) 'Backup exactly matches original fixture'
        & $helper -GameRoot $directory | Out-Null
        & $helper -GameRoot $directory -CheckOnly | Out-Null
        Assert-Test (Same-Bytes $changed ([IO.File]::ReadAllBytes($config))) 'Repeated runs remain byte-identical'
        Assert-Test (@(Get-Backups $directory).Count -eq 1) 'Repeated runs create no additional backup'
        [IO.File]::Copy($backups[0].FullName, $config, $true)
        Assert-Test (Same-Bytes $before ([IO.File]::ReadAllBytes($config))) 'Backup restores original fixture exactly'
    }
    $alreadyPrepared = [byte[]]$baseline.Clone()
    $alreadyPrepared[0xB8] = 3
    $directory = New-Fixture 'already prepared' $alreadyPrepared
    & $helper -GameRoot $directory | Out-Null
    & $helper -GameRoot $directory -CheckOnly | Out-Null
    Assert-Test (Same-Bytes $alreadyPrepared ([IO.File]::ReadAllBytes((Join-Path $directory 'th09.cfg')))) 'Already prepared input stays intact'
    Assert-Test (@(Get-Backups $directory).Count -eq 0) 'Already prepared input creates no backup'
    foreach ($length in @(203, 205)) {
        $invalid = New-Object byte[] $length
        [Array]::Copy($baseline, $invalid, [Math]::Min($length, $baseline.Length))
        $directory = New-Fixture ('invalid length ' + $length) $invalid
        Expect-Rejection $directory 'Unknown th09.cfg layout'
        Expect-Rejection $directory 'Unknown th09.cfg layout' $true
    }
    # Reject non-FULL 1P even if 2P is already LEFT. No early success bypass.
    foreach ($p1Type in @(0, 1, 3, 4, 255)) {
        foreach ($p2Type in @(2, 3)) {
            $invalid = [byte[]]$baseline.Clone()
            $invalid[0xB7] = $p1Type
            $invalid[0xB8] = $p2Type
            $directory = New-Fixture ('reject P1 ' + $p1Type + ' P2 ' + $p2Type) $invalid
            Expect-Rejection $directory 'requires 1P Type=FULL'
            Expect-Rejection $directory 'requires 1P Type=FULL' $true
        }
    }
    foreach ($scriptPath in @($helper, (Join-Path $project 'src\launcher\prepare-and-start.ps1'))) {
        $tokens = $null
        $parseErrors = $null
        # Sources are UTF-8; build-package.ps1 adds the BOM for PS5.1 releases.
        [void][Management.Automation.Language.Parser]::ParseInput([IO.File]::ReadAllText($scriptPath), [ref]$tokens, [ref]$parseErrors)
        Assert-Test ($parseErrors.Count -eq 0) ('Windows PowerShell parser: ' + $scriptPath + ' ' + ($parseErrors | Out-String))
    }
    if ($PackageRoot) {
        foreach ($name in @('prepare-input.ps1', 'prepare-and-start.ps1')) {
            $scriptPath = Join-Path $PackageRoot $name
            Assert-Test ([IO.File]::Exists($scriptPath)) ('Packaged script exists: ' + $scriptPath)
            $tokens = $null
            $parseErrors = $null
            [void][Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
            Assert-Test ($parseErrors.Count -eq 0) ('PS5.1 reads packaged encoding: ' + $scriptPath + ' ' + ($parseErrors | Out-String))
        }
    }

    # Exercise the actual launcher in a separate PS5.1 process because it
    # intentionally exits. -PrepareOnly ensures no launcher/game executable is
    # ever run. Everything writable below is an isolated copy under work/.
    if (-not $SourceGame) { $SourceGame = Join-Path (Split-Path -Parent $source) 'th09.exe' }
    $sourceGamePath = (Resolve-Path -LiteralPath $SourceGame).ProviderPath
    $practiceGame = New-Fixture 'practice settings' $baseline
    [IO.File]::Copy($sourceGamePath, (Join-Path $practiceGame 'th09.exe'))
    $practicePackage = Join-Path $practiceGame '[TH09-AI] package'
    $practiceRuntime = Join-Path $practicePackage 'runtime'
    [void][IO.Directory]::CreateDirectory($practiceRuntime)
    [void][IO.Directory]::CreateDirectory((Join-Path $practicePackage 'ai'))
    $runtimeSource = if ($PackageRoot) { Join-Path $PackageRoot 'runtime' } else { Join-Path $project 'dist\TH09-AI\runtime' }
    foreach ($name in @('th09ai-launcher.exe', 'window_support.dll')) {
        [IO.File]::Copy((Join-Path $runtimeSource $name), (Join-Path $practiceRuntime $name))
    }
    [IO.File]::Copy((Join-Path $project 'vendor\release\ka_ai_duka\inject.dll'), (Join-Path $practiceRuntime 'inject.dll'))
    [IO.File]::Copy((Join-Path $project 'src\ai\main.lua'), (Join-Path $practicePackage 'ai\main.lua'))
    $utf8Bom = New-Object Text.UTF8Encoding($true)
    foreach ($name in @('prepare-and-start.ps1', 'prepare-input.ps1')) {
        $launcherSource = Join-Path $project ('src\launcher\' + $name)
        [IO.File]::WriteAllText((Join-Path $practicePackage $name), [IO.File]::ReadAllText($launcherSource), $utf8Bom)
    }
    $practiceLauncher = Join-Path $practicePackage 'prepare-and-start.ps1'
    $practiceSettingsPath = Join-Path $practicePackage 'launcher-settings.json'
    $practiceIniPath = Join-Path $practiceRuntime 'ka_ai_duka.ini'
    $runtimeSettingsPath = Join-Path $practicePackage 'ai\runtime-settings.lua'
    $practiceConfigPath = Join-Path $practiceGame 'th09.cfg'
    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $windowDefaults = @{ enabled = $true; width = 960; height = 720; resizable = $true; keep_aspect = $true }

    function Invoke-PracticeFixture([object] $Settings, [int] $ExpectedExit, [string] $CaseName, [string] $RawJson = '') {
        $settingsJson = if ($RawJson) { $RawJson } else { ConvertTo-Json $Settings -Depth 8 }
        [IO.File]::WriteAllText($practiceSettingsPath, $settingsJson, $utf8Bom)
        $configBefore = [IO.File]::ReadAllBytes($practiceConfigPath)
        $iniBefore = if ([IO.File]::Exists($practiceIniPath)) { [IO.File]::ReadAllBytes($practiceIniPath) } else { $null }
        $runtimeBefore = if ([IO.File]::Exists($runtimeSettingsPath)) { [IO.File]::ReadAllBytes($runtimeSettingsPath) } else { $null }
        $childOutput = @(& $windowsPowerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $practiceLauncher -GameRootOverride $practiceGame -PrepareOnly 2>&1)
        $childExit = $LASTEXITCODE
        Assert-Test ($childExit -eq $ExpectedExit) ("$CaseName exit=$childExit expected=$ExpectedExit output=" + ($childOutput -join ' '))
        Assert-Test (Same-Bytes $configBefore ([IO.File]::ReadAllBytes($practiceConfigPath))) ("$CaseName does not change game config")
        Assert-Test (@(Get-Backups $practiceGame).Count -eq 0) ("$CaseName does not create input backup")
        if ($ExpectedExit -ne 0) {
            if ($null -eq $iniBefore) {
                Assert-Test (-not [IO.File]::Exists($practiceIniPath)) ("$CaseName does not create INI")
            } else {
                Assert-Test (Same-Bytes $iniBefore ([IO.File]::ReadAllBytes($practiceIniPath))) ("$CaseName preserves previous INI")
            }
            if ($null -eq $runtimeBefore) {
                Assert-Test (-not [IO.File]::Exists($runtimeSettingsPath)) ("$CaseName does not create AI runtime settings")
            } else {
                Assert-Test (Same-Bytes $runtimeBefore ([IO.File]::ReadAllBytes($runtimeSettingsPath))) ("$CaseName preserves previous AI runtime settings")
            }
            return ($childOutput -join ' ')
        }
        return [IO.File]::ReadAllText($practiceIniPath, [Text.Encoding]::Default)
    }
    function Assert-RuntimeSeconds([int] $ExpectedSeconds, [string] $CaseName) {
        Assert-Test ([IO.File]::Exists($runtimeSettingsPath)) ("$CaseName writes AI runtime settings")
        $runtimeBytes = [IO.File]::ReadAllBytes($runtimeSettingsPath)
        Assert-Test (@($runtimeBytes | Where-Object { $_ -gt 127 }).Count -eq 0) ("$CaseName runtime settings are plain ASCII without BOM")
        $runtimeText = [Text.Encoding]::ASCII.GetString($runtimeBytes)
        $runtimeText = [regex]::Replace($runtimeText, '(?m)^--[^\r\n]*(?:\r?\n|\z)', '')
        Assert-Test ($runtimeText -match ('\Areturn\s*\{\s*seconds\s*=\s*' + $ExpectedSeconds + '\s*\}\s*\z')) ("$CaseName writes exact seconds=$ExpectedSeconds")
    }
    function Assert-PracticeSettings([object] $Settings, [int] $NoDamage, [int] $Invincible, [string] $CaseName) {
        $ini = Invoke-PracticeFixture $Settings 0 $CaseName
        Assert-Test ([regex]::Matches($ini, '(?m)^\[practice\]\r?$').Count -eq 1) ("$CaseName writes one practice section")
        $practiceMatch = [regex]::Match($ini, '(?ms)^\[practice\]\r?\n(?<values>.*?)(?=^\[|\z)')
        Assert-Test $practiceMatch.Success ("$CaseName practice section is readable")
        $values = $practiceMatch.Groups['values'].Value
        Assert-Test ([regex]::Matches($values, ('(?m)^player1_no_damage=' + $NoDamage + '\r?$')).Count -eq 1) ("$CaseName writes exact no-damage integer")
        Assert-Test ([regex]::Matches($values, ('(?m)^player1_invincible=' + $Invincible + '\r?$')).Count -eq 1) ("$CaseName writes exact invincible integer")
        Assert-Test ($ini -match '(?ms)^\[1P\]\r?\nenabled=false\r?$.*^\[2P\]\r?\nenabled=true\r?$') ("$CaseName retains 1P human and 2P AI")
        Assert-Test ($ini -match '(?ms)^\[window\]\r?\nenabled=1\r?\nwidth=960\r?\nheight=720\r?\nresizable=1\r?\nkeep_aspect=1') ("$CaseName retains window settings")
        Assert-RuntimeSeconds 600 ("$CaseName missing seconds defaults to 600")
    }

    # On a first invalid launch neither generated configuration should appear.
    $firstSecondsError = Invoke-PracticeFixture @{ window = $windowDefaults; seconds = $null } 13 'Reject explicit null seconds on first launch'
    Assert-Test ($firstSecondsError -like '*seconds*') 'First-launch rejection identifies seconds'
    Assert-PracticeSettings @{ window = $windowDefaults } 0 0 'Missing practice defaults off'
    Assert-PracticeSettings @{ window = $windowDefaults; practice = $null } 0 0 'Null practice defaults off'
    Assert-PracticeSettings @{ window = $windowDefaults; practice = @{} } 0 0 'Empty practice defaults off'
    Assert-PracticeSettings @{ window = $windowDefaults; practice = @{ player1_no_damage = $true } } 1 0 'Missing invincible defaults off'
    Assert-PracticeSettings @{ window = $windowDefaults; practice = @{ player1_invincible = $true } } 0 1 'Missing no-damage defaults off'
    foreach ($noDamage in @($false, $true)) {
        foreach ($invincible in @($false, $true)) {
            $settings = @{ window = $windowDefaults; practice = @{ player1_no_damage = $noDamage; player1_invincible = $invincible } }
            Assert-PracticeSettings $settings ([int]$noDamage) ([int]$invincible) ("Boolean combination $noDamage/$invincible")
        }
    }
    $invalidValues = @(
        [pscustomobject]@{ Name = 'quoted true'; Value = 'true' },
        [pscustomobject]@{ Name = 'quoted false'; Value = 'false' },
        [pscustomobject]@{ Name = 'empty string'; Value = '' },
        [pscustomobject]@{ Name = 'integer zero'; Value = 0 },
        [pscustomobject]@{ Name = 'integer one'; Value = 1 },
        [pscustomobject]@{ Name = 'object'; Value = @{ enabled = $true } },
        [pscustomobject]@{ Name = 'boolean array'; Value = @($true, $false) },
        [pscustomobject]@{ Name = 'empty array'; Value = @() }
    )
    foreach ($field in @('player1_no_damage', 'player1_invincible')) {
        foreach ($invalidValue in $invalidValues) {
            $practice = @{ player1_no_damage = $false; player1_invincible = $false }
            $practice[$field] = $invalidValue.Value
            $message = Invoke-PracticeFixture @{ window = $windowDefaults; practice = $practice } 12 ("Reject $field " + $invalidValue.Name)
            Assert-Test ($message -like ('*practice.' + $field + '*')) ('Rejection identifies invalid field ' + $field)
        }
    }
    $invalidPracticeParents = @(
        [pscustomobject]@{ Name = 'string'; Value = 'true' },
        [pscustomobject]@{ Name = 'boolean'; Value = $true },
        [pscustomobject]@{ Name = 'integer'; Value = 1 },
        [pscustomobject]@{ Name = 'empty array'; Value = @() },
        [pscustomobject]@{ Name = 'object array'; Value = @(@{ player1_no_damage = $true }) }
    )
    foreach ($invalidParent in $invalidPracticeParents) {
        $message = Invoke-PracticeFixture @{ window = $windowDefaults; practice = $invalidParent.Value } 12 ('Reject practice parent ' + $invalidParent.Name)
        Assert-Test ($message -like '*practice*') 'Rejection identifies malformed practice object'
    }

    foreach ($seconds in @(0, 1, 600, 86400)) {
        $ini = Invoke-PracticeFixture @{ window = $windowDefaults; seconds = $seconds } 0 ("Valid seconds $seconds")
        Assert-RuntimeSeconds $seconds ("Valid seconds $seconds")
        Assert-Test ($ini -match '(?m)^\[practice\]\r?$') ("Valid seconds $seconds retains practice INI")
    }
    $invalidSecondsValues = @(
        [pscustomobject]@{ Name = 'fraction'; Value = 1.5 },
        [pscustomobject]@{ Name = 'negative'; Value = -1 },
        [pscustomobject]@{ Name = 'above maximum'; Value = 86401 },
        [pscustomobject]@{ Name = 'very large'; Value = [long]::MaxValue },
        [pscustomobject]@{ Name = 'numeric string'; Value = '600' },
        [pscustomobject]@{ Name = 'empty string'; Value = '' },
        [pscustomobject]@{ Name = 'true'; Value = $true },
        [pscustomobject]@{ Name = 'false'; Value = $false },
        [pscustomobject]@{ Name = 'object'; Value = @{ value = 600 } },
        [pscustomobject]@{ Name = 'integer array'; Value = @(600) },
        [pscustomobject]@{ Name = 'empty array'; Value = @() },
        [pscustomobject]@{ Name = 'explicit null'; Value = $null }
    )
    foreach ($invalidSeconds in $invalidSecondsValues) {
        $message = Invoke-PracticeFixture @{ window = $windowDefaults; seconds = $invalidSeconds.Value } 13 ('Reject seconds ' + $invalidSeconds.Name)
        Assert-Test ($message -like '*seconds*') 'Rejection identifies invalid seconds'
    }
    # Preserve the JSON number spelling: ConvertTo-Json can turn 600.0 into
    # 600, which would accidentally test an integer instead of a double.
    foreach ($numericToken in @('600.0', '6e2')) {
        $rawJson = '{"window":{"enabled":true,"width":960,"height":720,"resizable":true,"keep_aspect":true},"seconds":' + $numericToken + '}'
        $message = Invoke-PracticeFixture $null 13 ('Reject floating JSON token ' + $numericToken) $rawJson
        Assert-Test ($message -like '*seconds*') 'Rejection identifies non-integer JSON number'
    }
    Assert-Test (Same-Bytes $original ([IO.File]::ReadAllBytes($source))) 'Real game config was never changed'
    Write-Output ('PASS: {0} assertions; cfg/input, practice/INI and seconds/runtime-settings validation; no game launched.' -f $script:assertions)
    Write-Output ('Fixtures retained for inspection: ' + $fixtureRoot)
} catch {
    Write-Output ('Fixtures retained for inspection: ' + $fixtureRoot)
    throw
}
