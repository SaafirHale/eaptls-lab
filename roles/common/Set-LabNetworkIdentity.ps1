#Requires -Version 5.1
<#
.SYNOPSIS
    Static IPv4 address, gateway and DNS on the single lab NIC. Idempotent. Runs inside a Windows VM.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$IPAddress,
    [Parameter(Mandatory)][int]$PrefixLength,
    [Parameter(Mandatory)][string]$Gateway,
    [Parameter(Mandatory)][string[]]$DnsServers
)
$ErrorActionPreference = 'Stop'

$nic = Get-NetAdapter -Physical | Where-Object Status -eq 'Up' | Sort-Object ifIndex | Select-Object -First 1
if (-not $nic) { throw 'No connected network adapter.' }

$current = Get-NetIPAddress -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
if (-not ($current | Where-Object { $_.IPAddress -eq $IPAddress -and $_.PrefixOrigin -eq 'Manual' })) {
    Set-NetIPInterface -InterfaceIndex $nic.ifIndex -Dhcp Disabled
    $current | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    Get-NetRoute -InterfaceIndex $nic.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Remove-NetRoute -Confirm:$false
    New-NetIPAddress -InterfaceIndex $nic.ifIndex -IPAddress $IPAddress -PrefixLength $PrefixLength -DefaultGateway $Gateway | Out-Null
}

$dns = (Get-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -AddressFamily IPv4).ServerAddresses
if (($dns -join ',') -ne ($DnsServers -join ',')) {
    Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses $DnsServers
}

# The lab network is trusted; Private keeps ICMP and remote management simple.
Get-NetConnectionProfile -InterfaceIndex $nic.ifIndex -ErrorAction SilentlyContinue |
    Where-Object NetworkCategory -eq 'Public' |
    Set-NetConnectionProfile -NetworkCategory Private -ErrorAction SilentlyContinue

[pscustomobject]@{
    Computer  = $env:COMPUTERNAME
    Interface = $nic.Name
    IPAddress = $IPAddress
    Dns       = $DnsServers -join ', '
}
