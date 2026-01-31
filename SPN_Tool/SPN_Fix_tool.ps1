<#
.SYNOPSIS
    Missing SPN Fix tool

.DESCRIPTION
    Script can be used for checking for missing SPNs, registering these SPNs, or removing incorrectly registered SPNs for SQL Server instances.

.PARAMETER Instance_Name
    Instance_Name parameter, can be individual node, cluster name, named instance, or AG Listener

.PARAMETER Action
    Action to perform: Check, Register, or Remove

.NOTES
    Author: Mike Jewett
    Date: 02/06/2025
    Version: 1.1

.MODIFICATION LOG
    - 02/06/2025 Created script
    - 02/10/2025 Updated script, Setting SPN calls through DBATools command, 2 SPN service accounts exist, 1 for each domain. Script identifies which domain
    - 01/06/2026 Added parameter validation, error handling, consolidated Vault calls, improved readability

.EXAMPLE
    .\SPN_fix_tool.ps1 -Instance_Name "SQL01" -Action Check
    .\SPN_fix_tool.ps1 -Instance_Name "SQL01\INSTANCE1" -Action Register
    .\SPN_fix_tool.ps1 -Instance_Name "AGLISTENER01" -Action Remove

#>

Param (
    [Parameter(Mandatory=$true)]
    [string]$Instance_Name,

    [Parameter(Mandatory=$true)]
    [ValidateSet('Check', 'Register', 'Remove')]
    [string]$Action
)

# Error handling preference
$ErrorActionPreference = 'Stop'

#Introductory message
Write-Host "Welcome to the SPN Check and Fix Tool for SQL Servers" -ForegroundColor Cyan
Write-Host "This script is designed to help identify and resolve missing SPN errors on your SQL Server instances." -ForegroundColor Cyan
Write-Host "Action: $Action | Instance: $Instance_Name`n" -ForegroundColor Yellow


function Write-AuditLog {
    <#
    .SYNOPSIS
        Writes audit log entries for SPN operations
    .PARAMETER Message
        Log message to write
    .PARAMETER LogType
        Type of log entry (Info, Action, Input, Output, Error, Warning)
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message,
        
        [Parameter(Mandatory=$false)]
        [ValidateSet('Info', 'Action', 'Input', 'Output', 'Error', 'Warning')]
        [string]$LogType = 'Info'
    )
    
    try {
        $LogPath = <#Log file location#>
        $LogFile = Join-Path $LogPath "SPN_Audit_$($env:COMPUTERNAME)_$(Get-Date -Format 'yyyyMMdd').log"
        
        # Create log directory if it doesn't exist
        if (-not (Test-Path $LogPath)) {
            New-Item -Path $LogPath -ItemType Directory -Force | Out-Null
        }
        
        $Timestamp = Get-Date -Format "yyyy-MM-dd"
        $Username = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $ComputerName = $env:COMPUTERNAME
        
        $LogEntry = "[$Timestamp] [$LogType] [User: $Username] [Computer: $ComputerName] [Instance: $Instance_Name] [Action: $Action] - $Message"
        
        Add-Content -Path $LogFile -Value $LogEntry -ErrorAction Stop
    }
    catch {
        Write-Warning "Failed to write audit log: $_"
    }
}

Write-Output "`n######################################"
Write-Output "Checking for script modules necessary for setup"
Write-Output "######################################`n"

#Setup functions, installing required PowerShell tools if not already present
function Install-RequiredTools {
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


#Function to retrieve SPN credentials from Vault for the specified domain
function Get-SPNCredentials {
    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet(<#Potenital Domain#>)]
        [string]$Domain
    )

    Write-Output "Fetching credentials for SPN service account in $Domain domain"
        $role_id = Get-Content -Path <#Role id text file#>
        $secret_id = Get-Content -Path <#Secret id text file#>
    
    try {
        # Initialize Vault connection
        $env:VAULT_ADDR = <#Vault address#>
        $env:VAULT_NAMESPACE = <#Vault namespace#>
        $vault_token = vault write -field=token /auth/approle/login role_id=$role_id secret_id=$secret_id
        $env:VAULT_TOKEN = $vault_token
        $env:VAULT_NAMESPACE = <#Vault Namespace#>
    
        # Get username
         $global:SPN_UserName = vault kv get -mount=kv -field=Username $Domain
    
    # Get password (re-authenticate for security)
        $env:VAULT_ADDR = <#Vault address#>
        $env:VAULT_NAMESPACE = <#Vault namespace#>
        $vault_token = vault write -field=token /auth/approle/login role_id=$role_id secret_id=$secret_id
        $env:VAULT_TOKEN = $vault_token
        $env:VAULT_NAMESPACE = <#Vault namespace#>
    
        $global:SPN_Password = vault kv get -mount=kv -field=Password $Domain
    
        $global:FQDN_Username = "$Domain\$global:SPN_UserName"
    }
    catch {
        Write-Error "Failed to retrieve SPN credentials from Vault: $_"
        exit 1
    }
}

#Function to register missing SPNs
function Register_Missing_SPNs {
   
    Write-AuditLog -Message "Starting Register_Missing_SPNs function" -LogType "Action"
    # Get SPN list based on cluster type
    $SPN_List = Test-DbaSpn -ComputerName $Instance_Name
    
    if ($global:Cluster_type -eq 'AG') {
        $SPN_List += Test-DbaAGSPN -SqlInstance $Instance_Name -AvailabilityGroup $global:AG
    }

    #Check for missing SPNs

        if ($SPN_List.Error -like '*SPN missing*') {
            Write-Output 'Missing SPNs detected:'
            Write-Output "$($SPN_List.RequiredSPN)"
            $global:Missing_SPNs = $SPN_List | Where-Object { $_.Error -like '*SPN missing*' } | Select-Object RequiredSPN
            
            Write-AuditLog -Message "Missing SPNs detected: $($global:Missing_SPNs.Count) SPN(s)" -LogType "Output"

                foreach ($SPN in $global:Missing_SPNs) {
                    try {
                        
                        $register_confirm = Read-Host "Would you like to register the missing SPN: $($SPN.RequiredSPN)? (Y/N)"

                        if ($register_confirm -eq 'Y') {
                        Set-DbaSpn -SPN $SPN.RequiredSPN -ServiceAccount $global:Service_Account -Credential $global:MySecureCreds
                        Write-AuditLog -Message "Successfully registered SPN: $($SPN.RequiredSPN) to $($global:Service_Account)" -LogType "Action"
                        }
                        else {
                            Write-Output "Skipping registration of SPN: $($SPN.RequiredSPN)"
                            Write-AuditLog -Message "User declined to register SPN: $($SPN.RequiredSPN)" -LogType "Input"
                        }
                    }
                    catch {
                        Write-AuditLog -Message "Failed to register SPN $($SPN.RequiredSPN): $_" -LogType "Error"
                        Write-Error "Failed to register SPN $($SPN.RequiredSPN): $_ to $($global:Service_Account)"
                    }
        }
        else {
            Write-Output 'No missing SPNs detected on server or AG Listener'
            Write-AuditLog -Message "No missing SPNs detected" -LogType "Output"
            exit 
        }
        }    
}



<#Function to check missing SPNs, will check server and AG listener. Must be run against primary server
#>
function Check_Missing_SPNs {

    Write-AuditLog -Message "Starting Check_Missing_SPNs function" -LogType "Action"

    $SPN_Test = Test-DbaSpn -ComputerName $Instance_Name

    if ($global:Cluster_type -eq 'AG') {
        $SPN_Test += Test-DbaAGSPN -SqlInstance $Instance_Name -AvailabilityGroup $global:AG
    }


    if ($SPN_Test.Error -like '*SPN missing*') {
        Write-Output 'Missing SPNs detected:'
        Write-Output " - $($SPN_Test.RequiredSPN)"

        $global:Missing_SPNs = $SPN_Test | Where-Object { $_.Error -like '*SPN missing*' } | Select-Object RequiredSPN

        Write-AuditLog -Message "Missing SPNs detected: $($global:Missing_SPNs.Count) SPN(s)" -LogType "Output"

        $SPN_Register_choice =Read-host "Would you like to register these missing SPNs now? (Y/N)"
        Write-AuditLog -Message "User input received: $SPN_Register_choice" -LogType "Input"

        if ($SPN_Register_choice -eq 'Y') {
            foreach ($SPN in $global:Missing_SPNs) {
                try {
                    Set-DbaSpn -SPN $SPN.RequiredSPN -ServiceAccount $global:Service_Account -Credential $global:MySecureCreds -Confirm:$true
                    Write-Output "Successfully registered SPN: $($SPN.RequiredSPN)"
                    Write-AuditLog -Message "Successfully registered SPN: $($SPN.RequiredSPN)" -LogType "Action"
                }
                catch {
                    Write-AuditLog -Message "Failed to register SPN $($SPN.RequiredSPN): $_" -LogType "Error"
                    Write-Error "Failed to register SPN $($SPN.RequiredSPN): $_"
                }
            }
        }
        else {
            Write-Output 'Exiting without registering SPNs'
            Write-AuditLog -Message "User declined to register SPNs" -LogType "Input"
        }
    }
    else {
        Write-Output 'No missing SPNs detected on server or AG Listener' -ForegroundColor Green
        Write-AuditLog -Message "No missing SPNs detected" -LogType "Output"
    }
}


#Function to remove SPNs that may be misregistered to an incorrect service account
function Remove_Incorrect_SPNs {

    Write-AuditLog -Message "Starting Remove_Incorrect_SPNs function" -LogType "Action"

    # Get SPN list based on cluster type
    $SPN_List = Test-DbaSpn -ComputerName $Instance_Name
    
    if ($global:Cluster_type -eq 'AG') {
        $SPN_List += Test-DbaAGSPN -SqlInstance $Instance_Name -AvailabilityGroup $global:AG
    }

    if (-not $SPN_List) {
        Write-Host 'No SPNs found for this instance' -ForegroundColor Yellow
        Write-AuditLog -Message "No SPNs found for instance" -LogType "Warning"
        return
    }

    Write-Host "`nCurrent SPNs registered:" -ForegroundColor Cyan
    Write-AuditLog -Message "Displaying $($SPN_List.Count) registered SPN(s)" -LogType "Output"

    for ($i = 0; $i -lt $SPN_List.Count; $i++) {
        $status = if ($SPN_List[$i].Error -like '*SPN missing*') { '[MISSING]' } else { '[EXISTS]' }
        Write-Output "  $($i + 1). $status $($SPN_List[$i].RequiredSPN)"
    }

    Write-Warning 'This action will unregister the specified SPN from Active Directory. Please ensure you have the correct SPN to remove.'

    foreach ($SPN in $SPN_List) {
        try {
            
            $remove_confirm = Read-Host "Would you like to remove the SPN: $($SPN.RequiredSPN)? (Y/N)"
            
            if ($remove_confirm -eq 'Y') {
            Remove-DbaSpn -SPN $SPN.RequiredSPN -ServiceAccount $global:Service_Account -Credential $global:MySecureCreds
            Write-Output "Successfully removed SPN: $($SPN.RequiredSPN)"
            Write-AuditLog -Message "Successfully removed SPN: $($SPN.RequiredSPN)" -LogType "Action"
            }
            else {
                Write-Output "Skipping removal of SPN: $($SPN.RequiredSPN)"
                Write-AuditLog -Message "User declined to remove SPN: $($SPN.RequiredSPN)" -LogType "Input"
            }
        }
        catch {
            Write-AuditLog -Message "Failed to remove SPN $($SPN.RequiredSPN): $_" -LogType "Error"
            Write-Error "Failed to remove SPN $($SPN.RequiredSPN): $_"
        }
    
    }
}    

#End setup and module installation section
#########################################################################################################################################################################

# Log script start
Write-AuditLog -Message "Script execution started" -LogType "Info"

#Run function for installing required tools
Install-RequiredTools

#Configure DBATools to trust certs
Set-DbatoolsConfig -FullName sql.connection.trustcert -Value $true -PassThru | Out-Null

#Gather instance information
try {
    Write-AuditLog -Message "Gathering instance information" -LogType "Info"
    $global:Service_Account = Get-DbaService -ComputerName $Instance_Name -Type Engine | Select-Object -ExpandProperty StartName
    $global:AG = Get-DbaAvailabilityGroup -SqlInstance $Instance_Name | Select-Object -ExpandProperty AvailabilityGroup
    $global:AG_Listener = Get-DbaAGListener -SqlInstance $Instance_Name -AvailabilityGroup $global:AG | Select-Object -ExpandProperty Name
    Write-AuditLog -Message "Instance information gathered successfully - Service Account: $global:Service_Account" -LogType "Output"
}
catch {
    Write-AuditLog -Message "Failed to gather instance information: $_" -LogType "Error"
    Write-Error "Failed to gather instance information: $_"
    exit 1
}


if ($global:Service_Account -like <#DomainA#>) {
    Write-AuditLog -Message "Domain identified: <#DomainA#>" -LogType "Info"    
    Get-SPNCredentials -Domain <#DomainA#>
}
    elseif ($global:Service_Account -like <#DomainB#>) {
        Write-AuditLog -Message "Domain identified: <#DomainB#>" -LogType "Info"
        Get-SPNCredentials -Domain <#DomainB#>
    }
    else {
    Write-AuditLog -Message "Unrecognized service account domain: $global:Service_Account" -LogType "Error"
    Write-Error "Service account domain not recognized: $global:Service_Account"
    exit 1
}
       
    $pass = ConvertTo-SecureString -AsPlainText $global:SPN_Password -Force
    $SecureString = $pass
    $global:MySecureCreds = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $global:FQDN_Username,$SecureString

 #Determine if server is FCI or new AG build
if ($null -eq $global:AG_Listener) {
    $global:Cluster_type = 'FCI'
    Write-Output "Cluster type determined: $global:Cluster_type"
    Write-AuditLog -Message "Cluster type determined: FCI" -LogType "Output"
}
else {
    $global:Cluster_type = 'AG'
    Write-Output "Cluster type determined: $global:Cluster_type"
    Write-AuditLog -Message "Cluster type determined: AG - Listener: $global:AG_Listener" -LogType "Output"  
}   

Write-Output "Serivce Account detected: $global:Service_Account"


# Execute action based on parameter
Write-Output "######################################"
Write-Output "Executing Action: $Action"
Write-Output "######################################`n"

Write-AuditLog -Message "Executing action: $Action" -LogType "Action"

switch ($Action) {
    'Register' { Register_Missing_SPNs }
    'Remove'   { Remove_Incorrect_SPNs }
    'Check'    { Check_Missing_SPNs }
}

Write-Host "`n######################################" -ForegroundColor Cyan
Write-Host "Script execution completed" -ForegroundColor Cyan
Write-Host "######################################`n" -ForegroundColor Cyan

Write-AuditLog -Message "Script execution completed successfully" -LogType "Info"
