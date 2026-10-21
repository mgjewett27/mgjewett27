function Invoke-InstanceSetupPhase {
    <#
    .SYNOPSIS
        Creates the maintenance database, deploys the maintenance scripts, enables the jobs, adds the
        monitor login and disables sa.
    .DESCRIPTION
        Scripts are read from the jump box and environment tokens (such as ##BACKUP_LOCATION##) are
        replaced in a temp copy. The shared source scripts are never modified.
    #>
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context
    )

    $log = @{ ComputerName = $Context.ComputerName; Phase = 'InstanceSetup' }
    $config = $Context.Config
    $server = Connect-DbaInstance -SqlInstance $Context.ComputerName -EnableException

    if (Get-DbaDatabase -SqlInstance $server -Database $config.MaintenanceDatabase) {
        Write-BuildLog @log -Message "$($config.MaintenanceDatabase) already exists"
    }
    else {
        New-DbaDatabase -SqlInstance $server -Name $config.MaintenanceDatabase -RecoveryModel Simple -Owner sa -EnableException | Out-Null
        Write-BuildLog @log -Message "Created $($config.MaintenanceDatabase)"
    }

    foreach ($sqlScript in $config.MaintenanceScripts) {
        $rendered = Join-Path ([System.IO.Path]::GetTempPath()) "SqlAutoInstall_$([guid]::NewGuid()).sql"
        try {
            $content = Expand-ScriptToken -Content (Get-Content -Path $sqlScript.Path -Raw -ErrorAction Stop) -Tokens $Context.Environment.ScriptTokens
            Set-Content -Path $rendered -Value $content
            Invoke-DbaQuery -SqlInstance $server -Database $sqlScript.Database -File $rendered -EnableException | Out-Null
            Write-BuildLog @log -Message "Ran $(Split-Path $sqlScript.Path -Leaf) in $($sqlScript.Database)"
        }
        finally {
            Remove-Item -Path $rendered -ErrorAction SilentlyContinue
        }
    }

    $jobs = Get-DbaAgentJob -SqlInstance $server -Job $config.JobsToEnable -EnableException
    $missingJobs = $config.JobsToEnable | Where-Object { $_ -notin $jobs.Name }
    if ($missingJobs) {
        throw "Jobs not created by the maintenance scripts: $($missingJobs -join ', ')"
    }
    Set-DbaAgentJob -SqlInstance $server -Job $config.JobsToEnable -Enabled -Confirm:$false -EnableException | Out-Null
    Write-BuildLog @log -Message "Enabled $($config.JobsToEnable.Count) maintenance jobs"

    $monitorAccount = $config.Monitoring.ServiceAccount
    if (-not (Get-DbaLogin -SqlInstance $server -Login $monitorAccount)) {
        New-DbaLogin -SqlInstance $server -Login $monitorAccount -EnableException | Out-Null
    }
    foreach ($role in $config.Monitoring.ServerRoles) {
        Add-DbaServerRoleMember -SqlInstance $server -ServerRole $role -Login $monitorAccount -Confirm:$false -EnableException | Out-Null
    }
    Write-BuildLog @log -Message "Monitor login $monitorAccount granted $($config.Monitoring.ServerRoles -join ', ')"

    Set-DbaLogin -SqlInstance $server -Login sa -Disable -Confirm:$false -EnableException | Out-Null
    Write-BuildLog @log -Message 'Instance setup complete, sa disabled' -Level Success
}
