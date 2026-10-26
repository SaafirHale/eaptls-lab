#Requires -Version 5.1
<#
.SYNOPSIS
    Promotes DC01 to the first domain controller of a new forest (AD DS + DNS). Idempotent. Runs on DC01.

.DESCRIPTION
    If the machine is already a DC of the target domain this only reports. Otherwise
    it installs the role and runs Install-ADDSForest, which reboots the machine;
    the host waits for PowerShell Direct and Active Directory Web Services to return.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DomainName,
    [Parameter(Mandatory)][string]$NetBiosName,
    [Parameter(Mandatory)][securestring]$SafeModePassword
)
$ErrorActionPreference = 'Stop'

$role = (Get-CimInstance Win32_ComputerSystem).DomainRole
# DomainRole 4/5 = backup/primary domain controller.
if ($role -ge 4) {
    Write-Output "$env:COMPUTERNAME is already a domain controller of $((Get-CimInstance Win32_ComputerSystem).Domain)."
    return
}

if (-not (Get-WindowsFeature AD-Domain-Services).Installed) {
    Install-WindowsFeature AD-Domain-Services -IncludeManagementTools | Out-Null
}

Import-Module ADDSDeployment
Install-ADDSForest `
    -DomainName $DomainName `
    -DomainNetbiosName $NetBiosName `
    -SafeModeAdministratorPassword $SafeModePassword `
    -InstallDns `
    -NoRebootOnCompletion:$false `
    -Force | Out-Null
