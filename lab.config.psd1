#
# Single source of truth for the lab. Every script reads this file; nothing else
# hard-codes a name, address or size. All names are lab-only (RFC 2606 .example).
#
@{
    Paths = @{
        # VM disks, generated secrets and exported evidence live outside the repo.
        Root    = 'C:\Lab\eaptls'
        Secrets = 'C:\Lab\eaptls\secrets'
        Out     = 'C:\Lab\eaptls\out'
        Iso     = 'C:\Lab\iso'
    }

    Media = @{
        # Evaluation media. File names are what Build-Lab.ps1 expects in Paths.Iso;
        # see README "Media" for sources. Image names are matched as regex against
        # Get-WindowsImage output, so they survive minor ISO revisions.
        ServerIso          = 'WindowsServer2025-Eval.iso'
        ServerCoreImage    = '^Windows Server 2025 Standard Evaluation$'
        ServerDesktopImage = '^Windows Server 2025 Standard Evaluation \(Desktop Experience\)$'
        ClientIso          = 'Windows11-Enterprise-Eval.iso'
        ClientImage        = '^Windows 11 Enterprise Evaluation$'
        # Debian 13 genericcloud image (tar.xz holding disk.raw) for the authenticator VM.
        # https://cloud.debian.org/images/cloud/trixie/latest/
        LinuxImageArchive  = 'debian-13-genericcloud-amd64.tar.xz'
    }

    Domain = @{
        Fqdn     = 'lab.example'
        NetBios  = 'LAB'
        TimeZone = 'Eastern Standard Time'
    }

    Network = @{
        # LabNet: internal switch shared by servers, the authenticator uplink and the host.
        SwitchName       = 'LabNet'
        # LabAccess: private switch. The only things on it are the client and the
        # authenticator's access port, so the client has no path to anything that
        # does not go through 802.1X.
        AccessSwitchName = 'LabAccess'
        Prefix           = '10.20.0'
        PrefixLength     = 24
        Gateway          = '10.20.0.1'   # host vNIC on LabNet
        NatName          = 'LabNat'       # host NAT so AUTH01 can apt-get its packages
        UpstreamDns      = '1.1.1.1'
    }

    VMs = @(
        # NPS runs on the domain controller on purpose: the production design put
        # NPS/RADIUS on the (Azure-hosted) DCs. NPS (the NPAS role) is not available
        # on Server Core, so DC01 is the one VM with Desktop Experience.
        @{ Name = 'DC01';     Role = 'dc';     Os = 'ServerDesktop'; Ip = '10.20.0.10'; Cpu = 2; StartupMB = 2048; MinMB = 1536; MaxMB = 3072; DiskGB = 40 }
        @{ Name = 'CA01';     Role = 'ca';     Os = 'ServerCore';    Ip = '10.20.0.11'; Cpu = 2; StartupMB = 1536; MinMB = 1024; MaxMB = 2048; DiskGB = 40 }
        @{ Name = 'CLIENT01'; Role = 'client'; Os = 'Client';        Ip = '10.20.0.50'; Cpu = 2; StartupMB = 4096; MinMB = 2048; MaxMB = 4096; DiskGB = 64 }
        # AUTH01 NICs get fixed MACs so cloud-init can name them uplink/access by MAC.
        @{ Name = 'AUTH01';   Role = 'auth';   Os = 'Linux';         Ip = '10.20.0.40'; Cpu = 1; StartupMB = 512;  MinMB = 512;  MaxMB = 512;  DiskGB = 8; UplinkMac = '00155D140040'; AccessMac = '00155D140041' }
    )

    Pki = @{
        CaCommonName            = 'LAB-ROOT-CA'
        CaValidityYears         = 10
        CdpHost                 = 'pki.lab.example'   # CNAME to CA01; the name the demo makes unreachable
        CrlPeriodDays           = 7
        CrlDeltaPeriodDays      = 1
        ClientTemplate          = 'LabComputerAuth'
        ClientTemplateDisplay   = 'Lab Computer Authentication'
        # Lab-only: lets the eapol_test path reuse CLIENT01's identity. Production
        # machine keys should not be exportable.
        ClientKeyExportable     = $true
        NpsServerTemplate       = 'RASAndIASServer'
    }

    Radius = @{
        PolicyName        = 'Lab Wired 802.1X EAP-TLS'
        ClientFriendlyName = 'AUTH01'
        DeviceGroup       = 'LAB-8021X-Computers'
        NasPortType       = 15   # Ethernet. Wi-Fi would be 19 (Wireless - IEEE 802.11).
    }

    Client = @{
        LocalAdmin = 'labadmin'
    }
}
