param(
    [string]$InjectPath,
    [string]$CompilerPath
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not $InjectPath) {
    $InjectPath = Join-Path $projectRoot 'vendor\release\ka_ai_duka\inject.dll'
}
if (-not $CompilerPath) {
    $CompilerPath = Join-Path $projectRoot 'work\win32-toolchain\tcc\tcc.exe'
}
$InjectPath = (Resolve-Path -LiteralPath $InjectPath).ProviderPath
$CompilerPath = (Resolve-Path -LiteralPath $CompilerPath).ProviderPath

# Use .NET directly, so this also works in restricted PowerShell hosts where
# Get-FileHash is missing. The DLL is opened only for reading.
$stream = [System.IO.File]::OpenRead($InjectPath)
$sha = [System.Security.Cryptography.SHA256]::Create()
try {
    $actualHash = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '')
} finally {
    $stream.Dispose()
    $sha.Dispose()
}
$expectedHash = '2BA67F1F80EBE53F978DC6843777764B5EAD911A688C89C9CD68CC8C2D9CAE00'
if ($actualHash -ne $expectedHash) {
    throw "Unsupported upstream DLL hash: $actualHash"
}

$testDirectory = Join-Path $projectRoot 'work\native-tests'
[System.IO.Directory]::CreateDirectory($testDirectory) | Out-Null
$testExecutable = Join-Path $testDirectory 'native_setkeys_test.exe'
$testSource = Join-Path $PSScriptRoot 'native_setkeys_test.c'
& $CompilerPath '-o' $testExecutable $testSource
if ($LASTEXITCODE -ne 0) {
    throw "Native test compilation failed: exit $LASTEXITCODE"
}
& $testExecutable $InjectPath
if ($LASTEXITCODE -ne 0) {
    throw "Native key-state regression failed: exit $LASTEXITCODE"
}
Write-Host 'native_setkeys_test: PASS (original DLL unchanged; no game process used)'
