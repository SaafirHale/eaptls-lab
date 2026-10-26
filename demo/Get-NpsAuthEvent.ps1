#Requires -Version 5.1
<#
.SYNOPSIS
    Reads NPS accept/deny decisions from the Security log as objects. Runs on the NPS server (DC01).

.DESCRIPTION
    6272 = access granted, 6273 = access denied, 6274 = request discarded,
    6276 = quarantined, 6278 = full access granted. ReasonCode/Reason are the
    fields that say *why*; on a CDP outage they name revocation, not the radio,
    the switch or the client. Every EventData field is returned under Data so
    nothing NPS logged is thrown away.

.EXAMPLE
    .\Get-NpsAuthEvent.ps1 -Minutes 10 | Format-List Time, Result, Machine, ReasonCode, Reason
#>
[CmdletBinding()]
param(
    [int]$Minutes = 15,
    [int]$MaxEvents = 20
)

$results = @{
    6272 = 'Granted'; 6273 = 'Denied'; 6274 = 'Discarded'; 6276 = 'Quarantined'; 6278 = 'FullAccess'
}
$filter = @{
    LogName   = 'Security'
    Id        = [int[]]$results.Keys
    StartTime = (Get-Date).AddMinutes(-$Minutes)
}

$events = Get-WinEvent -FilterHashtable $filter -MaxEvents $MaxEvents -ErrorAction SilentlyContinue
foreach ($e in $events) {
    $data = [ordered]@{}
    foreach ($node in ([xml]$e.ToXml()).Event.EventData.Data) { $data[$node.Name] = $node.'#text' }
    $machine = if ($data['FullyQualifiedSubjectMachineName'] -and $data['FullyQualifiedSubjectMachineName'] -ne '-') {
        $data['FullyQualifiedSubjectMachineName']
    }
    else { $data['FullyQualifiedSubjectUserName'] }

    [pscustomobject]@{
        Time           = $e.TimeCreated
        EventId        = $e.Id
        Result         = $results[$e.Id]
        Machine        = $machine
        CallingStation = $data['CallingStationID']
        RadiusClient   = $data['ClientName']
        NetworkPolicy  = $data['NetworkPolicyName']
        AuthType       = $data['AuthenticationType']
        EapType        = $data['EAPType']
        ReasonCode     = $data['ReasonCode']
        Reason         = $data['Reason']
        Data           = [pscustomobject]$data
    }
}
