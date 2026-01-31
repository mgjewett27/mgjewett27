<#
.SYNOPSIS
    Rebuild Availability Group database from backups

.DESCRIPTION
    Script can be used if a database in an Availability Group is no longer synchronizing properly, and a full rebuild is required.

.PARAMETER Instance
    Instance name of the SQL Server (can include named instance)

.PARAMETER Database
    Name of the database to rebuild in the Availability Group

.NOTES
    Author: Mike Jewett
    Date: 1/12/2026
    Version: 1.0

.MODIFICATION LOG
    - 01/12/2026: Initial script creation

.EXAMPLE
    .\Rebuild-AGDatabase.ps1 -Instance "SQLSERVER01\INSTANCE1" -Database "MyDatabase"
    .\Rebuild-AGDatabase.ps1 -Instance "SQLSERVER01AGL" -Database "SalesDB"

#>

param(
    [Parameter(Mandatory)]
    [string]$Instance,
    [Parameter(Mandatory)]
    [string]$Database
)

#Setting up audit logging for investigation of install issues
$Log_path = 'C:\Source\Logs'
$Log_check = Test-Path -Path $Log_path

if ($Log_check -like '*False*') {
    New-Item -Path $Log_path -ItemType Directory
}
else {
    Write-Output "Log directory exists, proceeding to next step" | Yellow
}

Start-Transcript -Path "C:\Source\Logs\SQL_Install_Log_$($Hostname)_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt" -Append


#################################################################################################################################
# Setup functions for script
#################################################################################################################################
# Ensure dbatools module is installed and up to date
function Test-Dbatools {
try {
        # Checking for Chocolatey install, if not install software on local server
        $chocoInstalled = Test-Path 'C:\ProgramData\chocolatey\choco.exe'

        if (-not $chocoInstalled) {
            Write-Output 'Chocolatey Package Manager not installed, installing now'
            Set-ExecutionPolicy Bypass -Scope Process -Force
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
            Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
        }
        else {
            Write-Output 'Chocolatey already installed, proceeding to next step'
        }

        # Check for required packages, install if missing
        $dbaToolsInstalled = Get-Module -ListAvailable -Name dbatools

        if (-not $dbaToolsInstalled) {
            Write-Output 'Installing required packages (DBATools)'
            if (-not $dbaToolsInstalled) {
                choco install dbatools -y
            }
        }
        else {
            Write-Output 'All required packages installed, skipping install'
        }
    }
    catch {
        Write-Error "Failed to install required tools: $_"
        exit 1
    }
}

Test-Dbatools

<#
.SYNOPSIS
    Retrieves all nodes in the Availability Group for a specified database.
.DESCRIPTION
    Queries the SQL Server instance to identify the Availability Group containing the specified database,
    then retrieves all replicas including the primary and secondary nodes.
.NOTES
    Sets global variables: $AG_Name, $ag, $primaryNode, $secondaryNodes
#>
function Get-AGNodes {
    $global:AG_Name = (Get-DbaAgDatabase -SqlInstance $Instance -Database $Database).AvailabilityGroup
    $global:ag = Get-DbaAgReplica -SqlInstance $Instance -AvailabilityGroup $AG_Name
    $global:primaryNode = ($ag | Where-Object { $_.Role -eq 'Primary' }).Name
    $global:secondaryNodes = ($ag | Where-Object { $_.Role -eq 'Secondary' }).Name 
}

<#
.SYNOPSIS
    Gets the folder path of the most recent full backup for the specified database.
.DESCRIPTION
    Retrieves the most recent full backup history and extracts the directory path by trimming the filename.
.NOTES
    Sets global variables: $backup_folder, $restore_files, $Full_path, $TrimmedPath
#>
function Get-LastFullBackupPath {
        $global:backup_folder = Get-DbaDbBackupHistory -SqlInstance $Instance -Database $Database -Type Full | Sort-Object -Property End -Descending | Select-Object -First 1
        $global:restore_files = $backup_folder.Path

        $global:Full_path = $backup_folder.Path | Select-Object -First 1
        $global:Character = '\'

    # Find the last occurrence of the character
        $global:LastIndex = $Full_path.LastIndexOf($Character)

    # Check if the character was found
        if ($global:LastIndex -ne -1) {
        # Extract the substring from the beginning up to the character's position
            $global:TrimmedPath = $Full_path.Substring(0, $LastIndex)
            } else {
    # If the character is not found, the original string remains untrimmed
            $global:TrimmedPath = $Full_path
        }
}

<#
.SYNOPSIS
    Gets the folder path of the most recent transaction log backup for the specified database.
.DESCRIPTION
    Retrieves the most recent log backup history and extracts the directory path by trimming the filename.
.NOTES
    Sets global variables: $log_backup, $restore_log_file, $LOG_path, $Log_TrimmedPath
#>
function Get-LastLOGBackupPath {
        $global:log_backup = Get-DbaDbBackupHistory -SqlInstance $Instance -Database $Database -Type Log | Sort-Object -Property End -Descending | Select-Object -First 1
        $global:restore_log_file = $log_backup.Path

        $global:LOG_path = $log_backup.Path | Select-Object -First 1
        $global:Character = '\'

        # Find the last occurrence of the character
        $global:LastIndex = $LOG_path.LastIndexOf($Character)
        # Check if the character was found
        if ($LastIndex -ne -1) {
            # Extract the substring from the beginning up to the character's position
            $global:Log_TrimmedPath = $LOG_path.Substring(0, $LastIndex)
        } else {
            # If the character is not found, the original string remains untrimmed
            $global:Log_TrimmedPath = $LOG_path
        }
}

<#
.SYNOPSIS
    Disables the transaction log backup job for the database.
.DESCRIPTION
    Finds and disables the SQL Agent job responsible for transaction log backups.
    This is typically done before AG maintenance to prevent backup conflicts.
.NOTES
    Sets global variable: $TLOG_Job_name
    Throws an error if the job cannot be disabled.
#>
function Disable-LogBackups {
    Write-Host "Disabling transaction log backups for $Database on $Instance..."
    $global:TLOG_Job_name = Find-DbaAgentJob -SqlInstance $Instance -JobName *user_databases_TLOG* | Select-Object -ExpandProperty Name
    Set-DbaAgentJob -SqlInstance $Instance -Job $TLOG_Job_name -Disabled
    if ($?) {
        Write-Host "Transaction log backup job disabled successfully."
    } else {
        throw "Failed to disable transaction log backup job."
    }
}

<#
.SYNOPSIS
    Re-enables the transaction log backup job for the database.
.DESCRIPTION
    Finds and enables the SQL Agent job responsible for transaction log backups.
    This should be called after AG maintenance is complete.
.NOTES
    Uses global variable: $TLOG_Job_name
    Throws an error if the job cannot be enabled.
#>
function Enable-LogBackups {
    Write-Host "Enabling transaction log backups for $Database on $Instance..."
        $global:TLOG_Job_name = Find-DbaAgentJob -SqlInstance $Instance -JobName *user_databases_TLOG* | Select-Object -ExpandProperty Name
    Set-DbaAgentJob -SqlInstance $Instance -Job $TLOG_Job_name -Enabled
    if ($?) {
        Write-Host "Transaction log backup job disabled successfully."
    } else {
        throw "Failed to disable transaction log backup job."
    }
}

<#
.SYNOPSIS
    Creates a full backup of the specified database.
.DESCRIPTION
    Performs a compressed, verified full backup using 8 files to the last known backup location.
    Updates the global restore file list with the newly created backup files.
.NOTES
    Uses approved verb: Backup-DbaDatabase (instead of Take-FullBackup)
    Sets global variables: $last_backup_folder, $new_restore_files
#>
function New-FullBackup {
    Write-Host "Taking full backup of $Database on $Instance..."
    Backup-DbaDatabase -SqlInstance $Instance -Database $Database -Path $TrimmedPath -Type Full -FileCount 8 -CompressBackup -Verify
    $global:last_backup_folder = Get-DbaDbBackupHistory -SqlInstance $Instance -Database $Database -Type Full | Sort-Object -Property End -Descending | Select-Object -First 1
    $global:new_restore_files = $last_backup_folder.Path
}

<#
.SYNOPSIS
    Creates a transaction log backup of the specified database.
.DESCRIPTION
    Performs a transaction log backup to the last known log backup location.
    Updates the global log restore file list with the newly created backup file.
.NOTES
    Uses approved verb: Backup-DbaDatabase (instead of Take-LogBackup)
    Sets global variables: $log_backup_folder, $log_restore_files
#>
function New-LogBackup {
    Write-Host "Taking transaction log backup of $Database on $Instance..."
    Backup-DbaDatabase -SqlInstance $primaryNode -Database $Database -Path $Log_TrimmedPath -Type Log
    $global:log_backup_folder = Get-DbaDbBackupHistory -SqlInstance $Instance -Database $Database -Type Log | Sort-Object -Property End -Descending | Select-Object -First 1
    $global:log_restore_files = $log_backup_folder.Path
}

<#
.SYNOPSIS
    Restores a full backup to all secondary replicas.
.DESCRIPTION
    Restores the most recent full backup to all secondary nodes in NORECOVERY mode with REPLACE option.
    This prepares the databases for re-joining the Availability Group.
.NOTES
    Uses the Ola Hallengren maintenance solution backup format.
    Database must be in NORECOVERY mode to apply log backups afterward.
#>
function Restore-FullBackup_Secondary {
    Write-Host "Restoring full backup of $Database on $secondaryNodes in NORECOVERY mode..."
    foreach ($node in $secondaryNodes) {
        Restore-DbaDatabase -SqlInstance $node -Database $Database -Path $new_restore_files -NoRecovery -WithReplace -MaintenanceSolutionBackup
    }
}

<#
.SYNOPSIS
    Restores a transaction log backup to all secondary replicas.
.DESCRIPTION
    Restores the most recent log backup to all secondary nodes in NORECOVERY mode.
    Uses Continue parameter to apply the log to already restored databases.
.NOTES
    Uses the Ola Hallengren maintenance solution backup format.
    Database must remain in NORECOVERY mode for AG synchronization.
#>
function Restore-LogBackup {
    Write-Host "Restoring log backup of $Database on $secondaryNodes in NORECOVERY mode..."
    foreach ($node in $secondaryNodes) {
        Restore-DbaDatabase -SqlInstance $node -Database $Database -Path $log_restore_files -NoRecovery -MaintenanceSolutionBackup -Continue
    }
}

<#
.SYNOPSIS
    Removes the specified database from the Availability Group.
.DESCRIPTION
    Removes the database from the AG on both primary and secondary replicas without confirmation prompts.
.NOTES
    This does not delete the database, only removes it from AG synchronization.
#>
function Remove-DatabaseFromAG {
    Write-Host "Removing $Database from $AG_Name on $PrimaryNode..."
    Remove-DbaAgDatabase -SqlInstance $PrimaryNode -Database $Database -AvailabilityGroup $AG_Name -Confirm:$false
}

<#
.SYNOPSIS
    Adds the database back to the Availability Group on all replicas.
.DESCRIPTION
    Re-joins the database to the AG using manual seeding mode.
    Assumes databases on secondary replicas are already restored and in NORECOVERY mode.
.NOTES
    Uses Manual seeding mode because backups were already restored manually.
    Database must be synchronized before becoming available on secondaries.
#>
function Add-DatabaseToAG_Primary {

    $splat = @{
        SQLInstance = $PrimaryNode
        AvailabilityGroup = $AG_Name
        Database = $Database
        Secondary = $secondaryNodes
        SeedingMode = 'Manual'
    }
    Write-Host "Adding $Database back to $AG_Name using join-only..."
    Add-DbaAgDatabase @splat 
}



#################################################################################################################################
# Main logic
#################################################################################################################################

#################################################################################################################################
# Introduction and Warning
#################################################################################################################################
Write-Host "========================================================================================================" -ForegroundColor Cyan
Write-Host "UWM Availability Group Rebuild Script" -ForegroundColor Cyan
Write-Host "========================================================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "This script will rebuild the sepecified database in an Availability Group according to UWM's standards." -ForegroundColor Yellow
Write-Host ""
Write-Host "WARNING: This process involves taking backups and restoring databases." -ForegroundColor Red
Write-Host "Services may be impacted while this script is running. Use with caution!" -ForegroundColor Red
Write-Host ""
Write-Host "Target Primary Instance: $Instance" -ForegroundColor White
Write-Host "Target Database: $Database" -ForegroundColor White
Write-Host ""
Write-Host "========================================================================================================" -ForegroundColor Cyan
Write-Host ""

$confirmation = Read-Host "Do you want to proceed? (Y/N)"
if ($confirmation -ne 'Y') {
    Write-Host "Script cancelled by user." -ForegroundColor Yellow
    exit 0
}

Write-Host ""
Write-Host "Proceeding with Availability Group rebuild..." -ForegroundColor Green
Write-Host ""


#Retreive nodes in AG and all AG details
    try {
        Write-Host "Retrieving Availability Group nodes for database $Database on instance $Instance..." -ForegroundColor Green
        Get-AGNodes
    }
    catch {
        Write-Error "Failed to retrieve Availability Group nodes: $_"
        exit 1
    }

#Retreive Full and Log backup paths
    try {
        Write-Host "Retrieving last full backup path for database $Database..." -ForegroundColor Green
        Get-LastFullBackupPath
        Write-Host "Retrieving last log backup path for database $Database..." -ForegroundColor Green
        Get-LastLOGBackupPath
    }
    catch {
        Write-Error "Failed to retrieve backup paths: $_"
        exit 1
    }

#Disabling TLOG backups on primary node
    try {
        Write-Host "Disabling transaction log backups..." -ForegroundColor Green
        Disable-LogBackups
    }
    catch {
        Write-Error "Failed to disable transaction log backups: $_"
        exit 1
    }

#Taking full backup of Database
    try {
        Write-Host "Taking full backup of database $Database..." -ForegroundColor Green
        New-FullBackup
    }
    catch {
        Write-Error "Failed to take full backup: $_"
        exit 1
    }

#Taking log backup of Database
    try {
        Write-Host "Taking transaction log backup of database $Database..." -ForegroundColor Green
        New-LogBackup
    }
    catch {
        Write-Error "Failed to take transaction log backup: $_"
        exit 1
    }

#Removing database from AG
    try {
        Write-Host "Removing database $Database from Availability Group $AG_Name..." -ForegroundColor Green
        Remove-DatabaseFromAG
    }
    catch {
        Write-Error "Failed to remove database from Availability Group: $_"
        exit 1
    }

#Restoring full backup to all secondary nodes
    try {
        Write-Host "Restoring full backup to secondary nodes..." -ForegroundColor Green
        Restore-FullBackup_Secondary
    }
    catch {
        Write-Error "Failed to restore full backup to secondary nodes: $_"
        exit 1
    }

#Restoring log backup to all secondary nodes
    try {
        Write-Host "Restoring transaction log backup to secondary nodes..." -ForegroundColor Green
        Restore-LogBackup
    }
    catch {
        Write-Error "Failed to restore transaction log backup to secondary nodes: $_"
        exit 1
    }

#Adding database back into AG with manual seeding
    try {
        Write-Host "Adding database $Database back to Availability Group $AG_Name..." -ForegroundColor Green
        Add-DatabaseToAG_Primary
    }
    catch {
        Write-Error "Failed to add database back to Availability Group: $_"
        exit 1
    }

#Enabling TLOG backups on primary node
    try {
        Write-Host "Enabling transaction log backups..." -ForegroundColor Green
        Enable-LogBackups
    }
    catch {
        Write-Error "Failed to enable transaction log backups: $_"
        exit 1
    }

Write-Host "Database rebuild and AG join complete."
Stop-Transcript
