$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$checks = 0
foreach ($name in @('build-from-source.ps1', 'build-package.ps1', 'build-public-package.ps1', 'rebuild-from-package.ps1')) {
    $text = [IO.File]::ReadAllText((Join-Path $project $name))
    $match = [regex]::Match($text, "notmatch '([^']+)'")
    if (-not $match.Success) { throw "Missing version validation: $name" }
    $pattern = $match.Groups[1].Value
    foreach ($value in @('0.1.9', '0.1.9.2', '0.1.9.2-local', '12.34.56.78-test', '0.1.8-test')) {
        if ($value -notmatch $pattern) { throw "Valid version rejected: $name / $value" }
        $checks++
    }
    foreach ($value in @('', '0.1', '0.1.9.2.3', '0.1.9.', '../0.1.9.2', '0.1.9.2/../x',
        '0.1.9.2 test', "0.1.9.2`n", "0.1.9.2`r`n", '0.1.9.2;test', '0.1.9.2-')) {
        if ($value -match $pattern) { throw "Unsafe version accepted: $name / $value" }
        $checks++
    }
    $tokens = $null; $errors = $null
    [Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -ne 0) { throw "PowerShell parse failed: $name" }
    $checks++
}
Write-Output "PASS: $checks release-version validation checks; three/four components accepted, unsafe paths rejected."
