#Requires -Version 5.1
<#
.SYNOPSIS
    Directory objects the rest of the lab depends on. Idempotent. Runs on DC01.

.DESCRIPTION
    - OU=Lab Workstations for the client, so the 802.1X settings target devices, not the domain.
    - LAB-8021X-Computers: the group the NPS network policy authorizes. Membership,
      not "any domain computer", is what grants the port.
    - pki.<domain>: a CNAME for the CRL/AIA host. Certificates carry this name, not
      CA01's, so the CDP can move without reissuing every certificate.
    - A DNS forwarder so the lab can resolve package mirrors through the host NAT.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CdpHost,
    [Parameter(Mandatory)][string]$CaHostName,
    [Parameter(Mandatory)][string]$DeviceGroup,
    [Parameter(Mandatory)][string]$UpstreamDns
)
$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory

$domain = Get-ADDomain
$ouName = 'Lab Workstations'
$ouDn = "OU=$ouName,$($domain.DistinguishedName)"
if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$ouDn'")) {
    New-ADOrganizationalUnit -Name $ouName -Path $domain.DistinguishedName -ProtectedFromAccidentalDeletion $false
}

if (-not (Get-ADGroup -Filter "SamAccountName -eq '$DeviceGroup'")) {
    New-ADGroup -Name $DeviceGroup -SamAccountName $DeviceGroup -GroupScope Global -GroupCategory Security `
        -Path $domain.DistinguishedName -Description 'Computers allowed on 802.1X ports (NPS network policy condition).'
}

$zone = $domain.DNSRoot
$label = $CdpHost -replace "\.$([regex]::Escape($zone))$", ''
$alias = "$CaHostName.$zone."
$existing = Get-DnsServerResourceRecord -ZoneName $zone -Name $label -RRType CName -ErrorAction SilentlyContinue
if (-not $existing) {
    Add-DnsServerResourceRecordCName -ZoneName $zone -Name $label -HostNameAlias $alias
}
elseif ($existing.RecordData.HostNameAlias -ne $alias) {
    $existing | Remove-DnsServerResourceRecord -ZoneName $zone -Force
    Add-DnsServerResourceRecordCName -ZoneName $zone -Name $label -HostNameAlias $alias
}

if ((Get-DnsServerForwarder).IPAddress.IPAddressToString -notcontains $UpstreamDns) {
    Set-DnsServerForwarder -IPAddress $UpstreamDns
}

[pscustomobject]@{
    OU          = $ouDn
    DeviceGroup = $DeviceGroup
    CdpRecord   = "$label.$zone -> $alias"
}
