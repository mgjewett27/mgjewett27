#####################################################################################
# This script will be used to automate the install of a SQL stand alone instance
# on a new server. This script focuses on setting up the SQL instance and databases
#     
#
#    2/15/2024 - Mike Jewett - Created script
#    3/11/2024 - Mike Jewett - Added automation to add Host to Redgate Monitor
#    2/25/2025 - Mike Jewett - Updated Redgate API calls to reflect new version
#    5/30/2025 - Mike Jewett - Added logic to handle multiple Redgate Base Monitors
#    6/04/2025 - Mike Jewett - Added logic to handle adding tags to SQL Instance
#    10/28/2025 - Arielle Bessala- Updated stage backup location to new Qumulo Cluster
#    11/4/2025 - Mike Jewett - Using Vault to securely store RedGate auth token credentials, rather than copying a plain text file
#####################################################################################


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


#Set host variables
[System.Net.Dns]::GetHostByName($env:COMPUTERNAME).HostName

$cluster_name = Get-WmiObject -Namespace root\cimv2 -Class Win32_ComputerSystem | Select -ExpandProperty Name
$domain_name = Get-WmiObject -Namespace root\cimv2 -Class Win32_ComputerSystem | Select -ExpandProperty Domain
$Hostname = "$cluster_name.$domain_name"
$MyConnection = Connect-DbaInstance -SqlInstance $Hostname -TrustServerCertificate
Import-Module <#Redgate API directory#>

#Update OLA jobs script to match the backup directory to the correct environment
Write-Output "Updating backup jobs to point to the correct Qumulo location" 
#Update if Dev server
if ($Hostname -like <#Dev server identifier#>) {
$dev_backup = "@Directory = <#Location for Dev backup files#>"
$string = Get-Content -Path <#SQL Script to create backup jobs#>
$replace_backup = $string.Replace("##BACKUP_LOCATION##",$dev_backup)
Set-Content -Path <#SQL Script to create backup jobs#> $replace_backup
}

    #Update if Stage server
    elseif($Hostname -like <#Integration server identifier#>) {
        $int_backup = "@Directory = <#Location for Integration backup files#>"
        $string = Get-Content -Path <#SQL Script to create backup jobs#>
        $replace_backup = $string.Replace("##BACKUP_LOCATION##",$int_backup)
        Set-Content -Path <#SQL Script to create backup jobs#> $replace_backup
    }

        #Update if Stage server
        elseif($Hostname -like <#Staging server identifier#>) {
            $stg_backup = "@Directory = ''\\sqlbackup\sql_stg_bak$"
            $string = Get-Content -Path <#SQL Script to create backup jobs#>
            $replace_backup = $string.Replace("##BACKUP_LOCATION##",$stg_backup)
            Set-Content -Path <#SQL Script to create backup jobs#> $replace_backup
        }
        
            #Update if Prod server
            elseif($Hostname -like <#Production server identifier#>) {
                $prd_backup = "@Directory = ''\\sqlbackup\sql_prd_bak$"
                $string = Get-Content -Path <#SQL Script to create backup jobs#>
                $replace_backup = $string.Replace("##BACKUP_LOCATION##",$prd_backup)
                Set-Content -Path <#SQL Script to create backup jobs#> $replace_backup
            }


#Create PerfDB database 
Write-Output "Creating PerfDB database on $Hostname" 
New-DbaDatabase -SQLInstance $MyConnection -Name PerfDB -RecoveryModel Simple -Owner sa 

#Run OLA Maintenance Scripts
Write-Output "Executing maintenance scripts against $Hostname" 
Invoke-DbaQuery -SQLInstance $MyConnection -Database PerfDB -File <#OLA Maintenance job script#>
Invoke-DbaQuery -SqlInstance $MyConnection -Database PerfDB -File <#OLA Maintenance job script#>
Invoke-DbaQuery -SqlInstance $MyConnection -Database PerfDB -File <#OLA Maintenance job script#>
Invoke-DbaQuery -SqlInstance $MyConnection -Database PerfDB -File <#OLA Maintenance job script#>
Invoke-DbaQuery -SqlInstance $MyConnection -Database PerfDB -File <#OLA Maintenance job script#>
Invoke-DbaQuery -SqlInstance $MyConnection -Database msdb -File <#OLA Maintenance job script#>
Invoke-DbaQuery -SqlInstance $MyConnection -Database msdb -File <#SQL script to create backup jobs#>
Invoke-DbaQuery -SqlInstance $MyConnection -Database PerfDB -File <#Custom SQL Maintenance job scripts#>
Invoke-DbaQuery -SqlInstance $MyConnection -Database PerfDB -File <#Custom SQL Maintenance job scripts#>
Invoke-DbaQuery -SqlInstance $MyConnection -Database PerfDB -File <#Custom SQL Maintenance job scripts#>
Invoke-DbaQuery -SqlInstance $MyConnection -Database PerfDB -File <#Custom SQL Maintenance job scripts#>
Invoke-DbaQuery -SqlInstance $MyConnection -Database PerfDB -File <#Custom SQL Maintenance job scripts#>


#Enable maintenance jobs
Write-Output "Maintenance scripts run successfully, enabling backup jobs now" 
Invoke-DbaQuery -SQLInstance $MyConnection -Database "msdb" -Query "EXEC dbo.sp_update_job @job_name = N'<#Full system backup job#>', @enabled = 1;"
Invoke-DbaQuery -SQLInstance $MyConnection -Database "msdb" -Query "EXEC dbo.sp_update_job @job_name = N'<#TLOG system backup job#>', @enabled = 1;"
Invoke-DbaQuery -SQLInstance $MyConnection -Database "msdb" -Query "EXEC dbo.sp_update_job @job_name = N'<#Full user backup job#>', @enabled = 1;" 
Invoke-DbaQuery -SQLInstance $MyConnection -Database "msdb" -Query "EXEC dbo.sp_update_job @job_name = N'<#TLOG user backup job#>', @enabled = 1;" 
Invoke-DbaQuery -SQLInstance $MyConnection -Database "msdb" -Query "EXEC dbo.sp_update_job @job_name = N'<#Index maintenance job#>', @enabled = 1;" 
Write-Host "Backup jobs enabled successfully" 
#Disabling sa login
Write-Output "Disabling sa login" 
Invoke-DbaQuery -SQLInstance $MyConnection -Query "Alter Login sa DISABLE;"

#Adding Redgate service account to logins and as sa on instance
Write-Output "Adding RedGate service account to instance and granting permissions" 
New-DbaLogin -SqlInstance $MyConnection -Login <#Red Gate Service Account#>
Set-DbaLogin -SqlInstance $MyConnection -Login <#Red Gate Service Account#> -AddRole sysadmin

#Exit script complete
Write-Host "SQL server has been fully configured and setup on $Hostname, make sure to double check everything is correct" 

#Add SQL Host to Redgate Monitor
Write-Output "Adding SQL Host to Redgate Monitor"
$dev_monitor_group = '4 - Development'
$int_monitor_group = '3 - Integration'
$stg_monitor_group = '2 - Staging'
$prd_monitor_group = '1 - Production'
$mssn_crt_monitor_group = '0 - Mission Critical'

if ($Hostname -like <#Staging Server Identifier#>) {
    $sqlMonitorGroup = $stg_monitor_group
}
    elseif ($Hostname -like <#Development Server Identifier#>) {
        $sqlMonitorGroup = $dev_monitor_group
    }
    elseif ($Hostname -like <#Integration Server Identifier#>) {
        $sqlMonitorGroup = $int_monitor_group   
    }
    else {
        $prod_choice = Read-Host "Is this server Mission Critical? (Y/N)"

        if ($prod_choice -like "Y") {
            $sqlMonitorGroup = $mssn_crt_monitor_group
        }
        elseif ($prod_choice -like "N") {
            $sqlMonitorGroup = $prd_monitor_group
        }
        else {
            Throw "ERROR: Input not recognized, exiting script now"
        }
    }
#Get RedGate Monitor Auth Token from Vault, use it to connect to Redgate Monitor
    $env:VAULT_ADDR = <#Vault address#>
    $env:VAULT_NAMESPACE = <#Vault namespace#>
    $role_id = Get-Content -Path <#Role id file#>
    $secret_id = Get-Content -Path <#Secret id file#>
    $vault_token = vault write -field=token /auth/approle/login role_id=$role_id secret_id=$secret_id
    $env:VAULT_TOKEN = $vault_token
    $env:VAULT_NAMESPACE = <#Vault namespace#>
    $RG_Auth_Token = vault kv get -mount kv -field=Auth_Token RedGateMonitor

#$Auth_token = Get-Content -Path 'C:\Source\RedgateMonitor\Redgate_AuthToken.txt'
Connect-RedgateMonitor -ServerUrl <#Redgate Monitor URL#> -AuthToken $RG_Auth_Token

$BaseMonitor = Get-SqlMonitorBaseMonitor -Name 'localhost'
$Group = Get-SqlMonitorGroup $sqlMonitorGroup -BaseMonitor $BaseMonitor

$server = New-SqlMonitorWindowsHost `
    -HostName "$Hostname" `
    -BaseMonitor $BaseMonitor `
    -Group $Group
$server | Add-SqlMonitorMonitoredObject

if ($? -eq 'True') {
    Write-Output "SQL Host added to Redgate Monitor Successfully"
}

    else {
        Throw "Adding host to Redgate Monitor failed, please check output to determine issue."
    }
