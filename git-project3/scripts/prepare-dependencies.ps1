[CmdletBinding()]
param([switch] $VerifyOnly)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)).TrimEnd('\')
$rootPrefix = $repoRoot + '\'
$lock = Get-Content -LiteralPath (Join-Path $repoRoot 'dependencies.lock.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ($lock.schema_version -ne 1) { throw 'Unsupported dependencies.lock.json schema.' }
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Assert-RelativePath([string] $Relative) {
    if ([string]::IsNullOrWhiteSpace($Relative) -or [IO.Path]::IsPathRooted($Relative) -or $Relative.Contains(':')) {
        throw "Unsafe relative path: $Relative"
    }
    $parts = $Relative.Replace('\', '/').Split('/')
    foreach ($part in $parts) {
        if ($part -eq '..' -or $part -eq '.' -or $part -eq '' -or $part -match '[. ]$' -or $part -match '[<>"|?*]' -or $part -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') {
            throw "Unsafe relative path: $Relative"
        }
    }
}

function Resolve-SafePath([string] $Relative) {
    Assert-RelativePath $Relative
    $full = [IO.Path]::GetFullPath((Join-Path $repoRoot $Relative))
    if (-not $full.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Path escapes repository: $Relative" }
    $cursor = $full
    while ($cursor.Length -ge $repoRoot.Length) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Refusing reparse point: $cursor" }
        }
        if ($cursor -eq $repoRoot) { break }
        $cursor = Split-Path -Parent $cursor
    }
    return $full
}

function Assert-File([string] $Path, [string] $Hash, [long] $Size) {
    if (-not [IO.File]::Exists($Path)) { throw "Required dependency file missing: $Path. Run scripts/prepare-dependencies.ps1 without -VerifyOnly." }
    $stream = [IO.File]::OpenRead($Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $actualHash = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '') } finally { $sha.Dispose(); $stream.Dispose() }
    if ((Get-Item -LiteralPath $Path).Length -ne $Size -or $actualHash -ne $Hash) {
        throw "Dependency verification failed; the existing file was preserved: $Path. Review it and move it aside yourself before retrying."
    }
}

function Get-Archive($Dependency) {
    Assert-RelativePath $Dependency.archive
    $archive = Resolve-SafePath ('downloads/' + $Dependency.archive)
    if (Test-Path -LiteralPath $archive) {
        Assert-File $archive $Dependency.sha256 $Dependency.size
        return $archive
    }
    [IO.Directory]::CreateDirectory((Split-Path -Parent $archive)) | Out-Null
    $partial = $archive + '.partial-' + [Guid]::NewGuid().ToString('N')
    Write-Host ('Downloading pinned dependency: ' + $Dependency.name)
    $oldProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -UseBasicParsing -Uri $Dependency.url -OutFile $partial -Headers @{ 'User-Agent' = 'TH09-AI-dependency-bootstrap' }
        Assert-File $partial $Dependency.sha256 $Dependency.size
        [IO.File]::Move($partial, $archive)
    } catch {
        throw "Dependency download failed. Any partial file is retained at $partial. $($_.Exception.Message)"
    } finally { $ProgressPreference = $oldProgress }
    return $archive
}

function Open-CheckedArchive([string] $Path, $Dependency) {
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entries = @{}
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName.Replace('\', '/')
            $relative = $name.TrimEnd('/')
            Assert-RelativePath $relative
            if ($entries.ContainsKey($relative)) { throw "Duplicate archive entry: $relative" }
            # ZIP Unix symlinks are never followed or extracted.
            if ((($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) { throw "Archive contains symbolic link: $relative" }
            $entries[$relative] = $entry
        }
        foreach ($file in $Dependency.files) {
            $name = $Dependency.archive_prefix + $file.path
            if (-not $entries.ContainsKey($name)) { throw "Pinned archive entry missing: $name" }
            $entry = $entries[$name]
            if ($entry.Length -ne $file.size) { throw "Archive entry size mismatch: $name" }
            $stream = $entry.Open()
            $sha = [Security.Cryptography.SHA256]::Create()
            try { $hash = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '') } finally { $sha.Dispose(); $stream.Dispose() }
            if ($hash -ne $file.sha256) { throw "Archive entry hash mismatch: $name" }
        }
        return $zip
    } catch { $zip.Dispose(); throw }
}

$jobs = New-Object Collections.ArrayList
$seenTargets = @{}
# Check every existing target before downloading or writing dependency files.
foreach ($dependency in $lock.dependencies) {
    Assert-RelativePath $dependency.destination
    if (-not $dependency.destination.StartsWith('vendor/', [StringComparison]::Ordinal)) { throw 'Dependency destination must be under vendor/.' }
    if (-not $dependency.url.StartsWith('https://', [StringComparison]::Ordinal)) { throw 'Dependency download must use HTTPS.' }
    $missing = New-Object Collections.ArrayList
    foreach ($file in $dependency.files) {
        Assert-RelativePath $file.path
        $target = Resolve-SafePath ($dependency.destination + '/' + $file.path)
        if ($seenTargets.ContainsKey($target)) { throw "Duplicate dependency target: $target" }
        $seenTargets[$target] = $true
        if (Test-Path -LiteralPath $target) { Assert-File $target $file.sha256 $file.size }
        elseif ($VerifyOnly) { throw "Required dependency file missing: $target. Run scripts/prepare-dependencies.ps1 without -VerifyOnly." }
        else { [void] $missing.Add($file) }
    }
    if ($missing.Count -gt 0) { [void] $jobs.Add(@{ Dependency = $dependency; Missing = $missing; Zip = $null }) }
}

try {
    # Verify all archives and selected entries before creating any target files.
    foreach ($job in $jobs) {
        $archive = Get-Archive $job.Dependency
        $job.Zip = Open-CheckedArchive $archive $job.Dependency
    }
    foreach ($job in $jobs) {
        foreach ($file in $job.Missing) {
            $target = Resolve-SafePath ($job.Dependency.destination + '/' + $file.path)
            [IO.Directory]::CreateDirectory((Split-Path -Parent $target)) | Out-Null
            # CreateNew also refuses a file created concurrently after preflight.
            $output = [IO.File]::Open($target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try {
                $inputStream = $job.Zip.GetEntry($job.Dependency.archive_prefix + $file.path).Open()
                try { $inputStream.CopyTo($output) } finally { $inputStream.Dispose() }
            } finally { $output.Dispose() }
            Assert-File $target $file.sha256 $file.size
        }
    }
} finally {
    foreach ($job in $jobs) { if ($null -ne $job.Zip) { $job.Zip.Dispose() } }
}
Write-Output ('Dependencies verified: {0} pinned files. No game files are downloaded or launched.' -f $seenTargets.Count)
