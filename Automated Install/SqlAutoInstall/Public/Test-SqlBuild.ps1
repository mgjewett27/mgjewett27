function Test-SqlBuild {
    <#
    .SYNOPSIS
        Validates a built SQL Server against the standard and returns one result per check.

    .DESCRIPTION
        Confirms that the ini-driven install settings took effect and that the build phases completed:
        CU level, service accounts, data/log/TempDB placement, memory, MAXDOP, IFI, HADR, sa, the
        maintenance database, jobs and the monitor login.

        Settings this tool does not configure (TCP port, encryption, SPNs, cost threshold) are reported
        with Status 'Info' so the gaps stay visible.

        Results are also written as JSON to the config LogPath, or to -ReportPath.

    .PARAMETER ComputerName
        Server to validate. Resolved to its FQDN.

    .PARAMETER ExpectedServiceAccount
        DOMAIN\account expected to run the engine and Agent. When omitted the accounts are reported as Info.

    .EXAMPLE
        Test-SqlBuild -ComputerName sqldev01 -ConfigPath .\config\config.psd1 | Format-Table
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ComputerName,

        [string]$ConfigPath = (Join-Path $PSScriptRoot '..\..\config\config.psd1'),

        [string]$ExpectedServiceAccount,

        [pscredential]$Credential,

        [string]$ReportPath
    )

    Set-DbatoolsConfig -FullName sql.connection.trustcert -Value $true
    $config = Get-BuildConfig -Path $ConfigPath
    $fqdn = [System.Net.Dns]::GetHostEntry($ComputerName).HostName
    $results = [System.Collections.Generic.List[object]]::new()

    function Add-Result {
        param($Check, $Status, $Expected, $Actual)
        $results.Add([pscustomobject]@{
            ComputerName = $fqdn
            Check        = $Check
            Status       = $Status
            Expected     = [string]$Expected
            Actual       = [string]$Actual
        })
    }

    #Each check runs on its own so one failure does not hide the rest
    function Invoke-Check {
        param([string]$Check, [scriptblock]$ScriptBlock)
        try {
            & $ScriptBlock
        }
        catch {
            Add-Result $Check 'Fail' 'Check to run' "Error: $($_.Exception.Message)"
        }
    }

    $session = New-BuildSession -ComputerName $fqdn -Credential $Credential
    try {
        $facts = Get-TargetFact -Session $session
    }
    finally {
        Remove-PSSession -Session $session
    }
    $server = Connect-DbaInstance -SqlInstance $fqdn -EnableException
    $majorVersion = $server.VersionMajor

    Invoke-Check 'CU level' {
        $build = Test-DbaBuild -SqlInstance $server -MaxBehind $config.CuMaxBehind -EnableException
        Add-Result 'CU level' ($(if ($build.Compliant) { 'Pass' } else { 'Fail' })) "Within $($config.CuMaxBehind) ($($build.BuildTarget))" "$($build.Build) $($build.CULevel)"
    }

    Invoke-Check 'Service accounts' {
        foreach ($service in Get-DbaService -ComputerName $fqdn -Type Engine, Agent -EnableException) {
            $status = if (-not $ExpectedServiceAccount) { 'Info' } elseif ($service.StartName -eq $ExpectedServiceAccount) { 'Pass' } else { 'Fail' }
            Add-Result "$($service.ServiceType) service account" $status $ExpectedServiceAccount $service.StartName
            $running = $service.State -eq 'Running' -and $service.StartMode -eq 'Automatic'
            Add-Result "$($service.ServiceType) running, automatic start" ($(if ($running) { 'Pass' } else { 'Fail' })) 'Running / Automatic' "$($service.State) / $($service.StartMode)"
        }
    }

    Invoke-Check 'File placement' {
        $dirs = Resolve-SqlDirectory -Config $config -Volumes $facts.Volumes
        $defaults = Get-DbaDefaultPath -SqlInstance $server -EnableException
        Add-Result 'Default data path' ($(if ($defaults.Data.TrimEnd('\') -eq $dirs.Data) { 'Pass' } else { 'Fail' })) $dirs.Data $defaults.Data
        Add-Result 'Default log path' ($(if ($defaults.Log.TrimEnd('\') -eq $dirs.Log) { 'Pass' } else { 'Fail' })) $dirs.Log $defaults.Log

        $tempFiles = Get-DbaDbFile -SqlInstance $server -Database tempdb -EnableException
        $dataFiles = @($tempFiles | Where-Object TypeDescription -eq 'ROWS')
        $misplaced = $tempFiles | Where-Object { -not $_.PhysicalName.StartsWith("$($dirs.Volumes.TempDB.DriveLetter):\", 'OrdinalIgnoreCase') }
        Add-Result 'TempDB files on TempDB volume' ($(if (-not $misplaced) { 'Pass' } else { 'Fail' })) "$($dirs.Volumes.TempDB.DriveLetter):\" (($misplaced.PhysicalName) -join ', ')
        Add-Result 'TempDB data file count' 'Info' 'Per ini SQLTEMPDBFILECOUNT' $dataFiles.Count
    }

    #SQL 2017 setup cannot set max memory or MAXDOP, so those are reported rather than failed
    $iniBaselineStatus = if ($majorVersion -lt 15) { 'Info' } else { 'Fail' }

    Invoke-Check 'Max server memory' {
        $memory = Get-DbaMaxMemory -SqlInstance $server -EnableException
        $status = if ($memory.MaxValue -lt 2147483647) { 'Pass' } else { $iniBaselineStatus }
        Add-Result 'Max server memory' $status "Set below total ($($memory.Total) MB)" "$($memory.MaxValue) MB"
    }

    Invoke-Check 'MAXDOP' {
        $maxDop = (Get-DbaSpConfigure -SqlInstance $server -Name MaxDegreeOfParallelism -EnableException).ConfiguredValue
        Add-Result 'MAXDOP' ($(if ($maxDop -ne 0) { 'Pass' } else { $iniBaselineStatus })) 'Not 0' $maxDop
    }

    Invoke-Check 'Instant file initialization' {
        $ifi = Invoke-DbaQuery -SqlInstance $server -EnableException -Query "SELECT instant_file_initialization_enabled FROM sys.dm_server_services WHERE servicename LIKE 'SQL Server (%'"
        Add-Result 'Instant file initialization' ($(if ($ifi.instant_file_initialization_enabled -eq 'Y') { 'Pass' } else { 'Fail' })) 'Y' $ifi.instant_file_initialization_enabled
    }

    Invoke-Check 'HADR enabled' {
        $hadr = (Get-DbaAgHadr -SqlInstance $server -EnableException).IsHadrEnabled
        Add-Result 'HADR enabled' ($(if ($hadr) { 'Pass' } else { 'Fail' })) $true $hadr
    }

    Invoke-Check 'sa disabled' {
        $sa = Get-DbaLogin -SqlInstance $server -Login sa -EnableException
        Add-Result 'sa disabled' ($(if ($sa.IsDisabled) { 'Pass' } else { 'Fail' })) $true $sa.IsDisabled
    }

    Invoke-Check 'Maintenance database' {
        $db = Get-DbaDatabase -SqlInstance $server -Database $config.MaintenanceDatabase -EnableException
        Add-Result "$($config.MaintenanceDatabase) exists" ($(if ($db) { 'Pass' } else { 'Fail' })) $true ([bool]$db)
    }

    Invoke-Check 'Maintenance jobs' {
        $jobs = Get-DbaAgentJob -SqlInstance $server -EnableException
        foreach ($name in $config.JobsToEnable) {
            $job = $jobs | Where-Object Name -eq $name
            $actual = if (-not $job) { 'Missing' } elseif ($job.IsEnabled) { 'Enabled' } else { 'Disabled' }
            Add-Result "Job: $name" ($(if ($actual -eq 'Enabled') { 'Pass' } else { 'Fail' })) 'Enabled' $actual
        }
    }

    Invoke-Check 'Monitor login' {
        $account = $config.Monitoring.ServiceAccount
        $roles = (Get-DbaServerRoleMember -SqlInstance $server -Login $account -EnableException).Role
        $missing = $config.Monitoring.ServerRoles | Where-Object { $_ -notin $roles }
        Add-Result "Monitor login $account" ($(if (-not $missing) { 'Pass' } else { 'Fail' })) ($config.Monitoring.ServerRoles -join ', ') ($roles -join ', ')
    }

    #Not configured by this tool, reported so the gaps are visible
    Invoke-Check 'TCP port' {
        $port = Get-DbaTcpPort -SqlInstance $server -EnableException
        Add-Result 'TCP port (not configured by this tool)' 'Info' '' $port.Port
    }
    Invoke-Check 'Force encryption' {
        $encryption = Get-DbaForceNetworkEncryption -SqlInstance $fqdn -EnableException
        Add-Result 'Force encryption (not configured by this tool)' 'Info' '' $encryption.ForceEncryption
    }
    Invoke-Check 'Cost threshold' {
        $cost = (Get-DbaSpConfigure -SqlInstance $server -Name CostThresholdForParallelism -EnableException).ConfiguredValue
        Add-Result 'Cost threshold for parallelism (not configured by this tool)' 'Info' '' $cost
    }
    Invoke-Check 'SPNs' {
        $spns = Test-DbaSpn -ComputerName $fqdn -EnableException
        $missingSpns = @($spns | Where-Object { -not $_.IsSet })
        Add-Result 'SPNs (not configured by this tool, see SPN_Tool)' 'Info' 'All set' "$($missingSpns.Count) missing"
    }

    if (-not $ReportPath) {
        New-Item -Path $config.LogPath -ItemType Directory -Force | Out-Null
        $ReportPath = Join-Path $config.LogPath "$fqdn.validation_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
    }
    $results | ConvertTo-Json -Depth 3 | Set-Content -Path $ReportPath

    $results
}
