#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Creates one Windows lab VM on a differencing disk with its answer file injected. Idempotent.

.DESCRIPTION
    Generation 2, Secure Boot, dynamic memory sized from lab.config.psd1. The
    Windows 11 client also gets a virtual TPM. The VM is started and the script
    waits until PowerShell Direct answers, so the next stage can run immediately.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Name,
    [hashtable]$Config
)

Import-Module (Join-Path $PSScriptRoot 'LabCommon.psm1') -Force
if (-not $Config) { $Config = Get-LabConfig }
$spec = Get-LabVMSpec -Config $Config -Name $Name
if ($spec.Os -eq 'Linux') { throw "$Name is the Linux authenticator; use New-LabLinuxVM.ps1." }

$root = $Config.Paths.Root
$baseFile = switch ($spec.Os) {
    'ServerCore' { 'ws2025-core.vhdx' }
    'ServerDesktop' { 'ws2025-desktop.vhdx' }
    'Client' { 'win11-ent.vhdx' }
}
$parent = Join-Path $root "base\$baseFile"
$vhd = Join-Path $root "vms\$Name\$Name.vhdx"

if (Get-VM -Name $Name -ErrorAction SilentlyContinue) {
    Write-LabStep "$Name exists; ensuring it is running"
}
else {
    if (-not (Test-Path -LiteralPath $parent)) { throw "Base disk missing: $parent. Run the BaseDisks stage first." }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $vhd) | Out-Null

    if (-not (Test-Path -LiteralPath $vhd)) {
        Write-LabStep "Creating differencing disk for $Name"
        New-VHD -Path $vhd -ParentPath $parent -Differencing | Out-Null

        # Inject the answer file into the child disk before first boot.
        $template = if ($spec.Os -eq 'Client') { 'client.xml' } else { 'server.xml' }
        $values = @{
            COMPUTER_NAME = $Name
            TIME_ZONE     = $Config.Domain.TimeZone
        }
        if ($spec.Os -eq 'Client') {
            $values.LOCAL_ADMIN = $Config.Client.LocalAdmin
            $values.LOCAL_ADMIN_PASSWORD = ConvertFrom-LabSecureString (Get-LabSecret -Config $Config -Name ClientPassword)
        }
        else {
            $values.ADMIN_PASSWORD = ConvertFrom-LabSecureString (Get-LabSecret -Config $Config -Name AdminPassword)
        }
        $xml = Expand-LabTemplate -Path (Join-Path $PSScriptRoot "unattend\$template") -Values $values

        $disk = Mount-VHD -Path $vhd -Passthru | Get-Disk
        try {
            $part = Get-Partition -DiskNumber $disk.Number | Where-Object Type -eq 'Basic' | Sort-Object Size -Descending | Select-Object -First 1
            if (-not $part.DriveLetter -or $part.DriveLetter -eq [char]0) {
                $part | Add-PartitionAccessPath -AssignDriveLetter
                $part = Get-Partition -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber
            }
            $panther = "$($part.DriveLetter):\Windows\Panther"
            New-Item -ItemType Directory -Force -Path $panther | Out-Null
            [IO.File]::WriteAllText("$panther\unattend.xml", $xml, (New-Object Text.UTF8Encoding $false))
        }
        finally {
            Dismount-VHD -Path $vhd
        }
        $xml = $null
    }

    Write-LabStep "Creating VM $Name ($($spec.Os), $($spec.StartupMB) MB)"
    $vm = New-VM -Name $Name -Generation 2 -MemoryStartupBytes ($spec.StartupMB * 1MB) -VHDPath $vhd `
        -SwitchName $Config.Network.SwitchName -Path (Join-Path $root 'vms')
    Set-VM -VM $vm -ProcessorCount $spec.Cpu -DynamicMemory `
        -MemoryMinimumBytes ($spec.MinMB * 1MB) -MemoryMaximumBytes ($spec.MaxMB * 1MB) `
        -AutomaticCheckpointsEnabled $false -AutomaticStopAction ShutDown
    Set-VMFirmware -VM $vm -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows
    Enable-VMIntegrationService -VM $vm -Name 'Guest Service Interface'

    if ($spec.Os -eq 'Client') {
        # Windows 11 expects a TPM; a local key protector is enough for a lab.
        Set-VMKeyProtector -VM $vm -NewLocalKeyProtector
        Enable-VMTPM -VM $vm
    }
}

if ((Get-VM -Name $Name).State -ne 'Running') { Start-VM -Name $Name }

$creds = if ($spec.Os -eq 'Client') {
    @((Get-LabCredential -Config $Config -Kind DomainAdministrator), (Get-LabCredential -Config $Config -Kind ClientLocalAdmin))
}
else {
    @((Get-LabCredential -Config $Config -Kind DomainAdministrator), (Get-LabCredential -Config $Config -Kind LocalAdministrator))
}
# On a re-run the machine may already be promoted or joined, so try the domain
# credential first and fall back to the local one.
$cred = Wait-LabVM -VMName $Name -Credential $creds
Write-LabStep "$Name is answering PowerShell Direct as $($cred.UserName)"
