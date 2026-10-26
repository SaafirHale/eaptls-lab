#Requires -Version 5.1
<#
.SYNOPSIS
    Serves CertSrv\CertEnroll over HTTP from IIS so the CDP/AIA URLs resolve. Idempotent. Runs on CA01.

.DESCRIPTION
    Delta CRL file names end in '+', which IIS request filtering rejects as a
    double-escaped character unless allowDoubleEscaping is set for that path.
    Forgetting this is a classic way to end up with a base CRL that downloads and
    a delta CRL that 404s.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$CdpHost)
$ErrorActionPreference = 'Stop'

if (-not (Get-WindowsFeature Web-Server).Installed) {
    Install-WindowsFeature Web-Server | Out-Null
}
Import-Module WebAdministration

$site = 'Default Web Site'
$physical = Join-Path $env:SystemRoot 'System32\CertSrv\CertEnroll'
if (-not (Get-WebVirtualDirectory -Site $site -Name 'CertEnroll')) {
    New-WebVirtualDirectory -Site $site -Name 'CertEnroll' -PhysicalPath $physical | Out-Null
}

Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Location "$site/CertEnroll" `
    -Filter 'system.webServer/security/requestFiltering' -Name 'allowDoubleEscaping' -Value $true

# Directory browsing makes the run log easier to read; nothing secret lives here.
Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Location "$site/CertEnroll" `
    -Filter 'system.webServer/directoryBrowse' -Name 'enabled' -Value $true

if (-not (Get-NetFirewallRule -DisplayName 'LAB CDP HTTP' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName 'LAB CDP HTTP' -Direction Inbound -Protocol TCP -LocalPort 80 -Action Allow | Out-Null
}

# Prove every published file is fetchable by the name certificates carry.
$results = Get-ChildItem $physical -File | ForEach-Object {
    # Literal name on purpose: clients request "+" unescaped for delta CRLs.
    $url = "http://$CdpHost/CertEnroll/$($_.Name)"
    try {
        $r = Invoke-WebRequest -Uri $url -UseBasicParsing -Method Head
        [pscustomobject]@{ File = $_.Name; Status = [int]$r.StatusCode }
    }
    catch {
        [pscustomobject]@{ File = $_.Name; Status = "FAIL: $($_.Exception.Message)" }
    }
}
$results
if ($results | Where-Object { $_.Status -ne 200 }) { throw 'One or more CertEnroll files are not reachable over HTTP.' }
