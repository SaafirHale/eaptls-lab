#Requires -Version 5.1
<#
.SYNOPSIS
    Renders every template with dummy values and checks the result parses: unattend as XML, cloud-init as YAML. Exit code 1 on failure.

.DESCRIPTION
    Catches a broken template before it is baked into a VM disk, where the only
    symptom would be a VM that never finishes first boot. YAML is checked with
    Python's PyYAML when it is available; otherwise that check is reported as skipped.
#>
[CmdletBinding()]
param()

Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'host\LabCommon.psm1') -Force
$repo = Get-LabRepoRoot
$failed = $false
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('eaptls-render-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null

$common = @{
    COMPUTER_NAME = 'TEST01'; TIME_ZONE = 'Eastern Standard Time'; ADMIN_PASSWORD = 'Dummy-Passw0rd'
    LOCAL_ADMIN = 'labadmin'; LOCAL_ADMIN_PASSWORD = 'Dummy-Passw0rd'
    HOSTNAME = 'auth01'; DOMAIN = 'lab.example'; SSH_PUBKEY = 'ssh-ed25519 AAAAdummy eaptls-lab'
    INSTANCE_ID = 'auth01-test'; UPLINK_MAC = '00:15:5d:14:00:40'; ACCESS_MAC = '00:15:5d:14:00:41'
    AUTH_IP = '10.20.0.40'; PREFIX_LENGTH = '24'; GATEWAY = '10.20.0.1'; DNS1 = '10.20.0.10'; DNS2 = '1.1.1.1'
    NAS_ID = 'auth01.lab.example'; RADIUS_SERVER = '10.20.0.10'; RADIUS_SECRET = 'dummysecret'
    CLIENT_FQDN = 'CLIENT01.lab.example'
    WRITE_FILES = "  - path: /tmp/x`n    permissions: `"0644`"`n    encoding: b64`n    content: aGVsbG8K"
}

$checks = @(
    @{ File = 'host\unattend\server.xml'; Kind = 'xml' }
    @{ File = 'host\unattend\client.xml'; Kind = 'xml' }
    @{ File = 'roles\auth01\cloud-init\user-data.template'; Kind = 'yaml' }
    @{ File = 'roles\auth01\cloud-init\meta-data.template'; Kind = 'yaml' }
    @{ File = 'roles\auth01\cloud-init\network-config.template'; Kind = 'yaml' }
    @{ File = 'roles\auth01\hostapd-access.conf.template'; Kind = 'text' }
    @{ File = 'roles\auth01\eapol-test.conf.template'; Kind = 'text' }
)

$python = Get-Command python -ErrorAction SilentlyContinue | Select-Object -First 1
$hasYaml = $false
if ($python) {
    & $python.Source -c 'import yaml' 2>$null
    $hasYaml = ($LASTEXITCODE -eq 0)
}

foreach ($c in $checks) {
    $path = Join-Path $repo $c.File
    try {
        $text = Expand-LabTemplate -Path $path -Values $common
        switch ($c.Kind) {
            'xml' { [xml]$text | Out-Null; $note = 'xml ok' }
            'yaml' {
                if ($hasYaml) {
                    $out = Join-Path $tmp ([IO.Path]::GetFileName($path))
                    [IO.File]::WriteAllText($out, $text.Replace("`r`n", "`n"))
                    & $python.Source -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1]))' $out 2>&1 | Out-Null
                    if ($LASTEXITCODE -ne 0) { throw 'YAML does not parse.' }
                    $note = 'yaml ok'
                }
                else { $note = 'rendered (YAML parse skipped: no PyYAML)' }
            }
            default { $note = 'rendered' }
        }
        Write-Output "OK   $($c.File): $note"
    }
    catch {
        $failed = $true
        Write-Output "FAIL $($c.File): $($_.Exception.Message)"
    }
}
Remove-Item -LiteralPath $tmp -Recurse -Force
if ($failed) { exit 1 }

exit 0
