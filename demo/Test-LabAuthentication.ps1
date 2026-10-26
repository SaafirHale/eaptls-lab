#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Forces CLIENT01 to re-authenticate on its 802.1X port and collects the evidence from all three sides. Runs on the host.

.DESCRIPTION
    Client:        netsh lan state, Wired-AutoConfig events, whether DC01 answers a ping
    Authenticator: the authorized-MAC set and hostapd's log
    NPS:           6272/6273 events with reason codes

    PowerShell Direct reaches CLIENT01 over VMBus, so the client can be inspected
    even while its port is closed and it has no network at all.

    Writes <label>-<timestamp>.json and .txt to Paths.Out for the run log.
#>
[CmdletBinding()]
param(
    [hashtable]$Config,
    [string]$Label = 'auth',
    [int]$WaitSeconds = 30
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'host\LabCommon.psm1') -Force
if (-not $Config) { $Config = Get-LabConfig }
$cred = Get-LabCredential -Config $Config -Kind DomainAdministrator
$dcIp = (Get-LabVMSpec -Config $Config -Name DC01).Ip
$started = Get-Date

Write-LabStep "[$Label] Reconnecting CLIENT01's wired interface"
Invoke-Command -VMName CLIENT01 -Credential $cred -ScriptBlock {
    $nic = Get-NetAdapter -Physical | Sort-Object ifIndex | Select-Object -First 1
    & netsh.exe lan reconnect interface="$($nic.Name)" | Out-Null
}
Start-Sleep -Seconds $WaitSeconds

$clientSide = Invoke-Command -VMName CLIENT01 -Credential $cred -ArgumentList $dcIp, $started -ScriptBlock {
    param($DcIp, $Since)
    $events = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Wired-AutoConfig/Operational'; StartTime = $Since } -ErrorAction SilentlyContinue |
        Select-Object -First 10 | ForEach-Object {
            [pscustomobject]@{ Time = $_.TimeCreated; Id = $_.Id; Message = ($_.Message -split "`r?`n")[0] + ' ' + (($_.Message -split "`r?`n") -match 'Reason|Error|Status' -join ' ') }
        }
    [pscustomobject]@{
        LanState   = (& netsh.exe lan show interfaces) -join "`n"
        PingDc     = Test-Connection -ComputerName $DcIp -Count 2 -Quiet
        WiredEvents = $events
    }
}

$npsSide = Invoke-LabScript -VMName DC01 -Credential $cred -Path 'demo\Get-NpsAuthEvent.ps1' -Parameters @{
    Minutes = [int][Math]::Ceiling(((Get-Date) - $started).TotalMinutes) + 1
}

$authSide = (Invoke-LabSsh -Config $Config -Command 'sudo nft list set bridge dot1x authorized; echo ---; sudo journalctl -u dot1x-hostapd -u dot1x-gate -n 25 --no-pager -o short-iso') -join "`n"

$result = [pscustomobject]@{
    Label         = $Label
    Started       = $started
    ClientPingsDc = $clientSide.PingDc
    NpsDecisions  = @($npsSide | Select-Object Time, EventId, Result, Machine, RadiusClient, NetworkPolicy, AuthType, EapType, ReasonCode, Reason)
    ClientLan     = $clientSide.LanState
    ClientEvents  = $clientSide.WiredEvents
    Authenticator = $authSide
}

$stamp = '{0}-{1:yyyyMMdd-HHmmss}' -f $Label, $started
$out = $Config.Paths.Out
New-Item -ItemType Directory -Force -Path $out | Out-Null
$result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $out "$stamp.json") -Encoding UTF8
@(
    "== $Label @ $started =="
    "Client pings DC01: $($result.ClientPingsDc)"
    ''
    '-- NPS (Security log) --'
    ($result.NpsDecisions | Format-List | Out-String).Trim()
    ''
    '-- Client: netsh lan show interfaces --'
    $result.ClientLan
    ''
    '-- Client: Wired-AutoConfig/Operational --'
    ($result.ClientEvents | Format-Table -AutoSize -Wrap | Out-String).Trim()
    ''
    '-- AUTH01: authorized set, hostapd/gate log --'
    $result.Authenticator
) | Set-Content -LiteralPath (Join-Path $out "$stamp.txt") -Encoding UTF8

Write-LabStep "[$Label] Evidence written to $(Join-Path $out $stamp).{json,txt}"
$result
