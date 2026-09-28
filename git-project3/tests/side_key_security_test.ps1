param([string] $LauncherPath = (Join-Path $PSScriptRoot '..\src\launcher\prepare-and-start.ps1'))
# Exercise the actual verifier function without executing launcher startup.
# All known-answer passwords below are public synthetic fixtures, not 1P keys.
$ErrorActionPreference = 'Stop'
$checks = 0
function Check([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
    $script:checks++
}
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput([IO.File]::ReadAllText([IO.Path]::GetFullPath($LauncherPath)), [ref]$tokens, [ref]$parseErrors)
Check ($parseErrors.Count -eq 0) 'Launcher parse failed.'
$functionAst = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-AiSideKey' }, $true)
Check ($null -ne $functionAst) 'Actual key verifier was not found.'
$definition = $functionAst.Extent.Text
$recordMatch = [regex]::Match($definition, "(?m)^  \`$record = '([^']+)'\r?`$")
Check $recordMatch.Success 'Verifier record must be an explicit versioned constant.'
$releaseRecord = $recordMatch.Groups[1].Value
$fields = $releaseRecord.Split([char]'$')
Check ($fields.Length -eq 5 -and $fields[0] -ceq 'v1' -and $fields[1] -ceq 'pbkdf2-sha256' -and $fields[2] -ceq '600000') 'Unexpected release KDF parameters.'
Check (([Convert]::FromBase64String($fields[3])).Length -eq 16) 'Release salt must be 128 bits.'
Check (([Convert]::FromBase64String($fields[4])).Length -eq 32) 'Release verifier must be 256 bits.'
Check ($definition -notmatch 'ComputeHash|ToLowerInvariant|ToUpperInvariant|\.Trim\(') 'Fast-hash fallback or key normalization appeared.'
Check ($definition -match 'HashAlgorithmName\]::SHA256') 'KDF must select SHA256 explicitly.'

$vectorKey = 'synthetic-test-key-not-an-authorization-key'
# Independently computed with Python hashlib.pbkdf2_hmac SHA256.
$vectorRecord = 'v1$pbkdf2-sha256$600000$AAECAwQFBgcICQoLDA0ODw==$v9o5pU5qokx2MpRKu+84j+vjBvD1uqf8Dpsc7QA0L5E='
$vectorDefinition = $definition.Replace($releaseRecord, $vectorRecord)
. ([scriptblock]::Create($vectorDefinition))
$timer = [Diagnostics.Stopwatch]::StartNew()
Check (Test-AiSideKey $vectorKey) 'Independent SHA256 PBKDF2 known-answer vector failed.'
$timer.Stop()
Check (-not (Test-AiSideKey 'synthetic-wrong-test-key')) 'Wrong key accepted.'

$unicodeKey = 'synthetic-' + [char]0x56fa + [char]0x7075 + '-' + [char]::ConvertFromUtf32(0x1f600)
$unicodeRecord = 'v1$pbkdf2-sha256$600000$AAECAwQFBgcICQoLDA0ODw==$CRpbSD/6qkXTDWBYZHu5RAt42iUprxC2EuU3OKcDeQI='
. ([scriptblock]::Create($definition.Replace($releaseRecord, $unicodeRecord)))
Check (Test-AiSideKey $unicodeKey) 'Exact UTF8 or surrogate pair handling failed.'

# Invalid input must be rejected before spending any KDF work.
$script:deriveCalls = 0
$countedDefinition = $vectorDefinition.Replace('$kdf = [Security.Cryptography.Rfc2898DeriveBytes]::new', '$script:deriveCalls++; $kdf = [Security.Cryptography.Rfc2898DeriveBytes]::new')
. ([scriptblock]::Create($countedDefinition))
foreach ($value in @($null, 0, $true, $false, @(1,2), @{ key='synthetic' }, '', ('a' * 257), ([string][char]0xd800), ($vectorKey + [char]0), ('a' + [char]0 + 'b'))) {
    $result = @(Test-AiSideKey $value *>&1)
    Check ($result.Count -eq 1 -and $result[0] -is [bool] -and -not $result[0]) 'Invalid input must fail silently.'
}
Check ($script:deriveCalls -eq 0) 'Rejected input reached PBKDF2.'

# Corrupted, unknown, or weakened metadata must fail before a crypto call.
foreach ($record in @(
    $vectorRecord.Replace('v1$', 'v2$'),
    $vectorRecord.Replace('pbkdf2-sha256', 'pbkdf2-sha1'),
    $vectorRecord.Replace('$600000$', '$599999$'),
    $vectorRecord.Replace('$600000$', '$600001$'),
    $vectorRecord.Replace('$600000$', '$0600000$'),
    $vectorRecord.Replace('AAECAwQFBgcICQoLDA0ODw==', 'not-base64'),
    $vectorRecord.Replace('AAECAwQFBgcICQoLDA0ODw==', 'AA=='),
    $vectorRecord.Replace('v9o5pU5qokx2MpRKu+84j+vjBvD1uqf8Dpsc7QA0L5E=', 'AA=='),
    ($vectorRecord + '$extra')
)) {
    . ([scriptblock]::Create($countedDefinition.Replace($vectorRecord, $record)))
    $result = @(Test-AiSideKey $vectorKey *>&1)
    Check ($result.Count -eq 1 -and $result[0] -is [bool] -and -not $result[0]) 'Invalid KDF metadata must fail silently.'
}
Check ($script:deriveCalls -eq 0) 'Invalid KDF metadata reached PBKDF2.'

# Substitute only the derivation result to isolate comparison/cleanup. All
# 32 mismatch positions must be rejected; full PBKDF2 itself was tested above.
$derivedHex = 'v9o5pU5qokx2MpRKu+84j+vjBvD1uqf8Dpsc7QA0L5E='
$fixedDefinition = $vectorDefinition.Replace('$derived = $kdf.GetBytes(32)', ('$derived = [Convert]::FromBase64String(''' + $derivedHex + ''')'))
$fixedDefinition = $fixedDefinition.Replace('for ($i = 0; $i -lt 32; $i++) {', 'for ($i = 0; $i -lt 32; $i++) { $script:comparisonIterations++')
for ($position = 0; $position -lt 32; $position++) {
    $mismatch = [Convert]::FromBase64String($derivedHex)
    $mismatch[$position] = $mismatch[$position] -bxor 1
    $mismatchRecord = $vectorRecord.Replace($derivedHex, [Convert]::ToBase64String($mismatch))
    . ([scriptblock]::Create($fixedDefinition.Replace($vectorRecord, $mismatchRecord)))
    $script:comparisonIterations = 0
    Check (-not (Test-AiSideKey $vectorKey)) 'Digest mismatch was accepted.'
    Check ($script:comparisonIterations -eq 32) 'Digest comparison exited before inspecting every byte.'
}
. ([scriptblock]::Create($fixedDefinition))
Check (Test-AiSideKey ('a' * 256)) 'Maximum-length candidate was incorrectly rejected before comparison.'
Check (-not (Test-AiSideKey ('a' * 257))) 'Overlong candidate reached the comparison.'
$capturingDefinition = $fixedDefinition.Replace('    $difference = 0', '    $script:capturedBuffers = @($keyBytes, $derived, $expected, $salt); $difference = 0')
. ([scriptblock]::Create($capturingDefinition))
Check (Test-AiSideKey $vectorKey) 'Equal derived bytes were rejected.'
Check ($script:capturedBuffers.Count -eq 4) 'Secret buffer cleanup fixture failed.'
foreach ($buffer in $script:capturedBuffers) {
    Check (@($buffer | Where-Object { $_ -ne 0 }).Count -eq 0) 'Temporary byte buffers were not cleared.'
}

# Old Framework/crypto/provider failures must not expose exception text or
# turn into a weak-hash fallback. Inject failure at the actual constructor.
$failingDefinition = $vectorDefinition.Replace('$kdf = [Security.Cryptography.Rfc2898DeriveBytes]::new($keyBytes, $salt, 600000, [Security.Cryptography.HashAlgorithmName]::SHA256)', 'throw (''synthetic-provider-failure-'' + $candidate)')
Check ($failingDefinition -cne $vectorDefinition) 'Failure injection did not reach the constructor.'
. ([scriptblock]::Create($failingDefinition))
$result = @(Test-AiSideKey $vectorKey *>&1)
Check ($result.Count -eq 1 -and $result[0] -is [bool] -and -not $result[0]) 'Crypto failure must return only false without private details.'

Write-Output ('PASS: {0} side-key security checks; real PBKDF2 SHA256/600000 known-answer time {1:N0} ms; no private key used.' -f $checks, $timer.Elapsed.TotalMilliseconds)
