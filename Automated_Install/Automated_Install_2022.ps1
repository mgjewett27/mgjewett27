#####################################################################################
# This script will be used to automate the install of a SQL stand alone instance
# on a new server.
#     
#
#    2/15/2024 - Mike Jewett - Created script
#    3/11/2024 - Mike Jewett - Added automation to add Host to Redgate Monitor
#####################################################################################
#Install DBATools Powershell module
Set-DbatoolsConfig -FullName sql.connection.trustcert -Value $true -Register

#Set ISO depending on environment
[System.Net.Dns]::GetHostByName($env:COMPUTERNAME).HostName

#Setting server and domain name
$server_name = Get-WmiObject -Namespace root\cimv2 -Class Win32_ComputerSystem | Select-Object -ExpandProperty Name
$domain_name = Get-WmiObject -Namespace root\cimv2 -Class Win32_ComputerSystem | Select-Object -ExpandProperty Domain
$Hostname = "$server_name.$domain_name"

#Check which version of SQL Server ISO to mount and install
$SQL_Version = Get-Content -Path D:\SQL_Version.txt

#Set domain for user accounts depending on domain name
if ($domain_name -like '*<#domain_1#>*') {
    $AD_Domain = '<#domain_1#>'
}
elseif ($domain_name -like '*<#domain_2#>*') {
    $AD_Domain = '<#domain_2#>'
}

#Mount ISO for installing SQL. Check SQL Version and hostname to determine SQL Version and if Enterprise or Developer edition is needed.
if ($Hostname -like "*<#Prod_Server_Identifier#>*") {
    Write-Output "`n######################################"
    Write-Output "Production Server, mounting Enterprise edition ISO"
    Write-Output "######################################`n"
    if ($SQL_Version -eq '2022') {    
        $mountResult = Mount-DiskImage -ImagePath '<#Prod_2022_ISO_Location#>' -PassThru           
    }
    elseif ($SQL_Version -eq '2019') {
        $mountResult = Mount-DiskImage -ImagePath '<#Prod_2019_ISO_Location#>' -PassThru
    }
    elseif ($SQL_Version -eq '2017') {
        $mountResult = Mount-DiskImage -ImagePath '<#Prod_2017_ISO_Location#>' -PassThru
    }
}
    else {
        Write-Output "`n######################################"
        Write-Output "Non-prod server, mounting Developer edition ISO"
        Write-Output "######################################`n"
        if ($SQL_Version -eq '2022') {
            $mountResult = Mount-DiskImage -ImagePath '<#Dev_2022_ISO_Location#>' -PassThru  
        }
        elseif ($SQL_Version -eq '2019') {
            $mountResult = Mount-DiskImage -ImagePath '<#Dev_2019_ISO_Location#>' -PassThru
        }
        elseif ($SQL_Version -eq '2017') {
            $mountResult = Mount-DiskImage -ImagePath '<#Dev_2017_ISO_Location#>' -PassThru
        }
    }


$Data_Volume = Get-Volume | Where-Object {$_.FileSystemLabel -like '*SQLData*'} | Select-Object -ExpandProperty DriveLetter -First 1
$Log_Volume = Get-Volume | Where-Object {$_.FileSystemLabel -like '*SQLLog*'} | Select-Object -ExpandProperty DriveLetter -First 1
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
    
    Write-Output "Path exists, continuing to next step"
    Write-Output "######################################`n"
}
    else {
        Write-Output "Paths do not exist, creating SQL directories"
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
    Write-Output "`nPath exists, mounting ISO and copying files now"
    Write-Output "######################################`n"
}
    else {
        Write-Output "Path does not exist, creating folder and copying files now"
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
    if ($Hostname -like '*<#Prod_Server_Identifier#>*') {
        Dismount-DiskImage -ImagePath '<#Prod_2022_ISO_Location#>'          
    }
        else {
            Dismount-DiskImage -ImagePath '<#Dev_2022_ISO_Location#>'
        }
    
}
elseif ($SQL_Version -eq '2019') {
    if ($Hostname -like '*VPS*') {
        Dismount-DiskImage -ImagePath '<#Prod_2019_ISO_Location#>'
    }
        else {
            Dismount-DiskImage -ImagePath '<#Dev_2019_ISO_Location#>'
        }
}
elseif ($SQL_Version -eq '2017') {
    if ($Hostname -like '*VPS*') {
        Dismount-DiskImage -ImagePath '<#Prod_2017_ISO_Location#>'
    }
        else {
            Dismount-DiskImage -ImagePath '<#Dev_2017_ISO_Location#>'
        }
}

#Copy SQL ini file into C:\Source to use, check server envrironment to determine which ISO and requested version
Write-Output "`n######################################"
Write-Output "Copying configuration file into C:\Source directory"
Write-Output "######################################`n"
if ($SQL_Version -eq '2022' -and $Hostname -like "*<#Prod_Server_Identifier#>*") {
    Copy-Item "<#Prod_2022_Config_INI_File#>" -Destination "C:\Source"           
}
    elseif ($SQL_Version -eq '2022' -and $Hostname -notlike '*<#Prod_Server_Identifier#>*') {
        Copy-Item "<#Dev_2022_Config_INI_File#>" -Destination "C:\Source"
    }
    elseif ($SQL_Version -eq '2019' -and $Hostname -like '*<#Prod_Server_Identifier#>*') {
        Copy-Item "<#Prod_2019_Config_INI_File#>" -Destination "C:\Source"
    }
    elseif ($SQL_Version -eq '2019' -and $Hostname -notlike '*<#Prod_Server_Identifier#>*') {
        Copy-Item "<#Dev_2019_Config_INI_File#>" -Destination "C:\Source"
    }
    elseif ($SQL_Version -eq '2017' -and $Hostname -like '*<#Prod_Server_Identifier#>*') {
        Copy-Item "<#Prod_2017_Config_INI_File#>" -Destination "C:\Source"
    }
    elseif ($SQL_Version -eq '2017' -and $Hostname -notlike '*<#Prod_Server_Identifier#>*') {
        Copy-Item "<#Dev_2017_Config_INI_File#>" -Destination "C:\Source"
    }

Write-Output "Pre-work has been completed successfully, beginning installation of SQL Software`n"
Write-Output "`n######################################"
Write-Output "Welcome to the DBA SQL Install script."
Write-Output "######################################`n"

Write-Output "`nRetrieving SQL Server Service Account information from Vault`n"
#Set Vault variables based on current environment
if ($Hostname -like '*<#Prod_Server_Identifier#>*') {
    $env:VAULT_ADDR = '<#Vault_env_secret_address#>'
    $env:VAULT_NAMESPACE = '<#prod_env_namespace#>'
    $role_id = Get-Content -Path '<#Vault_role_id_value#>'
    $secret_id = Get-Content -Path '<#Vault_Secret_id_value#>'
    $vault_token = vault write -field=token /auth/approle/login role_id=$role_id secret_id=$secret_id
    $env:VAULT_TOKEN = $vault_token
    $env:VAULT_NAMESPACE = '<#prod_service_account_namespace#>'
}
    elseif ($Hostname -like '*<#Stage_Server_Identifier#>*') {
        $env:VAULT_ADDR = '<#Vault_env_secret_address#>'
        $env:VAULT_NAMESPACE = '<#stage_env_namespace#>'
        $role_id = Get-Content -Path '<#Vault_role_id_value#>'
        $secret_id = Get-Content -Path '<#Vault_Secret_id_value#>'
        $vault_token = vault write -field=token /auth/approle/login role_id=$role_id secret_id=$secret_id
        $env:VAULT_TOKEN = $vault_token
        $env:VAULT_NAMESPACE = '<#stage_service_account_namespace#>'
    }
    else {
        $env:VAULT_ADDR = "<#Vault_env_secret_address#>"
        $env:VAULT_NAMESPACE = '<#dev_env_namespace#>'
        $role_id = Get-Content -Path '<#Vault_role_id_value#>'
        $secret_id = Get-Content -Path '<#Vault_Secret_id_value#>'
        $vault_token = vault write -field=token /auth/approle/login role_id=$role_id secret_id=$secret_id
        $env:VAULT_TOKEN = $vault_token
        $env:VAULT_NAMESPACE = '<#dev_service_account_namespace#>'
    }



#Get cluster name of built server. Use this unique identifier to pull service account and password
$cluster_name = Get-Cluster | Select-Object -ExpandProperty Name
$service_account = vault kv get -mount=kv -field=username $cluster_name
$SQL_username = "$AD_Domain" + '\' + "$service_account"
$service_pw_secure = vault kv get -mount=kv -field=password $cluster_name | ConvertTo-SecureString -AsPlainText -Force
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
Invoke-Expression -Command $installCmd

Write-Host "SQL has been installed successfully, installing latest stable Cumulative Update"

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
    $KB_Details = Get-DbaKbUpdate $KB
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
        Write-Output "CU update successful. Current CU: $currentCU"
        Write-Output "######################################`n"
    } else {
        Write-Error "CU update did not complete successfully. Please check logs for errors. Expected CU: $CU_Num, but found CU: $currentCU"
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
    Write-Output 'SQL Agent service is running'
    Write-Output 'AlwaysOn AG feature is enabled'
    Write-Output "######################################`n"
}

else {
    Write-Output "`n######################################"
    Write-Output "AlwaysOn AG has been enabled but SQL Agent has not started, please manually start SQL Server Agent service"
    Write-Output "######################################`n"
}

Write-Output "`n######################################"
Write-Output "Adding Redgate Service Account as local admin on $Hostname"
Write-Output "######################################`n"
#Add Redgate Service account as Admin on server
$RedGate_User = '<#Redgate Monitor Service Account#>'
$group = 'Administrators'
$isInGroup = Get-LocalGroupMember $group | Select-Object -ExpandProperty Name

if ($isInGroup -contains $RedGate_User) {
    Write-Output "Redgate service account exists, no further action necessary"
}

else {
    Write-Output "`n######################################"
    Write-Output "Service account does not exist, creating now"
    Write-Output "######################################`n"
    Add-LocalGroupMember -Group Administrators -Member "<#Redgate Monitor Service Account#>"
}

#Setup instance level backup jobs and standard maintenance
Write-Output "`n######################################"
Write-Output "Server level configurations set, moving onto instance level setup"
Write-Output "######################################`n"
Invoke-Command -ComputerName $Hostname -FilePath C:\Automated_Install\DB_Setup_development.ps1


