#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Checks the one thing nobody documents: does the Hyper-V private switch deliver CLIENT01's EAPOL frames to AUTH01? Runs on the host.

.DESCRIPTION
    EAPOL goes to the link-local group address 01:80:C2:00:00:03. Physical
    switches are supposed to consume such frames, and whether a Hyper-V private
    switch forwards them VM-to-VM is not documented anywhere. So before trusting
    any authentication result, capture on AUTH01's access port while CLIENT01
    restarts 802.1X:

      frames seen   -> the wired path works; use Test-LabAuthentication.ps1
      nothing seen  -> the switch eats EAPOL; use Invoke-LabEapolTest.ps1, which
                       runs the same EAP-TLS exchange against NPS from AUTH01
#>
[CmdletBinding()]
param([int]$CaptureSeconds = 30)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'host\LabCommon.psm1') -Force
Assert-LabHost
$config = Get-LabConfig
$cred = Get-LabCredential -Config $config -Kind DomainAdministrator
$clientMac = ((Get-VMNetworkAdapter -VMName CLIENT01 | Select-Object -First 1).MacAddress -replace '(..)(?!$)', '$1:').ToLower()

# Start the capture in the background on AUTH01, then kick the client.
$repo = Get-LabRepoRoot
$seconds = $CaptureSeconds
$job = Start-Job -ScriptBlock {
    Import-Module (Join-Path $using:repo 'host\LabCommon.psm1')
    Invoke-LabSsh -Config (Get-LabConfig) -Command "sudo timeout $($using:seconds) tcpdump -e -n -l -i access ether proto 0x888e 2>&1"
}
Start-Sleep -Seconds 3
Invoke-Command -VMName CLIENT01 -Credential $cred -ScriptBlock {
    $nic = Get-NetAdapter -Physical | Sort-Object ifIndex | Select-Object -First 1
    & netsh.exe lan reconnect interface="$($nic.Name)" | Out-Null
}
$capture = Receive-Job -Job $job -Wait -AutoRemoveJob
$frames = @($capture | Where-Object { $_ -match 'EAP' })
$fromClient = @($frames | Where-Object { $_ -match [regex]::Escape($clientMac) })

[pscustomobject]@{
    ClientMac         = $clientMac
    EapolFramesSeen   = $frames.Count
    FromClient        = $fromClient.Count
    Verdict           = if ($fromClient.Count) { 'EAPOL reaches AUTH01: wired path usable' } else { 'No EAPOL from CLIENT01 on the access port: use Invoke-LabEapolTest.ps1' }
    Capture           = $capture -join "`n"
}
