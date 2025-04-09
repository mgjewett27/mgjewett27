#Local variables
$Hostname = $env:COMPUTERNAME

#Check if DBATools module exists, if not install it
$dbatools_Check = Get-Module -ListAvailable | Where-Object {$_.Name -eq 'dbatools'} | Select-Object -ExpandProperty Name | Select-Object -First 1

if ($null -ne $dbatools_Check) {
    Write-Host "DBATools module exists, skipping install"
}

    else {
        Write-Host "DBATools does not exist, installing module now"
        Install-Module -Name DBATools -Force
    }

#Update DBATools Build reference to ensure up to date information on KB Builds
Update-DbaBuildReference


#Function to check if server is pending a reboot
#Adapted from https://gist.github.com/altrive/5329377
#Based on <https://gallery.technet.microsoft.com/scriptcenter/Get-PendingReboot-Query-bdb79542>
function Test-PendingReboot {
    if (Get-ChildItem "HKLM:\Software\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending" -EA Ignore) { return $true }
    if (Get-Item "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired" -EA Ignore) { return $true }
    if (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name PendingFileRenameOperations -EA Ignore) { return $true }
    try { 
        $util = [wmiclass]"\\.\root\ccm\clientsdk:CCM_ClientUtilities"
        $status = $util.DetermineIfRebootPending()
        if(($null -ne $status) -and $status.RebootPending){
     return $true
   }
 }catch{}
 
 return $false
}

#Function to prompt user for a reboot of the server, used pre and post attempted update
function Reboot_Server {
    $Confirm_reboot = Read-Host 'Server has a reboot pending, start reboot now? (Y/N)'
    if ($Confirm_reboot -like 'Y') {
    Write-Output 'Beginning reboot of server now'    
    Restart-Computer -ComputerName $Hostname -Force
    }
    elseif ($Confirm_reboot -like 'N') {
        Write-Output 'Server has not been restarted yet. Please schedule a restart before proceeding with the Cumulative Update'
        Exit
    }
    else {
        THROW 'Response not recognized, exiting script'
    }
}

#Run Pending Reboot function, break in script and prompt for server reboot if true
if (Test-PendingReboot -eq $true) {
    Reboot_Server
}
elseif (Test-PendingReboot -eq $false) {
    Write-Output 'Server is not pending a reboot. Updating CU now'
}


#Fuction to update SQL Server 2017 instance to latest CU
Function Update_SQL_2017 {
        
        #Locate newest CU in Repository
        $Newest_CU_2017 = Get-ChildItem -Path <#Directory for CU Update files#> -Exclude "Old_Versions" |Select-Object -ExpandProperty Name
        $CU_directory_2017 = <#Folder path of desired CU Update#>
        $CU_2017_exe = Get-ChildItem -Path $CU_directory_2017 | Select-Object -ExpandProperty Name

        #Check if CU folder already created on C: drive
        $CU_Path = <#Local path for CU Folder#>
        $CU_Path_Test = Test-Path $CU_Path

        #Copy latest CU directory to C:\Source if folder doesn't exist
        if ($CU_Path_Test -ne 'True') {
            New-Item -Path <#Folder Path for CU Folder#> -ItemType Directory
            Copy-Item -Path <#Folder path of desired CU Update#> -Destination <#Local path for CU Folder#> -Recurse
        }
        else {
            Write-Output 'New CU folder already exists, copying CU exe now'
            Copy-Item -Path <#Folder path of desired CU Update#> -Destination <#Local path for CU Folder#> -Recurse
        }
        
        #Get KB number to pass into Update function
        $KB_Number = $CU_2017_exe.Substring(14,9)

        #Function to update SQL Instance with latest CU
        Write-Host "Installing latest Cumulative_Update, $Newest_CU_2017, to $Hostname"
        Update-DbaInstance -ComputerName $Hostname -KB $KB_Number -Path <#Folder Path for CU Folder#>


}

#Fuction to update SQL Server 2019 instance to latest CU
Function Update_SQL_2019 {
        
        #Locate newest CU in O: drive folder
        $Newest_CU_2019 = Get-ChildItem -Path <#Directory for CU Update files#> -Exclude "Old_Versions" |Select-Object -ExpandProperty Name
        $CU_directory_2019 = <#Folder path of desired CU Update#>
        $CU_2019_exe = Get-ChildItem -Path $CU_directory_2019 | Select-Object -ExpandProperty Name

        #Check if CU folder already created on C: drive
        $CU_Path = <#Local path for CU Folder#>
        $CU_Path_Test = Test-Path $CU_Path

        #Copy latest CU directory to C:\Source if folder doesn't exist
        if ($CU_Path_Test -ne 'True') {
            New-Item -Path <#Folder Path for CU Folder#> -ItemType Directory
            Copy-Item -Path <#Folder path of desired CU Update#> -Destination <#Local path for CU Folder#> -Recurse
        }
        else {
            Write-Output 'New CU folder already exists, copying CU exe now'
            Copy-Item -Path <#Folder path of desired CU Update#> -Destination <#Local path for CU Folder#> -Recurse
            
        }

        #Get KB number to pass into Update function
        $KB_Number = $CU_2019_exe.Substring(14,9)

        #Function to update SQL Instance with latest CU
        Write-Host "Installing latest Cumulative_Update, $Newest_CU_2019, to $Hostname"
        Update-DbaInstance -ComputerName $Hostname -KB $KB_Number -Path <#Folder Path for CU Folder#>


}

#Fuction to update SQL Server 2022 instance to latest CU
Function Update_SQL_2022 {
        
        #Locate newest CU in O: drive folder
        $Newest_CU_2022 = Get-ChildItem -Path <#Directory for CU Update files#> -Exclude "Old_Versions" |Select-Object -ExpandProperty Name
        $CU_directory_2022 = <#Folder path of desired CU Update#>
        $CU_2022_exe = Get-ChildItem -Path $CU_directory_2022 | Select-Object -ExpandProperty Name

        #Check if CU folder already created on C: drive
        $CU_Path = <#Local path for CU Folder#>
        $CU_Path_Test = Test-Path $CU_Path

        #Copy latest CU directory to C:\Source if folder doesn't exist
        if ($CU_Path_Test -ne 'True') {
            New-Item -Path <#Folder Path for CU Folder#> -ItemType Directory
            Copy-Item -Path <#Folder path of desired CU Update#> -Destination <#Local path for CU Folder#> -Recurse
        }
        else {
            Write-Output 'New CU folder already exists, copying CU exe now'
            Copy-Item -Path <#Folder path of desired CU Update#> -Destination <#Local path for CU Folder#> -Recurse
        }

        #Get KB number to pass into Update function
        $KB_Number = $CU_2022_exe.Substring(14,9)

        #Function to update SQL Instance with latest CU
        Write-Host "Installing latest Cumulative_Update, $Newest_CU_2022, to $Hostname"
        Update-DbaInstance -ComputerName $Hostname -KB $KB_Number -Path <#Folder Path for CU Folder#>


}

#Check version of SQL server to determine which CU to update to
$Instance_Name = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server").InstalledInstances
$RegistryFolder = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL").$Instance_Name
$SQL_Version = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$RegistryFolder\Setup").PatchLevel

#IF/ELSE loop to update CU, checks SQL version, calls appropiate function to update the instance to the latest CU
if ($SQL_Version -like '14.*') {

    Update_SQL_2017    
}

    elseif ($SQL_Version -like '15.*') {
        
        Update_SQL_2019
    }

    elseif ($SQL_Version -like '16.*') {
        
        Update_SQL_2022
    }

else {
    THROW 'SQL Server is not in supported version 2017, 2019, or 2022. Exiting script'
}

#Check version level post-update. Compare Version level to pre-update to determine if update successful
$SQL_Version_Post_Update = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$RegistryFolder\Setup").PatchLevel

if ($SQL_Version -ne $SQL_Version_Post_Update) {
    Write-Output "SQL is now updated to $SQL_Version_Post_Update successfully"
    Reboot_Server
}

elseif ($SQL_Version -eq $SQL_Version_Post_Update) {
    Write-Output 'SQL Version was not updated, please investigate update logs to determine error'
}
