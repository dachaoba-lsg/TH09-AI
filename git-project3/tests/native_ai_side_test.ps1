param([string] $CompilerPath)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not $CompilerPath) { $CompilerPath = Join-Path $projectRoot 'work\win32-toolchain\tcc\tcc.exe' }
$fixture = Join-Path $projectRoot ('work\native-ai-side-test-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixture) | Out-Null
$executable = Join-Path $fixture 'native_ai_side_test.exe'
& $CompilerPath -Wall -Werror (Join-Path $PSScriptRoot 'native_ai_side_test.c') -o $executable
if ($LASTEXITCODE -ne 0) { throw 'Native AI-side parser self-test compilation failed.' }
& $executable
if ($LASTEXITCODE -ne 0) { throw 'Native AI-side parser self-test failed.' }
Write-Output "Evidence: $fixture"
