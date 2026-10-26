#Requires -Version 5.1
<#
.SYNOPSIS
    Proves, from the machine that will check revocation, that a certificate's CDP and AIA URLs are fetchable. Runs on DC01 (NPS).

.DESCRIPTION
    certutil -verify -urlfetch walks the chain and actually downloads every AIA
    and CDP URL instead of trusting a cache. Run on the RADIUS server against a
    client certificate, it answers the only question that matters for EAP-TLS
    revocation: can *this* server fetch *this* CRL right now. This is the
    per-site reachability check, packaged.

.EXAMPLE
    .\Test-LabCdpReachability.ps1 -CertificatePath C:\ProgramData\eaptls-lab\client01.cer
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$CertificatePath)

$raw = & certutil.exe -verify -urlfetch $CertificatePath 2>&1 | ForEach-Object { "$_" }
$text = $raw -join "`n"

# certutil prints one line per URL it tried: Verified "<kind>" ... / Failed "<kind>" ...
$urls = $raw | Where-Object { $_ -match '^\s*(Verified|Failed|Expired|Wrong Issuer)\s+"' } | ForEach-Object {
    if ($_ -match '^\s*(\S+(?: Issuer)?)\s+"([^"]+)"') { [pscustomobject]@{ Result = $Matches[1]; Object = $Matches[2]; Line = $_.Trim() } }
}

$offline = $text -match 'CRYPT_E_REVOCATION_OFFLINE|0x80092013'
$revoked = $text -match 'CRYPT_E_REVOKED|0x80092010'
$passed = $text -match 'Leaf certificate revocation check passed'

[pscustomobject]@{
    Computer          = $env:COMPUTERNAME
    Certificate       = $CertificatePath
    RevocationOutcome = if ($revoked) { 'Revoked' } elseif ($offline) { 'Offline (CRL not retrievable)' } elseif ($passed) { 'Passed' } else { 'See RawOutput' }
    Urls              = $urls
    RawOutput         = $text
}
