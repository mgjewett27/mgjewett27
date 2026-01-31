##########################################################################################
# This script will be used to help automate the install of a SQL stand alone instance
# on a new server. This script sets up some inital directories and copies setup files.
# Script will also install the DBATools module if it doesn't exist
#     
#
#    2/15/2024 - Mike Jewett - Created script
#    3/11/2024 - Mike Jewett - Added automation to add Host to Redgate Monitor
##########################################################################################

#Set local variable
[System.Net.Dns]::GetHostByName($env:COMPUTERNAME).HostName

$cluster_name = Get-WmiObject -Namespace root\cimv2 -Class Win32_ComputerSystem | Select-Object -ExpandProperty Name
$domain_name = Get-WmiObject -Namespace root\cimv2 -Class Win32_ComputerSystem | Select-Object -ExpandProperty Domain
$Hostname = "$cluster_name.$domain_name"

#Checking for DBATools module, if the module doesn't exist, it will be installed on the local server
$dbatools_Check = Get-Module -ListAvailable | Where-Object {$_.Name -eq 'dbatools'} | Select-Object -ExpandProperty Name | Select-Object -First 1

if ($null -ne $dbatools_Check) {
    Write-Output "DBATools module exists, skipping install"
}

    else {
        Write-Output "DBATools does not exist, installing module now"
        Install-Module -Name DBATools -Force
    }

#Checking for SQLServer module, if the module doesn't exist, it will be installed on the local server
$SqlServer_Check = Get-Module SqlServer -ListAvailable | Select-Object -ExpandProperty Name | Select-Object -First 1

if ($null -ne $SqlServer_Check) {
    Write-Output "SQLServer module exists, skipping install"
}

    else {
        Write-Output "SqlServer module does not exist, installing module now"
        Install-Module -Name SqlServer -Force
    }

#Create Automated-install and Source directories
Write-Output "Creating setup directories"
$Install_directory = #SQL Setup directory
$Install_directory_check = Test-Path -Path $Install_directory

if ($Install_directory_check -eq 'True') {
    Write-Output 'Install directory exists, moving to next step'
}

else {
New-Item -Path <#Install Directory#> -ItemType Directory
New-Item <#SQL Source Directory#> -ItemType Directory
New-Item <#Maintenance Scripts subdirectory#> -ItemType Directory
New-Item <#Redgate API directory#> -ItemType Directory
New-Item <#SPN Tool Directory#> -ItemType directory

#Copy Powershell scripts for auotmated install, DB setup, and the database maintenance scripts into the newly created directories
Write-Output "Copying setup files from DBA share drive onto $Hostname"
Copy-Item -Path <#Automated install PowerShell file#> -Destination C:\Automated_Install\
Copy-Item -Path <#Database setup PowerShell file#> -Destination C:\Automated_install\
Copy-Item -Path <#Ola Maintenance Scripts#> -Destination C:\Source\Maintenance_Scripts -Recurse
Copy-Item -Path <#Redgate API Folder#> -Destination C:\Source\RedgateSQM -Recurse
Copy-Item -Path <#SPN Tool file#> -Destination C:\Source\SQLCheck
}
