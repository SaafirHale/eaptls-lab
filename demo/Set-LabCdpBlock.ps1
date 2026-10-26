#Requires -Version 5.1
<#
.SYNOPSIS
    Cuts (or restores) the NPS server's path to the CRL distribution point. Runs on DC01.

.DESCRIPTION
    The lab version of a split-tunnel VPN route that does not include the PKI
    host: an outbound Windows Firewall block from the RADIUS server to the CDP's
    HTTP port. Nothing else changes. The CA is up, the CRL is valid, the
    certificate is good, AD is fine, the client is plugged into the same port.

    Why the RADIUS server and not the client: in EAP-TLS the server validates the
    client certificate, revocation included, while the client is still on an
    unauthorized port with no network at all. The CRL fetch that decides the
    outcome is made by NPS.

.EXAMPLE
    .\Set-LabCdpBlock.ps1 -CdpHost pki.lab.example -State Blocked
    .\Set-LabCdpBlock.ps1 -CdpHost pki.lab.example -State Open
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$CdpHost,
    [Parameter(Mandatory)][ValidateSet('Blocked', 'Open')][string]$State
)
$ErrorActionPreference = 'Stop'
$ruleName = 'LAB DEMO - block NPS to CDP'

$addresses = @(Resolve-DnsName -Name $CdpHost -Type A -DnsOnly | Where-Object Type -eq 'A' | ForEach-Object IPAddress)
if (-not $addresses) { throw "Cannot resolve $CdpHost." }

$existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
if ($State -eq 'Blocked' -and -not $existing) {
    if ($PSCmdlet.ShouldProcess($CdpHost, 'Block outbound TCP 80')) {
        New-NetFirewallRule -DisplayName $ruleName -Direction Outbound -Action Block `
            -Protocol TCP -RemotePort 80 -RemoteAddress $addresses | Out-Null
    }
}
elseif ($State -eq 'Open' -and $existing) {
    if ($PSCmdlet.ShouldProcess($CdpHost, 'Remove outbound block')) {
        $existing | Remove-NetFirewallRule
    }
}

# Run Clear-LabCrlCache.ps1 next (Invoke-LabDemo.ps1 does): until the cached CRL
# is gone, NPS keeps answering from cache and the block changes nothing.
$probe = Test-NetConnection -ComputerName $CdpHost -Port 80 -WarningAction SilentlyContinue
[pscustomobject]@{
    CdpHost        = $CdpHost
    Addresses      = $addresses -join ', '
    State          = $State
    Tcp80Reachable = $probe.TcpTestSucceeded
}
