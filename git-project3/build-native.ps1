param([string] $CompilerPath = '')
$ErrorActionPreference = 'Stop'
if (-not $CompilerPath) { $CompilerPath = Join-Path $PSScriptRoot 'work\win32-toolchain\tcc\tcc.exe' }
if (-not [IO.File]::Exists($CompilerPath)) { throw 'TinyCC win32 0.9.27 is required. See src/native/README.md.' }
$native = Join-Path $PSScriptRoot 'src\native'
$runtime = Join-Path $PSScriptRoot 'dist\TH09-AI\runtime'
$testOutput = Join-Path $PSScriptRoot 'work\native-tests'
[IO.Directory]::CreateDirectory($runtime) | Out-Null
[IO.Directory]::CreateDirectory($testOutput) | Out-Null
& $CompilerPath -Wall -Werror (Join-Path $native 'launcher.c') -o (Join-Path $runtime 'th09ai-launcher.exe') -lshell32 -luser32
if ($LASTEXITCODE -ne 0) { throw 'Native launcher compilation failed.' }
& $CompilerPath -shared -Wall -Werror -o (Join-Path $runtime 'window_support.dll') (Join-Path $native 'window_resize.c') (Join-Path $native 'window_support.c') (Join-Path $native 'practice_patches.c') (Join-Path $native 'laser_sensor.c') (Join-Path $native 'player_sensor.c') (Join-Path $native 'enemy_sensor.c') -luser32 -lkernel32
if ($LASTEXITCODE -ne 0) { throw 'Native window module compilation failed.' }
& $CompilerPath -Wall -Werror -o (Join-Path $testOutput 'window_resize_selftest.exe') (Join-Path $native 'window_resize.c') (Join-Path $native 'window_resize_selftest.c') -luser32 -lkernel32
if ($LASTEXITCODE -ne 0) { throw 'Native window self-test compilation failed.' }
& (Join-Path $testOutput 'window_resize_selftest.exe')
if ($LASTEXITCODE -ne 0) { throw 'Native window self-test failed.' }
& $CompilerPath -Wall -Werror -o (Join-Path $testOutput 'laser_sensor_selftest.exe') (Join-Path $native 'laser_sensor.c') (Join-Path $native 'laser_sensor_selftest.c') -lkernel32
if ($LASTEXITCODE -ne 0) { throw 'Laser sensor self-test compilation failed.' }
& (Join-Path $testOutput 'laser_sensor_selftest.exe')
if ($LASTEXITCODE -ne 0) { throw 'Laser sensor self-test failed.' }
& $CompilerPath -Wall -Werror -o (Join-Path $testOutput 'player_sensor_selftest.exe') (Join-Path $native 'player_sensor.c') (Join-Path $native 'player_sensor_selftest.c') -lkernel32
if ($LASTEXITCODE -ne 0) { throw 'Player sensor self-test compilation failed.' }
& (Join-Path $testOutput 'player_sensor_selftest.exe')
if ($LASTEXITCODE -ne 0) { throw 'Player sensor self-test failed.' }
& $CompilerPath -Wall -Werror -o (Join-Path $testOutput 'enemy_sensor_selftest.exe') (Join-Path $native 'enemy_sensor.c') (Join-Path $native 'enemy_sensor_selftest.c') -lkernel32
if ($LASTEXITCODE -ne 0) { throw 'Enemy sensor self-test compilation failed.' }
& (Join-Path $testOutput 'enemy_sensor_selftest.exe')
if ($LASTEXITCODE -ne 0) { throw 'Enemy sensor self-test failed.' }
$hashLines = foreach ($name in @('ka_ai_duka.exe', 'inject.dll', 'th09ai-launcher.exe', 'window_support.dll')) {
    $fileHash = Get-FileHash -LiteralPath (Join-Path $runtime $name) -Algorithm SHA256
    '{0}  {1}' -f $fileHash.Hash, $name
}
[IO.File]::WriteAllText((Join-Path $runtime 'SHA256SUMS.txt'), (($hashLines -join "`r`n") + "`r`n"), [Text.Encoding]::ASCII)
Write-Output 'Native build, owned-window, laser-sensor, player-sensor and enemy-sensor tests passed.'
