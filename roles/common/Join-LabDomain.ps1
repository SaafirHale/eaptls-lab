#Requires -Version 5.1
<#
.SYNOPSIS
    Joins the lab domain and reboots. No-op if already a member. Runs inside a Windows VM.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DomainName,
    [Parameter(Mandatory)][pscredential]$Credential,
    [string]$OUPath
)
$ErrorActionPreference = 'Stop'

$cs = Get-CimInstance Win32_ComputerSystem
if ($cs.PartOfDomain -and $cs.Domain -eq $DomainName) {
    Write-Output "$env:COMPUTERNAME is already a member of $DomainName."
    return
}

$join = @{ DomainName = $DomainName; Credential = $Credential; Force = $true }
if ($OUPath) { $join.OUPath = $OUPath }
Add-Computer @join
Write-Output "$env:COMPUTERNAME joined $DomainName; restarting."
# Restart outside the PowerShell Direct session so the call returns cleanly.
shutdown.exe /r /t 5 /c "Lab domain join" | Out-Null
