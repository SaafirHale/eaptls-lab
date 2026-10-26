#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    EAP-TLS straight to NPS with eapol_test on AUTH01, using CLIENT01's certificate. Runs on the host.

.DESCRIPTION
    The fallback path if EAPOL frames do not make it across the Hyper-V private
    switch, and a quicker loop for the failure demo: no Windows supplicant, no
    port, just RADIUS from the registered RADIUS client (AUTH01) carrying an
    EAP-TLS conversation that presents CLIENT01's identity and certificate.
    NPS applies the same policy and the same revocation check, and logs the
    same 6272/6273.

    -Prepare exports CLIENT01's certificate and key once (the lab template marks
    the key exportable for exactly this) and installs it on AUTH01 as PEM.

.EXAMPLE
    .\Invoke-LabEapolTest.ps1 -Prepare
    .\Invoke-LabEapolTest.ps1
#>
[CmdletBinding()]
param([switch]$Prepare)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'host\LabCommon.psm1') -Force
Assert-LabHost
$config = Get-LabConfig
$cred = Get-LabCredential -Config $config -Kind DomainAdministrator
$dc = Get-LabVMSpec -Config $config -Name DC01
$auth = Get-LabVMSpec -Config $config -Name AUTH01
$clientFqdn = "CLIENT01.$($config.Domain.Fqdn)"

if ($Prepare) {
    $pfxPassword = Get-LabSecret -Config $config -Name PfxPassword
    $pfxGuest = 'C:\ProgramData\eaptls-lab\client01.pfx'
    $rootGuest = 'C:\ProgramData\eaptls-lab\lab-root-ca.cer'
    Invoke-Command -VMName CLIENT01 -Credential $cred -ArgumentList $config.Pki.CaCommonName, $pfxGuest, $rootGuest, $pfxPassword -ScriptBlock {
        param([string]$Ca, [string]$Pfx, [string]$Root, [securestring]$Password)
        $c = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Issuer -eq "CN=$Ca" -and $_.EnhancedKeyUsageList.ObjectId -contains '1.3.6.1.5.5.7.3.2' } |
            Sort-Object NotAfter -Descending | Select-Object -First 1
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Pfx) | Out-Null
        Export-PfxCertificate -Cert $c -FilePath $Pfx -Password $Password -CryptoAlgorithmOption AES256_SHA256 | Out-Null
        $r = Get-ChildItem Cert:\LocalMachine\Root | Where-Object Subject -eq "CN=$Ca" | Select-Object -First 1
        Export-Certificate -Cert $r -FilePath $Root -Type CERT | Out-Null
    }
    $stage = Join-Path $config.Paths.Secrets 'eapol'
    Copy-LabFileFromVM -VMName CLIENT01 -Credential $cred -Path $pfxGuest -Destination (Join-Path $stage 'client01.pfx')
    Copy-LabFileFromVM -VMName CLIENT01 -Credential $cred -Path $rootGuest -Destination (Join-Path $stage 'lab-root-ca.cer')
    Invoke-Command -VMName CLIENT01 -Credential $cred -ArgumentList $pfxGuest -ScriptBlock { param($p) Remove-Item -LiteralPath $p -Force }

    $conf = Expand-LabTemplate -Path (Join-Path (Get-LabRepoRoot) 'roles\auth01\eapol-test.conf.template') -Values @{ CLIENT_FQDN = $clientFqdn }
    $confFile = Join-Path $stage 'eapol-test.conf'
    [IO.File]::WriteAllText($confFile, $conf.Replace("`r`n", "`n"), (New-Object Text.UTF8Encoding $false))

    Copy-LabFileToAuthenticator -Config $config -Path (Join-Path $stage 'client01.pfx') -Destination '/tmp/client01.pfx'
    Copy-LabFileToAuthenticator -Config $config -Path (Join-Path $stage 'lab-root-ca.cer') -Destination '/tmp/lab-root-ca.cer'
    Copy-LabFileToAuthenticator -Config $config -Path $confFile -Destination '/tmp/eapol-test.conf'

    $pass = ConvertFrom-LabSecureString $pfxPassword
    # Password goes over stdin, not argv, so it never shows in a process list.
    $script = @(
        'set -e'
        'sudo install -d -m 0700 /etc/eaptls'
        "printf '%s' '$pass' | sudo openssl pkcs12 -in /tmp/client01.pfx -passin stdin -clcerts -nokeys -out /etc/eaptls/client.pem"
        "printf '%s' '$pass' | sudo openssl pkcs12 -in /tmp/client01.pfx -passin stdin -nocerts -nodes -out /etc/eaptls/client.key"
        'sudo openssl x509 -inform der -in /tmp/lab-root-ca.cer -out /etc/eaptls/lab-root-ca.pem'
        'sudo install -m 0600 /tmp/eapol-test.conf /etc/eaptls/eapol-test.conf'
        'sudo chmod 0600 /etc/eaptls/client.key'
        'rm -f /tmp/client01.pfx /tmp/lab-root-ca.cer /tmp/eapol-test.conf'
        'sudo openssl x509 -in /etc/eaptls/client.pem -noout -subject -ext subjectAltName,crlDistributionPoints'
    ) -join "`n"
    Invoke-LabSsh -Config $config -Command $script
    $pass = $null
    Remove-Item -LiteralPath (Join-Path $stage 'client01.pfx') -Force
    return
}

$secret = ConvertFrom-LabSecureString (Get-LabSecret -Config $config -Name RadiusSecret)
# -N61:d:15 sends NAS-Port-Type = Ethernet so the wired network policy matches,
# the same attribute hostapd is configured to send (radius_auth_req_attr).
$cmd = "sudo eapol_test -c /etc/eaptls/eapol-test.conf -a $($dc.Ip) -s '$secret' -A $($auth.Ip) -N61:d:15 -t 20 2>&1 | tail -n 25"
$out = Invoke-LabSsh -Config $config -Command $cmd
$secret = $null
$out
$verdict = if ($out -match '^SUCCESS') { 'SUCCESS' } elseif ($out -match '^FAILURE') { 'FAILURE' } else { 'UNKNOWN' }
[pscustomobject]@{ Tool = 'eapol_test'; Identity = "host/$clientFqdn"; Result = $verdict }
