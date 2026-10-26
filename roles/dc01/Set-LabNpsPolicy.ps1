#Requires -Version 5.1
<#
.SYNOPSIS
    RADIUS client + EAP-TLS network policy on NPS, by import of a captured configuration. Idempotent. Runs on DC01.

.DESCRIPTION
    The network policy's EAP-TLS settings live in a binary attribute
    (msEAPConfiguration, attribute 0x1FA2) whose layout Microsoft does not
    document, and the NPS PowerShell module has no cmdlet for network policies.
    So this lab does what NPS itself supports for repeatable deployments:

      first build:   build the policy once in nps.msc (docs/nps-policy-gui.md),
                     then -Capture exports it, swaps every build-specific value
                     for a {{TOKEN}}, and hands the template back to the host,
                     which commits it as roles/dc01/nps/nps-config.template.xml
      every rebuild: the template is filled in (this build's server-certificate
                     thumbprint, RADIUS secret, RADIUS client address, domain
                     SID) and loaded with Import-NpsConfiguration

    Tokens: NPS_CERT_THUMBPRINT, RADIUS_SECRET, RADIUS_CLIENT_IP, DOMAIN_SID.

    The thumbprint sits inside the EAP-TLS blob; a renewed server certificate is
    handled by re-filling the template, not by editing the blob in place.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PolicyName,
    [Parameter(Mandatory)][string]$RadiusClientName,
    [Parameter(Mandatory)][string]$RadiusClientAddress,
    [Parameter(Mandatory)][securestring]$SharedSecret,
    [string]$ServerTemplate = 'RASAndIASServer',
    [string]$ConfigTemplate,
    [switch]$Capture
)
$ErrorActionPreference = 'Stop'
Import-Module NPS, ActiveDirectory

$workDir = Join-Path $env:ProgramData 'eaptls-lab'
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SharedSecret)
try { $secret = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }

# --- the NPS server certificate this build enrolled ------------------------------
$configNC = ([adsi]'LDAP://RootDSE').configurationNamingContext
$tpl = [adsi]"LDAP://CN=$ServerTemplate,CN=Certificate Templates,CN=Public Key Services,CN=Services,$configNC"
$identities = @($ServerTemplate, [string]$tpl.displayName, [string]$tpl.'msPKI-Cert-Template-OID') | Where-Object { $_ }
$templatePattern = ($identities | ForEach-Object { [regex]::Escape($_) }) -join '|'
$cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object {
    $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date) -and
    ($_.EnhancedKeyUsageList.ObjectId -contains '1.3.6.1.5.5.7.3.1')
} | Where-Object {
    $ext = $_.Extensions | Where-Object { $_.Oid.Value -in '1.3.6.1.4.1.311.20.2', '1.3.6.1.4.1.311.21.7' }
    (($ext | ForEach-Object { $_.Format($false) }) -join ' ') -match $templatePattern
} | Sort-Object NotAfter -Descending | Select-Object -First 1
if (-not $cert) { throw "No $ServerTemplate certificate on $env:COMPUTERNAME. Run Install-LabNps.ps1 first." }
$thumb = $cert.Thumbprint.ToLowerInvariant()
$domainSid = (Get-ADDomain).DomainSID.Value

function Export-Sanitized {
    # Export, then replace every build-specific value with its token.
    $raw = Join-Path $workDir 'nps-export.raw.xml'
    Export-NpsConfiguration -Path $raw
    $text = [IO.File]::ReadAllText($raw)
    Remove-Item -LiteralPath $raw -Force   # holds the shared secret in clear text
    $text = [regex]::Replace($text, [regex]::Escape($thumb), '{{NPS_CERT_THUMBPRINT}}', 'IgnoreCase')
    $text = $text.Replace($secret, '{{RADIUS_SECRET}}')
    $text = $text.Replace($RadiusClientAddress, '{{RADIUS_CLIENT_IP}}')
    $text = $text.Replace($domainSid, '{{DOMAIN_SID}}')
    $text
}

function Test-PolicyPresent {
    $out = (& netsh.exe nps show np) -join "`n"
    $out -match ('(?m)^\s*Name\s*=\s*' + [regex]::Escape($PolicyName) + '\s*$')
}

# --- capture mode: turn a hand-built policy into the committed template ---------
if ($Capture) {
    if (-not (Test-PolicyPresent)) { throw "No network policy named '$PolicyName' to capture. Build it first (docs/nps-policy-gui.md)." }
    $template = Export-Sanitized
    if ($template -notmatch '\{\{NPS_CERT_THUMBPRINT\}\}') {
        throw 'The export does not reference this server certificate. In the policy, edit "Microsoft: Smart Card or other certificate" and select the RAS and IAS Server certificate, then capture again.'
    }
    if ($template -notmatch '\{\{RADIUS_SECRET\}\}') {
        throw "The export does not contain the RADIUS client for $RadiusClientAddress with the lab secret. Run the Nps stage once before capturing."
    }
    return $template
}

# --- apply mode -----------------------------------------------------------------
function Set-RadiusClient {
    # Present, at AUTH01's address, with the current secret. Returns $true if changed.
    $client = Get-NpsRadiusClient | Where-Object Address -eq $RadiusClientAddress
    if (-not $client) {
        New-NpsRadiusClient -Name $RadiusClientName -Address $RadiusClientAddress -SharedSecret $secret | Out-Null
        return $true
    }
    if ($client.SharedSecret -ne $secret) {
        Set-NpsRadiusClient -Name $client.Name -SharedSecret $secret | Out-Null
        return $true
    }
    $false
}

# The RADIUS client goes in first, so a first build that stops below (no template
# yet) leaves NPS ready for the one-time GUI step and the capture.
$changed = Set-RadiusClient

if (-not (Test-PolicyPresent)) {
    if (-not $ConfigTemplate) {
        Restart-Service IAS
        throw "Network policy '$PolicyName' does not exist and no captured template was supplied. First build only: create it in nps.msc on $env:COMPUTERNAME following docs/nps-policy-gui.md, then run Build-Lab.ps1 -Stage NpsCapture."
    }
    $filled = $ConfigTemplate.Replace('{{NPS_CERT_THUMBPRINT}}', $thumb).Replace('{{RADIUS_SECRET}}', $secret)
    $filled = $filled.Replace('{{RADIUS_CLIENT_IP}}', $RadiusClientAddress).Replace('{{DOMAIN_SID}}', $domainSid)
    $importFile = Join-Path $workDir 'nps-import.xml'
    [IO.File]::WriteAllText($importFile, $filled)
    try { Import-NpsConfiguration -Path $importFile }
    finally { Remove-Item -LiteralPath $importFile -Force }
    $null = Set-RadiusClient
    $changed = $true
}

# New-NpsRadiusClient and Import-NpsConfiguration take effect after an IAS restart.
if ($changed) { Restart-Service IAS }

$sanitized = Export-Sanitized
[IO.File]::WriteAllText((Join-Path $workDir 'nps-export.xml'), $sanitized)
$secret = $null

[pscustomobject]@{
    Policy           = $PolicyName
    PolicyPresent    = Test-PolicyPresent
    RadiusClient     = "$RadiusClientName ($RadiusClientAddress)"
    ServerCert       = "$($cert.Subject) [$thumb]"
    PolicyUsesCert   = $sanitized -match '\{\{NPS_CERT_THUMBPRINT\}\}'
    Changed          = $changed
}
