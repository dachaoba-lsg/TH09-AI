param(
    [Parameter(Mandatory=$true)][string] $GameExe,
    [string] $RuntimePath
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not $RuntimePath) { $RuntimePath = Join-Path $projectRoot 'dist\TH09-AI\runtime' }
$fixture = Join-Path $projectRoot ('work\support-test-' + [Guid]::NewGuid().ToString('N'))
$gameFixture = Join-Path $fixture 'game'
[IO.Directory]::CreateDirectory($gameFixture) | Out-Null
foreach ($name in @('th09ai-launcher.exe','inject.dll','window_support.dll')) {
    Copy-Item -LiteralPath (Join-Path $RuntimePath $name) -Destination (Join-Path $fixture $name)
}
# Run only a copied executable with its local loader dependencies. No ResumeThread
# is used by verification mode, and no original game file is written.
$GameExe = (Resolve-Path -LiteralPath $GameExe).ProviderPath
Copy-Item -LiteralPath $GameExe -Destination (Join-Path $gameFixture 'th09.exe')
foreach ($dependency in [IO.Directory]::GetFiles((Split-Path -Parent $GameExe), '*.dll')) {
    Copy-Item -LiteralPath $dependency -Destination $gameFixture
}
$testGame = Join-Path $gameFixture 'th09.exe'
$scriptPath = Join-Path $fixture 'dummy.lua'
[IO.File]::WriteAllText($scriptPath, '-- Suspended-only fixture. Main thread never executes.', [Text.Encoding]::ASCII)
$iniPath = Join-Path $fixture 'ka_ai_duka.ini'
$checks = 0
function Invoke-Suspended([string]$Name, [int]$ExpectedExit) {
    $stdout = Join-Path $fixture ($Name + '-stdout.log')
    $stderr = Join-Path $fixture ($Name + '-stderr.log')
    $process = Start-Process -FilePath (Join-Path $fixture 'th09ai-launcher.exe') -ArgumentList @(('"{0}"' -f $testGame), '--verify-suspended') -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $null = $process.Handle # Keep the handle for ExitCode in Windows PowerShell 5.1.
    if (-not $process.WaitForExit(45000)) {
        Stop-Process -Id $process.Id -ErrorAction SilentlyContinue
        throw "Suspended verification timed out: $Name"
    }
    $process.Refresh()
    if ($process.ExitCode -ne $ExpectedExit) {
        throw "Unexpected exit for ${Name}: $($process.ExitCode); expected $ExpectedExit. $([IO.File]::ReadAllText($stderr))"
    }
    $script:checks++
}
foreach ($side in @(1,2)) {
    foreach ($noDamage in @(0,1)) {
        foreach ($invincible in @(0,1)) {
            $enabled1 = if ($side -eq 1) { 'true' } else { 'false' }
            $enabled2 = if ($side -eq 2) { 'true' } else { 'false' }
            $script1 = if ($side -eq 1) { $scriptPath } else { '' }
            $script2 = if ($side -eq 2) { $scriptPath } else { '' }
            $ini = "[common]`r`nexe_path=$testGame`r`nsnapshot=false`r`n[1P]`r`nenabled=$enabled1`r`nscript_path=$script1`r`n[2P]`r`nenabled=$enabled2`r`nscript_path=$script2`r`n[practice]`r`nplayer1_no_damage=$noDamage`r`nplayer1_invincible=$invincible`r`n[window]`r`nenabled=0`r`n"
            [IO.File]::WriteAllText($iniPath, $ini, [Text.Encoding]::Default)
            Invoke-Suspended "side-$side-practice-$noDamage-$invincible" 0
        }
    }
}
$log = [IO.File]::ReadAllText((Join-Path $fixture 'native-window.log'))
foreach ($line in @('both player-1 options disabled', 'install=ok player=1 no_damage=0 invincible=1', 'install=ok player=1 no_damage=1 invincible=0', 'install=ok player=1 no_damage=1 invincible=1')) {
    if (-not $log.Contains($line)) { throw "Missing initialization evidence: $line" }
}
foreach ($line in @('ai-input: verified AI=1P exclusive; human=2P unchanged', 'ai-input: verified AI=2P exclusive; human=1P unchanged', 'practice: AI=1P; player-1 practice forced off; no protection transferred to 2P')) {
    if ([regex]::Matches($log, [regex]::Escape($line)).Count -ne 4) { throw "Expected four initialization records: $line" }
}
if ([regex]::Matches($log, 'practice: both player-1 options disabled').Count -ne 5) {
    throw 'AI=1P must force both practice options off in all four combinations.'
}
foreach ($sensorReady in @('laser_sensor: install=ok managed segment anchor corrected; game physics unchanged', 'player_sensor: install=ok api=1 readonly snapshot; poison recomputed, C gate exported', 'enemy_sensor: install=ok api=1 readonly enemy combat')) {
    if ([regex]::Matches($log, [regex]::Escape($sensorReady)).Count -ne 8) {
        throw "Sensor was not verified in all eight suspended processes: $sensorReady"
    }
}
if ($log.Contains('install=FAILED')) { throw 'Sensor reported initialization failure.' }

# Invalid/misrouted configuration must fail before creating a game process.
$invalid = @{
    'both-off' = "[1P]`nenabled=false`nscript_path=`n[2P]`nenabled=false`nscript_path="
    'both-on' = "[1P]`nenabled=true`nscript_path=$scriptPath`n[2P]`nenabled=true`nscript_path=$scriptPath"
    'missing-side' = "[2P]`nenabled=true`nscript_path=$scriptPath"
    'bad-boolean' = "[1P]`nenabled=false`n[2P]`nenabled=1`nscript_path=$scriptPath"
    'wrong-case' = "[1P]`nenabled=false`n[2P]`nenabled=TRUE`nscript_path=$scriptPath"
    'enabled-no-script' = "[1P]`nenabled=false`n[2P]`nenabled=true`nscript_path="
    'disabled-with-script' = "[1P]`nenabled=false`nscript_path=$scriptPath`n[2P]`nenabled=true`nscript_path=$scriptPath"
}
foreach ($case in $invalid.GetEnumerator()) {
    [IO.File]::WriteAllText($iniPath, $case.Value, [Text.Encoding]::Default)
    Invoke-Suspended ('invalid-' + $case.Key) 3
}
Remove-Item -LiteralPath $iniPath
Invoke-Suspended 'missing-ini' 3

# Corrupt each side in the copied upstream DLL. Both opcodes must be validated,
# including the human side which the launcher must leave alone.
foreach ($side in @(1,2)) {
    $ini = "[common]`nexe_path=$testGame`nsnapshot=false`n[1P]`nenabled=false`nscript_path=`n[2P]`nenabled=true`nscript_path=$scriptPath`n[window]`nenabled=0`n"
    [IO.File]::WriteAllText($iniPath, $ini, [Text.Encoding]::Default)
    $dllBytes = [IO.File]::ReadAllBytes((Join-Path $RuntimePath 'inject.dll'))
    $rawOffset = if ($side -eq 1) { 0x1ce0f } else { 0x1ceaf }
    if ($dllBytes[$rawOffset] -ne 0x09) { throw 'Original DLL OR opcode was not the expected byte.' }
    $dllBytes[$rawOffset] = 0x08
    [IO.File]::WriteAllBytes((Join-Path $fixture 'inject.dll'), $dllBytes)
    Invoke-Suspended "changed-upstream-side-$side" 10
}
Write-Output "PASS: $checks suspended/configuration checks; both AI sides; human-side original instructions; AI=1P practice forcibly disabled; no game windows or player input."
Write-Output "Evidence: $fixture"
