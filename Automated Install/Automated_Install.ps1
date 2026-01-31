#####################################################################################
# This script will be used to automate the install of a SQL stand alone instance
# on a new server.
#     
#
#    2/15/2024 - Mike Jewett - Created script
#    3/11/2024 - Mike Jewett - Added automation to add Host to Redgate Monitor
#    3/31/2025 - Mike Jewett - Refactored to handle installing SQL 2017, 2019, or 2022 versions
#    11/4/2025 - Mike Jewett - Added logging and additional checks for service accounts to improve the performance of the install process
#####################################################################################

Param (
    [Parameter(Mandatory=$true)]
    [ValidateSet('2017', '2019', '2022', '2025')]
    [string]$SQL_Version
)

# Error handling preference
$ErrorActionPreference = 'Stop'


#Set DBATools module to always trust server certificates
Set-DbatoolsConfig -FullName sql.connection.trustcert -Value $true -Register

function Green
{
    process { Write-Host $_ -ForegroundColor Green }
}

function Red
{
    process { Write-Host $_ -ForegroundColor Red }
}

function Yellow
{
    process { Write-Host $_ -ForegroundColor Yellow }
}

#Set ISO depending on environment
[System.Net.Dns]::GetHostByName($env:COMPUTERNAME).HostName

#Setting server and domain name
$server_name = Get-WmiObject -Namespace root\cimv2 -Class Win32_ComputerSystem | Select-Object -ExpandProperty Name
$domain_name = Get-WmiObject -Namespace root\cimv2 -Class Win32_ComputerSystem | Select-Object -ExpandProperty Domain
$Hostname = "$server_name.$domain_name"

#Set domain for user accounts depending on domain name
if ($domain_name -like <#DomainA#>) {
    $AD_Domain = <#DomainA#>
}
elseif ($domain_name -like <#DomainB#>) {
    $AD_Domain = <#DomainB#>
}

#Setting up audit logging for investigation of install issues
$Log_path = 'C:\Automated_Install\Logs'
$Log_check = Test-Path -Path $Log_path

if ($Log_check -like '*False*') {
    New-Item -Path $Log_path -ItemType Directory
}
else {
    Write-Output "Log directory exists, proceeding to next step" | Yellow
}

Start-Transcript -Path "C:\Automated_Install\Logs\SQL_Install_Log_$($Hostname)_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt" -Append


#Mount ISO for installing SQL. Check SQL Version and hostname to determine SQL Version and if Enterprise or Developer edition is needed.
if ($Hostname -like <#Prod Server#>) {
    Write-Output "`n######################################" | Green
    Write-Output "Production Server, mounting Enterprise edition ISO" | Green
    Write-Output "######################################`n" | Green
    if ($SQL_Version -eq '2022') {    
        $mountResult = Mount-DiskImage -ImagePath <#SQL 2022 Enterprise ISO#> -PassThru           
    }
    elseif ($SQL_Version -eq '2019') {
        $mountResult = Mount-DiskImage -ImagePath <#SQL 2019 Enterprise ISO#> -PassThru
    }
    elseif ($SQL_Version -eq '2017') {
        $mountResult = Mount-DiskImage -ImagePath <#SQL 2017 Enterprise ISO#> -PassThru
    }
    elseif ($SQL_Version -eq '2025') {
        $mountResult = Mount-DiskImage -ImagePath <#SQL 2025 Enterprise ISO#> -PassThru
    }
}
    else {
        Write-Output "`n######################################" | Green
        Write-Output "Non-prod server, mounting Developer edition ISO" | Green
        Write-Output "######################################`n" | Green
        if ($SQL_Version -eq '2022') {
            $mountResult = Mount-DiskImage -ImagePath <#SQL 2022 Developer ISO#> -PassThru  
        }
        elseif ($SQL_Version -eq '2019') {
            $mountResult = Mount-DiskImage -ImagePath <#SQL 2019 Developer ISO#> -PassThru
        }
        elseif ($SQL_Version -eq '2017') {
            $mountResult = Mount-DiskImage -ImagePath <#SQL 2017 Developer ISO#> -PassThru
        }
        elseif ($SQL_Version -eq '2025') {
            $mountResult = Mount-DiskImage -ImagePath <#SQL 2025 Developer ISO#> -PassThru
        }
    }


$Data_Volume = Get-Volume | Where-Object {$_.FileSystemLabel -like '*SQLData*' -or $_.FileSystemLabel -like '*SQL_Data*'} | Select-Object -ExpandProperty DriveLetter -First 1
$Log_Volume = Get-Volume | Where-Object {$_.FileSystemLabel -like '*SQLLog*' -or $_.FileSystemLabel -like '*SQL_LOG*'} | Select-Object -ExpandProperty DriveLetter -First 1
$TempDB_Volume = Get-Volume | Where-Object {$_.FileSystemLabel -like '*TempDB*'} | Select-Object -ExpandProperty DriveLetter -First 1

#Create SQL data, log, and tempDB directories
$SQL_data = "$Data_Volume" + ':\MSSQL\SQLDATA'
$SQL_log = "$Log_Volume" + ':\MSSQL\SQLLOG'
$SQL_TempDB = "$TempDB_Volume" + ':\MSSQL'
$SQL_TempDBDATA = "$SQL_TempDB" + '\TEMPDB_SQLDATA'
$SQL_TempDBLOG = "$SQL_TempDB" + '\TEMPDB_SQLLOG'
$SQL_Data_check = Test-Path -Path $SQL_data
$SQL_Log_check = Test-Path -Path $SQL_log
$TempDB_check = Test-Path -Path $SQL_TempDB

Write-Output "`n######################################"
Write-Output "Checking to see if SQL directories exists"

if (($SQL_Data_check -eq 'True') -and ($SQL_Log_check -eq 'True') -and ($TempDB_check -eq 'True')) {
    
    Write-Output "Path exists, continuing to next step" | Green
    Write-Output "######################################`n"
}
    else {
        Write-Output "Paths do not exist, creating SQL directories" | Yellow
        Write-Output "######################################`n"
        New-Item -Path $SQL_data -ItemType Directory -ErrorAction SilentlyContinue
        New-Item -Path $SQL_log -ItemType Directory -ErrorAction SilentlyContinue
        New-Item -Path $SQL_TempDB -ItemType Directory -ErrorAction SilentlyContinue
        New-Item -Path $SQL_TempDBDATA -ItemType Directory -ErrorAction SilentlyContinue
        New-Item -Path $SQL_TempDBLOG -ItemType Directory -ErrorAction SilentlyContinue
    }


#Mount SQL 2022 iso image and copy files into C:\Source directory
$Source = 'C:\Source'
Write-Output "`n######################################"
Write-Output "Checking to see if Source directory exists"
if (Test-Path -Path $Source) {
    Write-Output "`nPath exists, mounting ISO and copying files now" | Green
    Write-Output "######################################`n"
}
    else {
        Write-Output "Path does not exist, creating folder and copying files now" | Yellow
        Write-Output "######################################`n"
        New-Item -Path C:\Source -ItemType Directory
    }
$volumeInfo = $mountResult | Get-Volume
$driveInfo = Get-PSDrive -Name $volumeInfo.DriveLetter
Copy-Item -Path (Join-Path -Path $driveInfo.root -ChildPath '*') -Destination C:\Source\ -Recurse

#Unmount ISO image, depending on which environment
Write-Output "`n######################################"
Write-Output "Unmounting ISO from $Hostname"
Write-Output "######################################`n"
if ($SQL_Version -eq '2022') {    
    if ($Hostname -like <#Production#>) {
        Dismount-DiskImage -ImagePath <#SQL 2022 ISO#>          
    }
        else {
            Dismount-DiskImage -ImagePath <#SQL 2022 ISO#>
        }
    
}
elseif ($SQL_Version -eq '2019') {
    if ($Hostname -like <#Production#>) {
        Dismount-DiskImage -ImagePath <#SQL 2019 ISO#>
    }
        else {
            Dismount-DiskImage -ImagePath <#SQL 2019 ISO#>
        }
}
elseif ($SQL_Version -eq '2017') {
    if ($Hostname -like <#Production#>) {
        Dismount-DiskImage -ImagePath <#SQL 2017 ISO#>
    }
        else {
            Dismount-DiskImage -ImagePath <#SQL 2017 ISO#>
        }
}
elseif ($SQL_Version -eq '2025') {
    if ($Hostname -like <#Production#>) {
        Dismount-DiskImage -ImagePath <#SQL 2025 ISO#>
    }
        else {
            Dismount-DiskImage -ImagePath <#SQL 2025 ISO#>
        }
}

#Copy SQL ini file into C:\Source to use, check server envrironment to determine which ISO and requested version
Write-Output "`n######################################"
Write-Output "Copying configuration file into C:\Source directory"
Write-Output "######################################`n"
if ($SQL_Version -eq '2022' -and $Hostname -like <#Production#>) {
    Copy-Item <#SQL 2022 Config ini#> -Destination "C:\Source\ConfigurationFile.ini"           
}
    elseif ($SQL_Version -eq '2022' -and $Hostname -notlike <#Production#>) {
        Copy-Item <#SQL 2022 Config ini#> -Destination "C:\Source\ConfigurationFile.ini"
    }
    elseif ($SQL_Version -eq '2019' -and $Hostname -like <#Production#>) {
        Copy-Item <#SQL 2019 Config ini#> -Destination "C:\Source\ConfigurationFile.ini"
    }
    elseif ($SQL_Version -eq '2019' -and $Hostname -notlike <#Production#>) {
        Copy-Item <#SQL 2019 Config ini#> -Destination "C:\Source\ConfigurationFile.ini"
    }
    elseif ($SQL_Version -eq '2017' -and $Hostname -like <#Production#>) {
        Copy-Item <#SQL 2017 Config ini#> -Destination "C:\Source\ConfigurationFile.ini"
    }
    elseif ($SQL_Version -eq '2017' -and $Hostname -notlike <#Production#>) {
        Copy-Item <#SQL 2017 Config ini#> -Destination "C:\Source\ConfigurationFile.ini"
    }
    elseif ($SQL_Version -eq '2025' -and $Hostname -like <#Production#>) {
        Copy-Item <#SQL 2025 Config ini#> -Destination "C:\Source\ConfigurationFile.ini"
    }
    elseif ($SQL_Version -eq '2025' -and $Hostname -notlike <#Production#>) {
        Copy-Item <#SQL 2025 Config ini#> -Destination "C:\Source\ConfigurationFile.ini"

Write-Output "Pre-work has been completed successfully, beginning installation of SQL Software`n" | Green
Write-Output "`n######################################"
Write-Output "Welcome to the DBA SQL Install script."
Write-Output "######################################`n"

Write-Output "`nRetrieving SQL Server Service Account information from Vault`n"
#Set Vault variables based on current environment
if ($Hostname -like <#Production#>) {
    $env:VAULT_ADDR = <#Vault address#>
    $env:VAULT_NAMESPACE = <#Vault Space#>
    $role_id = Get-Content -Path <#Role id file#>
    $secret_id = Get-Content -Path <#Secret id file#>
    $vault_token = vault write -field=token /auth/approle/login role_id=$role_id secret_id=$secret_id
    $env:VAULT_TOKEN = $vault_token
    $env:VAULT_NAMESPACE = <#Vault namespace#>
}
    elseif ($Hostname -like <#Staging#>) {
    $env:VAULT_ADDR = <#Vault address#>
    $env:VAULT_NAMESPACE = <#Vault Space#>
    $role_id = Get-Content -Path <#Role id file#>
    $secret_id = Get-Content -Path <#Secret id file#>
    $vault_token = vault write -field=token /auth/approle/login role_id=$role_id secret_id=$secret_id
    $env:VAULT_TOKEN = $vault_token
    $env:VAULT_NAMESPACE = <#Vault namespace#>
    }
    else {
    $env:VAULT_ADDR = <#Vault address#>
    $env:VAULT_NAMESPACE = <#Vault Space#>
    $role_id = Get-Content -Path <#Role id file#>
    $secret_id = Get-Content -Path <#Secret id file#>
    $vault_token = vault write -field=token /auth/approle/login role_id=$role_id secret_id=$secret_id
    $env:VAULT_TOKEN = $vault_token
    $env:VAULT_NAMESPACE = <#Vault namespace#>
    }



#Get cluster name of built server. Use this unique identifier to pull service account and password
$cluster_name = Get-Cluster | Select-Object -ExpandProperty Name

#Check the case sensitivity of the Password field in Vault, then use that to pull the correct password field
$password_case_check = vault kv get -mount=kv $cluster_name
$parsed_secret_check = $password_case_check | ConvertFrom-String -PropertyNames Key, Value, RunspaceID

if ($parsed_secret_check.key -ccontains "Password") {
    $service_pw_secure = vault kv get -mount=kv -field=Password $cluster_name | ConvertTo-SecureString -AsPlainText -Force
}
    elseif ($parsed_secret_check.key -ccontains "password") {
        $service_pw_secure = vault kv get -mount=kv -field=password $cluster_name | ConvertTo-SecureString -AsPlainText -Force
    }

if ($parsed_secret_check.key -ccontains "Username") {
    $service_account = vault kv get -mount=kv -field=Username $cluster_name
}
    elseif ($parsed_secret_check.key -ccontains "username") {
        $service_account = vault kv get -mount=kv -field=username $cluster_name
    }    

#Content check to see if the service account variable is null or empty, if so throw error to stop SQL from installing with invalid account
if ($service_account) {
    Write-Output "Successfully retrieved SQL Service account from Vault: $service_account`n"
}
else {
    Write-Output "Failed to retrieve SQL Service account from Vault" | Red
    Throw "Invalid SQL Service account"
}

#Content check if the service account password contains the $ character, if so throw error as SQL install will fail
if ($service_pw_secure) {
    $plain_pw = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($service_pw_secure))
    if ($plain_pw -like '*$*') {
        Write-Output "SQL Service account password contains invalid character '$'" | Red
        Throw "SQL Service account password contains invalid character '$', SQL installation cannot proceed"
    }
    else {
        Write-Output "Successfully retrieved SQL Service account password from Vault`n"
    }
}
else {
    Write-Output "Failed to retrieve SQL Service account password from Vault" | Red
    Throw "Invalid SQL Service account password"
}

#$service_account = vault kv get -mount=kv -field=$username_case $cluster_name
$SQL_username = "$AD_Domain" + '\' + "$service_account"
#$service_pw_secure = vault kv get -mount=kv -field=$password_case $cluster_name | ConvertTo-SecureString -AsPlainText -Force
$SA_password_secure = vault kv get -mount=kv -field=password sa | ConvertTo-SecureString -AsPlainText -Force


$SQL_password = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($service_pw_secure))
$SA_password =  [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SA_password_secure))


#Collect SQL Server Service Account and Password from Vault, as well as SA user and password

#Set replace variable to replace filler SQL Server Service Account with actual value 
Write-Output "`n######################################"
Write-Output "Updating Config file with SQL Server Service account information"
Write-Output "######################################`n"
Start-Sleep -Seconds 1
$replaceText = (Get-Content -Path C:\Source\ConfigurationFile.ini -Raw) -replace "##MyUser##", $SQL_username

#Run command, replacing SQL Server Service Account with actual account
Set-Content -Path C:\Source\ConfigurationFile.ini $replaceText

#Sets execution command
$installCMD = "C:\Source\Setup.exe /ConfigurationFile=C:\Source\ConfigurationFile.ini /SQLSVCPASSWORD=""$SQL_password"" /AGTSVCPASSWORD=""$SQL_password"" /SAPWD=""$SA_password"""

#Calls execution command
Write-Output "`n######################################"
Write-Output "Beginning SQL installation"
Write-Output "######################################`n"
try {
Invoke-Expression -Command $installCmd
}
catch {
    Write-Output "`n######################################"
    Write-Output "SQL installation failed, please check the log files for errors" | Red
    Write-Output "######################################`n"
    Throw $_
}

Write-Host "SQL has been installed successfully, installing latest stable Cumulative Update" | Green

#New CU Update function. Uses DBATools to install current N-1 CU update
function CU_Update {
    #Collecting information on current SQL instance and setting instance name, and base version as variables
    $Instance = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server').InstalledInstances
    $Instance_Name = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL").$Instance
    $version = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$Instance_Name\Setup").Version

    #Updating list of available CUs, then finding the second most recent CU, and saving the CU information as variables
    Update-DbaBuildReference
    $Target_CU = (Test-DbaBuild -Build $version -MaxBehind "1CU").BuildTarget
    $CU_Num = (Test-DbaBuild -Build $version -MaxBehind "1CU").CUTarget
    $pre_update_CU = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$Instance_Name\Setup").PatchLevel

    #Collecting KB number and details for CU, then saving the CU executable as a variable
    $KB = (Get-DbaBuildReference -Build $Target_CU).KBLevel
    #$file = ($KB_Details.Link | Select-Object -Last 1) -split ('/') | Select-Object -Last 1

    #Setting path for CU executable, then checking if the CU executable exists
    $CU_Path = 'C:\Source\' + "$CU_Num"
    $CU_Check = Test-Path $CU_Path

    #If CU executable exists, skip download, if not download CU executable
    if ($CU_Check -eq $true) {
        Write-Output "`n######################################"
        Write-Output "CU already exists, skipping download"
        Write-Output "######################################`n"
    }
        else {
            Write-Output "`n######################################"
            Write-Output "CU does not exist, downloading now"
            Write-Output "######################################`n"
            New-Item -Path $CU_Path -ItemType Directory
            Save-DbaKbUpdate $KB -Path $CU_Path
        }
    
    #Installing CU on SQL instance
    Write-Output "`n######################################"
    Write-Output "Installing $CU_Num on $Hostname"
    Write-Output "######################################`n"
    Update-DbaInstance -ComputerName $Hostname -KB $KB -Path $CU_Path -Confirm:$false
    Write-Output 'CU update complete, checking if update was successful'

    # Check current version of CU on localhost
    $currentCU = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$Instance_Name\Setup").PatchLevel

    #Compare current CU with target CU
    if ($currentCU -ne $pre_update_CU) {
        Write-Output "`n######################################"
        Write-Output "CU update successful. Current CU: $currentCU" | Green
        Write-Output "######################################`n"
    } else {
        Write-Error "CU update did not complete successfully. Please check logs for errors. Expected CU: $CU_Num, but found CU: $currentCU" | Red
    }
}

CU_Update

#New SSMS install via Chocolatey, replaces prompt and install version
Write-Output "`n######################################"
Write-Output 'Installing SQL Server Management Studio'
Write-Output "######################################`n"
choco install sql-server-management-studio -y --force


#Enable AlwaysOn Availability Groups
Write-Output "`n######################################"
Write-Output "Enabling AlwaysOn AG on $Hostname, SQL services will be restarted"
Write-Output "######################################`n"
Enable-SqlAlwaysOn -ServerInstance $Hostname -Force
Start-DbaService -ComputerName $Hostname -Type Agent
Start-Sleep -Seconds 1

Write-Output "`n######################################"
Write-Output "AlwaysOn AG has been enabled, checking SQL Agent service status"
Write-Output "######################################`n"
$Agent_State = Get-DbaService -ComputerName $Hostname -Type Agent | Select-Object -ExpandProperty State
if ($Agent_State -like '*Running*') {
    Write-Output "`n######################################"
    Write-Output 'SQL Agent service is running' | Green
    Write-Output 'AlwaysOn AG feature is enabled' | Green
    Write-Output "######################################`n"
}

else {
    Write-Output "`n######################################"
    Write-Output "AlwaysOn AG has been enabled but SQL Agent has not started, please manually start SQL Server Agent service" | Yellow
    Write-Output "######################################`n"
}

Write-Output "`n######################################"
Write-Output "Adding Redgate Service Account as local admin on $Hostname"
Write-Output "######################################`n"
#Add Redgate Service account as Admin on server
$RedGate_User = <#Monitor service account#>
$group = 'Administrators'
$isInGroup = Get-LocalGroupMember $group | Select-Object -ExpandProperty Name

if ($isInGroup -contains $RedGate_User) {
    Write-Output "Redgate service account exists, no further action necessary"
}

else {
    Write-Output "`n######################################"
    Write-Output "Service account does not exist, creating now" | Green
    Write-Output "######################################`n"
    Add-LocalGroupMember -Group Administrators -Member <#Monitor Service account#>
}

#Setup instance level backup jobs and standard maintenance
Write-Output "`n######################################"
Write-Output "Server level configurations set, moving onto instance level setup" | Green
Write-Output "######################################`n"
Invoke-Command -ComputerName $Hostname -FilePath C:\Automated_Install\DB_Setup.ps1

#Stop transcript
Stop-Transcript

