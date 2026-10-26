#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Applies one image from an evaluation ISO to a bootable UEFI base VHDX. Idempotent.

.DESCRIPTION
    No Windows Setup, no clicking through OOBE: the image is applied with DISM to a
    GPT disk laid out the way Microsoft documents for UEFI (ESP, MSR, Windows), and
    made bootable with bcdboot. The image in install.wim is already generalized, so
    every VM built on a differencing child of this disk runs specialize on first
    boot and gets its own SID.

.EXAMPLE
    .\New-LabBaseDisk.ps1 -IsoPath C:\Lab\iso\WindowsServer2025-Eval.iso `
        -ImageName '^Windows Server 2025 Standard Evaluation$' -Path C:\Lab\eaptls\base\ws2025-core.vhdx
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$IsoPath,
    [Parameter(Mandatory)][string]$ImageName,
    [Parameter(Mandatory)][string]$Path,
    [int]$SizeGB = 64
)

Import-Module (Join-Path $PSScriptRoot 'LabCommon.psm1') -Force

if (Test-Path -LiteralPath $Path) {
    Write-LabStep "Base disk exists: $Path"
    return
}
if (-not (Test-Path -LiteralPath $IsoPath)) { throw "ISO not found: $IsoPath (see README, Media)." }

function Get-FreeDriveLetter {
    $used = (Get-PSDrive -PSProvider FileSystem).Name
    [char[]](70..90) | Where-Object { $used -notcontains [string]$_ } | Select-Object -First 1
}

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
$partial = "$Path.partial"
Remove-Item -LiteralPath $partial -ErrorAction SilentlyContinue

$iso = Mount-DiskImage -ImagePath $IsoPath -PassThru
try {
    $isoLetter = ($iso | Get-Volume).DriveLetter
    $wim = "${isoLetter}:\sources\install.wim"
    if (-not (Test-Path $wim)) { $wim = "${isoLetter}:\sources\install.esd" }
    $image = Get-WindowsImage -ImagePath $wim | Where-Object { $_.ImageName -match $ImageName } | Select-Object -First 1
    if (-not $image) {
        $names = (Get-WindowsImage -ImagePath $wim).ImageName -join '; '
        throw "No image matching '$ImageName' in $wim. Available: $names"
    }
    Write-LabStep "Applying '$($image.ImageName)' (index $($image.ImageIndex)) to $Path"

    New-VHD -Path $partial -SizeBytes ($SizeGB * 1GB) -Dynamic | Out-Null
    $disk = Mount-VHD -Path $partial -Passthru | Get-Disk
    try {
        $sys = Get-FreeDriveLetter
        # Reserve the first letter before asking for a second.
        $win = [char[]](70..90) | Where-Object { (Get-PSDrive -PSProvider FileSystem).Name -notcontains [string]$_ -and $_ -ne $sys } | Select-Object -First 1

        # Layout from Microsoft's documented UEFI/GPT partition script.
        $diskpart = @"
select disk $($disk.Number)
clean
convert gpt
create partition efi size=260
format quick fs=fat32 label="System"
assign letter=$sys
create partition msr size=16
create partition primary
format quick fs=ntfs label="Windows"
assign letter=$win
exit
"@
        $dpFile = New-TemporaryFile
        Set-Content -LiteralPath $dpFile -Value $diskpart -Encoding ASCII
        $dpOut = & diskpart.exe /s $dpFile
        Remove-Item -LiteralPath $dpFile
        if ($LASTEXITCODE -ne 0) { throw "diskpart failed:`n$($dpOut -join "`n")" }

        Expand-WindowsImage -ImagePath $wim -Index $image.ImageIndex -ApplyPath "${win}:\" | Out-Null
        $bcd = & bcdboot.exe "${win}:\Windows" /s "${sys}:" /f UEFI
        if ($LASTEXITCODE -ne 0) { throw "bcdboot failed: $bcd" }
    }
    finally {
        Dismount-VHD -Path $partial
    }
}
finally {
    Dismount-DiskImage -ImagePath $IsoPath | Out-Null
}

Move-Item -LiteralPath $partial -Destination $Path
# The base is a parent for differencing disks; it must never change again.
Set-ItemProperty -LiteralPath $Path -Name IsReadOnly -Value $true
Write-LabStep "Base disk ready: $Path"
