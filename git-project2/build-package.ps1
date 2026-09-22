param([string] $Version = '2.0.7', [switch] $Overwrite)
$ErrorActionPreference = 'Stop'
if ($Version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(-[a-z0-9]+)?$') { throw 'Invalid package version.' }
$dist = Join-Path $PSScriptRoot 'dist\TH09-AI'
$zipPath = Join-Path $PSScriptRoot ('dist\TH09-AI-v' + $Version + '.zip')
if ([IO.File]::Exists($zipPath) -and -not $Overwrite) {
    throw "Package already exists: $zipPath. Choose a new version or pass -Overwrite."
}
foreach ($file in Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'src\ai') -File) {
    Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $dist ('ai\' + $file.Name)) -Force
}
foreach ($file in Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'src\launcher') -File) {
    if ($file.Extension -in @('.ps1', '.cmd') -and $file.Name -ne 'window-helper.ps1') {
        Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $dist $file.Name) -Force
    }
}
# Deterministic Windows-friendly text encodings are part of the build, not a
# manual post-release step. UTF-8 without BOM breaks Chinese strings in PS5.1.
foreach ($file in Get-ChildItem -LiteralPath $dist -File) {
    if ($file.Extension -in @('.ps1', '.cmd')) {
        $text = [IO.File]::ReadAllText($file.FullName) -replace '\r?\n', "`r`n"
        $encoding = if ($file.Extension -eq '.cmd') { [Text.Encoding]::ASCII } else { New-Object Text.UTF8Encoding($true) }
        [IO.File]::WriteAllText($file.FullName, $text, $encoding)
    }
}
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
# Review every relative path before opening an archive. A stray game executable,
# recording, save file or local configuration must not silently become public.
$allowedPaths = @(
    '^(README\.md|LICENSE\.txt|VERSION\.txt|launcher-settings\.json|prepare-and-start\.ps1|prepare-input\.ps1)$',
    '^(\u542f\u52a8TH09-AI\.cmd|\u4f7f\u7528\u8bf4\u660e\.txt|\u53d1\u5e03\u8bf4\u660e\.md)$',
    '^ai/(config|main|dodge|keyutils|bloom|bloom_observer)\.lua$',
    '^runtime/(inject\.dll|ka_ai_duka\.exe|th09ai-launcher\.exe|window_support\.(dll|def)|SHA256SUMS\.txt)$',
    '^licenses/(THIRD_PARTY_NOTICES\.txt|boost-LICENSE_1_0\.txt|lua-5\.1\.4\.txt|thprac-MIT\.txt|ka_ai_duka-readme-ja\.txt)$',
    '^licenses/ka_ai_duka/(LICENSE|readme)\.txt$',
    '^licenses/tinycc/(COPYING|GPL-2\.0\.txt|tcc-0\.9\.27\.tar\.bz2)$',
    '^source/[A-Za-z0-9_-]+\.(md|ps1|txt)$',
    '^source/src/ai/(config|main|dodge|keyutils|bloom|bloom_observer)\.lua$',
    '^source/src/launcher/(prepare-and-start\.ps1|prepare-input\.ps1|\u542f\u52a8TH09-AI\.cmd)$',
    '^source/src/native/[A-Za-z0-9_-]+\.(c|h|md)$'
) -join '|'
$packageFiles = foreach ($file in Get-ChildItem -LiteralPath $dist -Recurse -File) {
    $relative = $file.FullName.Substring($dist.Length + 1).Replace('\', '/')
    if ($relative -in @('runtime/ka_ai_duka.ini', 'ai/runtime-settings.lua', 'window-helper.ps1') -or
        $file.Extension -in @('.log', '.csv')) { continue }
    if ($relative -notmatch $allowedPaths) {
        throw "Unreviewed file in package: $relative. Move it outside dist before publishing."
    }
    [PSCustomObject]@{ File = $file.FullName; Relative = $relative }
}
$mode = if ($Overwrite) { [IO.FileMode]::Create } else { [IO.FileMode]::CreateNew }
$stream = [IO.File]::Open($zipPath, $mode, [IO.FileAccess]::Write)
$archive = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($file in $packageFiles) {
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file.File,
            'TH09-AI/' + $file.Relative, [IO.Compression.CompressionLevel]::Optimal) | Out-Null
    }
} finally {
    $archive.Dispose()
    $stream.Dispose()
}
Write-Output $zipPath
