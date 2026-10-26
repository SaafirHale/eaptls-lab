@{
    Severity     = @('Error', 'Warning', 'Information')
    ExcludeRules = @(
        # Role scripts write a summary object to the pipeline on purpose and use
        # Write-Information for progress; Write-Host is never used.
        'PSAvoidUsingWriteHost'
        # Lab scripts are run interactively by the person building the lab; the
        # few that change state already support -WhatIf where it means something.
        'PSUseShouldProcessForStateChangingFunctions'
    )
    Rules        = @{
        PSUseCompatibleSyntax = @{
            Enable         = $true
            # Every script must run on Windows PowerShell 5.1 (Server 2025 Core, Windows 11).
            TargetVersions = @('5.1')
        }
        PSAvoidUsingCmdletAliases = @{ Enable = $true }
        PSPlaceOpenBrace = @{ Enable = $true; OnSameLine = $true }
        PSUseConsistentIndentation = @{ Enable = $true; IndentationSize = 4; Kind = 'space' }
    }
}
