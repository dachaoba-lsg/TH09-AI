param([Parameter(Mandatory = $true)][string] $GameRoot, [switch] $CheckOnly)
$ErrorActionPreference = 'Stop'
# Fixed keyboard TYPE dispatch, not the unused saved VK/DIK arrays.
# The native launcher remaps LEFT in memory to WASD/J/K/L for 2P.
$path = Join-Path $GameRoot 'th09.cfg'
if (-not [IO.File]::Exists($path)) { throw 'th09.cfg is missing. Run custom.exe once.' }
$bytes = [IO.File]::ReadAllBytes($path)
if ($bytes.Length -ne 0xCC) { throw 'Unknown th09.cfg layout; refusing to modify it.' }
if ($bytes[0xB7] -ne 2) {
    throw 'This package requires 1P Type=FULL in Option > Key Config. 1P mode has not been changed.'
}
if ($bytes[0xB8] -eq 3) { Write-Output '2P Type=LEFT (remapped by AI launcher to WASD/J/K/L).'; return }
if ($CheckOnly) { Write-Output 'On launch: back up th09.cfg, preserve 1P FULL, set 2P LEFT with native WASD/J/K/L mapping.'; return }
foreach ($process in @(Get-Process -Name th09 -ErrorAction SilentlyContinue)) {
    if ($process.Path -ieq (Join-Path $GameRoot 'th09.exe')) { throw 'Close this TH09 before changing input settings.' }
}
$backup = $path + '.before-ai-input-v014-' + [DateTime]::Now.ToString('yyyyMMdd-HHmmss-fff') + '.bak'
[IO.File]::Copy($path, $backup, $false)
$bytes[0xB8] = 3
[IO.File]::WriteAllBytes($path, $bytes)
Write-Output ('2P LEFT selected; native launcher supplies WASD/J/K/L. Backup: ' + $backup)
