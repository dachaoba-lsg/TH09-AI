param(
    [Parameter(Mandatory = $true)] [string] $CompilerPath,
    [string] $Version = '3.5.0-test',
    [switch] $Overwrite
)
$ErrorActionPreference = 'Stop'
if ($Version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(-[a-z0-9]+)?$') { throw 'Invalid package version.' }
if (-not [IO.Path]::IsPathRooted($CompilerPath) -or -not [IO.File]::Exists($CompilerPath)) {
    throw 'CompilerPath must be the full path to a complete TinyCC 0.9.27 win32 installation/tcc.exe.'
}
$CompilerPath = [IO.Path]::GetFullPath($CompilerPath)
$compilerVersion = (& $CompilerPath -v | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $compilerVersion -notmatch '0\.9\.27.*i386 Windows') {
    throw "Expected TinyCC 0.9.27 i386 Windows. Compiler reported: $compilerVersion"
}
$sourceRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$outerPackage = [IO.Directory]::GetParent($sourceRoot).FullName
# The extracted release folder is the package name (for example DS-TH09-AI),
# so a rebuilt archive keeps the same delivery name as its parent package.
$PackageName = Split-Path -Leaf $outerPackage
if ($PackageName -notmatch '^[A-Za-z0-9_-]+$') { $PackageName = 'TH09-AI' }
$targetPackage = Join-Path $sourceRoot 'dist\TH09-AI'
$zipPath = Join-Path $sourceRoot ('dist\' + $PackageName + '-v' + $Version + '.zip')
if ([IO.File]::Exists($zipPath) -and -not $Overwrite) {
    throw "ZIP already exists: $zipPath. Choose another -Version or explicitly pass -Overwrite."
}
# Unicode names are built from code points so the script itself also runs in
# Windows PowerShell 5.1 when copied without a UTF-8 BOM.
$playerGuide = -join ([char[]]@(0x4F7F, 0x7528, 0x8BF4, 0x660E))
$releaseNotes = -join ([char[]]@(0x53D1, 0x5E03, 0x8BF4, 0x660E))
$difficultyGuide = -join ([char[]]@(0x907F, 0x5F39, 0x96BE, 0x5EA6, 0x6321, 0x4F4D))
$seedFiles = @('runtime\ka_ai_duka.exe', 'runtime\inject.dll', 'README.md',
    ($playerGuide + '.txt'), 'VERSION.txt', 'launcher-settings.json', 'LICENSE.txt', ($releaseNotes + '.md'),
    ($difficultyGuide + '.md'), 'set-difficulty.ps1', 'set-difficulty.cmd')
foreach ($relative in $seedFiles) {
    if (-not [IO.File]::Exists((Join-Path $outerPackage $relative))) {
        throw "Missing parent package file: $relative. Keep the full TH09-AI/source folder inside the complete extracted release."
    }
}
foreach ($required in @('build-native.ps1', 'build-package.ps1', 'build-public-package.ps1', 'PUBLIC-SOURCE-BUILD.md', 'LICENSE.txt', 'README.md')) {
    if (-not [IO.File]::Exists((Join-Path $sourceRoot $required))) { throw "Missing source build file: $required" }
}
$licenseSource = Join-Path $outerPackage 'licenses'
foreach ($relative in @('THIRD_PARTY_NOTICES.txt', 'ka_ai_duka-readme-ja.txt',
    'boost-LICENSE_1_0.txt', 'lua-5.1.4.txt', 'thprac-MIT.txt',
    'ka_ai_duka\LICENSE.txt', 'ka_ai_duka\readme.txt',
    'tinycc\COPYING', 'tinycc\GPL-2.0.txt', 'tinycc\tcc-0.9.27.tar.bz2')) {
    $path = Join-Path $licenseSource $relative
    if (-not [IO.File]::Exists($path) -or (Get-Item -LiteralPath $path).Length -eq 0) {
        throw "Missing or empty required parent license/source file: licenses/$relative"
    }
}
function Get-BuildHash([string] $Path) {
    $stream = [IO.File]::OpenRead($Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '') }
    finally { $stream.Dispose(); $sha.Dispose() }
}
if ((Get-BuildHash (Join-Path $outerPackage 'runtime\inject.dll')) -ne '2BA67F1F80EBE53F978DC6843777764B5EAD911A688C89C9CD68CC8C2D9CAE00' -or
    (Get-BuildHash (Join-Path $outerPackage 'runtime\ka_ai_duka.exe')) -ne '625AFFD9F34E7580B4DDC9062F4C9A0AEB8829C46EB1F5D01928C1BC09B2F625') {
    throw 'The parent package does not contain the supported unmodified upstream ka_ai_duka v1.7 runtime.'
}
# Only this source/ workspace receives build outputs. Do not copy the outer
# source/ folder, any game files, generated logs, or existing generated INI.
[void][IO.Directory]::CreateDirectory((Join-Path $targetPackage 'runtime'))
[void][IO.Directory]::CreateDirectory((Join-Path $targetPackage 'ai'))
foreach ($relative in $seedFiles) {
    $target = Join-Path $targetPackage $relative
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
    [IO.File]::Copy((Join-Path $outerPackage $relative), $target, $true)
}
foreach ($license in Get-ChildItem -LiteralPath $licenseSource -Recurse -File) {
    $relative = $license.FullName.Substring($licenseSource.Length + 1)
    $target = Join-Path (Join-Path $targetPackage 'licenses') $relative
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
    [IO.File]::Copy($license.FullName, $target, $true)
}
[IO.File]::WriteAllText((Join-Path $targetPackage 'VERSION.txt'), ("$PackageName $Version`r`nRebuilt from bundled source using TinyCC 0.9.27 win32.`r`n"), [Text.Encoding]::ASCII)
& (Join-Path $sourceRoot 'build-native.ps1') -CompilerPath $CompilerPath
& (Join-Path $sourceRoot 'build-public-package.ps1') -Version $Version -Overwrite:$Overwrite -PackageName $PackageName
Write-Output ('Rebuild complete under source/dist. Original release/game files were not modified: ' + $targetPackage)
