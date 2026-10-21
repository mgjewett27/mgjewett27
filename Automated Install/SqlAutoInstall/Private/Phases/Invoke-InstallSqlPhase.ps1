function Invoke-InstallSqlPhase {
    <#
    .SYNOPSIS
        Mounts the staged ISO on the target and runs setup.exe with the rendered ini.
    .DESCRIPTION
        Setup runs from the mounted drive, the media is not copied to disk. Passwords go to setup as
        separate arguments, never through Invoke-Expression, so any character is allowed in them.
        Exit code and Summary.txt decide success.
    #>
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context
    )

    $log = @{ ComputerName = $Context.ComputerName; Phase = 'InstallSql' }
    $instanceName = $Context.Config.InstanceName

    if ($Context.Facts.InstalledInstances -contains $instanceName) {
        Write-BuildLog @log -Message "Instance $instanceName already installed, skipping setup" -Level Warning
        return
    }

    $mediaPath = Join-Path $Context.Config.TargetWorkingPath 'Media'
    $isoName = Split-Path -Path $Context.Media.Iso -Leaf

    Write-BuildLog @log -Message "Running SQL $($Context.SqlVersion) setup, this takes 10 to 30 minutes"
    $result = Invoke-Command -Session $Context.Session -ScriptBlock {
        param([string]$MediaPath, [string]$IsoName, [pscredential]$ServiceCredential, [pscredential]$SaCredential)

        $isoPath = Join-Path $MediaPath $IsoName
        $mount = Mount-DiskImage -ImagePath $isoPath -PassThru
        try {
            $driveLetter = ($mount | Get-Volume).DriveLetter
            $servicePassword = $ServiceCredential.GetNetworkCredential().Password
            $setupArgs = @(
                "/ConfigurationFile=$(Join-Path $MediaPath 'ConfigurationFile.ini')"
                "/SQLSVCPASSWORD=$servicePassword"
                "/AGTSVCPASSWORD=$servicePassword"
                "/SAPWD=$($SaCredential.GetNetworkCredential().Password)"
            )
            & "$($driveLetter):\setup.exe" @setupArgs | Out-Null
            $exitCode = $LASTEXITCODE
        }
        finally {
            Remove-Variable -Name setupArgs, servicePassword -ErrorAction SilentlyContinue
            Dismount-DiskImage -ImagePath $isoPath | Out-Null
        }

        $summary = Get-ChildItem -Path "$env:ProgramFiles\Microsoft SQL Server\*\Setup Bootstrap\Log\Summary.txt" -ErrorAction SilentlyContinue |
            Sort-Object -Property LastWriteTime -Descending | Select-Object -First 1
        [pscustomobject]@{
            ExitCode    = $exitCode
            SummaryPath = $summary.FullName
            SummaryHead = if ($summary) { (Get-Content -Path $summary.FullName -TotalCount 12) -join "`n" }
        }
    } -ArgumentList $mediaPath, $isoName, $Context.ServiceCredential, $Context.SaCredential

    #0 = success, 3010 = success with reboot required
    if ($result.ExitCode -notin 0, 3010) {
        Write-BuildLog @log -Message "Setup summary from $($result.SummaryPath):`n$($result.SummaryHead)" -Level Error
        throw "SQL setup failed with exit code $($result.ExitCode), see $($result.SummaryPath) on $($Context.ComputerName)"
    }
    Write-BuildLog @log -Message "SQL $($Context.SqlVersion) installed (exit code $($result.ExitCode))" -Level Success

    if ($result.ExitCode -eq 3010 -or (Invoke-Command -Session $Context.Session -ScriptBlock ${function:Test-PendingReboot})) {
        Restart-BuildTarget -Context $Context -Phase 'InstallSql'
    }
}
