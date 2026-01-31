##########################################################################################
# This script will be used to help automate the install of a SQL stand alone instance
# on a new server. This script sets up some inital directories and copies setup files.
# Script will also install the DBATools module if it doesn't exist
#     
#
#    2/15/2024 - Mike Jewett - Created script
#    3/11/2024 - Mike Jewett - Added automation to add Host to Redgate Monitor
#    2/25/2025 - Mike Jewett - Overhaul of script, Vault for grabbing credentials, Chocolatey for package management and new CU install
#    3/31/2025 - Mike Jewett - Added check for SQL Version, script can now install 2017, 2019, or 2022
#    11/4/2025 - Mike Jewett - Removing copy of RedGate Auth token file, using Vault to securely store credentials instead
##########################################################################################

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

Write-Output "##########################################################################################"
Write-Output "# This script will be used to help automate the install of a SQL stand alone instance"
Write-Output "# on a new server. This script sets up some initial directories and copies setup files."
Write-Output "# Script will also install the DBATools module if it doesn't exist"
Write-Output "#"
Write-Output "##########################################################################################"
Write-Output ""
Write-Output "Starting the SQL setup script script..."

#Set local variable
[System.Net.Dns]::GetHostByName($env:COMPUTERNAME).HostName

$server_name = Get-WmiObject -Namespace root\cimv2 -Class Win32_ComputerSystem | Select-Object -ExpandProperty Name
$domain_name = Get-WmiObject -Namespace root\cimv2 -Class Win32_ComputerSystem | Select-Object -ExpandProperty Domain
$Hostname = "$server_name.$domain_name"

Write-Output "`n######################################"
Write-Output "Checking for script modules necessary for setup"
Write-Output "######################################`n"
function PowerShell_tools_install {
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
        $vaultInstalled = ($null -ne (choco list --local-only 'vault' --exact --limit-output))
        $dbaToolsInstalled = Get-Module -ListAvailable -Name dbatools

        if (-not $vaultInstalled -or -not $dbaToolsInstalled) {
            Write-Output 'Installing required packages (Vault and/or DBATools)'
            if (-not $vaultInstalled) {
                choco install vault -y
            }
            if (-not $dbaToolsInstalled) {
                Install-Module dbatools -Scope CurrentUser -Force -AllowClobber
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

PowerShell_tools_install


#Create Automated-install and C:\Source directories
Write-Output "`n######################################"
Write-Output "Creating setup directories"
Write-Output "######################################`n"
$Install_directory = 'C:\Automated_Install'
$Install_directory_check = Test-Path -Path $Install_directory

if ($Install_directory_check -eq 'True') {
    Write-Output "`n######################################"
    Write-Output 'Install directory exists, moving to next step' | Green
}

else {
New-Item -Path C:\Automated_Install -ItemType Directory 
New-Item C:\Source -ItemType Directory -ErrorAction SilentlyContinue
New-Item C:\Source\Maintenance_Scripts -ItemType Directory -ErrorAction SilentlyContinue
New-Item C:\Source\SQLCheck -ItemType directory -ErrorAction SilentlyContinue
New-Item C:\source\RedgateMonitor -ItemType Directory -ErrorAction SilentlyContinue
}

#Copy Powershell scripts for auotmated install, DB setup, and the database maintenance scripts into the newly created directories
Write-Output "Copying setup files from DBA share drive onto $Hostname"
Write-Output "######################################`n"
Copy-Item -Path <#Path to Automated_Install file#> -Destination C:\Automated_Install\ -ErrorAction SilentlyContinue
Copy-Item -Path <#Path to DB Setup file#> -Destination C:\Automated_install\ -ErrorAction SilentlyContinue
Copy-Item -Path <#Path to Maintenance Scripts#> -Destination C:\Source\Maintenance_Scripts -Recurse -ErrorAction SilentlyContinue
Copy-Item -Path <#Path to SQLCheck Utility#> -Destination C:\Source\SQLCheck -ErrorAction SilentlyContinue
Copy-Item -Path <#Path to PowerShell Modules#> -Destination C:\Source\RedgateMonitor -Recurse -ErrorAction SilentlyContinue



#Unblock all files in the directories
Get-ChildItem C:\Automated_Install\* | Unblock-File
Get-ChildItem C:\Source\RedgateMonitor\* | Unblock-File

Write-Output "Setup files copied successfully, please execute automated_install script now, located in C:\Automated_Install" | Green
Write-Output "##########################################################################################" | Green
