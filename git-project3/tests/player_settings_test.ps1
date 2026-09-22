param([string] $ProjectRoot = '')
$ErrorActionPreference = 'Stop'
if (-not $ProjectRoot) { $ProjectRoot = Split-Path -Parent $PSScriptRoot }
$project = [IO.Path]::GetFullPath($ProjectRoot)
$fixture = Join-Path $project ('work\player-settings-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
$settingsPath = Join-Path $fixture 'launcher-settings.json'
$editor = Join-Path $project 'dist\TH09-AI\set-difficulty.ps1'
$checks = 0
function Check([bool] $Condition, [string] $Message) {
    $script:checks++
    if (-not $Condition) { throw $Message }
}
function Read-Settings { return ConvertFrom-Json ([IO.File]::ReadAllText($settingsPath)) }
function Invoke-Edit([hashtable] $Options) {
    & $editor -PackageRoot $fixture @Options *> $null
}
# Prevent the menu's display references from drifting away from runtime tiers.
$editorText = [IO.File]::ReadAllText($editor)
$configText = [IO.File]::ReadAllText((Join-Path $project 'src\ai\config.lua'))
foreach ($entry in [regex]::Matches($editorText, '(human\d+|unlimited)=@\((\d+),(\d+)\)')) {
    $tier=$entry.Groups[1].Value; $capacity=$entry.Groups[2].Value; $recovery=$entry.Groups[3].Value
    Check ($configText -match ($tier+'\s*=\s*\{\s*tracked_threat\s*=\s*'+$capacity+',\s*threat_per_second\s*=\s*'+$recovery+'\s*\}')) ('Menu preset reference differs from config.lua: '+$tier)
}
function Expect-Rejected([hashtable] $Options, [string] $Label) {
    $before = [Convert]::ToBase64String([IO.File]::ReadAllBytes($settingsPath))
    $rejected = $false
    try { Invoke-Edit $Options } catch { $rejected = $true }
    Check $rejected ('Accepted invalid setting: ' + $Label)
    Check ([Convert]::ToBase64String([IO.File]::ReadAllBytes($settingsPath)) -eq $before) ('Invalid edit changed file: ' + $Label)
}
$initial = @{
    seconds=600; note='preserve me'; unrelated=@{ nested=@{ list=@(1,2,3); flag=$true } }
    ai=@{ difficulty='human200'; debug_log=$true; enabled=$false; plan_interval=6;
        vision_radius=150; move_change_budget=6; tracked_threat=18;
        attention_capacity=33; attention_recovery_per_second=21; future_option='keep' }
}
[IO.File]::WriteAllText($settingsPath, ($initial | ConvertTo-Json -Depth 100), (New-Object Text.UTF8Encoding($false)))
Invoke-Edit @{ Difficulty='human300' }
$r = Read-Settings
Check ($r.ai.difficulty -eq 'human300') 'Legacy preset call failed.'
Invoke-Edit @{ Difficulty='HUMAN300' }
Check ((Read-Settings).ai.difficulty -eq 'human300') 'Preset case was not normalized for Lua.'
Check ($null -eq $r.ai.PSObject.Properties['attention_capacity'] -and $null -eq $r.ai.PSObject.Properties['attention_recovery_per_second']) 'Preset did not clear explicit attention overrides.'
Check ($r.ai.vision_radius -eq 150 -and $r.ai.move_change_budget -eq 6) 'Preset modified vision or movement.'
Check ($r.ai.debug_log -eq $true -and $r.ai.enabled -eq $false -and $r.ai.plan_interval -eq 6) 'Preset modified unrelated AI switches.'
Check ($r.note -eq 'preserve me' -and $r.unrelated.nested.list.Count -eq 3 -and $r.ai.future_option -eq 'keep' -and $r.ai.tracked_threat -eq 18) 'Unknown or legacy fields were lost.'

Invoke-Edit @{ AttentionCapacity='256'; AttentionRecoveryPerSecond='0.1'; MoveChangeBudget='10'; VisionRadius='640' }
$r = Read-Settings
Check ($r.ai.attention_capacity -eq 256 -and $r.ai.attention_recovery_per_second -eq 0.1) 'Explicit attention limits were not saved as numbers.'
Check ($r.ai.move_change_budget -eq 10 -and $r.ai.vision_radius -eq 640) 'Upper bounds were not accepted.'
Check ($r.ai.difficulty -eq 'human300' -and $r.ai.enabled -eq $false) 'Direct ability settings changed preset/enabled.'
Invoke-Edit @{ AttentionCapacity=1; AttentionRecoveryPerSecond=256; MoveChangeBudget=1; VisionRadius=16 }
$r = Read-Settings
Check ($r.ai.attention_capacity -eq 1 -and $r.ai.attention_recovery_per_second -eq 256 -and $r.ai.move_change_budget -eq 1 -and $r.ai.vision_radius -eq 16) 'Other numeric boundaries were not accepted.'
Invoke-Edit @{ Difficulty='custom'; AttentionCapacity=41.5; AttentionRecoveryPerSecond=30.25 }
$r = Read-Settings
Check ($r.ai.difficulty -eq 'custom' -and $r.ai.attention_capacity -eq 41.5 -and $r.ai.attention_recovery_per_second -eq 30.25) 'Combined custom preset and explicit values failed.'
Invoke-Edit @{ Difficulty='mech' }
$r = Read-Settings
Check ($r.ai.difficulty -eq 'mech' -and $r.ai.enabled -eq $false -and $null -eq $r.ai.PSObject.Properties['attention_capacity']) 'Mech selection unexpectedly enabled attention or kept override.'
foreach ($case in @(
    @{MoveChangeBudget=0}, @{MoveChangeBudget=11}, @{MoveChangeBudget=6.5}, @{MoveChangeBudget='NaN'},
    @{VisionRadius=15.999}, @{VisionRadius=640.001}, @{VisionRadius='Infinity'}, @{VisionRadius='1,5'},
    @{AttentionCapacity=0}, @{AttentionCapacity=256.1}, @{AttentionCapacity=[double]::NaN},
    @{AttentionRecoveryPerSecond=0}, @{AttentionRecoveryPerSecond=256.1}, @{AttentionRecoveryPerSecond=[double]::PositiveInfinity},
    @{MoveChangeBudget=$true}, @{Difficulty='not-a-tier'}, @{Difficulty='human200'; VisionRadius='bad'}
)) { Expect-Rejected $case ($case.Keys -join ',') }

# Verify invariant parsing even when the parent host uses decimal commas.
$culture = [Threading.Thread]::CurrentThread.CurrentCulture
try {
    [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('de-DE')
    Invoke-Edit @{ VisionRadius='149.333333333333'; AttentionRecoveryPerSecond='19.25' }
} finally { [Threading.Thread]::CurrentThread.CurrentCulture = $culture }
$r = Read-Settings
Check ([Math]::Abs($r.ai.vision_radius - 448.0/3.0) -lt 0.00000001 -and $r.ai.attention_recovery_per_second -eq 19.25) 'Invariant decimal input failed.'

# Exercise the actual menu with deterministic Read-Host input, without a game
# or visible helper window. Q must leave the previous JSON byte-for-byte intact.
$global:TH09SettingsTestAnswers = New-Object 'System.Collections.Generic.Queue[string]'
function Read-Host([string] $Prompt) {
    if ($global:TH09SettingsTestAnswers.Count -eq 0) { throw ('Unexpected menu prompt: ' + $Prompt) }
    return $global:TH09SettingsTestAnswers.Dequeue()
}
foreach ($answer in @('3','7','2','180','1','35','25','0')) { $global:TH09SettingsTestAnswers.Enqueue($answer) }
Invoke-Edit @{}
$r = Read-Settings
Check ($r.ai.move_change_budget -eq 7 -and $r.ai.vision_radius -eq 180 -and $r.ai.attention_capacity -eq 35 -and $r.ai.attention_recovery_per_second -eq 25) 'Menu did not save all three ability groups.'
Check ($global:TH09SettingsTestAnswers.Count -eq 0) 'Menu did not consume expected input.'
$before = [Convert]::ToBase64String([IO.File]::ReadAllBytes($settingsPath))
foreach ($answer in @('3','9','q')) { $global:TH09SettingsTestAnswers.Enqueue($answer) }
Invoke-Edit @{}
Check ([Convert]::ToBase64String([IO.File]::ReadAllBytes($settingsPath)) -eq $before) 'Menu cancellation wrote staged changes.'
foreach ($answer in @('4','human480','0')) { $global:TH09SettingsTestAnswers.Enqueue($answer) }
Invoke-Edit @{}
$r = Read-Settings
Check ($r.ai.difficulty -eq 'human480' -and $null -eq $r.ai.PSObject.Properties['attention_capacity'] -and $null -eq $r.ai.PSObject.Properties['attention_recovery_per_second']) 'Menu preset switch failed to clear manual attention.'
Check ($r.ai.move_change_budget -eq 7 -and $r.ai.vision_radius -eq 180 -and $r.ai.future_option -eq 'keep') 'Menu preset switch changed independent/unknown values.'
# The .cmd entry forwards strings through powershell.exe -File; exercise that
# binding as well as the in-process invocation used for scripted menu input.
$windowsPowerShell = Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
& $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File $editor -PackageRoot $fixture -Difficulty human300 -MoveChangeBudget 6 -VisionRadius 149.333333333333 -AttentionCapacity 32 -AttentionRecoveryPerSecond 24 *> (Join-Path $fixture 'native-cli.log')
Check ($LASTEXITCODE -eq 0) 'Native PowerShell -File invocation failed.'
$r = Read-Settings
Check ($r.ai.difficulty -eq 'human300' -and $r.ai.move_change_budget -eq 6 -and [Math]::Abs($r.ai.vision_radius - 448.0/3.0) -lt 0.00000001 -and $r.ai.attention_capacity -eq 32 -and $r.ai.attention_recovery_per_second -eq 24) 'Native CLI arguments were not stored as valid numeric settings.'
# Match main.lua's enabled precedence in the menu: preset first, explicit bool
# second. Mech may be explicitly re-enabled; a named human tier may be disabled.
foreach ($case in @(
    @{tier='mech'; enabled=$true; warning=$false},
    @{tier='mech'; warning=$true},
    @{tier='human200'; enabled=$false; warning=$true}
)) {
    $candidate = Read-Settings
    $candidate.ai.difficulty = $case.tier
    $candidate.ai.PSObject.Properties.Remove('enabled')
    if ($case.ContainsKey('enabled')) { $candidate.ai | Add-Member -NotePropertyName enabled -NotePropertyValue $case.enabled }
    [IO.File]::WriteAllText($settingsPath, ($candidate | ConvertTo-Json -Depth 100), (New-Object Text.UTF8Encoding($false)))
    $global:TH09SettingsTestAnswers.Enqueue('q')
    $display = & $editor -PackageRoot $fixture 6>&1 | Out-String
    Check (($display -match '当前关闭了注意力限制') -eq $case.warning) ('Menu enabled status differs from runtime for ' + $case.tier + ' / ' + $case.enabled)
}
Write-Output ('PASS: ' + $checks + ' player-settings checks; PowerShell ' + $PSVersionTable.PSVersion + '; fixture ' + $fixture)
