<#
  DS-TH09-AI player ability settings. No game process is launched.
  Compatible: .\set-difficulty.ps1 human300
  Example: .\set-difficulty.ps1 -MoveChangeBudget 6 -VisionRadius 149.333333333333
  Example: .\set-difficulty.ps1 -AttentionCapacity 32 -AttentionRecoveryPerSecond 24
  Without setting arguments, opens an interactive Chinese menu.
  Selecting a preset clears only the two explicit attention overrides. Other
  settings and unknown JSON fields are preserved. Explicit arguments in the
  same command are applied after selecting the preset.
#>
param(
    [Parameter(Position=0)] [string] $Difficulty = '',
    [string] $PackageRoot = '',
    [object] $MoveChangeBudget,
    [object] $VisionRadius,
    [object] $AttentionCapacity,
    [object] $AttentionRecoveryPerSecond
)
$ErrorActionPreference = 'Stop'
if (-not $PackageRoot) { $PackageRoot = $PSScriptRoot }
$settingsPath = Join-Path $PackageRoot 'launcher-settings.json'
if (-not [IO.File]::Exists($settingsPath)) { throw "找不到 launcher-settings.json：$settingsPath" }
$json = ConvertFrom-Json ([IO.File]::ReadAllText($settingsPath))
if ($json -isnot [pscustomobject]) { throw 'launcher-settings.json 必须是 JSON 对象。' }
if ($null -eq $json.PSObject.Properties['ai']) {
    $json | Add-Member -NotePropertyName ai -NotePropertyValue ([pscustomobject]@{})
} elseif ($json.ai -isnot [pscustomobject]) { throw 'ai 必须是 JSON 对象。' }
$tiers = @('mech', 'human45', 'human90', 'human120', 'human150', 'human180',
    'human200', 'human240', 'human300', 'human480', 'unlimited', 'custom',
    'pro', 'veteran', 'human', 'casual', 'novice', 'infinite')
$ranges = @{
    move_change_budget = @(1, 10)
    vision_radius = @(16, 640)
    attention_capacity = @(1, 256)
    attention_recovery_per_second = @(0.1, 256)
}
$argumentFields = [ordered]@{
    MoveChangeBudget='move_change_budget'; VisionRadius='vision_radius'
    AttentionCapacity='attention_capacity'; AttentionRecoveryPerSecond='attention_recovery_per_second'
}
# Display references only; config.lua remains the runtime source of truth.
# The sandbox regression checks these numbers against the packaged source.
$presetBudgets = @{
    human45=@(6,5); human90=@(9,7); human120=@(12,9); human150=@(16,12)
    human180=@(20,15); human200=@(26,19); human240=@(32,24); human300=@(40,30)
    human480=@(55,40); unlimited=@(120,90)
}
$presetAliases = @{ novice='human45'; casual='human120'; human='human200'; veteran='human300'; pro='human480'; infinite='unlimited' }
function Set-AiValue([string] $Name, $Value) {
    $json.ai | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}
function Set-Preset([string] $Name) {
    $Name = $Name.ToLowerInvariant()
    if ($tiers -notcontains $Name) { throw "未知预设：$Name。可用：$($tiers -join ', ')" }
    Set-AiValue 'difficulty' $Name
    $json.ai.PSObject.Properties.Remove('attention_capacity')
    $json.ai.PSObject.Properties.Remove('attention_recovery_per_second')
}
function Read-SettingNumber([string] $Name, $Value) {
    $number = 0.0
    if ($Value -is [string]) {
        if (-not [double]::TryParse($Value, [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
            throw "$Name 必须是数字；小数请使用点号，例如 149.3333。"
        }
    } elseif ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) {
        $number = [double]$Value
    } else { throw "$Name 必须是数字。" }
    $range = $ranges[$Name]
    if ([double]::IsNaN($number) -or [double]::IsInfinity($number) -or
        $number -lt $range[0] -or $number -gt $range[1]) {
        throw "$Name 必须是 $($range[0]) 到 $($range[1]) 之间的有限数字。"
    }
    if ($Name -eq 'move_change_budget') {
        if ($number -ne [Math]::Floor($number)) { throw '避弹变向上限必须是 1 到 10 的整数。' }
        return [int]$number
    }
    return $number
}
function Show-Value([string] $Name, [string] $Fallback) {
    $property = $json.ai.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Fallback }
    return [string]$property.Value
}
function Show-Current {
    Write-Host ''
    Write-Host ('预设：' + (Show-Value 'difficulty' 'human200'))
    $tier = Show-Value 'difficulty' 'human200'
    if ($presetAliases.ContainsKey($tier)) { $tier = $presetAliases[$tier] }
    $base = if ($presetBudgets.ContainsKey($tier)) { $presetBudgets[$tier] } else { $presetBudgets.human200 }
    $capacity = [double]$base[0]; $recovery = [double]$base[1]
    if ($tier -eq 'custom') {
        foreach ($entry in @(@('tracked_threat',1,64),@('threat_per_second',0.1,64))) {
            $v = $json.ai.($entry[0])
            if (($v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [decimal]) -and
                -not [double]::IsNaN([double]$v) -and -not [double]::IsInfinity([double]$v) -and
                $v -ge $entry[1] -and $v -le $entry[2]) {
                if ($entry[0] -eq 'tracked_threat') { $capacity = [double]$v } else { $recovery = [double]$v }
            }
        }
    }
    Write-Host ('注意力容量：' + (Show-Value 'attention_capacity' ($capacity.ToString() + '（预设/默认）')) +
        '；每秒新纳入额度：' + (Show-Value 'attention_recovery_per_second' ($recovery.ToString() + '（预设/默认）')))
    Write-Host ('视野半径：' + (Show-Value 'vision_radius' '149.333333333333') +
        '；避弹变向上限：' + (Show-Value 'move_change_budget' '6'))
    $attentionEnabled = $tier -ne 'mech'
    if ($json.ai.enabled -is [bool]) { $attentionEnabled = $json.ai.enabled }
    if (-not $attentionEnabled) {
        Write-Host '当前关闭了注意力限制；启用注意力后，手动注意力数值才会生效。' -ForegroundColor Yellow
    }
}
$direct = $PSBoundParameters.ContainsKey('Difficulty')
foreach ($name in $argumentFields.Keys) { if ($PSBoundParameters.ContainsKey($name)) { $direct = $true } }
if ($direct) {
    if ($PSBoundParameters.ContainsKey('Difficulty')) { Set-Preset $Difficulty }
    foreach ($name in $argumentFields.Keys) {
        if ($PSBoundParameters.ContainsKey($name)) {
            $field = $argumentFields[$name]
            Set-AiValue $field (Read-SettingNumber $field $PSBoundParameters[$name])
        }
    }
} else {
    Write-Host 'TH09-AI 能力设置：暂停按 200／300／480 秒标定，旧预设名继续可用。'
    Write-Host '视野使用 TH09 单侧场地坐标（高度 448），不随窗口像素尺寸改变。'
    $done = $false
    while (-not $done) {
        Show-Current
        Write-Host '1 注意力容量与每秒新纳入额度  2 视野半径  3 避弹变向上限  4 切换预设'
        Write-Host '0 保存并退出  Q 放弃本次修改'
        $choice = (Read-Host '请选择').Trim()
        try {
            switch ($choice) {
                '1' {
                    Write-Host '额度使用速度加权威胁单位；高值更能同时跟踪和接纳新弹。空白保留当前值。'
                    $capacity = Read-Host '注意力容量（1～256）'
                    $recovery = Read-Host '每秒新纳入额度（0.1～256）'
                    $nextCapacity = $null; $nextRecovery = $null
                    if ($capacity.Trim()) { $nextCapacity = Read-SettingNumber 'attention_capacity' $capacity }
                    if ($recovery.Trim()) { $nextRecovery = Read-SettingNumber 'attention_recovery_per_second' $recovery }
                    if ($null -ne $nextCapacity) { Set-AiValue 'attention_capacity' $nextCapacity }
                    if ($null -ne $nextRecovery) { Set-AiValue 'attention_recovery_per_second' $nextRecovery }
                }
                '2' {
                    $value = Read-Host '视野半径（16～640，默认约 149.3333；空白保留）'
                    if ($value.Trim()) { Set-AiValue 'vision_radius' (Read-SettingNumber 'vision_radius' $value) }
                }
                '3' {
                    Write-Host '这是被感知危险下的避弹变向预算，默认 6；不是固定每秒移动或按键次数。'
                    $value = Read-Host '避弹变向上限（1～10 整数；空白保留）'
                    if ($value.Trim()) { Set-AiValue 'move_change_budget' (Read-SettingNumber 'move_change_budget' $value) }
                }
                '4' {
                    Write-Host ('可用预设：' + ($tiers -join ' / '))
                    Write-Host '切换预设会清除两个手动注意力值；视野、变向、日志及其他设置保留。'
                    $value = Read-Host '预设名称（空白保留）'
                    if ($value.Trim()) { Set-Preset $value.Trim() }
                }
                '0' { $done = $true }
                'q' { Write-Host '已放弃本次修改。'; return }
                default { Write-Host '请输入 0～4 或 Q。' -ForegroundColor Yellow }
            }
        } catch { Write-Host $_.Exception.Message -ForegroundColor Red }
    }
}
[IO.File]::WriteAllText($settingsPath, ($json | ConvertTo-Json -Depth 100), (New-Object Text.UTF8Encoding($false)))
Write-Host '能力设置已保存。' -ForegroundColor Green
Show-Current
Write-Host '下次通过 启动TH09-AI.cmd 启动时生效；本工具不会启动或操作游戏。'
