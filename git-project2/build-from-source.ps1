param(
    [Parameter(Mandatory = $true)][string] $CompilerPath,
    [string] $Version = '',
    [switch] $SkipDependencyDownload,
    [switch] $Overwrite
)
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$metadata = Get-Content -LiteralPath (Join-Path $projectRoot 'project.json') -Raw | ConvertFrom-Json
if (-not $Version) { $Version = [string]$metadata.version }
$packageName = [string]$metadata.name
if ($Version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(-[a-z0-9]+)?$') { throw 'Invalid version.' }
if ($packageName -notmatch '^[A-Za-z0-9_-]+$') { throw 'Invalid project package name.' }
if (-not [IO.Path]::IsPathRooted($CompilerPath) -or -not [IO.File]::Exists($CompilerPath)) {
    throw 'CompilerPath must point to tcc.exe in a complete TinyCC 0.9.27 i386 Windows installation.'
}
$CompilerPath = [IO.Path]::GetFullPath($CompilerPath)
$compilerVersion = (& $CompilerPath -v | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $compilerVersion -notmatch '0\.9\.27.*i386 Windows') {
    throw "Expected TinyCC 0.9.27 i386 Windows. Reported: $compilerVersion"
}
$zipPath = Join-Path $projectRoot ('dist\' + $packageName + '-v' + $Version + '.zip')
if ([IO.File]::Exists($zipPath) -and -not $Overwrite) {
    throw 'This version already exists in dist. Choose another -Version or explicitly pass -Overwrite.'
}
$prepare = Join-Path $projectRoot 'scripts\prepare-dependencies.ps1'
if ($SkipDependencyDownload) { & $prepare -VerifyOnly } else { & $prepare }

# Only curated templates and verified third-party runtime files seed dist.
# A build never searches for, copies or launches an installed game.
$target = Join-Path $projectRoot 'dist\TH09-AI'
[void][IO.Directory]::CreateDirectory((Join-Path $target 'runtime'))
[void][IO.Directory]::CreateDirectory((Join-Path $target 'ai'))
function Copy-SourceTree([string] $Source, [string] $Destination) {
    $prefix = [IO.Path]::GetFullPath($Source).TrimEnd('\') + '\'
    foreach ($file in Get-ChildItem -LiteralPath $Source -Recurse -File) {
        if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Source templates must not be symbolic links.'
        }
        $relative = $file.FullName.Substring($prefix.Length)
        $to = Join-Path $Destination $relative
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($to))
        [IO.File]::Copy($file.FullName, $to, $true)
    }
}
Copy-SourceTree (Join-Path $projectRoot 'package') $target
Copy-SourceTree (Join-Path $projectRoot 'licenses') (Join-Path $target 'licenses')
foreach ($name in @('inject.dll', 'ka_ai_duka.exe')) {
    [IO.File]::Copy((Join-Path $projectRoot ('vendor\release\ka_ai_duka\' + $name)),
        (Join-Path $target ('runtime\' + $name)), $true)
}
$versionFile = Join-Path $target 'VERSION.txt'
$versionText = [IO.File]::ReadAllText($versionFile)
$versionText = [regex]::Replace($versionText, '\A[^\r\n]*', ($packageName + ' ' + $Version))
[IO.File]::WriteAllText($versionFile, $versionText, (New-Object Text.UTF8Encoding($false)))
& (Join-Path $projectRoot 'build-native.ps1') -CompilerPath $CompilerPath
$buildScript = Join-Path $projectRoot 'build-public-package.ps1'
$buildArguments = @{ Version = $Version; Overwrite = $Overwrite }
if ((Get-Command $buildScript).Parameters.ContainsKey('PackageName')) { $buildArguments.PackageName = $packageName }
& $buildScript @buildArguments
if (-not [IO.File]::Exists($zipPath)) { throw 'The expected release archive was not generated.' }
$checkScript = Join-Path $projectRoot 'tests\public_package_test.ps1'
$checkArguments = @{ ZipPath = $zipPath; Version = $Version }
if ((Get-Command $checkScript).Parameters.ContainsKey('PackageName')) { $checkArguments.PackageName = $packageName }
& $checkScript @checkArguments
Write-Output ('Source build and public package validation passed: ' + $zipPath)
