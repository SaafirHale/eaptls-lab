#Requires -Version 5.1
<#
.SYNOPSIS
    Installs NPS on DC01, registers it in AD, enrolls its server certificate and turns on NPS auditing. Idempotent.

.DESCRIPTION
    Registration = membership of "RAS and IAS Servers", which lets NPS read the
    dial-in properties of accounts and lets it enroll from the RASAndIASServer
    template. The machine's Kerberos tickets are purged after the group change so
    the enrollment request carries the new membership without a reboot.

    NPS writes accept/deny decisions to the Security log as events 6272/6273 only
    when the "Network Policy Server" audit subcategory is on; it is set explicitly
    here so the failure demo always has evidence to read.
#>
[CmdletBinding()]
param([string]$ServerTemplate = 'RASAndIASServer')
$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory

if (-not (Get-WindowsFeature NPAS).Installed) {
    Install-WindowsFeature NPAS -IncludeManagementTools | Out-Null
}

$me = Get-ADComputer $env:COMPUTERNAME
$group = Get-ADGroup 'RAS and IAS Servers'
if (-not (Get-ADGroupMember $group | Where-Object SID -eq $me.SID)) {
    Add-ADGroupMember -Identity $group -Members $me
    & klist.exe -li 0x3e7 purge | Out-Null
}

& gpupdate.exe /target:computer /force | Out-Null
& certutil.exe -pulse | Out-Null

# Match the template by name, display name or OID: depending on template version
# and whether the OID resolves locally, Format() shows any one of the three.
$configNC = ([adsi]'LDAP://RootDSE').configurationNamingContext
$tpl = [adsi]"LDAP://CN=$ServerTemplate,CN=Certificate Templates,CN=Public Key Services,CN=Services,$configNC"
$identities = @($ServerTemplate, [string]$tpl.displayName, [string]$tpl.'msPKI-Cert-Template-OID') | Where-Object { $_ }
$templatePattern = ($identities | ForEach-Object { [regex]::Escape($_) }) -join '|'

function Get-ServerAuthCert {
    $serverAuth = '1.3.6.1.5.5.7.3.1'
    $candidates = Get-ChildItem Cert:\LocalMachine\My | Where-Object {
        $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date).AddDays(7) -and
        ($_.EnhancedKeyUsageList.ObjectId -contains $serverAuth)
    }
    $candidates | Where-Object {
        $templateExt = $_.Extensions | Where-Object { $_.Oid.Value -in '1.3.6.1.4.1.311.20.2', '1.3.6.1.4.1.311.21.7' }
        (($templateExt | ForEach-Object { $_.Format($false) }) -join ' ') -match $templatePattern
    } | Sort-Object NotAfter -Descending | Select-Object -First 1
}

$cert = Get-ServerAuthCert
if (-not $cert) {
    $request = Get-Certificate -Template $ServerTemplate -CertStoreLocation Cert:\LocalMachine\My
    if ($request.Status -ne 'Issued') { throw "Enrollment from $ServerTemplate returned $($request.Status)." }
    $cert = Get-ServerAuthCert
}

& auditpol.exe /set /subcategory:"Network Policy Server" /success:enable /failure:enable | Out-Null

[pscustomobject]@{
    NpsInstalled = (Get-WindowsFeature NPAS).Installed
    Registered   = [bool](Get-ADGroupMember $group | Where-Object SID -eq $me.SID)
    ServerCert   = $cert.Subject
    Thumbprint   = $cert.Thumbprint
    Expires      = $cert.NotAfter
    Audit        = (& auditpol.exe /get /subcategory:"Network Policy Server") -match 'Network Policy Server' | Out-String
}
