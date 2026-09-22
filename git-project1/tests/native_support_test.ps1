param([Parameter(Mandatory=$true)][string] $GameExe)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$runtime = Join-Path $projectRoot 'dist\TH09-AI\runtime'
$fixture = Join-Path $projectRoot ('work\support-test-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixture) | Out-Null
foreach ($name in @('th09ai-launcher.exe','inject.dll','window_support.dll')) {
    Copy-Item -LiteralPath (Join-Path $runtime $name) -Destination (Join-Path $fixture $name)
}
foreach ($noDamage in @(0,1)) {
    foreach ($invincible in @(0,1)) {
        $ini = "[common]`r`nexe_path=$GameExe`r`nsnapshot=false`r`n[1P]`r`nenabled=false`r`n[2P]`r`nenabled=false`r`n[practice]`r`nplayer1_no_damage=$noDamage`r`nplayer1_invincible=$invincible`r`n[window]`r`nenabled=0`r`n"
        [IO.File]::WriteAllText((Join-Path $fixture 'ka_ai_duka.ini'), $ini, [Text.Encoding]::Default)
        & (Join-Path $fixture 'th09ai-launcher.exe') $GameExe --verify-suspended
        if ($LASTEXITCODE -ne 0) { throw "Support initialization failed: no_damage=$noDamage invincible=$invincible" }
    }
}
$log = [IO.File]::ReadAllText((Join-Path $fixture 'native-window.log'))
foreach ($line in @('both player-1 options disabled', 'install=ok player=1 no_damage=0 invincible=1', 'install=ok player=1 no_damage=1 invincible=0', 'install=ok player=1 no_damage=1 invincible=1')) {
    if (-not $log.Contains($line)) { throw "Missing initialization evidence: $line" }
}
$sensorReady = 'laser_sensor: install=ok managed segment anchor corrected; game physics unchanged'
if ([regex]::Matches($log, [regex]::Escape($sensorReady)).Count -ne 4) {
    throw 'Laser sensor correction was not verified in all four suspended game processes.'
}
if ($log.Contains('laser_sensor: install=FAILED')) { throw 'Laser sensor reported initialization failure.' }
$playerSensorReady = 'player_sensor: install=ok api=1 readonly snapshot; poison recomputed, C gate exported'
if ([regex]::Matches($log, [regex]::Escape($playerSensorReady)).Count -ne 4) {
    throw 'Player/poison sensor was not verified in all four suspended game processes.'
}
if ($log.Contains('player_sensor: install=FAILED')) { throw 'Player sensor reported initialization failure.' }
Write-Output 'PASS: laser/player sensors and all four practice configurations installed before ResumeThread, including window.enabled=false; no game windows or input.'
Write-Output "Evidence: $fixture"
