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
if ($body -notmatch '^\s*return\s*\{\s*seconds\s*=\s*1\s*\}\s*$') { throw ('Unexpected generated Lua: ' + $text) }
& python (Join-Path $project 'tests\runtime_settings_fixture_test.py') --fixture $fixture
if ($LASTEXITCODE -ne 0) { throw 'Lua did not honor the real launcher-generated settings.' }
if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($configPath)) -ne $originalConfig) {
    throw 'Read-only game configuration precondition was violated.'
}
Write-Output 'PASS: JSON seconds=1 -> actual launcher generation -> real Lua file parse -> stop after 60 active frames.'
Write-Output ('Fixture retained for inspection: ' + $fixture)
