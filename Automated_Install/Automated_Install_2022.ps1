#####################################################################################
# This script will be used to automate the install of a SQL stand alone instance
# on a new server.
#     
#
#    2/15/2024 - Mike Jewett - Created script
#    3/11/2024 - Mike Jewett - Added automation to add Host to Redgate Monitor
#####################################################################################
#Install DBATools Powershell module
Set-ExecutionPolicy -ExecutionPolicy Unrestricted

#Set ISO depending on environment
[System.Net.Dns]::GetHostByName($env:COMPUTERNAME).HostName

$cluster_name = Get-WmiObject -Namespace root\cimv2 -Class Win32_ComputerSystem | Select-Object -ExpandProperty Name
$domain_name = Get-WmiObject -Namespace root\cimv2 -Class Win32_ComputerSystem | Select-Object -ExpandProperty Domain
$Hostname = "$cluster_name.$domain_name"

if ($Hostname -like <#Production server identifier#>) {
    Write-Output "Production Server, mounting Enterprise edition ISO"
    $mountResult = Mount-DiskImage -ImagePath <#Location of Enterprise SQL ISO#> -PassThru           
}
    else {
        Write-Output "Non-prod server, mounting Developer edition ISO"
        $mountResult = Mount-DiskImage -ImagePath <#Location of Developer SQL ISO#> -PassThru  
    }

#Create SQL data, log, and tempDB directories
$SQL_data = <#SQL Data Directory#>
$SQL_log = <#SQL Log Directory#>
$SQL_TempDB = <#Base folder for TempDB#>
$SQL_TempDBDATA = <#TempDB Data Directory#>
$SQL_TempDBLOG = <#TempDB Log Directory#>
$SQL_Data_check = Test-Path -Path $SQL_data
$SQL_Log_check = Test-Path -Path $SQL_log
$TempDB_check = Test-Path -Path $SQL_TempDB

Write-Output "Checking to see if SQL directories exists"
if (($SQL_Data_check -eq 'True') -and ($SQL_Log_check -eq 'True') -and ($TempDB_check -eq 'True')) {
    
    Write-Output "Path exists, continuing to next step"
}
    else {
        Write-Output "Paths do not exist, creating SQL directories"
        New-Item -Path $SQL_data -ItemType Directory -ErrorAction SilentlyContinue
        New-Item -Path $SQL_log -ItemType Directory -ErrorAction SilentlyContinue
        New-Item -Path $SQL_TempDB -ItemType Directory -ErrorAction SilentlyContinue
        New-Item -Path $SQL_TempDBDATA -ItemType Directory -ErrorAction SilentlyContinue
        New-Item -Path $SQL_TempDBLOG -ItemType Directory -ErrorAction SilentlyContinue
    }


#Mount SQL 2022 iso image and copy files into C:\Source directory
$Source = <#SQL Source directory#>
Write-Output "Checking to see if Source directory exists"
if (Test-Path -Path $Source) {
    Write-Output "`nPath exists, mounting ISO and copying files now"
}
    else {
        Write-Output "Path does not exist, creating folder and copying files now"
        New-Item -Path <#SQL Source Directory#> -ItemType Directory
    }
$volumeInfo = $mountResult | Get-Volume
$driveInfo = Get-PSDrive -Name $volumeInfo.DriveLetter
Copy-Item -Path (Join-Path -Path $driveInfo.root -ChildPath '*') -Destination C:\Source\ -Recurse

#Unmount ISO image, depending on which environment
Write-Output "Unmounting ISO from $Hostname"
if ($Hostname -like <#Production environment identifier#>) {
    Dismount-DiskImage -ImagePath <#SQL Enterprise ISO file path#>        
}
    else {
        Dismount-DiskImage -ImagePath <#SQL Developer ISO file path#>
    }

#Copy SQL 2022 ini file into C:\Source to use, check server envrironment to determine which ISO
Write-Output "Copying configuration file into C:\Source directory"
if ($Hostname -like <#Production environment identifier#>) {
    Copy-Item <#Enterprise ISO config file#> -Destination <#SQL Source Directory#>           
}
    else {
        Copy-Item <#Developer ISO config file#> -Destination <#SQL Source Directory#> 
    }


Write-Output "Pre-work has been completed successfully, beginning installation of SQL Software`n`n"
Write-Output "`n`n######################################"
Write-Output "Welcome to the DBA SQL Install script."
Write-Output "######################################`n`n"

#Prompt for SQL Server Service Account and Password, as well as SA user and password
#Stores both passwords in Secure String
$SQLServiceAcct = $host.ui.PromptForCredential("Enter credentials", "Please enter SQL Server Service Account and password", "", <#Domain of SQL Server Service Account#>)
$SQL_username = $SQLServiceAcct.UserName
$SQL_password = $SQLServiceAcct.GetNetworkCredential().Password
$SAServiceAcct = $host.ui.PromptForCredential("Enter credentials", "Please enter SA account name and password", "", "")
$SA_password = $SQLServiceAcct.GetNetworkCredential().Password

#Set replace variable to replace filler SQL Server Service Account with actual value 
Write-Output "Updating Config file with SQL Server Service account information"
Start-Sleep -Seconds 1
$replaceText = (Get-Content -Path <#ISO Config file#> -Raw) -replace "##MyUser##", $SQLServiceAcct.UserName

#Run command, replacing SQL Server Service Account with actual account
Set-Content -Path <#ISO Config File#> $replaceText

#Sets execution command
$installCMD = <#SQL Source Directory#>\Setup.exe /ConfigurationFile=<#SQL Source Directory#>\ConfigurationFile.ini /SQLSVCPASSWORD=""$SQL_password"" /AGTSVCPASSWORD=""$SQL_password"" /SAPWD=""$SA_password"""

#Calls execution command
Write-Output "Beginning SQL installation"
Invoke-Expression -Command $installCmd

$CU_update = Read-Host "SQL has been installed successfully, install latest Cumulative Update? (Y/N)"
if ($CU_update -like 'Y' ) {
    #Check Cumulative_Update path for most recent direcotry, save into variable, and build path to latest CU folder
    $Newest_CU = Get-ChildItem -Path <#CU files repository#> -Exclude "Old_Versions" |Select-Object -ExpandProperty Name
    $CU_directory = <#Folder of CU to apply#>
    $CU_exe = Get-ChildItem -Path $CU_directory | Select-Object -ExpandProperty Name

    #Copy latest CU directory to C:\Source
    New-Item -Path <#CU directory in Source Directory#> -ItemType Directory
    Copy-Item -Path "$CU_directory\*" -Destination <#CU Directory in Source Directory#> -Recurse

    #Install latest CU to new instance
    Write-Output "Installing latest Cumulative_Update, $Newest_CU, to $Hostname"
    $updateCmd = <#CU setup exe file#> /qs /IAcceptSQLServerLicenseTerms /Action=Patch /InstanceName=MSSQLSERVER"

    #Execute SQL update
    Invoke-Expression -Command $updateCmd
}
    elseif ($CU_update -like 'N' -or ' ') {
        Write-Output "CU update skipped, moving on"
    }

        else {
            THROW "Response not recognized, exiting script"
        }

$SSMS_prompt = Read-host "Latest Cumulative Update installed, install SSMS 19? (Y/N)"
if ($SSMS_prompt -like 'Y' ) {
    #Copy SSMS installer to C:\Source, prepare to install SSMS
    New-Item -Path <#SSMS Install Directory#> -ItemType Directory
    Copy-Item -Path <#Path to SSMS install media#> -Destination <#SSMS Install Directory#> -Recurse


    #Install SSMS
    Write-Output "Installing SQL Server Management Studio (SSMS)"
    $SSMS_install = Get-ChildItem -Path <#SSMS install file#>
    $SSMS_install_path = "`<#SSMS Install path#>"
    $params = " /Install /Passive /SSMSInstallRoot=$SSMS_install_path"
    Start-Process -FilePath $SSMS_install -ArgumentList $params
    Write-Output "SSMS install complete"
}
    elseif ($SSMS_prompt -like 'N' -or ' ') {
        Write-Output "SSMS install skipped, moving on"
    }

        else {
            THROW "Response not recognized, exiting script"
        }


#Enable AlwaysOn Availability Groups
Write-Output "Enabling AlwaysOn AG on $Hostname, SQL services will be restarted"
Enable-SqlAlwaysOn -ServerInstance $Hostname -Force
Start-DbaService -ComputerName $Hostname -Type Agent
Start-Sleep -Seconds 1

$Agent_State = Get-DbaState -ComputerName $Hostname -Type Agent | Select-Object -ExpandProperty State
if ($Agent_State -like '*Running*') {
    Write-Output 'SQL Agent service is running'
    Write-Output 'AlwaysOn AG feature is enabled'
}

else {
Write-Output "AlwaysOn AG has been enabled but SQL Agent has not started, please manually start SQL Server Agent service"
}

#Add Redgate Service account as Admin on server
$RedGate_User = <#Service Account for Red Gate Monitor#>
$group = 'Administrators'
$isInGroup = Get-LocalGroupMember $group | Select-Object -ExpandProperty Name

if ($isInGroup -contains $RedGate_User) {
    Write-Output "Redgate service account exists, no further action necessary"
}

else {
    Write-Output "Service account does not exist, creating now"
    Add-LocalGroupMember -Group Administrators -Member <#Service Account for Red Gate Monitor#>
}

#Setup instance level backup jobs and standard maintenance
Write-Output "Server level configurations set, moving onto instance level setup"
Invoke-Command -ComputerName $Hostname -FilePath <#DB Setup PowerShell file#>
