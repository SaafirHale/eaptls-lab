#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    The failure demo: authenticate, cut the RADIUS server's path to the CDP, authenticate again, prove why, restore. Runs on the host.

.DESCRIPTION
    1. Baseline   CDP reachable, caches cleared, client authenticates   -> expect NPS 6272
    2. Break      outbound block DC01 -> pki.lab.example:80, caches cleared,
                  client re-authenticates                               -> expect NPS 6273
    3. Prove      certutil -verify -urlfetch on DC01 against CLIENT01's
                  certificate                                           -> expect revocation offline
    4. Restore    block removed, caches cleared, client re-authenticates -> expect NPS 6272

    Nothing about the client, the certificate, the CA or the "switch" changes
    between 1 and 2. Every phase writes its evidence to Paths.Out.

.PARAMETER Phase
    Run a subset, e.g. -Phase Break,Prove to leave the lab broken for inspection.

.PARAMETER Method
    Wired (default): CLIENT01's own supplicant through AUTH01's port.
    EapolTest: eapol_test on AUTH01 presenting CLIENT01's certificate, for hosts
    where the Hyper-V switch does not deliver EAPOL (Test-LabEapolPath.ps1).
#>
[CmdletBinding()]
param(
    [ValidateSet('Baseline', 'Break', 'Prove', 'Restore')]
    [string[]]$Phase = @('Baseline', 'Break', 'Prove', 'Restore'),
    [ValidateSet('Wired', 'EapolTest')]
    [string]$Method = 'Wired'
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'host\LabCommon.psm1') -Force
Assert-LabHost
$config = Get-LabConfig
$cred = Get-LabCredential -Config $config -Kind DomainAdministrator
$cdpHost = $config.Pki.CdpHost
$test = Join-Path $PSScriptRoot 'Test-LabAuthentication.ps1'

function Set-CdpState([string]$State) {
    Invoke-LabScript -VMName DC01 -Credential $cred -Path 'demo\Set-LabCdpBlock.ps1' -Parameters @{ CdpHost = $cdpHost; State = $State }
    Invoke-LabScript -VMName DC01 -Credential $cred -Path 'demo\Clear-LabCrlCache.ps1'
}

function Invoke-AuthAttempt([string]$Label, [string]$Via) {
    if ($Via -eq 'Wired') { return (& $test -Config $config -Label $Label) }
    $started = Get-Date
    $eapol = & (Join-Path $PSScriptRoot 'Invoke-LabEapolTest.ps1')
    Start-Sleep -Seconds 3
    $nps = Invoke-LabScript -VMName DC01 -Credential $cred -Path 'demo\Get-NpsAuthEvent.ps1' -Parameters @{ Minutes = 5 }
    $nps = @($nps | Where-Object Time -ge $started.AddSeconds(-2))
    $result = [pscustomobject]@{
        Label         = $Label
        Started       = $started
        ClientPingsDc = $null
        EapolTest     = ($eapol | Where-Object { $_ -is [pscustomobject] }).Result
        NpsDecisions  = @($nps | Select-Object Time, EventId, Result, Machine, RadiusClient, NetworkPolicy, AuthType, EapType, ReasonCode, Reason)
        EapolOutput   = ($eapol | Where-Object { $_ -is [string] }) -join "`n"
    }
    $file = Join-Path $config.Paths.Out ('{0}-{1:yyyyMMdd-HHmmss}.json' -f $Label, $started)
    $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $file -Encoding UTF8
    $result
}

$summary = New-Object System.Collections.Generic.List[object]

if ('Baseline' -in $Phase) {
    Set-CdpState Open | Out-Host
    $r = Invoke-AuthAttempt 'demo-1-baseline' $Method
    $summary.Add([pscustomobject]@{ Phase = 'Baseline'; ClientOnNetwork = $r.ClientPingsDc; Nps = ($r.NpsDecisions | Select-Object -First 1) })
}

if ('Break' -in $Phase) {
    Set-CdpState Blocked | Out-Host
    $r = Invoke-AuthAttempt 'demo-2-cdp-blocked' $Method
    $summary.Add([pscustomobject]@{ Phase = 'Break'; ClientOnNetwork = $r.ClientPingsDc; Nps = ($r.NpsDecisions | Select-Object -First 1) })
}

if ('Prove' -in $Phase) {
    # Export CLIENT01's public certificate and verify it *from the NPS server*.
    $cer = 'C:\ProgramData\eaptls-lab\client01.cer'
    $hostCopy = Join-Path $config.Paths.Out 'client01.cer'
    Invoke-Command -VMName CLIENT01 -Credential $cred -ArgumentList $config.Pki.CaCommonName, $cer -ScriptBlock {
        param($Ca, $Path)
        $c = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Issuer -eq "CN=$Ca" -and $_.EnhancedKeyUsageList.ObjectId -contains '1.3.6.1.5.5.7.3.2' } |
            Sort-Object NotAfter -Descending | Select-Object -First 1
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
        Export-Certificate -Cert $c -FilePath $Path | Out-Null
    }
    Copy-LabFileFromVM -VMName CLIENT01 -Credential $cred -Path $cer -Destination $hostCopy
    Copy-LabFileToVM -VMName DC01 -Credential $cred -Path $hostCopy -Destination $cer
    $proof = Invoke-LabScript -VMName DC01 -Credential $cred -Path 'demo\Test-LabCdpReachability.ps1' -Parameters @{ CertificatePath = $cer }
    $proofFile = Join-Path $config.Paths.Out ('demo-3-urlfetch-{0:yyyyMMdd-HHmmss}.txt' -f (Get-Date))
    $proof.RawOutput | Set-Content -LiteralPath $proofFile -Encoding UTF8
    $summary.Add([pscustomobject]@{ Phase = 'Prove'; ClientOnNetwork = $null; Nps = $proof.RevocationOutcome })
}

if ('Restore' -in $Phase) {
    Set-CdpState Open | Out-Host
    $r = Invoke-AuthAttempt 'demo-4-restored' $Method
    $summary.Add([pscustomobject]@{ Phase = 'Restore'; ClientOnNetwork = $r.ClientPingsDc; Nps = ($r.NpsDecisions | Select-Object -First 1) })
}

$summary | ForEach-Object {
    [pscustomobject]@{
        Phase           = $_.Phase
        ClientOnNetwork = $_.ClientOnNetwork
        NpsEvent        = if ($_.Nps -is [string]) { $_.Nps } elseif ($_.Nps) { "$($_.Nps.EventId) $($_.Nps.Result)" } else { '(none)' }
        ReasonCode      = if ($_.Nps -and $_.Nps -isnot [string]) { $_.Nps.ReasonCode } else { $null }
        Reason          = if ($_.Nps -and $_.Nps -isnot [string]) { $_.Nps.Reason } else { $null }
    }
} | Format-Table -AutoSize -Wrap
