function Invoke-SqlBuild {
    <#
    .SYNOPSIS
        Builds one or more blank Windows cluster nodes into patched, maintained and monitored SQL Server
        instances, run from a DBA jump box.

    .DESCRIPTION
        Runs these phases in order against each server:

          Preflight      read-only checks and Vault secrets, always runs, nothing changes if it fails
          StageMedia     SQL directories, ISO and rendered ini pushed to the target
          InstallSql     setup.exe from the mounted ISO
          Patch          CU to the configured level (N-1 by default), with reboot
          ServerConfig   HADR, SQL Agent, monitor account local admin, optional SSMS
          InstanceSetup  maintenance database, scripts, jobs, monitor login, sa disabled
          Monitoring     Redgate Monitor registration
          Validate       Test-SqlBuild, always runs, fails the build on any failed check

        Completed phases are recorded in <LogPath>\<server>.state.json. Rerunning the same command
        resumes after the last completed phase. Use -Phase to rerun specific phases, or -Force to rerun all.

    .PARAMETER ComputerName
        One or more target servers. Each is built in turn, a failure on one does not stop the rest.

    .PARAMETER SqlVersion
        SQL Server version to install. Media and ini come from the environment's Media block in config.

    .PARAMETER Environment
        Environment name from config. When omitted it is matched from the server FQDN by HostnamePattern.

    .PARAMETER MissionCritical
        Production only. Registers the server in the Mission Critical Redgate group.

    .PARAMETER Phase
        Run only these phases (Preflight and Validate always run), ignoring the state file.

    .PARAMETER Force
        Ignore the state file and run every phase.

    .EXAMPLE
        Invoke-SqlBuild -ComputerName sqldev01 -SqlVersion 2022 -WhatIf

        Runs Preflight and shows which phases would run, without changing anything.

    .EXAMPLE
        Invoke-SqlBuild -ComputerName sqlprd01, sqlprd02 -SqlVersion 2022 -MissionCritical

    .EXAMPLE
        Invoke-SqlBuild -ComputerName sqldev01 -SqlVersion 2022 -Phase Patch
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string[]]$ComputerName,

        [Parameter(Mandatory)]
        [ValidateSet('2017', '2019', '2022', '2025')]
        [string]$SqlVersion,

        [string]$ConfigPath = (Join-Path $PSScriptRoot '..\..\config\config.psd1'),

        [string]$Environment,

        [switch]$MissionCritical,

        [ValidateSet('StageMedia', 'InstallSql', 'Patch', 'ServerConfig', 'InstanceSetup', 'Monitoring')]
        [string[]]$Phase,

        [switch]$Force,

        [pscredential]$Credential
    )

    #Run order, each name maps to Invoke-<Name>Phase in Private\Phases
    $phases = 'StageMedia', 'InstallSql', 'Patch', 'ServerConfig', 'InstanceSetup', 'Monitoring'

    $config = Get-BuildConfig -Path $ConfigPath
    New-Item -Path $config.LogPath -ItemType Directory -Force -WhatIf:$false | Out-Null
    $runStamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $script:BuildLogFile = Join-Path $config.LogPath "SqlBuild_$runStamp.jsonl"
    Start-Transcript -Path (Join-Path $config.LogPath "SqlBuild_$runStamp.transcript.txt") -WhatIf:$false | Out-Null

    #Session only, not registered, so other dbatools use on the jump box keeps its own setting
    Set-DbatoolsConfig -FullName sql.connection.trustcert -Value $true

    $summary = [System.Collections.Generic.List[object]]::new()
    try {
        foreach ($name in $ComputerName) {
            $context = $null
            $currentPhase = 'Preflight'
            try {
                $fqdn = [System.Net.Dns]::GetHostEntry($name).HostName
                $statePath = Get-BuildStatePath -LogPath $config.LogPath -ComputerName $fqdn
                $state = Get-BuildState -Path $statePath
                if ($state.SqlVersion -and $state.SqlVersion -ne $SqlVersion -and -not $Force) {
                    throw "State file shows SQL $($state.SqlVersion) was being built on $fqdn, not $SqlVersion. Use -Force to start over."
                }
                $state.SqlVersion = $SqlVersion

                $context = @{
                    ComputerName    = $fqdn
                    Credential      = $Credential
                    Config          = $config
                    Environment     = Resolve-BuildEnvironment -Config $config -ComputerName $fqdn -Name $Environment
                    SqlVersion      = $SqlVersion
                    MissionCritical = [bool]$MissionCritical
                }
                Write-BuildLog -ComputerName $fqdn -Message "Starting SQL $SqlVersion build, environment $($context.Environment.Name)"

                $context.Session = New-BuildSession -ComputerName $fqdn -Credential $Credential
                Invoke-PreflightPhase -Context $context -State $state

                foreach ($phaseName in $phases) {
                    $currentPhase = $phaseName
                    if ($Phase -and $phaseName -notin $Phase) { continue }
                    if (-not $Phase -and -not $Force -and (Test-PhaseCompleted -State $state -Phase $phaseName)) {
                        Write-BuildLog -ComputerName $fqdn -Phase $phaseName -Message 'Already completed, skipping'
                        continue
                    }
                    if ($PSCmdlet.ShouldProcess($fqdn, "Run phase $phaseName")) {
                        & "Invoke-$($phaseName)Phase" -Context $context
                        Add-CompletedPhase -Path $statePath -State $state -Phase $phaseName
                    }
                }

                $currentPhase = 'Validate'
                if ($PSCmdlet.ShouldProcess($fqdn, 'Run phase Validate')) {
                    $validation = Test-SqlBuild -ComputerName $fqdn -ConfigPath $ConfigPath `
                        -ExpectedServiceAccount $context.ServiceCredential.UserName -Credential $Credential
                    $validation | Format-Table -Property Status, Check, Expected, Actual -AutoSize | Out-String | Write-Information -InformationAction Continue
                    $failed = @($validation | Where-Object Status -eq 'Fail')
                    if ($failed) {
                        throw "Validation failed $($failed.Count) check(s): $($failed.Check -join ', ')"
                    }
                }

                Write-BuildLog -ComputerName $fqdn -Message 'Build complete' -Level Success
                $summary.Add([pscustomobject]@{ ComputerName = $fqdn; Result = 'Succeeded'; Phase = $currentPhase; Error = $null })
            }
            catch {
                Write-BuildLog -ComputerName $name -Phase $currentPhase -Message $_.Exception.Message -Level Error
                $summary.Add([pscustomobject]@{ ComputerName = $name; Result = 'Failed'; Phase = $currentPhase; Error = $_.Exception.Message })
            }
            finally {
                if ($context -and $context.Session) {
                    Remove-PSSession -Session $context.Session -ErrorAction SilentlyContinue
                }
            }
        }
    }
    finally {
        $script:BuildLogFile = $null
        Stop-Transcript | Out-Null
    }

    $summary
}
