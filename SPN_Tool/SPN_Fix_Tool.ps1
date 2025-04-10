<#
.SYNOPSIS
    Missing SPN Fix tool

.DESCRIPTION
    Script will scan the requested server, check if any Service Prinicpal Names were not registered successfully.
    If SPNs are missing, SQL script is run to generate all setspn commands
    Once commands are generated, service account with sufficient permissions is retreived from Vault and used to run the setspn commands
    Final check of missing SPNs is run afterwards

.PARAMETER [ParameterName]
    Servername parameter, can be individual node, cluster name, named instance, or AG Listener

.NOTES
    Author: Mike Jewett
    Date: 02/06/2025
    Version: 1.0

.MODIFICATION LOG
    - 02/06/2025 Created script
    - 02/10/2025 Updated script, Setting SPN calls through DBATools command, 2 SPN service accounts exist, 1 for each domain. Script identifies which domain
#>

#Introductory message
Write-Host "Welcome to the SPN Check and Fix Tool for SQL Servers"
Write-Host "This script is designed to help identify and resolve missing SPN errors on your SQL Server instances."

#Set variables
$Server_Name = Read-Host 'Please enter name of SQL Instance'
$Remote_Server = '<#Remote server name#>'
$env:VAULT_ADDR = "<#Vault environment address#>"
$env:VAULT_NAMESPACE = '<#Vault environment#>'
$role_id = Get-content -path <#Vault role id authentication file#>
$secret_id = Get-content -path <#Vault secret id authentication file#>


#Check if DBATools is installed, if not install on local server
function DBAToolsModule_Check {
    Write-Output 'Checking if DBATools PowerShell module is installed'
    $dbatools_Check = Get-Module -ListAvailable | Where-Object {$_.Name -eq 'dbatools'} | Select-Object -ExpandProperty Name | Select-Object -First 1
    if ($null -ne $dbatools_Check) {
        Write-Host "DBATools module exists, skipping install"
    } else {
        Write-Host "DBATools does not exist, installing module now"
        Install-Module -Name DBATools -Force
    }
    Set-DbatoolsConfig -FullName sql.connection.trustcert -Value $true
}

DBAToolsModule_Check

#Uses DBATools function to check server if there are any missing SPNs. If so return true for future use
    function SPN_Check {
               
        $Test_missing_SPN = Test-DbaSpn -ComputerName $env:COMPUTERNAME | Select-Object -ExpandProperty Error -First 1

    if ($Test_missing_SPN -like '*SPN missing*') {
        return $true
        
    }
    else {
        return $false
    }

}

#Function for Domain_A service account. Function calls Vault to retreive the username and password for the Domain_A specific service account, stores them in secure variables
function Get_<#Domain_A#>_SPNCredentials {

    Write-Output 'Fetching credentials for SPN service account'
    $remote_script_UserName = {
            param (
                [string]$role_id,
                [string]$secret_id
            ) 
        $env:VAULT_ADDR = "<#Vault environment address#>"
        $env:VAULT_NAMESPACE = '<#Vault environment#>'
        $role_id = Get-content -path <#Vault role id authentication file#>
        $secret_id = Get-content -path <#Vault secret id authentication file#>
        $vault_token = vault write -field=token /auth/approle/login role_id=$role_id secret_id=$secret_id
        $env:VAULT_TOKEN = $vault_token
        $env:VAULT_NAMESPACE = '<#Vault namespace#>'

        
        vault kv get -mount=kv -field=Username <#Domain_A#>
    
    }
    
    $remote_script_Password = {
        param (
            [string]$role_id,
            [string]$secret_id
        )
    
        $env:VAULT_ADDR = "<#Vault environment address#>"
        $env:VAULT_NAMESPACE = '<#Vault environment#>'
        $role_id = Get-content -path <#Vault role id authentication file#>
        $secret_id = Get-content -path <#Vault secret id authentication file#>
        $vault_token = vault write -field=token /auth/approle/login role_id=$role_id secret_id=$secret_id
        $env:VAULT_TOKEN = $vault_token
        $env:VAULT_NAMESPACE = '<#Vault namespace#>'
        
        
        vault kv get -mount=kv -field=Password <#Domain_A#>
    
    }
    
    $global:SPN_UserName = Invoke-Command -ComputerName $Remote_Server -ScriptBlock $remote_script_UserName -ArgumentList $roleid, $secret_id
    $global:SPN_Password = Invoke-Command -ComputerName $Remote_Server -ScriptBlock $remote_script_Password -ArgumentList $roleid, $secret_id
    $global:FQDN_Username = "<#Domain_A>\<Service_Account>"
}

#Function for <#Domain_B#> service account. Function calls Vault to retreive the username and password for the <#Domain_B#> specific service account, stores them in secure variables
function Get_<#Domain_B#>_SPNCredentials {

    Write-Output 'Fetching credentials for SPN service account'
    $remote_script_UserName = {
            param (
                [string]$role_id,
                [string]$secret_id
            ) 
        $env:VAULT_ADDR = "<#Vault environment address#>"
        $env:VAULT_NAMESPACE = '<#Vault environment#>'
        $role_id = Get-Content -path <#Vault role id authentication file#>
        $secret_id = Get-content -path <#Vault secret id authentication file#>
        $vault_token = vault write -field=token /auth/approle/login role_id=$role_id secret_id=$secret_id
        $env:VAULT_TOKEN = $vault_token
        $env:VAULT_NAMESPACE = '<#Vault namespace#>'

        
        vault kv get -mount=kv -field=Username <#Domain_B#>
    
    }
    
    $remote_script_Password = {
        param (
            [string]$role_id,
            [string]$secret_id
        )
    
        $env:VAULT_ADDR = "<#Vault environment address#>"
        $env:VAULT_NAMESPACE = '<#Vault environment#>'
        $role_id = <#Vault role id authentication file#>
        $secret_id = Get-content -path <#Vault secret id authentication file#>
        $vault_token = vault write -field=token /auth/approle/login role_id=$role_id secret_id=$secret_id
        $env:VAULT_TOKEN = $vault_token
        $env:VAULT_NAMESPACE = '<#Vault namespace#>'
        
        
        vault kv get -mount=kv -field=Password Shoremortgage
    
    }
    
    $global:SPN_UserName = Invoke-Command -ComputerName $Remote_Server -ScriptBlock $remote_script_UserName -ArgumentList $roleid, $secret_id
    $global:SPN_Password = Invoke-Command -ComputerName $Remote_Server -ScriptBlock $remote_script_Password -ArgumentList $roleid, $secret_id
    $global:FQDN_Username = "<#Domain_B#>\<ServiceAccount>"
}


#Function for server missing SPNs. Runs SQL query that will return all SPNs for instance. Possible SPNs include FQDN, FQDN with port, Named Instance, and AG listener with and without port
function Missing_SPN {
        $global:Generate_SPNs = Invoke-DbaQuery -SQLinstance $Server_Name -File "<#Path to SQL query to retrieve name of SPNs#>" | Select-Object -ExpandProperty Column1
        $global:Service_Account = Invoke-DbaQuery -SQLInstance $Server_Name -File "<#Path to SQL query to retrieve SQL Service Account" | Select-Object -ExpandProperty Column1 
}  

#Run SPN_Check function, returns true/false for logic below
Write-Output 'Checking if SPNs are missing on this computer'
$SPN_Check = SPN_Check

<#If/else logic for SPNs, if Missing SPN check is true, script checks which domain, retreieves the SPN commands to set SPN, calls Vault for domain service account
  and saves password in Secure String, then creates credential object for Username/password. Then iterates through all Missing SPN commands and executes them as
  Domain specific service account. 
  
  If SPNs are not missing, script exits with message no further action required
#>
if ($SPN_Check -like '*True*') {
    Write-Output 'SPNs are missing from this server, running fix'
    Missing_SPN
    $domain = (Get-CimInstance Win32_ComputerSystem).Domain

    if ($Service_Account -like '*<#Domain_B#>*') {
        Get_<#Domain_B#>_SPNCredentials
    }
    elseif ($Service_Account -like '*<#Domain_A#>*') {
        Get_<#Domain_A#>_SPNCredentials
    }
       
    $pass = ConvertTo-SecureString -AsPlainText $SPN_Password -Force
    $SecureString = $pass
    $MySecureCreds = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $FQDN_Username,$SecureString

    Write-Output 'Setting SPNs now'
    foreach ($SPN in $Generate_SPNs) {
        Set-DbaSpn -SPN $SPN -ServiceAccount $Service_Account -Credential $MySecureCreds
    }

}
else {
    Write-Output 'No missing SPNs were found, exiting script now'
    Exit
}
