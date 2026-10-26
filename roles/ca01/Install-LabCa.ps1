#Requires -Version 5.1
<#
.SYNOPSIS
    Installs an Enterprise Root CA on CA01 with HTTP-only CDP and AIA. Idempotent. Runs on CA01 as an Enterprise Admin.

.DESCRIPTION
    The defaults would stamp every certificate with an LDAP CDP first and an HTTP
    one second. LDAP CDPs resolve fine from a domain controller, which hides the
    exact failure this lab exists to show, so both extensions are rewritten to a
    single HTTP URL on a name (pki.lab.example) that can be made unreachable
    independently of AD.

    A one-tier root that issues end-entity certificates is a lab shortcut. A
    production PKI would put an offline root above an issuing CA; the CDP
    behaviour demonstrated here is the same either way.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CaCommonName,
    [Parameter(Mandatory)][string]$CdpHost,
    [int]$ValidityYears = 10,
    [int]$CrlPeriodDays = 7,
    [int]$CrlDeltaPeriodDays = 1
)
$ErrorActionPreference = 'Stop'

# CAPolicy.inf is read once, at CA installation. LoadDefaultTemplates=0 keeps the
# CA from publishing the stock templates; only the ones this lab adds are offered.
$capolicy = @"
[Version]
Signature="`$Windows NT`$"

[Certsrv_Server]
RenewalKeyLength=4096
RenewalValidityPeriod=Years
RenewalValidityPeriodUnits=$ValidityYears
CRLPeriod=Days
CRLPeriodUnits=$CrlPeriodDays
CRLDeltaPeriod=Days
CRLDeltaPeriodUnits=$CrlDeltaPeriodDays
LoadDefaultTemplates=0

[CRLDistributionPoint]
Empty=True

[AuthorityInformationAccess]
Empty=True
"@
$capolicyPath = Join-Path $env:SystemRoot 'CAPolicy.inf'
if (-not (Test-Path $capolicyPath)) {
    Set-Content -LiteralPath $capolicyPath -Value $capolicy -Encoding ASCII
}

if (-not (Get-WindowsFeature ADCS-Cert-Authority).Installed) {
    Install-WindowsFeature ADCS-Cert-Authority -IncludeManagementTools | Out-Null
}

$configured = $false
try { $configured = [bool](Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration' -Name Active -ErrorAction Stop).Active }
catch { $configured = $false }

if (-not $configured) {
    Install-AdcsCertificationAuthority `
        -CAType EnterpriseRootCA `
        -CACommonName $CaCommonName `
        -CryptoProviderName 'RSA#Microsoft Software Key Storage Provider' `
        -KeyLength 4096 `
        -HashAlgorithmName SHA256 `
        -ValidityPeriod Years `
        -ValidityPeriodUnits $ValidityYears `
        -Force | Out-Null
}

# --- CDP: publish locally (for IIS to serve), advertise HTTP only -----------------
$crlLocal = 'C:\Windows\system32\CertSrv\CertEnroll\<CaName><CRLNameSuffix><DeltaCRLAllowed>.crl'
$crlHttp = "http://$CdpHost/CertEnroll/<CaName><CRLNameSuffix><DeltaCRLAllowed>.crl"
$changed = $false

foreach ($cdp in Get-CACrlDistributionPoint) {
    if ($cdp.Uri -ne $crlLocal -and $cdp.Uri -ne $crlHttp) {
        Remove-CACrlDistributionPoint -Uri $cdp.Uri -Force | Out-Null
        $changed = $true
    }
}
$current = Get-CACrlDistributionPoint
if (-not ($current | Where-Object Uri -eq $crlLocal)) {
    Add-CACrlDistributionPoint -Uri $crlLocal -PublishToServer -PublishDeltaToServer -Force | Out-Null
    $changed = $true
}
if (-not ($current | Where-Object Uri -eq $crlHttp)) {
    Add-CACrlDistributionPoint -Uri $crlHttp -AddToCertificateCdp -AddToFreshestCrl -Force | Out-Null
    $changed = $true
}

# --- AIA: HTTP only ---------------------------------------------------------------
$aiaHttp = "http://$CdpHost/CertEnroll/<ServerDNSName>_<CaName><CertificateName>.crt"
foreach ($aia in Get-CAAuthorityInformationAccess) {
    if ($aia.Uri -ne $aiaHttp) {
        Remove-CAAuthorityInformationAccess -Uri $aia.Uri -Force | Out-Null
        $changed = $true
    }
}
if (-not (Get-CAAuthorityInformationAccess | Where-Object Uri -eq $aiaHttp)) {
    Add-CAAuthorityInformationAccess -Uri $aiaHttp -AddToCertificateAia -Force | Out-Null
    $changed = $true
}

# CRL validity from config (CAPolicy.inf only applies at install time).
& certutil.exe -setreg CA\CRLPeriod Days | Out-Null
& certutil.exe -setreg CA\CRLPeriodUnits $CrlPeriodDays | Out-Null
& certutil.exe -setreg CA\CRLDeltaPeriod Days | Out-Null
& certutil.exe -setreg CA\CRLDeltaPeriodUnits $CrlDeltaPeriodDays | Out-Null

if ($changed) {
    Restart-Service certsvc
    Start-Sleep -Seconds 5
}
# Publish a fresh base + delta CRL to CertEnroll so IIS has something to serve.
& certutil.exe -crl | Out-Null
if ($LASTEXITCODE -ne 0) { throw "certutil -crl failed ($LASTEXITCODE)." }

[pscustomobject]@{
    CA  = $CaCommonName
    CDP = (Get-CACrlDistributionPoint | ForEach-Object Uri) -join ' | '
    AIA = (Get-CAAuthorityInformationAccess | ForEach-Object Uri) -join ' | '
}
