#Requires -Version 5.1
<#
.SYNOPSIS
    Confirms CLIENT01 holds an autoenrolled machine certificate, then configures wired 802.1X (EAP-TLS, machine auth). Idempotent.

.DESCRIPTION
    Wired 802.1X on Windows is the Wired AutoConfig service (dot3svc) plus a LAN
    profile. In a domain the profile would normally arrive through Computer
    Configuration > Windows Settings > Security Settings > Wired Network (IEEE
    802.3) Policies; that policy type has no PowerShell interface, so the lab
    applies the equivalent profile with netsh lan, which writes the same settings.

    Server validation is strict on purpose: the client only talks EAP-TLS to a
    RADIUS server whose certificate chains to LAB-ROOT-CA and whose name matches,
    and never prompts the user to trust something else.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CaCommonName,
    [Parameter(Mandatory)][string]$TemplateName,
    [Parameter(Mandatory)][string]$NpsServerName
)
$ErrorActionPreference = 'Stop'

# --- 1. Machine certificate via autoenrollment -------------------------------------
& gpupdate.exe /target:computer /force | Out-Null
& certutil.exe -pulse | Out-Null

$configNC = ([adsi]'LDAP://RootDSE').configurationNamingContext
$tpl = [adsi]"LDAP://CN=$TemplateName,CN=Certificate Templates,CN=Public Key Services,CN=Services,$configNC"
$templateOid = [string]$tpl.'msPKI-Cert-Template-OID'
$clientAuth = '1.3.6.1.5.5.7.3.2'

$cert = $null
for ($i = 0; $i -lt 18 -and -not $cert; $i++) {
    $cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object {
        $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date) -and
        ($_.EnhancedKeyUsageList.ObjectId -contains $clientAuth) -and
        (($_.Extensions | Where-Object { $_.Oid.Value -eq '1.3.6.1.4.1.311.21.7' } | ForEach-Object { $_.Format($false) }) -join ' ') -match [regex]::Escape($templateOid)
    } | Sort-Object NotAfter -Descending | Select-Object -First 1
    if (-not $cert) { Start-Sleep -Seconds 10; & certutil.exe -pulse | Out-Null }
}
if (-not $cert) { throw "No autoenrolled certificate from template $TemplateName after 3 minutes. Check the autoenrollment GPO and template ACL." }

$root = Get-ChildItem Cert:\LocalMachine\Root | Where-Object Subject -eq "CN=$CaCommonName" | Select-Object -First 1
if (-not $root) { throw "$CaCommonName is not in the machine Trusted Root store yet (Group Policy distributes it)." }

# --- 2. Wired AutoConfig ----------------------------------------------------------
Set-Service -Name dot3svc -StartupType Automatic
Start-Service -Name dot3svc

# --- 3. LAN profile: EAP-TLS (type 13), machine authentication ----------------------
# TrustedRootCA is the root's SHA-1 thumbprint as space-separated hex byte pairs.
$rootHash = ($root.Thumbprint.ToLower() -split '(..)' | Where-Object { $_ }) -join ' '
$profileXml = @"
<?xml version="1.0"?>
<LANProfile xmlns="http://www.microsoft.com/networking/LAN/profile/v1">
  <MSM>
    <security>
      <OneXEnforced>false</OneXEnforced>
      <OneXEnabled>true</OneXEnabled>
      <OneX xmlns="http://www.microsoft.com/networking/OneX/v1">
        <cacheUserData>false</cacheUserData>
        <authMode>machine</authMode>
        <EAPConfig>
          <EapHostConfig xmlns="http://www.microsoft.com/provisioning/EapHostConfig">
            <EapMethod>
              <Type xmlns="http://www.microsoft.com/provisioning/EapCommon">13</Type>
              <VendorId xmlns="http://www.microsoft.com/provisioning/EapCommon">0</VendorId>
              <VendorType xmlns="http://www.microsoft.com/provisioning/EapCommon">0</VendorType>
              <AuthorId xmlns="http://www.microsoft.com/provisioning/EapCommon">0</AuthorId>
            </EapMethod>
            <Config xmlns="http://www.microsoft.com/provisioning/EapHostConfig">
              <Eap xmlns="http://www.microsoft.com/provisioning/BaseEapConnectionPropertiesV1">
                <Type>13</Type>
                <EapType xmlns="http://www.microsoft.com/provisioning/EapTlsConnectionPropertiesV1">
                  <CredentialsSource>
                    <CertificateStore>
                      <SimpleCertSelection>true</SimpleCertSelection>
                    </CertificateStore>
                  </CredentialsSource>
                  <ServerValidation>
                    <DisableUserPromptForServerValidation>true</DisableUserPromptForServerValidation>
                    <ServerNames>$NpsServerName</ServerNames>
                    <TrustedRootCA>$rootHash</TrustedRootCA>
                  </ServerValidation>
                  <DifferentUsername>false</DifferentUsername>
                  <PerformServerValidation xmlns="http://www.microsoft.com/provisioning/EapTlsConnectionPropertiesV2">true</PerformServerValidation>
                  <AcceptServerName xmlns="http://www.microsoft.com/provisioning/EapTlsConnectionPropertiesV2">true</AcceptServerName>
                </EapType>
              </Eap>
            </Config>
          </EapHostConfig>
        </EAPConfig>
      </OneX>
    </security>
  </MSM>
</LANProfile>
"@

$nic = Get-NetAdapter -Physical | Sort-Object ifIndex | Select-Object -First 1
$profilePath = Join-Path $env:ProgramData 'eaptls-lab\lan-eaptls.xml'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $profilePath) | Out-Null
[IO.File]::WriteAllText($profilePath, $profileXml, (New-Object Text.UTF8Encoding $false))

$out = & netsh.exe lan add profile filename="$profilePath" interface="$($nic.Name)"
if ($LASTEXITCODE -ne 0) { throw "netsh lan add profile failed: $out" }

[pscustomobject]@{
    MachineCert   = $cert.Subject
    SAN           = ($cert.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.17' }).Format($false)
    CertCdp       = ($cert.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.31' }).Format($false)
    Issuer        = $cert.Issuer
    Expires       = $cert.NotAfter
    TrustedRoot   = $root.Thumbprint
    Interface     = $nic.Name
    WiredAutoConf = (Get-Service dot3svc).Status
}
