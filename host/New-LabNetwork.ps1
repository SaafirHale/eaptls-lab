#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Creates the two lab switches and the host-side NAT. Idempotent.

.DESCRIPTION
    LabNet (internal):   DC01, CA01, AUTH01 uplink, host vNIC 10.20.0.1, NAT out.
    LabAccess (private): CLIENT01 and AUTH01's access port only.

    A Hyper-V vSwitch has no 802.1X port authentication of its own, so port
    control lives in AUTH01 (hostapd, wired driver) sitting between the two
    switches. See README "Why a Linux authenticator".
#>
[CmdletBinding()]
param([hashtable]$Config)

Import-Module (Join-Path $PSScriptRoot 'LabCommon.psm1') -Force
if (-not $Config) { $Config = Get-LabConfig }
$net = $Config.Network

if (-not (Get-VMSwitch -Name $net.SwitchName -ErrorAction SilentlyContinue)) {
    Write-LabStep "Creating internal switch $($net.SwitchName)"
    New-VMSwitch -Name $net.SwitchName -SwitchType Internal | Out-Null
}
if (-not (Get-VMSwitch -Name $net.AccessSwitchName -ErrorAction SilentlyContinue)) {
    Write-LabStep "Creating private switch $($net.AccessSwitchName)"
    New-VMSwitch -Name $net.AccessSwitchName -SwitchType Private | Out-Null
}

$alias = "vEthernet ($($net.SwitchName))"
$existing = Get-NetIPAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue
if (-not ($existing | Where-Object IPAddress -eq $net.Gateway)) {
    Write-LabStep "Assigning $($net.Gateway)/$($net.PrefixLength) to $alias"
    $existing | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    New-NetIPAddress -InterfaceAlias $alias -IPAddress $net.Gateway -PrefixLength $net.PrefixLength | Out-Null
}

$subnet = "$($net.Prefix).0/$($net.PrefixLength)"
if (-not (Get-NetNat -Name $net.NatName -ErrorAction SilentlyContinue)) {
    Write-LabStep "Creating NAT $($net.NatName) for $subnet"
    New-NetNat -Name $net.NatName -InternalIPInterfaceAddressPrefix $subnet | Out-Null
}

Get-VMSwitch -Name $net.SwitchName, $net.AccessSwitchName | Select-Object Name, SwitchType
