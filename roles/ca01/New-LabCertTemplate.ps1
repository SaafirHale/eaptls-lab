#Requires -Version 5.1
<#
.SYNOPSIS
    Duplicates a certificate template in AD, grants Enroll/Autoenroll, and publishes it on the CA. Idempotent.
    Runs on CA01 as an Enterprise Admin.

.DESCRIPTION
    There is no in-box cmdlet for "Duplicate Template", and the MMC is not
    available on Server Core. A template is an AD object, though, so the
    duplicate is built the way the MMC builds it: copy the source template's
    pKI*/msPKI-* attributes, register a new template OID under the forest's
    OID container, raise the schema version to 2 so autoenrollment is allowed,
    and set the ACL. Flag values follow [MS-CRTD] (Certificate Templates
    Structure).

    Also publishes any additional existing templates named in -AlsoPublish
    (the lab uses this for RASAndIASServer, the NPS server certificate).

.EXAMPLE
    .\New-LabCertTemplate.ps1 -Name LabComputerAuth -DisplayName 'Lab Computer Authentication' `
        -SourceTemplate Workstation -EnrollPrincipal 'Domain Computers' -AlsoPublish RASAndIASServer
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$DisplayName,
    [string]$SourceTemplate = 'Workstation',
    [string]$EnrollPrincipal = 'Domain Computers',
    [switch]$ExportableKey,
    [string[]]$AlsoPublish = @()
)
$ErrorActionPreference = 'Stop'

# [MS-CRTD] flag values used below.
$CT_FLAG_AUTO_ENROLLMENT = 0x20          # flags and msPKI-Enrollment-Flag
$CT_FLAG_IS_DEFAULT = 0x10000            # flags: marks a stock template
$CT_FLAG_IS_MODIFIED = 0x20000           # flags: marks an admin-created template
$CT_FLAG_EXPORTABLE_KEY = 0x10           # msPKI-Private-Key-Flag
$ExtendedRightEnroll = [guid]'0e10c968-78fb-11d2-90d4-00c04f79dc55'
$ExtendedRightAutoEnroll = [guid]'a05b8cc2-17bc-4802-a710-e7c15ab866a2'

$configNC = ([adsi]'LDAP://RootDSE').configurationNamingContext
$pks = "CN=Public Key Services,CN=Services,$configNC"
$templatesDn = "CN=Certificate Templates,$pks"
$newDn = "CN=$Name,$templatesDn"

if (-not [adsi]::Exists("LDAP://$newDn")) {
    $src = [adsi]"LDAP://CN=$SourceTemplate,$templatesDn"
    if (-not $src.Properties['cn'].Value) { throw "Source template '$SourceTemplate' not found." }
    $get = { param($attr, $default) if ($src.Properties.Contains($attr)) { $src.Properties[$attr].Value } else { $default } }

    # 1. A new template OID under the forest OID arc, registered in CN=OID.
    $oidContainer = [adsi]"LDAP://CN=OID,$pks"
    $forestOid = $oidContainer.Properties['msPKI-Cert-Template-OID'].Value
    do {
        $oid = '{0}.{1}.{2}' -f $forestOid, (Get-Random -Minimum 1000000 -Maximum 99999999), (Get-Random -Minimum 1000000 -Maximum 99999999)
        $searcher = New-Object DirectoryServices.DirectorySearcher($oidContainer, "(msPKI-Cert-Template-OID=$oid)")
    } while ($searcher.FindOne())
    $oidCn = '{0}.{1}' -f ($oid.Split('.')[-1]), (-join ((1..32) | ForEach-Object { '{0:X}' -f (Get-Random -Maximum 16) }))
    $oidObject = $oidContainer.Create('msPKI-Enterprise-Oid', "CN=$oidCn")
    $oidObject.Put('msPKI-Cert-Template-OID', $oid)
    $oidObject.Put('displayName', $DisplayName)
    $oidObject.Put('flags', 1)   # 1 = certificate template OID
    $oidObject.SetInfo()

    # 2. The template object, attributes copied from the source.
    $templates = [adsi]"LDAP://$templatesDn"
    $new = $templates.Create('pKICertificateTemplate', "CN=$Name")
    $new.Put('displayName', $DisplayName)
    $new.Put('revision', 100)

    $flags = ((& $get 'flags' 0) -bor $CT_FLAG_IS_MODIFIED -bor $CT_FLAG_AUTO_ENROLLMENT) -band (-bnot $CT_FLAG_IS_DEFAULT)
    $new.Put('flags', $flags)

    foreach ($attr in 'pKIDefaultKeySpec', 'pKIMaxIssuingDepth', 'msPKI-RA-Signature',
        'msPKI-Certificate-Name-Flag', 'msPKI-Minimal-Key-Size') {
        $new.Put($attr, [int](& $get $attr 0))
    }
    foreach ($attr in 'pKIKeyUsage', 'pKIExpirationPeriod', 'pKIOverlapPeriod') {
        $new.Put($attr, [byte[]](& $get $attr $null))
    }
    $eku = @($src.Properties['pKIExtendedKeyUsage'] | ForEach-Object { [string]$_ })
    foreach ($attr in 'pKICriticalExtensions', 'pKIDefaultCSPs') {
        $values = @($src.Properties[$attr] | ForEach-Object { [string]$_ })
        if ($values.Count) { $new.PutEx(2, $attr, $values) }
    }
    if ($eku.Count) {
        $new.PutEx(2, 'pKIExtendedKeyUsage', $eku)
        # Schema v2 templates express EKUs as application policies too.
        $new.PutEx(2, 'msPKI-Certificate-Application-Policy', $eku)
    }

    $enrollFlag = [int](& $get 'msPKI-Enrollment-Flag' 0) -bor $CT_FLAG_AUTO_ENROLLMENT
    $new.Put('msPKI-Enrollment-Flag', $enrollFlag)
    $keyFlag = [int](& $get 'msPKI-Private-Key-Flag' 0)
    if ($ExportableKey) { $keyFlag = $keyFlag -bor $CT_FLAG_EXPORTABLE_KEY }
    $new.Put('msPKI-Private-Key-Flag', $keyFlag)

    $new.Put('msPKI-Template-Schema-Version', [Math]::Max(2, [int](& $get 'msPKI-Template-Schema-Version' 1)))
    $new.Put('msPKI-Template-Minor-Revision', 0)
    $new.Put('msPKI-Cert-Template-OID', $oid)
    $new.SetInfo()
    Write-Output "Created template $Name ($oid) from $SourceTemplate."
}

# 3. ACL: Read + Enroll + Autoenroll for the enrolling principal. Re-applied every
#    run; AddAccessRule merges with an identical existing rule.
$template = [adsi]"LDAP://$newDn"
$sid = (New-Object Security.Principal.NTAccount($EnrollPrincipal)).Translate([Security.Principal.SecurityIdentifier])
$acl = $template.ObjectSecurity
$acl.AddAccessRule((New-Object DirectoryServices.ActiveDirectoryAccessRule($sid, 'GenericRead', 'Allow')))
$acl.AddAccessRule((New-Object DirectoryServices.ActiveDirectoryAccessRule($sid, 'ExtendedRight', 'Allow', $ExtendedRightEnroll)))
$acl.AddAccessRule((New-Object DirectoryServices.ActiveDirectoryAccessRule($sid, 'ExtendedRight', 'Allow', $ExtendedRightAutoEnroll)))
$template.CommitChanges()

# 4. Publish on this CA. A template created seconds ago can take a moment to be
#    visible to certsvc, so retry briefly.
Import-Module ADCSAdministration
$published = (Get-CATemplate).Name
foreach ($t in @($Name) + $AlsoPublish) {
    if ($published -contains $t) { continue }
    $attempt = 0
    while ($true) {
        try { Add-CATemplate -Name $t -Force; break }
        catch {
            if (++$attempt -ge 12) { throw }
            Start-Sleep -Seconds 10
        }
    }
}

Get-CATemplate | Select-Object Name, Oid
