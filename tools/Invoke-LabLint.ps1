#Requires -Version 5.1
<#
.SYNOPSIS
    Parses and lints every PowerShell file in the repo; syntax-checks the shell scripts. Exit code 1 on any finding.

.DESCRIPTION
    Runs anywhere, Hyper-V or not: this is how the lab is checked before there is
    a lab. Needs PSScriptAnalyzer (Install-Module PSScriptAnalyzer -Scope CurrentUser).
#>
[CmdletBinding()]
param()

$root = Split-Path -Parent $PSScriptRoot
$settings = Join-Path $PSScriptRoot 'PSScriptAnalyzerSettings.psd1'
$files = Get-ChildItem -Path $root -Recurse -Include *.ps1, *.psm1, *.psd1 -File |
    Where-Object { $_.FullName -notmatch '\\\.git\\' }

$failed = $false

# 1. Parser errors (what PowerShell itself would refuse to run).
foreach ($f in $files) {
    $tokens = $null; $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    foreach ($e in $errors) {
        $failed = $true
        Write-Output ("PARSE {0}:{1} {2}" -f $f.FullName.Substring($root.Length + 1), $e.Extent.StartLineNumber, $e.Message)
    }
}

# 2. PSScriptAnalyzer.
Import-Module PSScriptAnalyzer -ErrorAction Stop
$findings = foreach ($f in $files) { Invoke-ScriptAnalyzer -Path $f.FullName -Settings $settings }
foreach ($r in $findings) {
    $failed = $true
    Write-Output ("{0} {1}:{2} [{3}] {4}" -f $r.Severity.ToString().ToUpper(), $r.ScriptPath.Substring($root.Length + 1), $r.Line, $r.RuleName, $r.Message)
}

# 3. Shell scripts: bash -n via Git for Windows if present.
$bash = @("$env:ProgramFiles\Git\bin\bash.exe", "${env:ProgramFiles(x86)}\Git\bin\bash.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($bash) {
    foreach ($sh in Get-ChildItem -Path $root -Recurse -Filter *.sh -File) {
        $out = & $bash -n $sh.FullName 2>&1
        if ($LASTEXITCODE -ne 0) { $failed = $true; Write-Output "SH $($sh.Name): $out" }
    }
}
else {
    Write-Output 'NOTE: bash not found; shell scripts not syntax-checked.'
}

$count = @($files).Count
if ($failed) { Write-Output "Lint failed ($count PowerShell files checked)."; exit 1 }
Write-Output "Lint clean: $count PowerShell files parsed and analyzed."
