#####################################################################################
# This script will be used to help with SQL Server DBA Patch Nights.
#      This was created in relation to https://kb.uwm.com/display/TDBA/DBAPCH003+-+YYYY-MM-DD+%5BPatch+night%5D+-+Automated+-+Template
#     
#
#   01/21/2022    Mike Wilson - Created the script. 
#   01/28/2022    Mike Wilson - updated variables to prod. Added some messages related to some bugs. 
#   02/07/2022    Mike Wilson - Broke out the cluster service stop, and failvoer functions into 1 function.  
#                               This function will invoke-command to run run the cluster admin tools local to a server.
#   02/15/2022    Mike Wilson - Updated the path for option #5 from the sql audit folder to C:\SOURCE\DBA_Scripts\.
#   03/22/2022    Mike Wilson - Changed the date to a variable to fix a date comparision issue during pre/post patch checks.
#							    Created a temp array of an existing array in order to fix error - "Collection was modified; enumeration operation may not execute." 
#								This was caused when trying to remove an object from an array that's in use. 
#   02/13/2024    Mike Jewett - Updating failover function to now automatically failover list of clusters to their new active node
#   12/16/2024    Mike Jewett - Added pre and post health check for MSDTC on all production clusters
#   03/19/2025    Mike Jewett - Reworked the script. Using DBATools module to run the SQL commands. All servers run concurrently instead of in foreach loop.
#####################################################################################

#Set TrustServerCertificate to true for DBATools connections
Set-DbatoolsConfig -FullName sql.connection.trustcert -Value $true -Register

# Variables for all instances.  Update these if the servers or named instances are rebuilt. 


#Set DTC Server list variables
[System.Collections.ArrayList]$SrvList = @()
$SrvList = @(Get-Content -Path <#List of servers with DTC configured#>)

#Set array of production instances, used for full backup management
$PRD_INST_ARRAY= <#Instances to check as part of patching#>


#Final variable. Update this to prd, stage or test as needed. 
$INST_ARRAY= $PRD_INST_ARRAY


#Query variables
$CLUS_CHECK_QUERY="SELECT @@servername as ServerName, NodeName, status, status_description, is_current_owner FROM sys.dm_os_cluster_nodes"
$DB_HEALTH_CHECK="SELECT @@servername as ServerName, NAME as DBName, user_access_desc as User_Access, STATE_DESC as State, delayed_durability_desc as Delayed_Durability FROM SYS.DATABASES"

#Setting an audit log folder.
$AUDIT_DIR='C:\SOURCE\DBA_PS_Audits'

#Check and create audit log folder.
$DIR_EXISTANCE=Test-Path $AUDIT_DIR

Write-Host "`n`n######################################"
Write-Host "Welcome to the DBA Patching script."
Write-Host "######################################`n`n"

IF ($DIR_EXISTANCE -eq 'True' )
    {
        Write-Host "SUCCESS: The Audit logging directory can be found at: $AUDIT_DIR."
    }
ELSE 
    {
        Write-Host "WARNING: The Audit logging directory does not exist. Creating it."
        #Create path for audit log location.
        New-Item -Path $AUDIT_DIR -ItemType Directory 

        $DIR_EXISTANCE=Test-Path $AUDIT_DIR
        IF ($DIR_EXISTANCE -eq 'True' )
           {
               Write-Host "SUCCESS: Audit logging directory successfully created and can be found at: $AUDIT_DIR."
           }
        ELSE
            {
                 throw "ERROR: Issues with creating the audit logging directory at $AUDIT_DIR."
            }
       } 

#DATE
$global:DATE=(get-date -f yyyy-MM-dd)
#Start logging all output and selections made while script is running
Start-Transcript -Path "$AUDIT_DIR\DBA_PATCHING_$(HOSTNAME)_$DATE.txt" -Append


##################################################################################################
# Function section.  The user's choice will call a function to perform the action requested. 
##################################################################################################
#choice number 1 - perform overall health check. 
function HealthCheckFunc
    {
        Write-Host "############################################################################"
        Write-Host "Welcome to the health check function."
        Write-Host "This function will gather cluster node information, along with DB health info such as DB Name, state, user access and more."
        Write-Host "############################################################################"

        #Checks below are looking for which node is the owner of the cluster and information on all databases in the instances, will be compared to post failovers to see if any issues arise.
        Write-Host "Performing pre-patching checks on Production clusters."
                Write-Host "############################################"
                Write-Host "Obtaining cluster node information for each cluster."
                Invoke-DbaQuery -SqlInstance $PRD_INST_ARRAY -Database "master" -Query $CLUS_CHECK_QUERY | format-table ServerName, nodename, status, status_description, is_current_owner | Tee-Object -FilePath "$AUDIT_DIR\$(HOSTNAME)_pre_cluster_healthcheck_$DATE.txt" -Append

                
                Write-Host "Performing a full database Health Check for each instance" 
                Invoke-DbaQuery -SqlInstance $PRD_INST_ARRAY -Database "master" -Query $DB_HEALTH_CHECK | format-table ServerName, DBName, User_Access, State, Delayed_Durability | Tee-Object -FilePath "$AUDIT_DIR\$(HOSTNAME)_pre_db_healthcheck_$DATE.txt" -Append

                #This check is a grid of DTC settings per cluster, will be compared at the end to verify settings look the same post failover
                Write-Host "Performing pre-patching MSDTC Check"
                Invoke-Command -ComputerName $SrvList -FilePath C:\code\dba-scripts\dba-scripts\Jewett_Scripts\PowerShell\Patching\Development\DTC_Configuration.ps1 | Tee-Object -FilePath "$AUDIT_DIR\$(HOSTNAME)_pre_DTC_check_$DATE.txt" -Append

        #Share the list of output files for review if necessary. 
        Write-Host "##################################################################################################################"
        Write-Host "SUMMARY: A pre-patching cluster healthcheck file has been saved to $AUDIT_DIR\$(HOSTNAME)_pre_cluster_healthcheck_$DATE.txt"
        Write-Host "SUMMARY: A DB health check output file has been saved to $AUDIT_DIR\$(HOSTNAME)_pre_db_healthcheck_$DATE.txt"
        Write-Host "SUMMARY: A pre-patching MSDTC health check has been saved to $AUDIT_DIR\$(HOSTNAME)_pre_DTC_check_$DATE.txt"
        Write-Host "##################################################################################################################`n"
         
    } # End of HealthCheck function.



#choice number 2 - disable delayed durability on certain production instances.
#Function will execute the SQL Agent Jobs to disable delayed durability on the certain databases in the instances.
#Check of job execution status will determine if the command ran successfully or not.
function DelayDurability_disable_func
    {
        # This needs to be ran against instances with Delayed_Durability forced on certain databases.  The job isn't scheduled elsewhere at this time. 
        $DD_DISABLE_ARRAY= <#Instance array#>        

            Write-Host "`n############################################################################"
            #Execute the Delayed Durability Disable job
            Write-Host "Executing job Maint: DELAYED_DURABILITY = DISABLED on SQL Instances.`n"
            Invoke-DbaQuery -SqlInstance $DD_DISABLE_ARRAY -Database "msdb" -Query "EXEC dbo.sp_start_job N'Maint: DELAYED_DURABLITY = DISABLED'"
            if ($? -eq 'True' )
                {
                    Start-Sleep -Seconds 5 # put in place such the script to not pick up an older runtime for the below query.   
                    $DD_JOB_CHECK_QUERY="select distinct top(1)
                                        @@servername as ServerName,
                                        j.name as 'JobName',
                                        run_date,
                                        run_time,
                                        case h.run_status 
                                        when 0 then 'Failed' 
                                        when 1 then 'Successful' 
                                        when 3 then 'Cancelled' 
                                        when 4 then 'In Progress' 
                                        end as JobStatus,
                                        msdb.dbo.agent_datetime(run_date, run_time) as 'RunDateTime'
                                    From msdb.dbo.sysjobs j 
                                    INNER JOIN msdb.dbo.sysjobhistory h 
                                    ON j.job_id = h.job_id 
                                    where j.name = '<#Delayed durability maintenance job#>'
                                    order by JobName, RunDateTime desc"

                    #Verify Job executed successfully
                    Write-Host "Validating that delayed durability maintenance job was ran.`n"
                    Invoke-DbaQuery -SqlInstance $DD_DISABLE_ARRAY -Database "msdb" -Query $DD_JOB_CHECK_QUERY | format-table ServerName, JobName, JobStatus, RunDateTime
                    Start-Sleep -Seconds 2
                    
                    #Checking status of job on each instance, returning Successful or not. 'if' statement checks for phrase Successful to determine if agent job ran successfully.
                    $DD_JOB_RUNTIME_CHECK = Invoke-DbaQuery -SqlInstance $DD_DISABLE_ARRAY -Database "msdb" -Query $DD_JOB_CHECK_QUERY | Select-Object -expand JobStatus
                         if ($DD_JOB_RUNTIME_CHECK -contains 'Successful'  )
                            {
                                Write-Host "SUCCESS: The delayed durability maintenance job has been verified as successful."
                            }
                        elseif ($DD_JOB_RUNTIME_CHECK -notcontains 'Successful' )
                            {
                                Write-Host "WARNING: The delayed durability maintenance job did not recieve output while trying to run query $DD_JOB_CHECK_QUERY."
                                Write-Host "WARNING: The SQL Agent job history most likely did not get populated. Please manually check."
                            }
                        else
                            {
                                Write-Host "ERROR: This failed with a value of: $DD_JOB_RUNTIME_CHECK ." 
                                throw "ERROR: Issues with verifying the delayed durability maintenance job. Please investigate."
                                exit
                            }
                }
            else 
                {
                    Throw "ERROR: delayed Durability maintenance job failed. Please investigate.`n"
                    exit    
                }
            Write-host "`nSUMMARY: Overall, job 'Maint: DELAYED_DURABLITY = DISABLED' was disabled and verified as disabled on servers: SHORE1 and SHORE6"
            Write-Host "############################################################################`n" 
    } # End of DelayDurability_Func function.



#choice number 3 - disable TLOG backups on production instances.
function disable_TLOG_func
    {
        #This needs to be ran against shore1 & 6 only. 
        $DISABLE_TLOG_ARRAY= <#Array of instances#>

                #Disable TLOG backups on the instance
                Write-Host "`n############################################################################"
                Write-Host "Disabling the transaction log backup job on SQL instances.`n"
                Invoke-DbaQuery -SqlInstance $DISABLE_TLOG_ARRAY -Database "msdb" -Query "EXEC dbo.sp_update_job @job_name = N'<#TLOG Backup job name#>', @enabled = 0;"
                if ($? -eq 'True' )
                    {
                        #Verify TLOG backups have been disabled
                        Write-Host "Verifying job TLOG Backup job is disabled.`n"

                        #Check of the status of the TLOG backup jobs on SHORE1 and SHORE6. Enabled jobs have a value of '1', disabled '0'. Returns the value of job staus and if '0' job is diabled and can continue
                        $TLOG_ENABLED_CHECK = Invoke-DbaQuery -SqlInstance $DISABLE_TLOG_ARRAY -Database "msdb" -Query "EXEC dbo.sp_help_job @job_name = N'<#TLOG backup job#>', @job_aspect = N'JOB'" | Select-Object -expand enabled
                        IF ($TLOG_ENABLED_CHECK -contains 1 )
                            {
                                THROW "WARNING: The TLOG backup job is still enabled. Please investigate."
                            }
                        ELSE{
                                Write-Host "SUCCESS: TLOG backup job has been verfified as disabled." 
                        }
                    }
                else 
                    {
                        Throw "ERROR: The TLOG backup job has failed to disable. Please investigate.`n"
                        exit    
                    }
         Write-host "############################################################################"
         Write-host "`nSUMMARY: Overall, TLOG Backup job was disabled and verified as diabled on SQL instances"
         Write-Host "############################################################################`n" 
    } # End of disable tlog function.



#choice number 4 - stop backup jobs. Typically on production SQL instances.
# This will check all instances, see if the backup job is running, and if it is, terminate it. 
# It will then store the instance to a backup file, which will be referenced in choice 6 to restart the killed backup jobs. 

function Stop_Backup_Jobs_func
    {
        Write-Host "####################################################################################"
        Write-Host "Welcome to the stop backup jobs function."
        Write-Host "####################################################################################"
        
        $STOP_BACKUP_JOB_INSTS_ARRAY = $INST_ARRAY
        #$STOP_BACKUP_JOB_INSTS_ARRAY = $TEST_INST #Testing purposes

        #create arrayList. Global makes this useable in other functions.
        $global:DB_JOB_STOP_ARRAY = New-Object -TypeName 'System.Collections.ArrayList'

        foreach ( $INST in $STOP_BACKUP_JOB_INSTS_ARRAY )
            {
                
                #See if backup is running.
                [int]$BACKUP_JOB_STATUS = Invoke-Sqlcmd -ServerInstance $INST -Database "msdb" -Query "EXEC dbo.sp_help_job @job_name = N'<#Full backup job name#>', @job_aspect = N'JOB'" -TrustServerCertificate | Select-Object -expand current_execution_status
                
               #Depending on status of the job, stopped jobs can continue, running jobs will be stopped and the instance added to an array. That array can be used to restart full backup jobs post patching 
               Write-Host "`nChecking to see if Full backup job on $INST is running.`n"
               if ( $BACKUP_JOB_STATUS -eq 4 )
                    {
                        Write-Host "SUCCESS: The Full backup job is not active on $INST. No action needed."
                    }
                elseif (  $BACKUP_JOB_STATUS -eq 1 )
                    {
                            Write-Host "`nBackup job - Full backup job is currently running on $INST. Stopping it.`n"
                            Invoke-Sqlcmd -ServerInstance $INST -Database "msdb" -Query "EXEC dbo.sp_stop_job N'<#Full backup job name#>'" -TrustServerCertificate
                            [int]$BACKUP_JOB_STATUS = Invoke-Sqlcmd -ServerInstance $INST -Database "msdb" -Query "EXEC dbo.sp_help_job @job_name = N'<#Full backup job name#>', @job_aspect = N'JOB'" -TrustServerCertificate | Select-Object -expand current_execution_status
                            if ($? -eq 'True' )
                                {
                                    Write-Host "`nSUCCESS: The Full backup job has successfully stopped on $INST."
                                    Write-Host "`nVerifying that the Full backup job is stopped on $INST. Please wait up to a minute for this to run."
                                    
                                    Start-Sleep -Seconds 15

                                    [int]$BACKUP_JOB_STATUS_CHK=Invoke-Sqlcmd -ServerInstance $INST -Database "msdb" -Query "EXEC dbo.sp_help_job @job_name = N'<#Full backup job name#>', @job_aspect = N'JOB'" -TrustServerCertificate | Select-Object -expand current_execution_status
                                    if ( $BACKUP_JOB_STATUS_CHK -eq 4 )
                                        {
                                            Write-Host "SUCCESS: Validated that Full backup job was stopped, and is idle on $INST."
                                            Write-Host "Adding a record to an array, so it can be referenced when we need to restart the backup job afterwards." 
                                            $DB_JOB_STOP_ARRAY.add($INST)
                                            Write-Host "$INST has been added to Array: $DB_JOB_STOP_ARRAY"
                                        }
                                else
                                    {
                                        write-host "Error: $BACKUP_JOB_STATUS_CHK"
                                        Throw "ERROR: Issues with trying to validate that Full backup job was stopped on $INST. Please investigate."
                                        exit 
                                    }
                                } 
                    } #end of backup check where the job is running. 
                else
                    {
                        Throw "ERROR: The Full backup job has failed to stop on $INST. Please investigate."
                         exit
                    }
                                     
            } #end of foreach loop.
        Write-Host "####################################################################################"
    } #end of stop backup job function.


#choice number 5 - admin a cluster. This allows one to failover a cluster, or start/stop/verify a sql cluster role.
function cluster_failover_func
    {
    #Get cluster name for each server in desired active server list
    #Place cluster names in Cluster file
    Write-Host "Gathering cluster names from list of servers provided`n"
    $Prod_Servers = Get-Content C:\source\DBA_Scripts\Patching\Prod_Patching\Prod_Servers.txt
    $Cluster_info = @{
        ComputerName = $Prod_Servers
        FilePath = C:\source\DBA_Scripts\Patching\Script_components\Cluster_info.ps1
    }
    Invoke-Command @Cluster_info | Out-File -FilePath C:\source\DBA_Scripts\Patching\Prod_Patching\Clusters.txt -Append
    Start-Sleep -Seconds 2
    
    #Get list of owner nodes pre failover, append them to file
    Write-Host "Finding current active node of each cluster`n"
    $Active_Node = @{
        Cluster_Name = (Get-Content -Path C:\source\DBA_Scripts\Patching\Prod_Patching\Clusters.txt)
        FilePath = C:\source\DBA_Scripts\Patching\Script_components\Cluster_group.ps1
    }
    Invoke-Command @Active_Node | Out-file -FilePath C:\source\DBA_Scripts\Patching\Prod_Patching\Owner_node_PRE_failover.txt -Append
    Start-Sleep -Seconds 2

    #Get full name of cluster role, append to file to use for failovers
    Write-Host "Finding full name of cluster role for failover"
    $Cluster_Role = @{
        Cluster_Name = (Get-Content -Path C:\source\DBA_Scripts\Patching\Prod_Patching\Clusters.txt)
        FilePath = C:\source\DBA_Scripts\Patching\Script_components\Cluster_role.ps1
    }
    Invoke-Command @Cluster_Role | Out-file -FilePath C:\source\DBA_Scripts\Patching\Prod_Patching\cluster_group.txt -Append
    Start-Sleep -Seconds 2


    #Compare length of sever file and cluster file, make sure each server has a matching cluster
    Write-Host "Making sure cluster and server information match up`n"
        $Server_file_length = Get-Content -Path C:\source\DBA_Scripts\Patching\Prod_Patching\Prod_Servers.txt | Measure-Object -Line | Select-Object -ExpandProperty Lines
        $Cluster_file_length = Get-Content -Path C:\source\DBA_Scripts\Patching\Prod_Patching\Clusters.txt | Measure-Object -Line | Select-Object -ExpandProperty Lines

    if ($Server_file_length -eq $Cluster_file_length) {
        Write-Host "Server and cluster files are 1 for 1, continuing with failovers"
    } 
        else {
            Write-Host "Mismatch in files, please review cluster and server files for discrepancy"
        }
Start-Sleep -Seconds 2

    #Create array from server file and cluster file
    $Server_Array = @(Get-Content C:\source\DBA_Scripts\Patching\Prod_Patching\Prod_Servers.txt)
    $Cluster_Array = @(Get-Content C:\source\DBA_Scripts\Patching\Prod_Patching\Clusters.txt)
    $Cluster_group_Array = @(Get-Content C:\source\DBA_Scripts\Patching\Prod_Patching\cluster_group.txt)

    #Loop through arrays, failing over the current cluster to its desired active node
    Write-Host "Beginning cluster failovers`n"
        for($i=0; $i -lt $Server_Array.Length; $i++) {
    
            #confirm you want to fail over
            $Failover_Choice = Read-Host "You are about to failover cluster $($Cluster_Array[$i]), would you like to continue? (Y/N)"

            #Iterate through array, failing over $i cluster to $i server, then increment $i until end of array
            if ($Failover_Choice -like "Y") {
                Move-ClusterGroup -Cluster $($Cluster_Array[$i]) -Name $($Cluster_group_array[$i]) -Node $($Server_Array[$i]) > null
                Write-Host "Failover of $($Cluster_Array[$i]) complete, moving to next cluster in list`n"
            }
            elseif ( $Failover_Choice -like "N" ) {
		        Write-Host "NOTE: You selected not to failover. Moving to next cluster."
	        }
	        else
	        {
		        Throw "ERROR: You did not input a correct value. exiting." 
	        }
        }

    #Get list of owner nodes post failover, append them to file
    Write-Host "Checking active node of each cluster post failover`n"
    $Active_Node_POST = @{
        Cluster_Name = (Get-Content -Path C:\source\DBA_Scripts\Patching\Prod_Patching\Clusters.txt)
        FilePath = C:\source\DBA_Scripts\Patching\Script_components\Cluster_group.ps1
    }
    Invoke-Command @Active_Node_POST | Out-file -FilePath C:\source\DBA_Scripts\Patching\Prod_Patching\Owner_node_POST_failover.txt -Append

    #Load pre_failover server file and compare it to post_failover server file, return servers that were already active before script and need a failover to occur still.
    $Pre_Failover_owners = (Get-Content -Path C:\source\DBA_Scripts\Patching\Prod_Patching\Owner_node_PRE_failover.txt)
    $Post_Failover_owners = (Get-Content -Path C:\source\DBA_Scripts\Patching\Prod_Patching\Owner_node_POST_failover.txt)

    Write-Host "The below servers were already active nodes, no failover occured yet. Make sure to manually fail node over and back.`n If no results below, all failovers were completed to a new node successfully."
    Compare-Object -ReferenceObject $Pre_Failover_owners -DifferenceObject $Post_Failover_owners -IncludeEqual -ExcludeDifferent | Select-Object -ExpandProperty InputObject


    #Cleanup files used in process, will be created next time script is run
    $Cleanup_Choice = Read-Host "Failovers complete, would you like to delete files used in this script run? (Y/N)"

        if ($Cleanup_Choice -like "Y") {
    
            Write-Host "Deleting files now"
            Remove-Item -Path C:\source\DBA_Scripts\Patching\Prod_Patching\cluster_group.txt
            Remove-Item -Path C:\source\DBA_Scripts\Patching\Prod_Patching\Clusters.txt
            Remove-Item -Path C:\source\DBA_Scripts\Patching\Prod_Patching\Owner_node_PRE_failover.txt
            Remove-Item -Path C:\source\DBA_Scripts\Patching\Prod_Patching\Owner_node_POST_failover.txt
        }
        elseif ( $Cleanup_Choice -like "N" )
        {
		    Write-Host "NOTE: You selected not to clean up files. Exiting."
	    }
	    else {
		    Throw "ERROR: You did not input a correct value. exiting." 
	    }

    Write-Host "Failovers complete, returning to menu."

    } #end of function.




#choice number 6 - restart backup jobs. Typically on certain prodution instances. 
function restart_backup_jobs_func
    {
		Write-Host "#################################################################"
        Write-Host "Welcome to the restart backup jobs function."
        Write-Host "This typically needs to occur on production instances."
        Write-Host "#################################################################"
		
        #Create an temp array of the DB stop Job array. This resolve an error we saw - Collection was modified; enumeration operation may not execute.
        $TEMP_JOB_RESTART_ARRAY = $DB_JOB_STOP_ARRAY.ToArray()

        #loop through the list. ask if you want to restart the job or not. 
			   Write-Host "####################################################################################"
               Write-Host "`nJob Maint: backup_databases_USER_FULL was terminated earlier."
               $BACKUP_RESTART = Read-host "Would you like to restart stopped Full backup jobs. ( Y / N )"
               if ( $BACKUP_RESTART -like "Y" )
                {
                    Invoke-DbaQuery -SqlInstance $TEMP_JOB_RESTART_ARRAY -Database "msdb" -Query "EXEC dbo.sp_start_job N'<#Full backup job name#>'" -AppendServerInstance
			        Write-Host "Job has been rerstarted. Waiting 1 minute to check and verify the job is still running."
			   
                    Start-Sleep -Seconds 45 #give time to verify the job is running, and not failing right after kicking off the job. 

			        #Verify that the backup job is running.
                    [int]$BACKUP_JOB_STATUS = Invoke-DbaQuery -SqlInstance $TEMP_JOB_RESTART_ARRAY -Database "msdb" -Query "EXEC dbo.sp_help_job @job_name = N'<#Full backup job name#>', @job_aspect = N'JOB'" -AppendServerInstance | Select-Object -expand current_execution_status
               
                    Write-Host "`nVerifying backup job Maint: backup_databases_USER_FULL is running.`n"
                       if ( $BACKUP_JOB_STATUS -contains 1 )
                         {	
                            Write-Host "SUCCESS: The Full backup job is running."
                         }
				        else
					      {
						    throw "ERROR: The The Full backup job is not running. Please investigate."
					      }

                        }
                elseif ( $BACKUP_RESTART -like "N" )
                    {
                        Write-Host "WARNING: You selected NOT to restart full backup job. Skipping."
                    }
                else
                    {
                          throw "ERROR: A non Y / N character was inputted. Please retry the script." 
                    }

        Write-Host "####################################################################################"
    } #end of backup restart function

#choice number 7 - restart delayed durability for production instances. 
function restart_dd_func
    {
        Write-Host "#############################################################################"
        Write-Host "Welcome to the Delayed Durability maintenace job function."
        Write-Host "#############################################################################"
        
        $DD_ENABLE_ARRAY= $SHORE1, $SHORE6
        

                #Prompt to start the delayed durability job.
                $DD_FORCED_PROMPT = Read-host "Would you like to start job '<#Delayed durability maintenance job#>'. ( Y / N )"
                IF ( $DD_FORCED_PROMPT -like "y" )
                {
                #Execute the Delayed Durability Disable job
                Write-Host "Executing Delayed Durability maintenance job.`n"
                Invoke-DbaQuery -SqlInstance $DD_ENABLE_ARRAY -Database "msdb" -Query "EXEC dbo.sp_start_job N'<#Delayed durability maintenance job#>'" -AppendServerInstance
                if ($? -eq 'True' )
                    {
                        #Verify Job executed successfully
                        Write-Host "`nVerifying the Delayed Durability maintenance job is enabled on.`n"
                        
                        Invoke-DbaQuery -SqlInstance $DD_ENABLE_ARRAY -Database "msdb" -Query "EXEC dbo.sp_help_jobactivity @job_name = N'<#Delayed durability maintenance job#>'" -AppendServerInstance  | format-list
                        $DD_FORCED_CHK = Invoke-DbaQuery -SqlInstance $DD_TLOG_ARRAY -Database "msdb" -Query "EXEC dbo.sp_help_job @job_name = N'<#Delayed durability maintenance job#>'"  | Select-Object -expand Enabled
                        if ($DD_FORCED_CHK -contains 1 )
                            {
                                Write-Host "SUCCESS: The delayed durability disabled FORCED job has been verified as enabled."
                            }
                        else
                            {
                                Write-Host "ERROR: Issues with verifying the delayed durability disable job. Please investigate."
                                exit
                            }

                    }
                } 
                elseif ( $DD_FORCED_PROMPT -like "n" )
                    {
                        Write-Host "WARNING: You selected to not restart the delayed durability job. Please remember to run this when the time is ready."
                    }
                else
                    {
                        write-host "ERROR: A non Y/N choice was inputted. skipping."
                    }
            #End of foreach loop for delayed durability forced.
    }#end of Delayed Durability forced function

#choice number 8 - to restart tlog jobs.
function enable_TLOG_func
    {
        #This needs to be ran against production instances. 
        $ENABLE_TLOG_ARRAY= <#SQL Instances#>
        #$ENABLE_TLOG_ARRAY = $TEST_INST

        Write-Host "`n############################################################################"
                 #Enable TLOG backups on the instance
                 $TLOG_RESTART = Read-host "Would you like to restart job '<#TLOG Backup job name#>' on production instances ( Y / N )"
                 if ( $TLOG_RESTART -like "Y" )
                    {
                        Write-Host "Attempting to enable the TLOG backup job.`n"
                        Invoke-DbaQuery -SqlInstance $ENABLE_TLOG_ARRAY -Database "msdb" -Query "EXEC dbo.sp_update_job @job_name = N'<#TLOG Backup job name#>', @enabled = 1;"
                        if ($? -eq 'True' )
                            {
                                #Verify TLOG backups have been enabled
                                Write-Host "Verifying TLOG backup job is enabled.`n"


                                $TLOG_ENABLED_CHECK = Invoke-DbaQuery -SqlInstance $ENABLE_TLOG_ARRAY -Database "msdb" -Query "EXEC dbo.sp_help_job @job_name = N'<#TLOG Backup job name#>', @job_aspect = N'JOB'" | Select-Object -expand enabled
                                IF ($TLOG_ENABLED_CHECK -contains 1 ) 
                                    {
                                        Write-Host "SUCCESS: Job '<#TLOG Backup job name#>' has been verfified as enabled." 
                                    }

                                ELSE 
                                    {
                                        Throw "ERROR: Job '<#TLOG Backup job name#>' has not been enabled. Please investigate.`n"
                                    }

                            }
               } # End of if statement if user selects Y.
            elseif ( $TLOG_RESTART -like "N" )
                {
                    Write-host "WARNING: You selected NOT to run the job on $INST. Please remember to run it when ready."
                }
            else
                {
                    throw "ERROR: User did not select a valid Y/N choice. Exiting."
                }
    } #end of re-enable TLOG backup function


#choice number 9 - schedule freeproccache on production instances. 
function schedule_freeproccache_func
    {
        $FREEPCCACHE_ENABLE= <#Production Instances#>
        #$FREEPCCACHE_ENABLE = $TEST_INST

        Write-Host "`n############################################################################"
                #Enable Freeproccache jobs on shore1 & shore6.
                $FREEPCCACHE_ENABLE_CHOICE = Read-host "Would you like to schedule job '<#Free procedure cache job name#>' on production instances. ( Y / N )"
                if ( $FREEPCCACHE_ENABLE_CHOICE -like "Y" )
                    {
                        $FPC_START_DATE = Read-Host "Please enter the date you want job '<#Free procedure cache job name#>' enabled in the format of YYYYMMDD (e.g. 20220116):"
                        Write-Host "`nScheduling job '<#Free procedure cache job name#>' to run on $FPC_START_DATE, at 6:00am"
                        Invoke-DbaQuery -SqlInstance $FREEPCCACHE_ENABLE -Database "msdb" -Query "EXEC dbo.sp_update_schedule @name = N'<#Free procedure cache job name#>', @active_start_date = $FPC_START_DATE, @enabled = 1, @active_start_time = 060000"

                        Write-Host "`nVerifying that job '<#Free procedure cache job name#>' is enabled to run at 6am on $FPC_START_DATE."
                        Invoke-DbaQuery -SqlInstance $FREEPCCACHE_ENABLE -Database "msdb" -Query "EXEC dbo.sp_help_job @job_name = N'<#Free procedure cache job name#>', @job_aspect = 'SCHEDULES'"
                        $FPCACHE_VERIFY = Invoke-DbaQuery -SqlInstance $FREEPCCACHE_ENABLE -Database "msdb" -Query "EXEC dbo.sp_help_job @job_name = N'<#Free procedure cache job name#>', @job_aspect = 'SCHEDULES'" | Select-Object -expand enabled 
                        $FPCACHE_DATE_VERIFY = Invoke-DbaQuery -SqlInstance $FREEPCCACHE_ENABLE -Database "msdb" -Query "EXEC dbo.sp_help_job @job_name = N'<#Free procedure cache job name#>', @job_aspect = 'SCHEDULES'"  | Select-Object -expand active_start_date
                        if ( $FPCACHE_VERIFY -contains 1 -and $FPCACHE_DATE_VERIFY -eq $FPC_START_DATE )
                            {
                                #1 notes that the job is enabled and 
                                Write-Host "SUCCESS: Job '<#Free procedure cache job name#>' is enabled to run at 6am on $FPC_START_DATE."
                            }
                        else
                            {
                                # anything else, e.g. 0, means the job is not enabled. Possibly if they put an incorrect date. 
                                throw "ERROR: Issues with trying to validate that job '<#Free procedure cache job name#>' is enabled for date $FPC_START_DATE on $INST.`nIt's possible a date from the past was entered."
                            }
                             
                        } # End of if statement if user selects Y.
                elseif ( $FREEPCCACHE_ENABLE_CHOICE -like "N" )
                    {
                        Write-host "WARNING: You selected NOT to run job <#Free procedure cache job name#> on $INST. Please remember to run it when ready."
                    }
                else
                    {
                        throw "ERROR: User did not select a valid Y/N choice. Exiting."
                    }
    } # end of freeproc cache schedule function
 

#choice number 10 - perform post-patch check. 
function post_patch_check_func
    {
        Write-Host "################################################"
        Write-Host "Welcome to the post-patch check function."
        Write-Host "################################################"

        #Run the same checks as the pre-patch function, write output to post-patch file, will be used for comparison
        Write-Host "Performing post-patching checks."
        Write-Host "Connecting to production clusters"
        Invoke-DbaQuery -SqlInstance $INST_ARRAY -Database "master" -Query $CLUS_CHECK_QUERY | Tee-Object -FilePath "$AUDIT_DIR\$(HOSTNAME)_post_cluster_healthcheck_$DATE.txt" -Append
                    
        Write-Host "`n`n################################################"
        Write-Host "Performing a database Health Check for production clusters." 
        Invoke-DbaQuery -SqlInstance $PRD_INST_ARRAY -Database "master" -Query $DB_HEALTH_CHECK | format-table ServerName, DBName, User_Access, State, Delayed_Durability | Tee-Object -FilePath "$AUDIT_DIR\$(HOSTNAME)_post_db_healthcheck_$DATE.txt" -Append
                     
        Write-Host "Performing post-patching MSDTC Check"
        Invoke-Command -ComputerName $SrvList -FilePath C:\code\dba-scripts\dba-scripts\Jewett_Scripts\PowerShell\Patching\Development\DTC_Configuration.ps1 | Tee-Object -FilePath "$AUDIT_DIR\$(HOSTNAME)_post_DTC_check_$DATE.txt" -Append
            
        #Begin comparison of pre and post patching files. Display any differences for DBA to validate if change is allowed or needs to be remediated
             Write-Host "`n################################################"
             Write-Host "Comparing the pre and post patching output files for the Cluster health check."
             Write-Host "Please review the pre & post cluster healthcheck files from C:\SOURCE\DBA_PS_Audits_*post_cluster_healthcheck*.txt files."
             Write-Host "If below is empty, there's no differences between the pre & post cluster checks, which means that all clusters have the same state as before patching occured."  
             compare-object (get-content "$AUDIT_DIR\$(HOSTNAME)_pre_cluster_healthcheck_$DATE.txt") (get-content "$AUDIT_DIR\$(HOSTNAME)_post_cluster_healthcheck_$DATE.txt")  | format-list
              
             
             Write-Host "`n################################################"       
             Write-Host "Comparing the pre and post Database patching files for the database health check." 
             Write-Host "Please review the pre & post scripts from C:\SOURCE\DBA_PS_Audits_*post_db_healthcheck*.txt files." 
             Write-Host "If below is empty, there's no differences between the pre & post database health checks.`n"  
             compare-object (get-content "$AUDIT_DIR\$(HOSTNAME)_pre_db_healthcheck_$DATE.txt") (get-content "$AUDIT_DIR\$(HOSTNAME)_post_db_healthcheck_$DATE.txt")  | format-list
             Write-Host "################################################"

             #Share the list of output files for review if necessary. 
             Write-Host "`A post-cluster healthcheck file has been saved to $AUDIT_DIR\$(HOSTNAME)_post_cluster_healthcheck_$DATE.txt"
             Write-Host "`A post-DB health check output file has been saved to $AUDIT_DIR\$(HOSTNAME)_post_db_healthcheck_$DATE.txt"
             Wirte-Host "`A post-patching DTC healthcheck has been saved to $AUDIT_DIR\$(HOSTNAME)_post_DTC_check_$DATE.txt"
             Write-Host "##################################################################################################################"
    }

#function number 11 to start, stop, or verify sql server stand alone services. 
function start_stop_verify_sql_svc_func
    {
        Write-Host "################################################"
        Write-Host "Welcome to the start, stop, verify SQL Server service function."
        Write-Host "This will be used for standalone patching."
        Write-Host "################################################"

    }

do {
    Write-Host "`n`n`nPlease select what you'd like to do: `n"
    [int]$userMenuChoice = 0
    while ($userMenuChoice -lt 1 -or $userMenuChoice -gt 12) {
    Write-Host "1: Perform a DB/instance health pre-check before patching."
    Write-Host "2: Stop delayed durability on Shore 1 & Shore 6."
    Write-Host "3: Stop Tlog jobs on Shore 1 & Shore 6."
    Write-Host "4: Stop Backup jobs. Typically on shore 1, 2, 3, 6, dochub"
    Write-Host "5: Admin a cluster: start, stop, verify a SQL cluster role OR perform a cluster failover."
    Write-Host "6: Restart a backup job."
    Write-Host "7: Restart delayed durability FORCED jobs on Shore 1 & Shore 6."
    Write-Host "8: Restart Tlog jobs on Shore 1 & Shore 6."
    Write-Host "9: Schedule FREEPROCCACHE Cache."
    Write-Host "10: Perform Post-patching check."
    Write-Host "11: Start, stop, verify a SQL Server service for standalone clusters."
    Write-Host "12: Exit."

    [int]$userMenuChoice = Read-Host "`nPlease choose an option"

    switch ($userMenuChoice) {
        1{HealthCheckFunc}
        2{DelayDurability_disable_func}
        3{disable_TLOG_func}
        4{Stop_Backup_Jobs_func}
        5{cluster_failover_func}
        6{restart_backup_jobs_func}
        7{restart_dd_func}
        8{enable_TLOG_func}
        9{schedule_freeproccache_func}
        10{post_patch_check_func}
        11{start_stop_verify_sql_svc_func}
        default {Write-Host "Please select a valid number or 12 to exit.`n`n"}
    }
}
} while ($userMenuChoice -ne 12)

#Stop logging for the script run
Stop-Transcript
