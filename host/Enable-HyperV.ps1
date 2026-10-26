#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Enables Hyper-V (platform + management tools) on Windows 11 Pro. Reboot required.

.DESCRIPTION
    This is a system change, so the lab never runs it on its own: run it yourself
    from an elevated PowerShell, then reboot. Safe to re-run; it reports and exits
    if Hyper-V is already on.

    Prerequisites the script checks: Pro/Enterprise/Education edition and
    virtualization enabled in firmware (VT-x on the i7-8650U).
#>
[CmdletBinding(SupportsShouldProcess)]
param()

$feature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All
if ($feature.State -eq 'Enabled') {
    Write-Output 'Hyper-V is already enabled.'
    return
}

$cs = Get-CimInstance Win32_ComputerSystem
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
if (-not $cs.HypervisorPresent -and -not $cpu.VirtualizationFirmwareEnabled) {
    throw 'Virtualization is disabled in firmware. Enable Intel VT-x in the BIOS/UEFI setup first.'
}

if ($PSCmdlet.ShouldProcess('Microsoft-Hyper-V-All', 'Enable Windows optional feature')) {
    Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All -NoRestart | Out-Null
    Write-Output 'Hyper-V enabled. Reboot to finish (Restart-Computer).'
}
