param(
    [Parameter(Mandatory = $true)] [string] $SourceGameRoot,
    [string] $ProjectRoot = ''
)
# Generate settings using the real source launcher with -PrepareOnly. All
# generated files stay under project/work; the game is neither started nor edited.
$ErrorActionPreference = 'Stop'
if (-not $ProjectRoot) { $ProjectRoot = Split-Path -Parent $PSScriptRoot }
$project = [IO.Path]::GetFullPath($ProjectRoot)
$gameRoot = [IO.Path]::GetFullPath($SourceGameRoot)
$configPath = Join-Path $gameRoot 'th09.cfg'
$originalConfig = [Convert]::ToBase64String([IO.File]::ReadAllBytes($configPath))
$fixtureRoot = Join-Path $project ('work\runtime-settings-fixture-' + [Guid]::NewGuid().ToString('N'))
$package = Join-Path $fixtureRoot '[test package] TH09-AI'
$runtime = Join-Path $package 'runtime'
$ai = Join-Path $package 'ai'
[void][IO.Directory]::CreateDirectory($runtime)
[void][IO.Directory]::CreateDirectory($ai)
foreach ($name in @('inject.dll', 'window_support.dll', 'th09ai-launcher.exe')) {
    [IO.File]::Copy((Join-Path $project ('dist\TH09-AI\runtime\' + $name)), (Join-Path $runtime $name))
}
foreach ($name in @('main.lua', 'config.lua', 'dodge.lua', 'keyutils.lua', 'bloom.lua', 'bloom_observer.lua')) {
    [IO.File]::Copy((Join-Path $project ('src\ai\' + $name)), (Join-Path $ai $name))
}
foreach ($name in @('prepare-input.ps1', 'prepare-and-start.ps1')) {
    $sourceText = [IO.File]::ReadAllText((Join-Path $project ('src\launcher\' + $name)))
    # Match the release build's Windows PowerShell 5.1 encoding.
    [IO.File]::WriteAllText((Join-Path $package $name), $sourceText, (New-Object Text.UTF8Encoding($true)))
}
$settings = ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $project 'dist\TH09-AI\launcher-settings.json')))
$settings | Add-Member -NotePropertyName 'seconds' -NotePropertyValue 1 -Force
[IO.File]::WriteAllText((Join-Path $package 'launcher-settings.json'), ($settings | ConvertTo-Json -Depth 8), [Text.Encoding]::UTF8)
$windowsPowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
& $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $package 'prepare-and-start.ps1') -GameRootOverride $gameRoot -PrepareOnly
if ($LASTEXITCODE -ne 0) { throw 'Source launcher failed to prepare real runtime settings.' }
$fixture = Join-Path $ai 'runtime-settings.lua'
if (-not [IO.File]::Exists($fixture)) { throw 'Launcher did not generate runtime-settings.lua.' }
$bytes = [IO.File]::ReadAllBytes($fixture)
if (@($bytes | Where-Object { $_ -gt 127 }).Count -ne 0) { throw 'Runtime Lua must be ASCII without a BOM.' }
$text = [IO.File]::ReadAllText($fixture)
$body = $text -replace '(?m)--[^\r\n]*', ''
if ($body -notmatch '^\s*return\s*\{\s*seconds\s*=\s*1\s*,\s*ai\s*=\s*\{') { throw ('Unexpected generated Lua: ' + $text) }
if ($body -notmatch 'difficulty\s*=\s*"human200"') { throw ('Generated Lua lost the dodge difficulty: ' + $text) }
if ($body -notmatch 'move_change_budget\s*=\s*6\b') { throw ('Generated Lua lost movement budget: ' + $text) }
if ($body -notmatch 'vision_radius\s*=\s*149\.333333333333') { throw ('Generated Lua lost vision radius: ' + $text) }
if ($body -match 'attention_capacity|attention_recovery_per_second') { throw ('Public defaults must not override attention presets: ' + $text) }
if ($body -match 'threat_per_second') { throw ('The generated file must not pin the tier budget: ' + $text) }
if ($body -notmatch 'overload_action\s*=\s*"c_then_panic"') { throw ('Generated Lua lost the overload action: ' + $text) }
& python (Join-Path $project 'tests\runtime_settings_fixture_test.py') --fixture $fixture
if ($LASTEXITCODE -ne 0) { throw 'Lua did not honor the real launcher-generated settings.' }

# Exercise the real PS5.1 launcher at numeric boundaries and reject malformed
# input before replacing the last valid runtime-settings.lua. No game is run.
$settingsJson = $settings | ConvertTo-Json -Depth 100
$checks = 0
function Run-Prepare([string] $Label) {
    $log = Join-Path $fixtureRoot ($Label + '.log')
    $previousPreference = $ErrorActionPreference
    try {
        # Expected invalid JSON can make the child write stderr; inspect its exit
        # status instead of treating that NativeCommandError as a harness failure.
        $ErrorActionPreference = 'Continue'
        & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $package 'prepare-and-start.ps1') -GameRootOverride $gameRoot -PrepareOnly *> $log
        $prepareExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    return $prepareExitCode
}
foreach ($case in @(
    @{difficulty='custom'; move_change_budget=1; vision_radius=16; attention_capacity=1; attention_recovery_per_second=0.1},
    @{difficulty='human300'; move_change_budget=10; vision_radius=640; attention_capacity=256; attention_recovery_per_second=256}
)) {
    $candidate = ConvertFrom-Json $settingsJson
    foreach ($name in $case.Keys) { $candidate.ai | Add-Member -NotePropertyName $name -NotePropertyValue $case[$name] -Force }
    [IO.File]::WriteAllText((Join-Path $package 'launcher-settings.json'), ($candidate | ConvertTo-Json -Depth 100), [Text.Encoding]::UTF8)
    if ((Run-Prepare ('valid-' + $checks)) -ne 0) { throw 'Launcher rejected valid player-setting boundaries.' }
    $generated = [IO.File]::ReadAllText($fixture)
    foreach ($name in $case.Keys) {
        $expected = if ($case[$name] -is [string]) { '"' + $case[$name] + '"' } else { ([double]$case[$name]).ToString([Globalization.CultureInfo]::InvariantCulture) }
        if ($generated -notmatch ([regex]::Escape($name) + '\s*=\s*' + [regex]::Escape($expected) + '\s*[,}]')) { throw "Launcher lost $name = $expected." }
        $checks++
    }
}
$invalid = @(
    @('move_change_budget',0), @('move_change_budget',11), @('move_change_budget',6.5), @('move_change_budget','6'),
    @('vision_radius',15.9), @('vision_radius',641), @('vision_radius','NaN'),
    @('attention_capacity',0), @('attention_capacity',257), @('attention_capacity',$true),
    @('attention_recovery_per_second',0.01), @('attention_recovery_per_second',257),
    @('attention_recovery_per_second','Infinity')
)
foreach ($case in $invalid) {
    $candidate = ConvertFrom-Json $settingsJson
    $candidate.ai | Add-Member -NotePropertyName $case[0] -NotePropertyValue $case[1] -Force
    [IO.File]::WriteAllText((Join-Path $package 'launcher-settings.json'), ($candidate | ConvertTo-Json -Depth 100), [Text.Encoding]::UTF8)
    $before = [Convert]::ToBase64String([IO.File]::ReadAllBytes($fixture))
    if ((Run-Prepare ('invalid-' + $checks)) -eq 0) { throw ('Launcher accepted invalid ' + $case[0]) }
    if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($fixture)) -ne $before) { throw 'Rejected settings replaced the previous valid runtime file.' }
    $checks++
}
foreach ($token in @('NaN','Infinity','-Infinity','1e309')) {
    $candidate = ConvertFrom-Json $settingsJson
    $candidate.ai | Add-Member -NotePropertyName attention_capacity -NotePropertyValue 'NONFINITE_TOKEN' -Force
    $raw = ($candidate | ConvertTo-Json -Depth 100).Replace('"NONFINITE_TOKEN"', $token)
    [IO.File]::WriteAllText((Join-Path $package 'launcher-settings.json'), $raw, [Text.Encoding]::UTF8)
    $before = [Convert]::ToBase64String([IO.File]::ReadAllBytes($fixture))
    if ((Run-Prepare ('nonfinite-' + $checks)) -eq 0) { throw ('Launcher accepted nonfinite token ' + $token) }
    if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($fixture)) -ne $before) { throw 'Nonfinite input replaced valid runtime settings.' }
    $checks++
}
[IO.File]::WriteAllText((Join-Path $package 'launcher-settings.json'), $settingsJson, [Text.Encoding]::UTF8)
if ((Run-Prepare 'restored-defaults') -ne 0) { throw 'Could not restore fixture defaults.' }
if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($configPath)) -ne $originalConfig) {
    throw 'Read-only game configuration precondition was violated.'
}
Write-Output 'PASS: JSON seconds=1 -> actual launcher generation -> real Lua file parse -> stop after 60 active frames.'
Write-Output ('PASS: ' + $checks + ' additional real-launcher player-setting boundary/validation checks.')
Write-Output ('Fixture retained for inspection: ' + $fixture)
