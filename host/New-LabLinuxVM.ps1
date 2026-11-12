#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Builds AUTH01, the wired 802.1X authenticator, from the Debian generic cloud image. Idempotent.

.DESCRIPTION
    Debian publishes cloud images as raw disks; Hyper-V Generation 2 boots VHDX.
    A fixed VHD is a raw disk with a 512-byte footer, so the conversion needs no
    third-party tools: create a fixed VHD of the same size, copy the raw bytes
    over its data area, and Convert-VHD it to VHDX.

    First-boot configuration is cloud-init NoCloud from a small FAT32 disk
    labelled CIDATA (user-data, meta-data, network-config), generated from the
    templates in roles\auth01. That installs hostapd, eapoltest and nftables
    from the Debian mirror through the host NAT, drops in the authenticator
    config and the port gate, and starts them.

    Both NICs get fixed MACs (cloud-init matches on them) and MAC address
    spoofing: the bridge forwards the client's frames with the client's source
    MAC, which Hyper-V would otherwise drop.
#>
[CmdletBinding()]
param(
    [string]$Name = 'AUTH01',
    [hashtable]$Config
)

Import-Module (Join-Path $PSScriptRoot 'LabCommon.psm1') -Force
if (-not $Config) { $Config = Get-LabConfig }
$spec = Get-LabVMSpec -Config $Config -Name $Name
$net = $Config.Network
$dc = Get-LabVMSpec -Config $Config -Name DC01
$root = $Config.Paths.Root
$repo = Get-LabRepoRoot

# --- 1. Base VHDX from the cloud image (once) -------------------------------------
$baseVhdx = Join-Path $root 'base\debian13-generic.vhdx'
if (-not (Test-Path -LiteralPath $baseVhdx)) {
    $archive = Join-Path $Config.Paths.Iso $Config.Media.LinuxImageArchive
    if (-not (Test-Path -LiteralPath $archive)) { throw "Missing $archive (see README, Media)." }

    # Downloaded archive: extract into its own empty directory.
    $extract = Join-Path $root ('base\debian-extract-{0:yyyyMMddHHmmss}' -f (Get-Date))
    New-Item -ItemType Directory -Force -Path $extract | Out-Null
    Write-LabStep "Extracting $archive"
    & "$env:SystemRoot\System32\tar.exe" -xf $archive -C $extract
    if ($LASTEXITCODE -ne 0) { throw 'tar extraction failed.' }
    $raw = Get-ChildItem -LiteralPath $extract -Filter *.raw -Recurse | Select-Object -First 1
    if (-not $raw) { throw "No .raw disk inside $archive." }
    if ($raw.Length % 1MB) { throw "Raw image size $($raw.Length) is not a whole number of MiB; refusing to guess." }

    $fixed = Join-Path $extract 'disk.vhd'
    Write-LabStep "Converting $($raw.Name) ($([math]::Round($raw.Length / 1GB, 1)) GiB) to VHDX"
    New-VHD -Path $fixed -SizeBytes $raw.Length -Fixed | Out-Null
    $in = [IO.File]::OpenRead($raw.FullName)
    $out = [IO.File]::Open($fixed, [IO.FileMode]::Open, [IO.FileAccess]::Write)
    try { $in.CopyTo($out, 4MB) }   # overwrite the data area; the footer at the end stays
    finally { $in.Dispose(); $out.Dispose() }
    Convert-VHD -Path $fixed -DestinationPath $baseVhdx -VHDType Dynamic
    Remove-Item -LiteralPath $extract -Recurse -Force
    Set-ItemProperty -LiteralPath $baseVhdx -Name IsReadOnly -Value $true
}

if (-not (Get-VM -Name $Name -ErrorAction SilentlyContinue)) {
    $vmDir = Join-Path $root "vms\$Name"
    New-Item -ItemType Directory -Force -Path $vmDir | Out-Null

    # --- 2. System disk: a copy of the base, grown; cloud-init grows the root fs ---
    $systemDisk = Join-Path $vmDir "$Name.vhdx"
    Copy-Item -LiteralPath $baseVhdx -Destination $systemDisk
    Set-ItemProperty -LiteralPath $systemDisk -Name IsReadOnly -Value $false
    Resize-VHD -Path $systemDisk -SizeBytes ($spec.DiskGB * 1GB)

    # --- 3. cloud-init seed --------------------------------------------------------
    $authDir = Join-Path $repo 'roles\auth01'
    $secret = ConvertFrom-LabSecureString (Get-LabSecret -Config $Config -Name RadiusSecret)
    $hostapdConf = Expand-LabTemplate -Path (Join-Path $authDir 'hostapd-access.conf.template') -Values @{
        AUTH_IP = $spec.Ip; NAS_ID = "$($Name.ToLower()).$($Config.Domain.Fqdn)"
        RADIUS_SERVER = $dc.Ip; RADIUS_SECRET = $secret
    }
    $secret = $null
    $files = @(
        @{ Path = '/etc/hostapd/wired-access.conf'; Mode = '0600'; Text = $hostapdConf }
        @{ Path = '/etc/nftables.conf'; Mode = '0755'; Text = (Get-Content -LiteralPath (Join-Path $authDir 'nftables.conf') -Raw) }
        @{ Path = '/usr/local/sbin/dot1x-gate.sh'; Mode = '0755'; Text = (Get-Content -LiteralPath (Join-Path $authDir 'dot1x-gate.sh') -Raw) }
        @{ Path = '/etc/systemd/system/dot1x-hostapd.service'; Mode = '0644'; Text = (Get-Content -LiteralPath (Join-Path $authDir 'dot1x-hostapd.service') -Raw) }
        @{ Path = '/etc/systemd/system/dot1x-gate.service'; Mode = '0644'; Text = (Get-Content -LiteralPath (Join-Path $authDir 'dot1x-gate.service') -Raw) }
    )
    # Base64 sidesteps YAML quoting; LF line endings because these run on Linux.
    $writeFiles = ($files | ForEach-Object {
            $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($_.Text.Replace("`r`n", "`n")))
            "  - path: $($_.Path)`n    permissions: `"$($_.Mode)`"`n    encoding: b64`n    content: $b64"
        }) -join "`n"

    $pubKey = (Get-Content -LiteralPath "$(Get-LabSshKey -Config $Config).pub" -Raw).Trim()
    $common = @{ HOSTNAME = $Name.ToLower(); DOMAIN = $Config.Domain.Fqdn }
    $seed = @{
        'user-data'      = Expand-LabTemplate -Path (Join-Path $authDir 'cloud-init\user-data.template') -Values ($common + @{
                SSH_PUBKEY = $pubKey; WRITE_FILES = $writeFiles })
        'meta-data'      = Expand-LabTemplate -Path (Join-Path $authDir 'cloud-init\meta-data.template') -Values ($common + @{
                INSTANCE_ID = "$($Name.ToLower())-$(Get-Date -Format yyyyMMddHHmmss)" })
        'network-config' = Expand-LabTemplate -Path (Join-Path $authDir 'cloud-init\network-config.template') -Values ($common + @{
                UPLINK_MAC = ($spec.UplinkMac -replace '(..)(?!$)', '$1:').ToLower()
                ACCESS_MAC = ($spec.AccessMac -replace '(..)(?!$)', '$1:').ToLower()
                AUTH_IP = $spec.Ip; PREFIX_LENGTH = $net.PrefixLength; GATEWAY = $net.Gateway
                DNS1 = $dc.Ip; DNS2 = $net.UpstreamDns })
    }

    $seedDisk = Join-Path $vmDir 'cidata.vhdx'
    New-VHD -Path $seedDisk -SizeBytes 128MB -Dynamic | Out-Null
    $disk = Mount-VHD -Path $seedDisk -Passthru | Get-Disk
    try {
        Initialize-Disk -Number $disk.Number -PartitionStyle MBR
        $part = New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter
        Format-Volume -Partition $part -FileSystem FAT32 -NewFileSystemLabel CIDATA -Confirm:$false | Out-Null
        $letter = (Get-Partition -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber).DriveLetter
        foreach ($key in $seed.Keys) {
            $text = $seed[$key].Replace("`r`n", "`n")
            [IO.File]::WriteAllText("${letter}:\$key", $text, (New-Object Text.UTF8Encoding $false))
        }
    }
    finally { Dismount-VHD -Path $seedDisk }
    $seed = $null; $hostapdConf = $null; $files = $null; $writeFiles = $null

    # --- 4. The VM ---------------------------------------------------------------
    Write-LabStep "Creating VM $Name (Debian 13, $($spec.StartupMB) MB)"
    $vm = New-VM -Name $Name -Generation 2 -MemoryStartupBytes ($spec.StartupMB * 1MB) -VHDPath $systemDisk `
        -SwitchName $net.SwitchName -Path (Join-Path $root 'vms')
    Set-VM -VM $vm -ProcessorCount $spec.Cpu -StaticMemory -AutomaticCheckpointsEnabled $false -AutomaticStopAction ShutDown
    # Linux on Gen2 needs the third-party UEFI CA template; Debian ships a signed shim.
    Set-VMFirmware -VM $vm -EnableSecureBoot On -SecureBootTemplate MicrosoftUEFICertificateAuthority
    Add-VMHardDiskDrive -VM $vm -Path $seedDisk

    $uplink = Get-VMNetworkAdapter -VM $vm | Select-Object -First 1
    Rename-VMNetworkAdapter -VMNetworkAdapter $uplink -NewName 'uplink'
    Set-VMNetworkAdapter -VMNetworkAdapter $uplink -StaticMacAddress $spec.UplinkMac -MacAddressSpoofing On
    Add-VMNetworkAdapter -VM $vm -Name 'access' -SwitchName $net.AccessSwitchName -StaticMacAddress $spec.AccessMac
    Set-VMNetworkAdapter -VMName $Name -Name 'access' -MacAddressSpoofing On
}

if ((Get-VM -Name $Name).State -ne 'Running') { Start-VM -Name $Name }

# --- 5. Wait for cloud-init to finish and the authenticator to be up ---------------
Write-LabStep "Waiting for $Name (cloud-init installs packages on first boot)"
$deadline = (Get-Date).AddMinutes(15)
$status = $null
while ((Get-Date) -lt $deadline) {
    $status = Invoke-LabSsh -Config $Config -Command 'cloud-init status --wait >/dev/null 2>&1; systemctl is-active nftables dot1x-hostapd dot1x-gate | tr "\n" " "' 2>$null
    if ($LASTEXITCODE -eq 0 -and $status -match '^active active active') { break }
    Start-Sleep -Seconds 15
}
if ($status -notmatch '^active active active') {
    throw "$Name did not come up cleanly (services: '$status'). Check: ssh labadmin@$($spec.Ip) 'sudo cloud-init status --long; sudo journalctl -u dot1x-hostapd'."
}
Write-LabStep "${Name}: nftables, hostapd (wired) and the port gate are active"
