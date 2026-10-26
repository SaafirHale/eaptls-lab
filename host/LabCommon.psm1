#Requires -Version 5.1
<#
    Helpers shared by the host-side build scripts. Runs on the Hyper-V host only;
    nothing in here is copied into a VM.
#>
Set-StrictMode -Version Latest

$script:RepoRoot = Split-Path -Parent $PSScriptRoot

function Get-LabConfig {
    [CmdletBinding()]
    param([string]$Path = (Join-Path $script:RepoRoot 'lab.config.psd1'))
    Import-PowerShellDataFile -Path $Path
}

function Get-LabRepoRoot {
    [CmdletBinding()]
    param()
    $script:RepoRoot
}

function Get-LabVMSpec {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$Name
    )
    $spec = $Config.VMs | Where-Object { $_.Name -eq $Name }
    if (-not $spec) { throw "No VM named '$Name' in lab.config.psd1." }
    $spec
}

function Write-LabStep {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message)
    Write-Information -MessageData ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $Message) -InformationAction Continue
}

function New-LabSecureString {
    <#
        Random secret built straight into a SecureString. The alphabet leaves out
        characters that would need escaping in unattend XML, hostapd.conf or a
        shell heredoc, so the same secret can be dropped into any of them.
    #>
    [CmdletBinding()]
    [OutputType([securestring])]
    param([int]$Length = 24, [switch]$AlphaNumericOnly)

    $lower = 'abcdefghijkmnopqrstuvwxyz'
    $upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $digit = '23456789'
    $symbol = '-_.+='
    $sets = if ($AlphaNumericOnly) { @($lower, $upper, $digit) } else { @($lower, $upper, $digit, $symbol) }
    $all = -join $sets

    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    $buffer = New-Object byte[] 4
    $pick = {
        param([string]$From)
        $rng.GetBytes($buffer)
        $From[[BitConverter]::ToUInt32($buffer, 0) % $From.Length]
    }

    # One from every class first so complexity rules always pass, then fill.
    $chars = New-Object System.Collections.Generic.List[char]
    foreach ($set in $sets) { $chars.Add((& $pick $set)) }
    while ($chars.Count -lt $Length) { $chars.Add((& $pick $all)) }

    $secure = New-Object securestring
    $chars | Sort-Object { & $pick '0123456789' } | ForEach-Object { $secure.AppendChar($_) }
    $secure.MakeReadOnly()
    $rng.Dispose()
    $secure
}

function Get-LabSecret {
    <#
        Returns a lab secret as a SecureString, generating it on first use. Stored
        with Export-Clixml, so it is DPAPI-protected for the current user on this
        host and never lands in the repo.
    #>
    [CmdletBinding()]
    [OutputType([securestring])]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][ValidateSet('AdminPassword', 'DsrmPassword', 'ClientPassword', 'RadiusSecret', 'PfxPassword')]
        [string]$Name
    )
    $dir = $Config.Paths.Secrets
    $file = Join-Path $dir "$Name.clixml"
    if (-not (Test-Path -LiteralPath $file)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $secret = New-LabSecureString -AlphaNumericOnly:($Name -eq 'RadiusSecret')
        $secret | Export-Clixml -LiteralPath $file
    }
    Import-Clixml -LiteralPath $file
}

function ConvertFrom-LabSecureString {
    <# Plain text is only ever needed to write unattend.xml or a Linux config file. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][securestring]$SecureString)
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Get-LabCredential {
    <#
        Local credentials before a machine is domain-joined, LAB\Administrator after.
        The forest root Administrator keeps the local Administrator password of DC01
        when it is promoted, so one secret covers both.
    #>
    [CmdletBinding()]
    [OutputType([pscredential])]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][ValidateSet('LocalAdministrator', 'DomainAdministrator', 'ClientLocalAdmin')]
        [string]$Kind
    )
    switch ($Kind) {
        'LocalAdministrator' { New-Object pscredential ('Administrator', (Get-LabSecret -Config $Config -Name AdminPassword)) }
        'DomainAdministrator' { New-Object pscredential ("$($Config.Domain.NetBios)\Administrator", (Get-LabSecret -Config $Config -Name AdminPassword)) }
        'ClientLocalAdmin' { New-Object pscredential ($Config.Client.LocalAdmin, (Get-LabSecret -Config $Config -Name ClientPassword)) }
    }
}

function Wait-LabVM {
    <#
        Blocks until PowerShell Direct answers and returns the credential that
        worked. Used after every reboot (rename, promotion, domain join) because
        "VM is Running" says nothing about whether the guest is ready. Pass several
        credentials when the right one depends on how far the build got: a DC's
        local Administrator stops existing once it is promoted.
    #>
    [CmdletBinding()]
    [OutputType([pscredential])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][pscredential[]]$Credential,
        [int]$TimeoutSeconds = 900,
        [scriptblock]$ReadyTest = { $true }
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        foreach ($cred in $Credential) {
            try {
                $ready = Invoke-Command -VMName $VMName -Credential $cred -ScriptBlock $ReadyTest -ErrorAction Stop
                if ($ready) { return $cred }
            }
            catch {
                Write-Verbose "$VMName not ready as $($cred.UserName): $($_.Exception.Message)"
            }
        }
        Start-Sleep -Seconds 10
    }
    throw "Timed out after $TimeoutSeconds s waiting for $VMName."
}

function Invoke-LabScript {
    <#
        Runs a role script inside a VM over PowerShell Direct (VMBus, no network
        needed) with named parameters. The script file stays on the host; its text
        is shipped across and invoked with splatting so role scripts keep normal
        param() blocks and can also be run by hand inside the VM.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][pscredential]$Credential,
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$Parameters = @{}
    )
    $full = if ([IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $script:RepoRoot $Path }
    $text = Get-Content -LiteralPath $full -Raw
    Write-LabStep "$VMName <- $(Split-Path -Leaf $full)"
    Invoke-Command -VMName $VMName -Credential $Credential -ArgumentList $text, $Parameters -ScriptBlock {
        param($ScriptText, $ScriptParameters)
        $ErrorActionPreference = 'Stop'
        $block = [scriptblock]::Create($ScriptText)
        & $block @ScriptParameters
    }
}

function Copy-LabFileToVM {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][pscredential]$Credential,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Destination
    )
    $session = New-PSSession -VMName $VMName -Credential $Credential
    try {
        $dir = Split-Path -Parent $Destination
        Invoke-Command -Session $session -ScriptBlock { New-Item -ItemType Directory -Force -Path $using:dir | Out-Null }
        Copy-Item -LiteralPath $Path -Destination $Destination -ToSession $session -Force
    }
    finally { Remove-PSSession $session }
}

function Copy-LabFileFromVM {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][pscredential]$Credential,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Destination
    )
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
    $session = New-PSSession -VMName $VMName -Credential $Credential
    try { Copy-Item -Path $Path -Destination $Destination -FromSession $session -Force }
    finally { Remove-PSSession $session }
}

function Expand-LabTemplate {
    <# {{TOKEN}} substitution for unattend, cloud-init and hostapd templates. #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$Values
    )
    $text = Get-Content -LiteralPath $Path -Raw
    foreach ($key in $Values.Keys) { $text = $text.Replace("{{$key}}", [string]$Values[$key]) }
    $left = [regex]::Matches($text, '\{\{[A-Z0-9_]+\}\}') | ForEach-Object Value | Sort-Object -Unique
    if ($left) { throw "Unfilled template tokens in ${Path}: $($left -join ', ')" }
    $text
}

function Get-LabSshKey {
    <# Host key pair for AUTH01, generated on first use (Windows 11 ships ssh-keygen). #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$Config)
    $key = Join-Path $Config.Paths.Secrets 'auth01_ed25519'
    if (-not (Test-Path -LiteralPath $key)) {
        New-Item -ItemType Directory -Force -Path $Config.Paths.Secrets | Out-Null
        # '""' is how Windows PowerShell 5.1 passes an empty passphrase to a native exe.
        & ssh-keygen.exe -q -t ed25519 -N '""' -C 'eaptls-lab' -f $key
        if ($LASTEXITCODE -ne 0) { throw 'ssh-keygen failed.' }
    }
    $key
}

function Invoke-LabSsh {
    <# Runs a command on AUTH01 as labadmin over the LabNet host vNIC. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$Command
    )
    $auth = Get-LabVMSpec -Config $Config -Name AUTH01
    $knownHosts = Join-Path $Config.Paths.Secrets 'known_hosts'
    & ssh.exe -i (Get-LabSshKey -Config $Config) -o BatchMode=yes -o ConnectTimeout=10 `
        -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$knownHosts" `
        "labadmin@$($auth.Ip)" $Command
}

function Copy-LabFileToAuthenticator {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Destination
    )
    $auth = Get-LabVMSpec -Config $Config -Name AUTH01
    $knownHosts = Join-Path $Config.Paths.Secrets 'known_hosts'
    & scp.exe -q -i (Get-LabSshKey -Config $Config) -o BatchMode=yes `
        -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$knownHosts" `
        $Path "labadmin@$($auth.Ip):$Destination"
    if ($LASTEXITCODE -ne 0) { throw "scp to AUTH01 failed for $Path." }
}

function Assert-LabHost {
    <# Fails early, with the reason, instead of halfway through a build. #>
    [CmdletBinding()]
    param()
    $principal = New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run from an elevated PowerShell: Hyper-V, VHD mounting and NAT all need it.'
    }
    if (-not (Get-Module -ListAvailable -Name Hyper-V)) {
        throw 'The Hyper-V PowerShell module is missing. Enable Hyper-V first (host\Enable-HyperV.ps1), then reboot.'
    }
}

Export-ModuleMember -Function *-Lab*
