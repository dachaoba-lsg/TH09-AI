param([string] $GameRootOverride = '', [switch] $PrepareOnly)
$ErrorActionPreference = 'Stop'
$packageRoot = $PSScriptRoot
$runtimeRoot = Join-Path $packageRoot 'runtime'
$launcherExe = Join-Path $runtimeRoot 'th09ai-launcher.exe'
$injectDll = Join-Path $runtimeRoot 'inject.dll'
$windowDll = Join-Path $runtimeRoot 'window_support.dll'
$aiScript = Join-Path $packageRoot 'ai\main.lua'
$runtimeIni = Join-Path $runtimeRoot 'ka_ai_duka.ini'
$aiRuntimeSettings = Join-Path $packageRoot 'ai\runtime-settings.lua'
$inputHelper = Join-Path $packageRoot 'prepare-input.ps1'
try {
  $settings = ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $packageRoot 'launcher-settings.json')))
} catch {
  # Windows PowerShell can include an unquoted JSON value in its parser error.
  # Keep configuration values, including side_key, out of the console/log.
  Write-Host '无法读取launcher-settings.json，请检查文件和JSON语法；字符串必须使用双引号。' -ForegroundColor Red
  exit 14
}

function Stop-WithMessage([string] $message, [int] $exitCode) {
  Write-Host $message -ForegroundColor Red
  exit $exitCode
}
function Get-Sha256Hex([string] $path) {
  $stream = [IO.File]::OpenRead($path)
  try {
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha256.ComputeHash($stream)).Replace('-', '') }
    finally { $sha256.Dispose() }
  } finally { $stream.Dispose() }
}

function Test-AiSideKey($candidate) {
  # This convenience gate stores only a digest. Never emit the candidate or
  # forward it into the generated native/Lua settings.
  if ($candidate -isnot [string]) { return $false }
  $sha256 = [Security.Cryptography.SHA256]::Create()
  try {
    $utf8 = New-Object Text.UTF8Encoding($false, $true)
    $digest = [BitConverter]::ToString($sha256.ComputeHash($utf8.GetBytes($candidate))).Replace('-', '').ToLowerInvariant()
    return $digest -ceq '82410b1bd4d8eeee2897f9c69b45a88bddab8bafa29881218f42c8c0b628c19e'
  } catch {
    return $false
  } finally {
    $sha256.Dispose()
  }
}

function Resolve-GameRoot {
  if ($GameRootOverride) { return [IO.Path]::GetFullPath($GameRootOverride) }
  # Resolve from this script, never the shell's working directory or a saved
  # installation path. An extraction wrapper may add one or more ancestors.
  $candidate = [IO.Directory]::GetParent($packageRoot)
  while ($null -ne $candidate) {
    if ([IO.File]::Exists((Join-Path $candidate.FullName 'th09.exe'))) {
      return $candidate.FullName
    }
    $candidate = $candidate.Parent
  }
  Stop-WithMessage "从启动器所在目录向上未找到th09.exe：$packageRoot。请将TH09-AI文件夹放入游戏目录，可保留解压外层文件夹。" 2
}

$gameRoot = Resolve-GameRoot
$gameExe = Join-Path $gameRoot 'th09.exe'

foreach ($required in @($gameExe, $launcherExe, $injectDll, $windowDll, $aiScript, $inputHelper)) {
  if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { Stop-WithMessage "缺少文件：$required" 2 }
}
$actualSha256 = Get-Sha256Hex $gameExe
if ($actualSha256 -ne '10350095BCF95EDB59E03BEE9849A2DC8A7714B4927AD5909C569C550FCE6822') {
  Stop-WithMessage "游戏版本不匹配，只支持已验证的日文版TH09 v1.50a。SHA256: $actualSha256" 6
}
if ((Get-Sha256Hex $injectDll) -ne '2BA67F1F80EBE53F978DC6843777764B5EAD911A688C89C9CD68CC8C2D9CAE00') {
  Stop-WithMessage 'AI运行库版本不匹配，请使用完整发布包。' 9
}
Write-Host "游戏目录：$gameRoot"
$seconds = 600
if ($settings.PSObject.Properties.Name -contains 'seconds') {
  $value = $settings.seconds
  if (($value -isnot [int] -and $value -isnot [long]) -or $value -lt 0 -or $value -gt 86400) {
    Stop-WithMessage 'seconds 必须是0到86400之间的整数，不要加引号；0表示不限时。' 13
  }
  $seconds = [int]$value
}
$windowWidth = [int]$settings.window.width
$windowHeight = [int]$settings.window.height
if ($windowWidth -lt 320 -or $windowWidth -gt 7680 -or $windowHeight -lt 240 -or $windowHeight -gt 4320) {
  Stop-WithMessage '窗口尺寸应在320x240到7680x4320之间。' 11
}
$windowEnabled = [int][bool]$settings.window.enabled
$windowResizable = [int][bool]$settings.window.resizable
$keepAspect = if ($null -eq $settings.window.keep_aspect) { 1 } else { [int][bool]$settings.window.keep_aspect }
$noDamage = 0
$invincible = 0
if ($null -ne $settings.practice) {
  if ($settings.practice -isnot [pscustomobject]) {
    Stop-WithMessage 'practice 必须是包含练习开关的JSON对象。' 12
  }
  foreach ($name in @('player1_no_damage', 'player1_invincible')) {
    $value = $settings.practice.$name
    if ($null -ne $value -and $value -isnot [bool]) {
      Stop-WithMessage "practice.$name 必须是true或false，不要加引号。" 12
    }
  }
  $noDamage = [int][bool]$settings.practice.player1_no_damage
  $invincible = [int][bool]$settings.practice.player1_invincible
}
# 3.1 dodge difficulty. Only validated values are emitted; presets live in the
# Lua config, so this side stays a schema check and a plain pass-through.
# Historical preset names remain compatible; survival-time calibration is paused.
$aiPresets = @('mech', 'human45', 'human90', 'human120', 'human150', 'human180',
  'human200', 'human240', 'human300', 'human480', 'unlimited', 'custom',
  'pro', 'veteran', 'human', 'casual', 'novice', 'infinite')
$aiActions = @('c', 'panic', 'c_then_panic', 'hold')
$aiNumbers = [ordered]@{
  threat_per_second = @(0.1, 64); tracked_threat = @(1, 64); plan_interval = @(1, 60)
  reflex_radius = @(0, 256); blind_urgent_limit = @(1, 64); overload_frames = @(1, 600); sight_radius = @(0, 256)
  speed_reference = @(0.1, 20); speed_exponent = @(0.25, 2); width_reference = @(16, 1024)
  move_change_budget = @(1, 10); vision_radius = @(16, 640)
  attention_capacity = @(1, 256); attention_recovery_per_second = @(0.1, 256)
}
$aiDifficulty = 'human200'
$aiSide = 2
$aiOverrides = [ordered]@{}
$aiEnabled = $null
$aiDebugLog = $null
if ($null -ne $settings.ai) {
  if ($settings.ai -isnot [pscustomobject]) {
    Stop-WithMessage 'ai 必须是JSON对象，例如 "ai": { "difficulty": "human" }。' 14
  }
  if ($settings.ai.PSObject.Properties.Name -contains 'side') {
    $value = $settings.ai.side
    if (($value -isnot [int] -and $value -isnot [long]) -or $value -notin @(1, 2)) {
      Stop-WithMessage 'ai.side 必须是整数 1 或 2，不要加引号；1=AI接管1P，2=AI接管2P。' 14
    }
    $aiSide = [int]$value
  }
  if ($settings.ai.PSObject.Properties.Name -contains 'difficulty') {
    $value = $settings.ai.difficulty
    if ($value -isnot [string] -or $aiPresets -notcontains $value) {
      Stop-WithMessage 'ai.difficulty 必须是 mech、human45/human90/human120/human150/human180/human200/human240/human300/human480、unlimited 或 custom（要加引号）；pro/veteran/human/casual/novice 是旧名，仍可用。' 14
    }
    $aiDifficulty = $value.ToLowerInvariant()
  }
  foreach ($name in $aiNumbers.Keys) {
    $value = $settings.ai.$name
    if ($null -eq $value) { continue }
    if ($value -isnot [int] -and $value -isnot [long] -and $value -isnot [double] -and $value -isnot [decimal]) {
      Stop-WithMessage "ai.$name 必须是数字，不要加引号。" 14
    }
    $range = $aiNumbers[$name]
    if ([double]::IsNaN([double]$value) -or [double]::IsInfinity([double]$value) -or
        [double]$value -lt $range[0] -or [double]$value -gt $range[1]) {
      Stop-WithMessage "ai.$name 应在 $($range[0]) 到 $($range[1]) 之间。" 14
    }
    if ($name -eq 'move_change_budget' -and [double]$value -ne [Math]::Floor([double]$value)) {
      Stop-WithMessage 'ai.move_change_budget 必须是 1 到 10 的整数。' 14
    }
    $aiOverrides[$name] = [double]$value
  }
  if ($settings.ai.PSObject.Properties.Name -contains 'overload_action') {
    $value = $settings.ai.overload_action
    if ($value -isnot [string] -or $aiActions -notcontains $value) {
      Stop-WithMessage 'ai.overload_action 必须是 c、panic、c_then_panic、hold 之一（要加引号）。' 14
    }
    $aiOverrides['overload_action'] = $value
  }
  foreach ($name in @('enabled', 'debug_log')) {
    if ($settings.ai.PSObject.Properties.Name -contains $name) {
      if ($settings.ai.$name -isnot [bool]) {
        Stop-WithMessage "ai.$name 必须是true或false，不要加引号。" 14
      }
      if ($name -eq 'enabled') { $aiEnabled = $settings.ai.$name } else { $aiDebugLog = $settings.ai.$name }
    }
  }
}
# Resolve the effective side before deriving the human side, practice gates,
# script bindings, or native INI. Preserve the user's saved request and key.
if ($aiSide -eq 1 -and -not (Test-AiSideKey $settings.ai.side_key)) {
  Write-Host '1P接管key未通过，本次使用2P AI；已保存的设置保持不变。' -ForegroundColor Yellow
  $aiSide = 2
}
# Keep the keyboard layout fixed. Only the script binding and the selected
# native SendKeys isolation change sides. Legacy practice switches name 1P;
# they must never grant protection to the AI when it takes that side.
$humanSide = 3 - $aiSide
if ($aiSide -eq 1 -and ($noDamage -or $invincible)) {
  Write-Host 'AI接管1P：本次禁用1P练习免伤/无敌，保留JSON中的原设置；不会转移给2P。' -ForegroundColor Yellow
  $noDamage = 0
  $invincible = 0
}
$player1Enabled = if ($aiSide -eq 1) { 'true' } else { 'false' }
$player2Enabled = if ($aiSide -eq 2) { 'true' } else { 'false' }
$player1Script = if ($aiSide -eq 1) { $aiScript } else { '' }
$player2Script = if ($aiSide -eq 2) { $aiScript } else { '' }
# Original upstream runtime uses ANSI file paths.
$ini = @"
[common]
exe_path=$gameExe
snapshot=false
run_while_replay=false
[1P]
enabled=$player1Enabled
script_path=$player1Script
[2P]
enabled=$player2Enabled
script_path=$player2Script
[practice]
player1_no_damage=$noDamage
player1_invincible=$invincible
[window]
enabled=$windowEnabled
width=$windowWidth
height=$windowHeight
resizable=$windowResizable
keep_aspect=$keepAspect
"@
if (-not $PrepareOnly) {
  foreach ($runningGame in @(Get-Process -Name th09 -ErrorAction SilentlyContinue)) {
    if ($runningGame.Path -ieq $gameExe) { Stop-WithMessage '这份TH09已在运行，请正常退出后重新启动AI。' 7 }
  }
}
[IO.File]::WriteAllText($runtimeIni, $ini, [Text.Encoding]::Default)
# Only a validated integer is emitted, never raw JSON or arbitrary Lua code.
# This generated file is not a second user configuration; it is refreshed on launch.
$invariant = [Globalization.CultureInfo]::InvariantCulture
$aiParts = @("difficulty = " + [char]34 + $aiDifficulty + [char]34)
foreach ($name in $aiOverrides.Keys) {
  $value = $aiOverrides[$name]
  if ($value -is [string]) { $aiParts += $name + " = " + [char]34 + $value + [char]34 }
  else { $aiParts += $name + " = " + ([double]$value).ToString($invariant) }
}
if ($null -ne $aiEnabled) { $aiParts += 'enabled = ' + $(if ($aiEnabled) { 'true' } else { 'false' }) }
if ($null -ne $aiDebugLog) { $aiParts += 'debug_log = ' + $(if ($aiDebugLog) { 'true' } else { 'false' }) }
$aiLua = 'ai = { ' + ($aiParts -join ', ') + ' }'
$luaSettings = "-- Generated from launcher-settings.json; do not edit." + [char]13 + [char]10 + "return { seconds = $seconds, $aiLua }" + [char]13 + [char]10
[IO.File]::WriteAllText($aiRuntimeSettings, $luaSettings, [Text.Encoding]::ASCII)
if ($PrepareOnly) {
  & $inputHelper -GameRoot $gameRoot -CheckOnly
  Write-Host "启动配置已生成：$runtimeIni" -ForegroundColor Green
  exit 0
}
& $inputHelper -GameRoot $gameRoot
Write-Host "正在启动TH09：AI接管 ${aiSide}P，玩家操作 ${humanSide}P；开战后仅AI侧输入由AI独占。" -ForegroundColor Green
Write-Host "键位保持：1P方向键/Z/X/Shift，2P WASD/J/K/L；请将 ${aiSide}P 的 Charge Type 设为 Slow。"
Write-Host "AI操作时限：$seconds 秒（0=不限时）；1P不掉血=$noDamage，无敌=$invincible。"
Write-Host "AI注意力预设：$aiDifficulty（旧挡位名保留，暂停按存活秒数标定；双击 set-difficulty.cmd 可设置注意力、视野和避弹变向上限）"
Push-Location -LiteralPath $runtimeRoot
try { & $launcherExe $gameExe; $launcherExit = $LASTEXITCODE }
finally { Pop-Location }
exit $launcherExit
