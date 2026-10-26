#Requires -Version 5.1
<#
.SYNOPSIS
    Makes the NPS server forget every CRL it has cached, so the next authentication has to fetch it. Runs on DC01.

.DESCRIPTION
    Windows caches CRLs until their NextUpdate. Without this step a CDP outage
    stays invisible until the cached CRL expires, which is days after whatever
    change caused it. That delay is half of why this failure gets misdiagnosed;
    the demo removes it so cause and effect sit next to each other.

    NPS runs as LocalSystem, whose URL cache is not the administrator's, so the
    purge runs as SYSTEM through a one-shot scheduled task. The chain engine's
    in-memory cache is told to resync, and the NPS service (IAS) is restarted to
    drop cached TLS sessions that would otherwise skip the revocation check.
#>
[CmdletBinding(SupportsShouldProcess)]
param()
$ErrorActionPreference = 'Stop'

$taskName = 'LAB purge SYSTEM CRL cache'
if ($PSCmdlet.ShouldProcess('LocalSystem CryptnetUrlCache', 'Delete all cached CRLs')) {
    $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\certutil.exe" -Argument '-urlcache * delete'
    $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Force | Out-Null
    try {
        Start-ScheduledTask -TaskName $taskName
        do { Start-Sleep -Milliseconds 500 } while ((Get-ScheduledTask -TaskName $taskName).State -eq 'Running')
    }
    finally {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }

    # Current user's cache too, so certutil -verify run from this session is honest.
    & certutil.exe -urlcache * delete | Out-Null
    & certutil.exe -setreg chain\ChainCacheResyncFiletime '@now' | Out-Null
    Restart-Service -Name IAS
}

[pscustomobject]@{
    CacheCleared = $true
    IasStatus    = (Get-Service IAS).Status
    Time         = Get-Date
}
