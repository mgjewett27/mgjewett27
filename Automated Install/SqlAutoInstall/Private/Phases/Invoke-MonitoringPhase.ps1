function Invoke-MonitoringPhase {
    <#
    .SYNOPSIS
        Registers the host in Redgate Monitor under the environment's group, or the Mission Critical
        group for production servers built with -MissionCritical.
    #>
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context
    )

    $log = @{ ComputerName = $Context.ComputerName; Phase = 'Monitoring' }
    $monitoring = $Context.Config.Monitoring
    $groupName = if ($Context.MissionCritical) { $monitoring.MissionCriticalGroup } else { $Context.Environment.MonitorGroup }
    $baseMonitorName = if ($Context.Environment.BaseMonitorName) { $Context.Environment.BaseMonitorName } else { $monitoring.BaseMonitorName }

    Import-Module -Name $monitoring.ModulePath -ErrorAction Stop

    $token = [pscredential]::new('token', $Context.RedgateToken).GetNetworkCredential().Password
    try {
        Connect-RedgateMonitor -ServerUrl $monitoring.ServerUrl -AuthToken $token -ErrorAction Stop
    }
    finally {
        Remove-Variable -Name token
    }

    $baseMonitor = Get-SqlMonitorBaseMonitor -Name $baseMonitorName -ErrorAction Stop
    if (-not $baseMonitor) {
        throw "Redgate base monitor '$baseMonitorName' not found"
    }
    $group = Get-SqlMonitorGroup $groupName -BaseMonitor $baseMonitor -ErrorAction Stop
    if (-not $group) {
        throw "Redgate group '$groupName' not found on base monitor '$baseMonitorName'"
    }

    New-SqlMonitorWindowsHost -HostName $Context.ComputerName -BaseMonitor $baseMonitor -Group $group -ErrorAction Stop |
        Add-SqlMonitorMonitoredObject -ErrorAction Stop

    Write-BuildLog @log -Message "Added to Redgate Monitor group '$groupName' on base monitor '$baseMonitorName'" -Level Success
}
