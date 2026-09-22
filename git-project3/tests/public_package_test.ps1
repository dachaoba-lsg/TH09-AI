param([Parameter(Mandatory=$true)][string] $ZipPath, [string] $Version = '2.0.0',
    [string] $PackageName = 'TH09-AI')
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($ZipPath)
$checks = 0
function Check([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
    $script:checks++
}
function Read-Entry([string] $Name) {
    $entry = $zip.GetEntry($PackageName + '/' + $Name)
    if (-not $entry) { throw "Missing entry: $Name" }
    $reader = New-Object IO.StreamReader($entry.Open(), [Text.Encoding]::UTF8)
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}
function Entry-Hash([string] $Name) {
    $entry = $zip.GetEntry($PackageName + '/' + $Name)
    if (-not $entry) { throw "Missing entry: $Name" }
    $stream = $entry.Open()
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '') }
    finally { $stream.Dispose(); $sha.Dispose() }
}
try {
    $difficultyGuide = -join ([char[]]@(0x907F, 0x5F39, 0x96BE, 0x5EA6, 0x6321, 0x4F4D))
    $required = @('README.md','LICENSE.txt','VERSION.txt','launcher-settings.json', ($difficultyGuide + '.md'),
        'set-difficulty.ps1','set-difficulty.cmd',
        'licenses/THIRD_PARTY_NOTICES.txt','licenses/ka_ai_duka/LICENSE.txt',
        'licenses/ka_ai_duka/readme.txt','licenses/lua-5.1.4.txt',
        'licenses/boost-LICENSE_1_0.txt','licenses/thprac-MIT.txt',
        'licenses/tinycc/COPYING','licenses/tinycc/GPL-2.0.txt','licenses/tinycc/tcc-0.9.27.tar.bz2',
        'source/BUILD.md','source/build-native.ps1','source/build-package.ps1',
        'source/build-public-package.ps1','source/rebuild-from-package.ps1',
        'source/LICENSE.txt','source/src/native/launcher.c',
        'source/src/native/ai_side_config.h','source/src/native/ai_input_patches.h',
        'source/src/native/enemy_sensor.c','source/src/native/enemy_sensor.h','source/src/native/enemy_sensor_selftest.c',
        'source/src/native/window_support.c','source/src/native/practice_patches.c',
        'source/src/native/laser_sensor.c','source/src/native/laser_sensor.h',
        'source/src/native/player_sensor.c','source/src/native/player_sensor.h',
        'source/src/native/player_sensor_selftest.c')
    foreach ($path in $required) {
        Check ($null -ne $zip.GetEntry($PackageName + '/' + $path)) "Missing required release material: $path"
    }
    foreach ($entry in $zip.Entries) {
        Check ($entry.FullName.StartsWith($PackageName + '/')) "Invalid ZIP root: $($entry.FullName)"
        Check ($entry.FullName -notmatch '(^|/)(th09\.exe|score[^/]*\.(dat|data)|th09\.cfg|ka_ai_duka\.ini|runtime-settings\.lua|__pycache__|vendor|work)(/|$)|\.(log|csv|mp4|mkv|avi|pyc|anm|ecl)$') "Private/game/generated file in archive: $($entry.FullName)"
        if ($entry.FullName -match '\.(md|ps1|lua|json|cmd|c|h|txt)$' -and
            $entry.FullName -notmatch 'licenses/ka_ai_duka') {
            $name = $entry.FullName.Substring($PackageName.Length + 1)
            $text = Read-Entry $name
            Check ($text -notmatch '(?i)[A-Z]:[\\/](Users|Documents and Settings)[\\/]|[A-Z]:[\\/](game[\\/]aiTh09|testgame)([\\/]|$)') "Personal local path in archive: $name"
            if ($entry.FullName.EndsWith('.ps1')) {
                $tokens = $null; $parseErrors = $null
                [Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$parseErrors) | Out-Null
                Check ($parseErrors.Count -eq 0) "Invalid PowerShell source in archive: $name"
            }
        }
    }
    $settings = (Read-Entry 'launcher-settings.json') | ConvertFrom-Json
    Check ($settings.seconds -eq 600) 'Public timer default is not 600.'
    Check ($settings.practice.player1_no_damage -eq $false) 'No-damage enabled in public default.'
    Check ($settings.practice.player1_invincible -eq $false) 'Invincibility enabled in public default.'
    Check ($settings.window.resizable -eq $true) 'Resizable default changed.'
    Check ($settings.ai.difficulty -eq 'human200') 'Public dodge difficulty default is not human200.'
    Check ($settings.ai.side -is [int] -and $settings.ai.side -eq 2) 'Public AI side must default to numeric 2.'
    Check ($settings.ai.side_key -is [string] -and $settings.ai.side_key.Length -eq 0) 'Public AI side key must be an empty string.'
    Check ($settings.ai.move_change_budget -eq 6) 'Public movement-change budget default is not 6.'
    Check ([Math]::Abs([double]$settings.ai.vision_radius - (448.0 / 3.0)) -lt 0.00000001) 'Public vision radius default is not one third of the 448-unit field height.'
    Check ($null -eq $settings.ai.PSObject.Properties['attention_capacity']) 'The public default must not override preset attention capacity.'
    Check ($null -eq $settings.ai.PSObject.Properties['attention_recovery_per_second']) 'The public default must not override preset attention recovery.'
    Check ($null -eq $settings.ai.PSObject.Properties['threat_per_second']) 'The public default must not pin the tier budget.'
    Check ($null -eq $settings.ai.PSObject.Properties['tracked_threat']) 'The public default must not pin the tier budget.'
    Check ($settings.ai.overload_action -eq 'c_then_panic') 'Public overload action default changed.'
    Check ((Read-Entry 'LICENSE.txt') -eq (Read-Entry 'source/LICENSE.txt')) 'Root/source MIT licenses differ.'
    $author = -join ([char[]](0x5723,0x8bde,0x8001,0x4eba,0x7684,0x9a6f,0x9e7f))
    Check ((Read-Entry 'LICENSE.txt').Contains('Copyright (c) 2026 ' + $author + '-xunlu')) 'Author mismatch.'
    Check ((Read-Entry 'VERSION.txt').StartsWith($PackageName + ' ' + $Version)) 'Version mismatch.'
    # Compare complete Lua module inventories, so newly added modules cannot be
    # omitted from either the runtime or the corresponding editable source.
    $runtimeLua = @($zip.Entries | Where-Object { $_.FullName -match ('^' + $PackageName + '/ai/[^/]+\.lua$') } |
        ForEach-Object { $_.FullName.Substring(($PackageName + '/ai/').Length) } | Sort-Object)
    $sourceLua = @($zip.Entries | Where-Object { $_.FullName -match ('^' + $PackageName + '/source/src/ai/[^/]+\.lua$') } |
        ForEach-Object { $_.FullName.Substring(($PackageName + '/source/src/ai/').Length) } | Sort-Object)
    foreach ($file in @('main.lua','config.lua','dodge.lua','keyutils.lua','bloom.lua','bloom_observer.lua')) {
        Check ($runtimeLua -contains $file) "Missing required bloom AI module: $file"
    }
    Check (($runtimeLua -join '|') -eq ($sourceLua -join '|')) 'Runtime/source Lua module inventories differ.'
    foreach ($file in $runtimeLua) {
        Check ((Entry-Hash ('ai/' + $file)) -eq (Entry-Hash ('source/src/ai/' + $file))) "AI source/runtime mismatch: $file"
    }
    $expectedHashes = @{
        'runtime/inject.dll' = '2BA67F1F80EBE53F978DC6843777764B5EAD911A688C89C9CD68CC8C2D9CAE00'
        'runtime/ka_ai_duka.exe' = '625AFFD9F34E7580B4DDC9062F4C9A0AEB8829C46EB1F5D01928C1BC09B2F625'
        'licenses/tinycc/tcc-0.9.27.tar.bz2' = 'DE23AF78FCA90CE32DFF2DD45B3432B2334740BB9BB7B05BF60FDBFC396CEB9C'
    }
    foreach ($path in $expectedHashes.Keys) {
        Check ((Entry-Hash $path) -eq $expectedHashes[$path]) "Binary/source archive unexpectedly changed: $path"
    }
    foreach ($line in ((Read-Entry 'runtime/SHA256SUMS.txt') -split '\r?\n')) {
        if (-not $line.Trim()) { continue }
        Check ($line -match '^([0-9A-Fa-f]{64})  ([A-Za-z0-9_.-]+)$') 'Invalid runtime hash manifest line.'
        $expected = $Matches[1]; $filename = $Matches[2]
        Check ((Entry-Hash ('runtime/' + $filename)) -eq $expected) "Runtime hash manifest mismatch: $filename"
    }
    Check ($null -eq $zip.GetEntry($PackageName + '/licenses/ka_ai_duka-MIT.txt')) 'Misleading legacy license filename present.'
    Write-Output "PASS: $checks public-package checks; $($zip.Entries.Count) entries."
} finally { $zip.Dispose() }
