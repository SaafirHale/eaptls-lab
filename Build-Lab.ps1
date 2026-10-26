#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Builds the EAP-TLS lab end to end, or any stage of it. Every stage is idempotent: re-running skips what is already done.

.DESCRIPTION
    Stages, in order:
      Network        LabNet + LabAccess switches, host vNIC, NAT
      BaseDisks      Server Core and Windows 11 base VHDX from the evaluation ISOs
      Domain         DC01: static IP, new forest lab.example, OU, device group, pki CNAME
      Pki            CA01: join, Enterprise Root CA, HTTP-only CDP/AIA, IIS, templates
      Nps            DC01: autoenrollment GPO, NPS + server certificate, RADIUS client, EAP-TLS
                     policy imported from roles\dc01\nps\nps-config.template.xml
      NpsCapture     One-time and not in the default run: captures a policy built by hand
                     in nps.msc into that template (docs\nps-policy-gui.md)
      Client         CLIENT01: join into OU=Lab Workstations, autoenrolled cert, wired 802.1X profile
      Authenticator  AUTH01: Debian + hostapd (wired) + nftables port gate, RADIUS client of NPS
      Attach         Moves CLIENT01 behind AUTH01 and runs one authentication

    Run from an elevated Windows PowerShell 5.1 on the Hyper-V host.

.EXAMPLE
    .\Build-Lab.ps1                 # everything
    .\Build-Lab.ps1 -Stage Pki,Nps  # just those stages
#>
[CmdletBinding()]
param(
    [ValidateSet('Network', 'BaseDisks', 'Domain', 'Pki', 'Nps', 'NpsCapture', 'Client', 'Authenticator', 'Attach')]
    [string[]]$Stage = @('Network', 'BaseDisks', 'Domain', 'Pki', 'Nps', 'Client', 'Authenticator', 'Attach')
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'host\LabCommon.psm1') -Force
Assert-LabHost
$config = Get-LabConfig
$net = $config.Network
$domain = $config.Domain
$pki = $config.Pki
$dc = Get-LabVMSpec -Config $config -Name DC01
$ca = Get-LabVMSpec -Config $config -Name CA01
$client = Get-LabVMSpec -Config $config -Name CLIENT01
$auth = Get-LabVMSpec -Config $config -Name AUTH01

New-Item -ItemType Directory -Force -Path $config.Paths.Out | Out-Null
$transcript = Join-Path $config.Paths.Out ("build-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
Start-Transcript -Path $transcript | Out-Null

try {
    $domainCred = Get-LabCredential -Config $config -Kind DomainAdministrator
    $localCred = Get-LabCredential -Config $config -Kind LocalAdministrator
    $ip = @{ PrefixLength = $net.PrefixLength; Gateway = $net.Gateway }
    $adReady = { try { [bool](Get-ADDomain -ErrorAction Stop) } catch { $false } }
    $npsTemplate = Join-Path $PSScriptRoot 'roles\dc01\nps\nps-config.template.xml'
    $npsParams = @{
        PolicyName          = $config.Radius.PolicyName
        RadiusClientName    = $config.Radius.ClientFriendlyName
        RadiusClientAddress = $auth.Ip
        SharedSecret        = (Get-LabSecret -Config $config -Name RadiusSecret)
        ServerTemplate      = $pki.NpsServerTemplate
    }

    if ('Network' -in $Stage) {
        & (Join-Path $PSScriptRoot 'host\New-LabNetwork.ps1') -Config $config
    }

    if ('BaseDisks' -in $Stage) {
        $iso = $config.Paths.Iso
        $base = Join-Path $config.Paths.Root 'base'
        $newBase = Join-Path $PSScriptRoot 'host\New-LabBaseDisk.ps1'
        & $newBase -IsoPath (Join-Path $iso $config.Media.ServerIso) -ImageName $config.Media.ServerCoreImage -Path (Join-Path $base 'ws2025-core.vhdx') -SizeGB 40
        if ($config.VMs | Where-Object Os -eq 'ServerDesktop') {
            & $newBase -IsoPath (Join-Path $iso $config.Media.ServerIso) -ImageName $config.Media.ServerDesktopImage -Path (Join-Path $base 'ws2025-desktop.vhdx') -SizeGB 40
        }
        & $newBase -IsoPath (Join-Path $iso $config.Media.ClientIso) -ImageName $config.Media.ClientImage -Path (Join-Path $base 'win11-ent.vhdx') -SizeGB 64
    }

    if ('Domain' -in $Stage) {
        & (Join-Path $PSScriptRoot 'host\New-LabVM.ps1') -Name DC01 -Config $config
        $cred = Wait-LabVM -VMName DC01 -Credential $domainCred, $localCred
        Invoke-LabScript -VMName DC01 -Credential $cred -Path 'roles\common\Set-LabNetworkIdentity.ps1' -Parameters ($ip + @{
                IPAddress = $dc.Ip; DnsServers = @('127.0.0.1')
            })
        try {
            Invoke-LabScript -VMName DC01 -Credential $cred -Path 'roles\dc01\Install-LabForest.ps1' -Parameters @{
                DomainName = $domain.Fqdn; NetBiosName = $domain.NetBios
                SafeModePassword = (Get-LabSecret -Config $config -Name DsrmPassword)
            }
        }
        catch [System.Management.Automation.Remoting.PSRemotingTransportException] {
            # Promotion reboots the VM; a session cut mid-reply is expected here.
            Write-LabStep 'DC01 session closed by the post-promotion reboot'
        }
        Write-LabStep 'Waiting for AD DS on DC01 (first boot after promotion takes a few minutes)'
        Wait-LabVM -VMName DC01 -Credential $domainCred -ReadyTest $adReady -TimeoutSeconds 1500 | Out-Null
        Invoke-LabScript -VMName DC01 -Credential $domainCred -Path 'roles\dc01\Set-LabDirectory.ps1' -Parameters @{
            CdpHost = $pki.CdpHost; CaHostName = 'CA01'; DeviceGroup = $config.Radius.DeviceGroup; UpstreamDns = $net.UpstreamDns
        }
    }

    if ('Pki' -in $Stage) {
        & (Join-Path $PSScriptRoot 'host\New-LabVM.ps1') -Name CA01 -Config $config
        Invoke-LabScript -VMName CA01 -Credential $localCred -Path 'roles\common\Set-LabNetworkIdentity.ps1' -Parameters ($ip + @{
                IPAddress = $ca.Ip; DnsServers = @($dc.Ip)
            })
        Invoke-LabScript -VMName CA01 -Credential $localCred -Path 'roles\common\Join-LabDomain.ps1' -Parameters @{
            DomainName = $domain.Fqdn; Credential = $domainCred
        }
        $joined = { (Get-CimInstance Win32_ComputerSystem).PartOfDomain }
        Start-Sleep -Seconds 20
        Wait-LabVM -VMName CA01 -Credential $domainCred -ReadyTest $joined | Out-Null

        Invoke-LabScript -VMName CA01 -Credential $domainCred -Path 'roles\ca01\Install-LabCa.ps1' -Parameters @{
            CaCommonName = $pki.CaCommonName; CdpHost = $pki.CdpHost; ValidityYears = $pki.CaValidityYears
            CrlPeriodDays = $pki.CrlPeriodDays; CrlDeltaPeriodDays = $pki.CrlDeltaPeriodDays
        }
        Invoke-LabScript -VMName CA01 -Credential $domainCred -Path 'roles\ca01\Publish-LabCdp.ps1' -Parameters @{ CdpHost = $pki.CdpHost }
        Invoke-LabScript -VMName CA01 -Credential $domainCred -Path 'roles\ca01\New-LabCertTemplate.ps1' -Parameters @{
            Name = $pki.ClientTemplate; DisplayName = $pki.ClientTemplateDisplay; SourceTemplate = 'Workstation'
            EnrollPrincipal = "$($domain.NetBios)\Domain Computers"; ExportableKey = [bool]$pki.ClientKeyExportable
            AlsoPublish = @($pki.NpsServerTemplate)
        }
    }

    if ('Nps' -in $Stage) {
        Invoke-LabScript -VMName DC01 -Credential $domainCred -Path 'roles\dc01\Set-LabAutoenrollGpo.ps1'
        Invoke-LabScript -VMName DC01 -Credential $domainCred -Path 'roles\dc01\Install-LabNps.ps1' -Parameters @{ ServerTemplate = $pki.NpsServerTemplate }
        $apply = $npsParams.Clone()
        if (Test-Path -LiteralPath $npsTemplate) { $apply.ConfigTemplate = [IO.File]::ReadAllText($npsTemplate) }
        Invoke-LabScript -VMName DC01 -Credential $domainCred -Path 'roles\dc01\Set-LabNpsPolicy.ps1' -Parameters $apply
        # Keep the resulting NPS configuration (secrets already swapped for tokens) with the run's evidence.
        Copy-LabFileFromVM -VMName DC01 -Credential $domainCred -Path 'C:\ProgramData\eaptls-lab\nps-export.xml' `
            -Destination (Join-Path $config.Paths.Out 'nps-export.sanitized.xml')
    }

    if ('NpsCapture' -in $Stage) {
        # One-time, after the policy was built in nps.msc (docs\nps-policy-gui.md).
        $capture = $npsParams.Clone()
        $capture.Capture = $true
        $template = Invoke-LabScript -VMName DC01 -Credential $domainCred -Path 'roles\dc01\Set-LabNpsPolicy.ps1' -Parameters $capture
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $npsTemplate) | Out-Null
        [IO.File]::WriteAllText($npsTemplate, [string]$template, (New-Object Text.UTF8Encoding $false))
        Write-LabStep "Captured NPS template: $npsTemplate (commit it)"
    }

    if ('Client' -in $Stage) {
        & (Join-Path $PSScriptRoot 'host\New-LabVM.ps1') -Name CLIENT01 -Config $config
        $clientLocal = Get-LabCredential -Config $config -Kind ClientLocalAdmin
        $cred = Wait-LabVM -VMName CLIENT01 -Credential $domainCred, $clientLocal
        Invoke-LabScript -VMName CLIENT01 -Credential $cred -Path 'roles\common\Set-LabNetworkIdentity.ps1' -Parameters ($ip + @{
                IPAddress = $client.Ip; DnsServers = @($dc.Ip)
            })
        $ouPath = "OU=Lab Workstations,DC=$($domain.Fqdn -replace '\.', ',DC=')"
        Invoke-LabScript -VMName CLIENT01 -Credential $cred -Path 'roles\common\Join-LabDomain.ps1' -Parameters @{
            DomainName = $domain.Fqdn; Credential = $domainCred; OUPath = $ouPath
        }
        Start-Sleep -Seconds 20
        Wait-LabVM -VMName CLIENT01 -Credential $domainCred -ReadyTest { (Get-CimInstance Win32_ComputerSystem).PartOfDomain } | Out-Null

        # Port access is granted by group, so put the client in it.
        Invoke-Command -VMName DC01 -Credential $domainCred -ArgumentList $config.Radius.DeviceGroup -ScriptBlock {
            param($Group)
            $computer = Get-ADComputer CLIENT01
            if (-not (Get-ADGroupMember $Group | Where-Object SID -eq $computer.SID)) { Add-ADGroupMember $Group -Members $computer }
        }

        Invoke-LabScript -VMName CLIENT01 -Credential $domainCred -Path 'roles\client01\Set-LabWiredDot1x.ps1' -Parameters @{
            CaCommonName = $pki.CaCommonName; TemplateName = $pki.ClientTemplate; NpsServerName = "DC01.$($domain.Fqdn)"
        }
    }

    if ('Authenticator' -in $Stage) {
        & (Join-Path $PSScriptRoot 'host\New-LabLinuxVM.ps1') -Name AUTH01 -Config $config
    }

    if ('Attach' -in $Stage) {
        Write-LabStep 'Moving CLIENT01 onto LabAccess (behind AUTH01)'
        Get-VMNetworkAdapter -VMName CLIENT01 | Connect-VMNetworkAdapter -SwitchName $net.AccessSwitchName
        $path = & (Join-Path $PSScriptRoot 'demo\Test-LabEapolPath.ps1')
        $path | Select-Object ClientMac, EapolFramesSeen, FromClient, Verdict | Format-List | Out-Host
        $path.Capture | Set-Content -LiteralPath (Join-Path $config.Paths.Out 'attach-eapol-capture.txt') -Encoding UTF8
        if ($path.FromClient) {
            & (Join-Path $PSScriptRoot 'demo\Test-LabAuthentication.ps1') -Config $config -Label 'attach'
        }
        else {
            Write-LabStep 'Wired EAPOL path unavailable on this host; switching to the eapol_test path.'
            & (Join-Path $PSScriptRoot 'demo\Invoke-LabEapolTest.ps1') -Prepare
            & (Join-Path $PSScriptRoot 'demo\Invoke-LabEapolTest.ps1')
        }
    }

    Write-LabStep "Done. Transcript: $transcript"
}
finally {
    Stop-Transcript | Out-Null
}
