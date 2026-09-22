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
$settings = ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $packageRoot 'launcher-settings.json')))

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
# Original upstream runtime uses ANSI file paths.
$ini = @"
[common]
exe_path=$gameExe
snapshot=false
run_while_replay=false
[1P]
enabled=false
script_path=
[2P]
enabled=true
script_path=$aiScript
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
$luaSettings = "-- Generated from launcher-settings.json; do not edit.`r`nreturn { seconds = $seconds }`r`n"
[IO.File]::WriteAllText($aiRuntimeSettings, $luaSettings, [Text.Encoding]::ASCII)
if ($PrepareOnly) {
  & $inputHelper -GameRoot $gameRoot -CheckOnly
  Write-Host "启动配置已生成：$runtimeIni" -ForegroundColor Green
  exit 0
}
& $inputHelper -GameRoot $gameRoot
Write-Host '正在启动TH09：1P玩家，2P选人使用WASD/J/K；开战后2P输入完全由AI控制。' -ForegroundColor Green
Write-Host "AI操作时限：$seconds 秒（0=不限时）；1P不掉血=$noDamage，无敌=$invincible。"
Push-Location -LiteralPath $runtimeRoot
try { & $launcherExe $gameExe; $launcherExit = $LASTEXITCODE }
finally { Pop-Location }
exit $launcherExit
