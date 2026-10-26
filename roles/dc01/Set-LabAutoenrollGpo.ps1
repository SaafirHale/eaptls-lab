#Requires -Version 5.1
<#
.SYNOPSIS
    Creates and links the computer certificate autoenrollment GPO. Idempotent. Runs on DC01.

.DESCRIPTION
    Equivalent of Computer Configuration > Policies > Windows Settings > Security
    Settings > Public Key Policies > "Certificate Services Client - Auto-Enrollment"
    set to Enabled with both boxes ticked ("Renew expired certificates, update
    pending certificates, and remove revoked certificates" and "Update certificates
    that use certificate templates"). The UI writes AEPolicy = 7 under
    HKLM\SOFTWARE\Policies\Microsoft\Cryptography\AutoEnrollment:
        0x1 enable autoenrollment, 0x2 renew/update pending/remove revoked,
        0x4 update certificates that use templates.

    Linked at the domain root so it reaches CLIENT01 and DC01 (the NPS server
    certificate renews through the same mechanism).
#>
[CmdletBinding()]
param([string]$GpoName = 'LAB - Certificate Autoenrollment')
$ErrorActionPreference = 'Stop'
Import-Module GroupPolicy, ActiveDirectory

$domainDn = (Get-ADDomain).DistinguishedName
$gpo = Get-GPO -Name $GpoName -ErrorAction SilentlyContinue
if (-not $gpo) {
    $gpo = New-GPO -Name $GpoName -Comment 'Computer certificate autoenrollment for 802.1X EAP-TLS.'
}

$key = 'HKLM\SOFTWARE\Policies\Microsoft\Cryptography\AutoEnrollment'
Set-GPRegistryValue -Guid $gpo.Id -Key $key -ValueName 'AEPolicy' -Type DWord -Value 7 | Out-Null
# Expiry notification threshold (percent of lifetime remaining); UI default is 10.
Set-GPRegistryValue -Guid $gpo.Id -Key $key -ValueName 'OfflineExpirationPercent' -Type DWord -Value 10 | Out-Null
# The user half of the GPO is left unconfigured: this lab authenticates machines.
if ($gpo.GpoStatus -ne 'UserSettingsDisabled') { $gpo.GpoStatus = 'UserSettingsDisabled' }

$linked = (Get-GPInheritance -Target $domainDn).GpoLinks | Where-Object DisplayName -eq $GpoName
if (-not $linked) {
    New-GPLink -Guid $gpo.Id -Target $domainDn -LinkEnabled Yes | Out-Null
}

Get-GPRegistryValue -Guid $gpo.Id -Key $key | Select-Object ValueName, Value
