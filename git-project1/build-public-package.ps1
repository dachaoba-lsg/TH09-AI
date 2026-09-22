param(
    [string] $Version = '0.1.9',
    [switch] $Overwrite
)
$ErrorActionPreference = 'Stop'
if ($Version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(-[a-z0-9]+)?$') { throw 'Invalid package version.' }
$project = [IO.Path]::GetFullPath($PSScriptRoot)
$dist = Join-Path $project 'dist\TH09-AI'
$zipPath = Join-Path $project ('dist\TH09-AI-v' + $Version + '.zip')
if ([IO.File]::Exists($zipPath) -and -not $Overwrite) {
    throw "ZIP already exists: $zipPath. Choose another -Version or explicitly pass -Overwrite."
}
if (-not [IO.Directory]::Exists($dist)) { throw 'Missing dist/TH09-AI. From an extracted source/ folder, run rebuild-from-package.ps1 first.' }
$playerGuide = -join ([char[]]@(0x4F7F, 0x7528, 0x8BF4, 0x660E))
$releaseNotes = -join ([char[]]@(0x53D1, 0x5E03, 0x8BF4, 0x660E))
$requiredPackageFiles = @('README.md', 'LICENSE.txt', 'VERSION.txt', 'launcher-settings.json',
    ($playerGuide + '.txt'), ($releaseNotes + '.md'),
    'runtime\ka_ai_duka.exe', 'runtime\inject.dll', 'runtime\th09ai-launcher.exe',
    'runtime\window_support.dll', 'runtime\SHA256SUMS.txt',
    'licenses\THIRD_PARTY_NOTICES.txt', 'licenses\ka_ai_duka-readme-ja.txt',
    'licenses\boost-LICENSE_1_0.txt', 'licenses\lua-5.1.4.txt', 'licenses\thprac-MIT.txt',
    'licenses\ka_ai_duka\LICENSE.txt', 'licenses\ka_ai_duka\readme.txt',
    'licenses\tinycc\COPYING', 'licenses\tinycc\GPL-2.0.txt', 'licenses\tinycc\tcc-0.9.27.tar.bz2')
foreach ($relative in $requiredPackageFiles) {
    $path = Join-Path $dist $relative
    if (-not [IO.File]::Exists($path) -or (Get-Item -LiteralPath $path).Length -eq 0) {
        throw "Missing or empty required player package/runtime/license file: $relative"
    }
}

# Publish only our editable code and explicitly named build/license documents.
# Never recursively copy the project root, vendor/, tests/, work/, or dist/.
$files = New-Object 'System.Collections.Generic.List[string]'
foreach ($name in @('build-native.ps1', 'build-package.ps1', 'build-public-package.ps1',
    'rebuild-from-package.ps1', 'PUBLIC-SOURCE-BUILD.md', 'LICENSE.txt', 'README.md')) {
    $files.Add($name)
}
foreach ($relative in @('src\ai', 'src\launcher', 'src\native')) {
    $directory = Join-Path $project $relative
    if (-not [IO.Directory]::Exists($directory)) { throw "Missing required source directory: $relative" }
    foreach ($file in Get-ChildItem -LiteralPath $directory -File) {
        $include = if ($relative -eq 'src\ai') {
            $file.Extension -eq '.lua' -and $file.Name -ne 'runtime-settings.lua'
        } elseif ($relative -eq 'src\launcher') {
            $file.Name -in @('prepare-and-start.ps1', 'prepare-input.ps1') -or $file.Extension -eq '.cmd'
        } else {
            $file.Extension -in @('.c', '.h') -or $file.Name -eq 'README.md'
        }
        if ($include) { $files.Add((Join-Path $relative $file.Name)) }
    }
}
foreach ($required in @('src\ai\main.lua', 'src\ai\config.lua', 'src\ai\dodge.lua', 'src\ai\keyutils.lua',
    'src\launcher\prepare-and-start.ps1', 'src\launcher\prepare-input.ps1',
    'src\native\launcher.c', 'src\native\window_support.c', 'src\native\window_resize.c',
    'src\native\window_resize.h', 'src\native\window_resize_selftest.c', 'src\native\input_patches.h',
    'src\native\practice_patches.c', 'src\native\practice_patches.h',
    'src\native\laser_sensor.c', 'src\native\laser_sensor.h',
    'src\native\laser_sensor_selftest.c', 'src\native\player_sensor.c',
    'src\native\player_sensor.h', 'src\native\player_sensor_selftest.c', 'src\native\README.md')) {
    if (-not $files.Contains($required)) { throw "Missing required source file: $required" }
}
if (@($files | Where-Object { $_ -like 'src\launcher\*.cmd' }).Count -ne 1) {
    throw 'Exactly one launcher CMD source is required.'
}
foreach ($relative in $files) {
    $path = Join-Path $project $relative
    if (-not [IO.File]::Exists($path) -or (Get-Item -LiteralPath $path).Length -eq 0) { throw "Missing or empty required public source/license document: $relative" }
    $text = [IO.File]::ReadAllText($path)
    # Generic documentation examples such as C:\tools are fine. Actual local
    # user profiles or this project's private development location are not.
    if ($text -match '(?i)[A-Z]:[\\/](Users|Documents and Settings)[\\/]' -or
        $text -match '(?i)[A-Z]:[\\/]game[\\/]aiTh09[\\/]') {
        throw "Personal absolute path found in public source: $relative. Replace it with a portable example."
    }
}

$stageRoot = Join-Path $project ('work\public-source-stage-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($stageRoot)
$bom = New-Object Text.UTF8Encoding($true)
foreach ($relative in $files) {
    $target = Join-Path $stageRoot $relative
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
    $source = Join-Path $project $relative
    # A release source/ folder has its own standalone rebuild workflow.
    # Do not copy the Git README's links to scripts/package/tests into it.
    if ($relative -eq 'README.md') { $source = Join-Path $project 'PUBLIC-SOURCE-BUILD.md' }
    if ([IO.Path]::GetExtension($relative) -in @('.ps1', '.cmd')) {
        $content = [IO.File]::ReadAllText($source) -replace '\r?\n', "`r`n"
        $encoding = if ([IO.Path]::GetExtension($relative) -eq '.cmd') { [Text.Encoding]::ASCII } else { $bom }
        [IO.File]::WriteAllText($target, $content, $encoding)
    } else {
        [IO.File]::Copy($source, $target)
    }
}
[IO.File]::Copy((Join-Path $project 'PUBLIC-SOURCE-BUILD.md'), (Join-Path $stageRoot 'BUILD.md'))
$sourceTarget = Join-Path $dist 'source'
if ([IO.Directory]::Exists($sourceTarget)) {
    $backupRoot = Join-Path $project 'work\public-source-backups'
    [void][IO.Directory]::CreateDirectory($backupRoot)
    $backup = Join-Path $backupRoot ([Guid]::NewGuid().ToString('N'))
    # Validate exact resolved directory targets before a recursive directory
    # move. Preserve the preceding generated snapshot instead of deleting it.
    $expectedSource = [IO.Path]::GetFullPath((Join-Path $project 'dist\TH09-AI\source'))
    $backupPrefix = [IO.Path]::GetFullPath($backupRoot).TrimEnd('\') + '\'
    if ([IO.Path]::GetFullPath($sourceTarget) -ne $expectedSource -or
        -not [IO.Path]::GetFullPath($backup).StartsWith($backupPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing a source snapshot move outside the expected build directories.'
    }
    if (([IO.File]::GetAttributes($sourceTarget) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Refusing to replace a source directory that is a link/junction.'
    }
    [IO.Directory]::Move($sourceTarget, $backup)
    Write-Output ('Previous generated source snapshot preserved at: ' + $backup)
}
if (-not [IO.Path]::GetFullPath($stageRoot).StartsWith(([IO.Path]::GetFullPath((Join-Path $project 'work')).TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase) -or
    [IO.Path]::GetFullPath($sourceTarget) -ne [IO.Path]::GetFullPath((Join-Path $project 'dist\TH09-AI\source'))) {
    throw 'Refusing a staged source move outside the expected build directories.'
}
[IO.Directory]::Move($stageRoot, $sourceTarget)
& (Join-Path $project 'build-package.ps1') -Version $Version -Overwrite:$Overwrite
