#####################################################################################
# This script will be used to help with SQL Server DBA Patch Nights.
#      This was created in relation to https://kb.uwm.com/display/TDBA/DBAPCH003+-+YYYY-MM-DD+%5BPatch+night%5D+-+Automated+-+Template
#     
#
#   01/21/2022   -  Mike Wilson - Created the script. 
#   01/28/2022   - Mike Wilson - updated variables to prod. Added some messages related to some bugs. 
#   02/07/2022   Mike Wilson - Broke out the cluster service stop, and failvoer functions into 1 function.  
#                              This function will invoke-command to run run the cluster admin tools local to a server.
#   02/15/2022   Mike Wilson - Updated the path for option #5 from the sql audit folder to C:\SOURCE\DBA_Scripts\.
#   03/22/2022   Mike Wilson - Changed the date to a variable to fix a date comparision issue during pre/post patch checks.
#							   Created a temp array of an existing array in order to fix error - "Collection was modified; enumeration operation may not execute." 
#								This was caused when trying to remove an object from an array that's in use. 
#   02/13/2024   Mike Jewett - Updating failover function to now automatically failover list of clusters to their new active node
#   12/16/2024    Mike Jewett - Added pre and post health check for MSDTC on all production clusters
#####################################################################################

# Variables for all instances.  Update these if the servers or named instances are rebuilt. 
<#Instance names stored as variables#>

$STG_INST_ARRAY= <#Array of Stage database instances#>
$PRD_INST_ARRAY= <#Array of Production database instances#>
$TEST_INST=<#Test server name#>

#Final variable. Update this to prd, stage or test as needed. 
$INST_ARRAY= $PRD_INST_ARRAY


#Query variables
$CLUS_CHECK_QUERY="SELECT NodeName, status, status_description, is_current_owner FROM sys.dm_os_cluster_nodes"
$DB_HEALTH_CHECK="SELECT NAME, user_access_desc, STATE_DESC, delayed_durability_desc FROM SYS.DATABASES"
$ACTIVE_NODE_QUERY="SELECT * FROM sys.dm_os_cluster_nodes WHERE is_current_owner=1"
$INACTIVE_NODE_QUERY="SELECT * FROM sys.dm_os_cluster_nodes WHERE is_current_owner=0"


$SERVER=hostname

#Setting an audit log folder.
$AUDIT_DIR= <#Directory for Auditing#>

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


        Write-Host "Performing pre-patching checks on $INST_ARRAY."
            foreach ( $INST in $INST_ARRAY )
            {
                Write-Host "############################################"
                Write-Host "Connecting to $INST"
                Write-Host "Obtaining cluster node information."
                Invoke-Sqlcmd -ServerInstance $INST -Database "master" -Query $CLUS_CHECK_QUERY  | ft nodename, status, status_description, is_current_owner
                Invoke-Sqlcmd -ServerInstance $INST -Database "master" -Query $CLUS_CHECK_QUERY >> "$AUDIT_DIR\$(HOSTNAME)_pre_cluster_healthcheck_$DATE.txt"
                

                
                Write-Host "Performing a database Health Check for instance $INST." 
                Invoke-Sqlcmd -ServerInstance $INST -Database "master" -Query $DB_HEALTH_CHECK | ft NAME, user_access_desc, STATE_DESC, delayed_durability_desc
                Invoke-Sqlcmd -ServerInstance $INST -Database "master" -Query $DB_HEALTH_CHECK >> "$AUDIT_DIR\$(HOSTNAME)_pre_db_healthcheck_$DATE.txt"
             }

         Write-Host "Performing pre-patching MSDTC Check"
            foreach ($server in Get-Content -Path <#MSDTC Check PowerShell script#>) {
                Invoke-Command -ComputerName $server -ScriptBlock {Test-Dtc -LocalComputerName "$env:COMPUTERNAME" -Verbose} | Out-File "$AUDIT_DIR\$(HOSTNAME)_pre_DTC_check_$DATE.txt"
            }

        #Share the list of output files for review if necessary. 
        Write-Host "##################################################################################################################"
        Write-Host "SUMMARY: A pre-patching cluster healthcheck file has been saved to $AUDIT_DIR\$(HOSTNAME)_pre_cluster_healthcheck_$DATE.txt"
        Write-Host "SUMMARY: A DB health check output file has been saved to $AUDIT_DIR\$(HOSTNAME)_pre_db_healthcheck_$DATE.txt"
        Write-Host "SUMMARY: A pre-patching MSDTC health check has been saved to $AUDIT_DIR\$(HOSTNAME)_pre_DTC_check_$DATE.txt"
        Write-Host "##################################################################################################################`n"
         
    } # End of HealthCheck function.



#choice number 2 - disable delayed durability on shore 1 & 6.
function DelayDurability_disable_func
    {
        # This needs to be ran against shore1 & 6 only.  The job isn't scheduled elsewhere at this time. 
        $DD_DISABLE_ARRAY= $SHORE1, $SHORE6
        #$DD_DISABLE_ARRAY= $TEST_INST

        foreach ( $INST in $DD_DISABLE_ARRAY )
            {
                

            Write-Host "`n############################################################################"
            #Execute the Delayed Durability Disable job
            Write-Host "Executing job <#Disable Delayed Durability Agent Job#> on $INST.`n"
            Invoke-Sqlcmd -ServerInstance $INST -Database "msdb" -Query "EXEC dbo.sp_start_job N'<#Disable Delayed Durability Agent Job#>"
            if ($? -eq 'True' )
                {
                    Start-Sleep -Seconds 5 # put in place such the script to not pick up an older runtime for the below query.   
                    $DD_JOB_CHECK_QUERY="select distinct top(1)
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
                                    where j.name = <#Disable Delayed Durability Agent Job#>
                                    order by JobName, RunDateTime desc"

                    Write-Host "SUCCESS: Job <#Disable Delayed Durability Agent Job#> successfully ran on $INST."
                    #Verify Job executed successfully
                    Write-Host "Validating that job <#Disable Delayed Durability Agent Job#> was ran on $INST.`n"
                  
                    Invoke-Sqlcmd -ServerInstance $INST -Database "msdb" -Query $DD_JOB_CHECK_QUERY | ft JobName, JobStatus, RunDateTime
                    Start-Sleep -Seconds 2
                    $DD_JOB_RUNTIME_CHECK = Invoke-Sqlcmd -ServerInstance $INST -Database "msdb" -Query $DD_JOB_CHECK_QUERY | select -expand JobStatus
                         if ($DD_JOB_RUNTIME_CHECK -eq 'Successful'  )
                            {
                                Write-Host "SUCCESS: The <#Disable Delayed Durability Agent Job#> job has been verified as successful on $INST."
                            }
                        elseif ($DD_JOB_RUNTIME_CHECK -eq "" )
                            {
                                Write-Host "WARNING: The <#Disable Delayed Durability Agent Job#> job did not recieve output while trying to run query $DD_JOB_CHECK_QUERY against $INST."
                                Write-Host "WARNING: The SQL AGent job history most likely did not get populated. Please manually check."
                            }
                        else
                            {
                                Write-Host "ERROR: This failed with a value of: $DD_JOB_RUNTIME_CHECK ." 
                                throw "ERROR: Issues with verifying the <#Disable Delayed Durability Agent Job#> job on $INST. Please investigate."
                                exit
                            }
                }
            else 
                {
                    Throw "ERROR: Job <#Disable Delayed Durability Agent Job#> failed on $INST. Please investigate.`n"
                    exit    
                }

            } #end of for each instance loop.
         Write-host "`nSUMMARY: Overall, job <#Disable Delayed Durability Agent Job#> was disabled and verified as diabled on servers: $INST"
         Write-Host "############################################################################`n" 
    } # End of DelayDurability_Func function.


#choice number 3 - disable TLOG backups on certain instances.
function disable_TLOG_func
    {
        #This needs to be ran against certain instances. 
        $DISABLE_TLOG_ARRAY= <#Database instance array#>
        #$DISABLE_TLOG_ARRAY= $TEST_INST

        foreach ( $INST in $DISABLE_TLOG_ARRAY )
            {
                #Disable TLOG backups on the instance
                Write-Host "`n############################################################################"
                Write-Host "Disabling the <#User TLOG backup Agent job#> backup job on $INST.`n"
                Invoke-Sqlcmd -ServerInstance $INST -Database "msdb" -Query "EXEC dbo.sp_update_job @job_name = N<#User TLOG backup Agent job#>, @enabled = 0;"
                if ($? -eq 'True' )
                    {
                        Write-Host "SUCCESS: Disabling job <#User TLOG backup Agent job#> completed on $INST.`n"

                        #Verify TLOG backups have been disabled
                        Write-Host "Verifying job <#User TLOG backup Agent job#> is disabled on $INST.`n"


                        $TLOG_ENABLED_CHECK = Invoke-Sqlcmd -ServerInstance $INST -Database "msdb" -Query "EXEC dbo.sp_help_job @job_name = N'<#User TLOG backup Agent job#>', @job_aspect = N'JOB'" | select -expand enabled
                        IF ($TLOG_ENABLED_CHECK -eq 0 ) 
                            {
                                Write-Host "SUCCESS: Job <#User TLOG backup Agent job#> has been verfified as disabled on $INST." 
                            }

                        ELSE 
                            {
                                Throw "ERROR: Job <#User TLOG backup Agent job#> has not been disabled on $INST. Please investigate.`n"
                            }

                    }
                else 
                    {
                        Throw "ERROR: The job <#User TLOG backup Agent job#> has failed to disable on $INST. Please investigate.`n"
                        exit    
                    }

            } #end of for each instance loop.
         Write-host "`nSUMMARY: Overall, job <#User TLOG backup Agent job#> was disabled and verified as diabled on servers: $INST"
         Write-Host "############################################################################`n" 
    } # End of disable tlog function.



#choice number 4 - stop backup jobs. Typically on certain instances.
# This will check all instances, see if the backup job is running, and if it is, terminate it. 
# It will then store the instance to a backup file, which will be referenced in choice 6 to restart the killed backup jobs. 

function Stop_Backup_Jobs_func
    {
        Write-Host "####################################################################################"
        Write-Host "Welcome to the stop backup jobs function."
        Write-Host "####################################################################################"
        
        $STOP_BACKUP_JOB_INSTS_ARRAY = $INST_ARRAY
        #$STOP_BACKUP_JOB_INSTS_ARRAY = $TEST_INST #Testing purposes

        #create arrayList. Global makes this useable anywhere.
        $global:DB_JOB_STOP_ARRAY = New-Object -TypeName 'System.Collections.ArrayList'

        foreach ( $INST in $STOP_BACKUP_JOB_INSTS_ARRAY )
            {
                
                #See if backup is running.
                [int]$BACKUP_JOB_STATUS = Invoke-Sqlcmd -ServerInstance $INST -Database "msdb" -Query "EXEC dbo.sp_help_job @job_name = N'<#User full backup agent job#>', @job_aspect = N'JOB'" | select -expand current_execution_status
      
               Write-Host "`nChecking to see if backup job <#User full backup agent job#> on $INST is running.`n"
               if ( $BACKUP_JOB_STATUS -eq 4 )
                    {
                        Write-Host "SUCCESS: The <#User full backup agent job#> job is not active on $INST. No action needed."
                    }
                elseif (  $BACKUP_JOB_STATUS -eq 1 )
                    {
                            Write-Host "`nBackup job - <#User full backup agent job#> is currently running on $INST. Stopping it.`n"
                            Invoke-Sqlcmd -ServerInstance $INST -Database "msdb" -Query "EXEC dbo.sp_stop_job N'<#User full backup agent job#>'"
                            [int]$BACKUP_JOB_STATUS = Invoke-Sqlcmd -ServerInstance $INST -Database "msdb" -Query "EXEC dbo.sp_help_job @job_name = N'<#User full backup agent job#>', @job_aspect = N'JOB'" | select -expand current_execution_status
                            if ($? -eq 'True' )
                                {
                                    Write-Host "`nSUCCESS: The <#User full backup agent job#> job has successfully stopped on $INST."
                                    Write-Host "`nVerifying that the <#User full backup agent job#> job is stopped on $INST. Please wait up to a minute for this to run."
                                    
                                    Start-Sleep -Seconds 15

                                    [int]$BACKUP_JOB_STATUS_CHK=Invoke-Sqlcmd -ServerInstance $INST -Database "msdb" -Query "EXEC dbo.sp_help_job @job_name = N'<#User full backup agent job#>', @job_aspect = N'JOB'" | select -expand current_execution_status
                                    if ( $BACKUP_JOB_STATUS_CHK -eq 4 )
                                        {
                                            Write-Host "SUCCESS: Validated that job <#User full backup agent job#> was stopped, and is idle on $INST."
                                            Write-Host "Adding a record to an array, so it can be referenced when we need to restart the backup job afterwards." 
                                            $DB_JOB_STOP_ARRAY.add($INST)
                                            Write-Host "$INST has been added to Array: $DB_JOB_STOP_ARRAY"
                                        }
                                else
                                    {
                                        write-host "Error: $BACKUP_JOB_STATUS_CHK"
                                        Throw "ERROR: Issues with trying to validate that job <#User full backup agent job#> was stopped on $INST. Please investigate."
                                        exit 
                                    }
                                } 
                    } #end of backup check where the job is running. 
                else
                    {
                        Throw "ERROR: The <#User full backup agent job#> job has failed to stop on $INST. Please investigate."
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
        foreach($server in Get-Content <#List of desired active server post failover#>) { 

            Invoke-Command -ComputerName $server -FilePath <#Cluster information PowerShell Script#> | Out-File -FilePath <#List of cluster objects text file#> -Append
        }
Start-Sleep -Seconds 2

    #Get list of owner nodes pre failover, append them to file
    Write-Host "Finding current active node of each cluster`n"
        foreach($cluster in Get-Content <#List of cluster objects text file#>) {
            Invoke-Command -ComputerName $cluster -FilePath <#Cluster group information PowerShell script#> | Out-file -FilePath <#List of owner nodes pre-failover#> -Append
        }
Start-Sleep -Seconds 2

    #Get full name of cluster role, append to file to use for failovers
    foreach($cluster in Get-Content <#List of cluster objects text file#>) {
        Invoke-Command -ComputerName $cluster -FilePath <#PowerShell script to identify cluster roles#> | Out-file -FilePath <#Output script for cluster groups#> -Append
    }
Start-Sleep -Seconds 2


    #Compare length of sever file and cluster file, make sure each server has a matching cluster
    Write-Host "Making sure cluster and server information match up`n"
        $Server_file_length = Get-Content -Path <#List of desired active server post failover#> | Measure-Object -Line | Select -ExpandProperty Lines
        $Cluster_file_length = Get-Content -Path <#List of cluster objects text file#> | Measure-Object -Line | Select -ExpandProperty Lines

    if ($Server_file_length -eq $Cluster_file_length) {
        Write-Host "Server and cluster files are 1 for 1, continuing with failovers"

    } 
        else {
            Write-Host "Mismatch in files, please review cluster and server files for discrepancy"
        }
Start-Sleep -Seconds 2

    #Create array from server file and cluster file
    $Server_Array = @(Get-Content <#List of desired active server post failover#>)
    $Cluster_Array = @(Get-Content <#List of cluster objects text file#>)
    $Cluster_group_Array = @(Get-Content <#Output script for cluster groups#>)

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

    #Get list of owner nodes past failover, append them to file
    foreach($cluster in Get-Content <#List of cluster objects text file#>) {
        Invoke-Command -ComputerName $cluster -FilePath <#Cluster group information PowerShell script#> | Out-file -FilePath <#List of owner nodes post failover#> -Append
    }

    #Load pre_failover server file and compare it to post_failover server file, return servers that were already active before script and need a failover to occur still.
    $Pre_Failover_owners = (Get-Content -Path <#List of owner nodes pre-failover#>)
    $Post_Failover_owners = (Get-Content -Path <#List of owner nodes post failover#>)

    Write-Host "The below servers were already active nodes, no failover occured yet. Make sure to manually fail node over and back.`n If no results below, all failovers were completed to a new node successfully."
    Compare-Object -ReferenceObject $Pre_Failover_owners -DifferenceObject $Post_Failover_owners -IncludeEqual -ExcludeDifferent | Select -ExpandProperty InputObject


    #Cleanup files used in process, will be created next time script is run
    $Cleanup_Choice = Read-Host "Failovers complete, would you like to delete files used in this script run? (Y/N)"

        if ($Cleanup_Choice -like "Y") {
    
            Write-Host "Deleting files now"
            Remove-Item -Path <#Output script for cluster groups#>
            Remove-Item -Path <#List of cluster objects text file#>
            Remove-Item -Path <#List of owner nodes pre-failover#>
            Remove-Item -Path <#List of owner nodes post failover#>
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




#choice number 6 - restart backup jobs. Typically on shore 1, 2, 3, 6, dochub. 
function restart_backup_jobs_func
    {
		Write-Host "#################################################################"
        Write-Host "Welcome to the restart backup jobs function."
        Write-Host "This typically needs to occur on shores 1, 2, 3, 6, and dochub."
        Write-Host "#################################################################"
		
        #Create an temp array of the DB stop Job array. This resolve an error we saw - Collection was modified; enumeration operation may not execute.
        $TEMP_JOB_RESTART_ARRAY = $DB_JOB_STOP_ARRAY.ToArray()

        #loop through the list. ask if you want to restart the job or not. 
        foreach ( $INST in $TEMP_JOB_RESTART_ARRAY )
            {
			   Write-Host "####################################################################################"
               Write-Host "`nJob <#User full backup agent job#> on $INST was terminated earlier."
               $BACKUP_RESTART = Read-host "Would you like to restart job '<#User full backup agent job#>' on $INST. ( Y / N )"
               if ( $BACKUP_RESTART -like "Y" )
                {
                    Invoke-Sqlcmd -ServerInstance $INST -Database "msdb" -Query "EXEC dbo.sp_start_job N'<#User full backup agent job#>'"
			        Write-Host "Job has been rerstarted on $INST. Waiting 1 minute to check and verify the job is still running."
			   
                    Start-Sleep -Seconds 45 #give time to verify the job is running, and not failing right after kicking off the job. 

			        #Verify that the backup job is running.
                    [int]$BACKUP_JOB_STATUS = Invoke-Sqlcmd -ServerInstance $INST -Database "msdb" -Query "EXEC dbo.sp_help_job @job_name = N'<#User full backup agent job#>', @job_aspect = N'JOB'" | select -expand current_execution_status
               
                    Write-Host "`nVerifying backup job <#User full backup agent job#> on $INST is running.`n"
                       if ( $BACKUP_JOB_STATUS -eq 1 )
                         {	
                            Write-Host "SUCCESS: The <#User full backup agent job#> job is running on $INST."
                            
                            Start-Sleep -Seconds 2
                            Write-Host "Removing the record for $INST from the array."
                            $DB_JOB_STOP_ARRAY.Remove($INST) 
                         }
				        else
					      {
						    throw "ERROR: The The <#User full backup agent job#> job is not running on $INST. Please investigate."
					      }

                        }
                elseif ( $BACKUP_RESTART -like "N" )
                    {
                        Write-Host "WARNING: You selected NOT to restart job <#User full backup agent job#> on $INST. Skipping."
                    }
                else
                    {
                          throw "ERROR: A non Y / N character was inputted. Please retry the script." 
                    }

            } #end of foreach loop.
        Write-Host "####################################################################################"
    }

#choice number 7 - restart delayed durability for certain instances. 
function restart_dd_func
    {
        Write-Host "#############################################################################"
        Write-Host "Welcome to the 'Maint: DELAYED_DURABLITY = FORCED' job function."
        Write-Host "#############################################################################"
        
        $DD_TLOG_ARRAY= <#Database instances#>
        #$DD_TLOG_ARRAY= $TEST_INST

        foreach ( $INST in $DD_TLOG_ARRAY )
            {

                $DD_BACKUP_RESTART = Read-host "Would you like to restart job '<#Enable Delayed Durability Agent Job#>' on $INST. ( Y / N )"
                IF ( $DD_BACKUP_RESTART -like "y" )
                {
                #Execute the Delayed Durability Disable job
                Write-Host "Executing job <#Enable Delayed Durability Agent Job#> on $INST.`n"
                Invoke-Sqlcmd -ServerInstance $INST -Database "msdb" -Query "EXEC dbo.sp_start_job N'<#Enable Delayed Durability Agent Job#>'"
                if ($? -eq 'True' )
                    {
                        Write-Host "SUCCESS: Job <#Enable Delayed Durability Agent Job#> successfully completed on $INST.`n"
                        #Verify Job executed successfully
                        Write-Host "`nVerifying the <#Enable Delayed Durability Agent Job#> job is enabled on $INST.`n"
                        
                        Invoke-Sqlcmd -ServerInstance $INST -Database "msdb" -Query "EXEC dbo.sp_help_jobactivity @job_name = N'<#Enable Delayed Durability Agent Job#>'"  | format-list
                        $DD_FORCED_CHK = Invoke-Sqlcmd -ServerInstance $INST -Database "msdb" -Query "EXEC dbo.sp_help_job @job_name = N'<#Enable Delayed Durability Agent Job#>'"  | select Enabled | select -expand Enabled
                        if ($DD_FORCED_CHK -eq 1 )
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
                elseif ( $DD_BACKUP_RESTART -like "n" )
                    {
                        Write-Host "WARNING: You selected to not restart the delayed durability job on $INST. Please remember to run this when the time is ready."
                    }
                else
                    {
                        write-host "ERROR: A non Y/N choice was inputted. skipping."
                    }
            } #End of foreach loop for delayed durability forced.
    }

#choice number 8 - to restart tlog jobs.
function enable_TLOG_func
    {
        #This needs to be ran against certain instances. 
        $ENABLE_TLOG_ARRAY= <#Database instances#>
        #$ENABLE_TLOG_ARRAY = $TEST_INST

        Write-Host "`n############################################################################"
        foreach ( $INST in $ENABLE_TLOG_ARRAY )
            {
                 #Enable TLOG backups on the instance
                 $TLOG_RESTART = Read-host "Would you like to restart job '<#User TLOG backup Agent Job#>' on $INST. ( Y / N )"
                 if ( $TLOG_RESTART -like "Y" )
                    {
                        Write-Host "Attempting to enable the '<#User TLOG backup Agent Job#>' backup job on $INST.`n"
                        Invoke-Sqlcmd -ServerInstance $INST -Database "msdb" -Query "EXEC dbo.sp_update_job @job_name = N'<#User TLOG backup Agent Job#>', @enabled = 1;"
                        if ($? -eq 'True' )
                            {
                                Write-Host "SUCCESS: Enabling job '<#User TLOG backup Agent Job#>' completed on $INST.`n"

                                #Verify TLOG backups have been enabled
                                Write-Host "Verifying job '<#User TLOG backup Agent Job#>' is enabled on $INST.`n"


                                $TLOG_ENABLED_CHECK = Invoke-Sqlcmd -ServerInstance $INST -Database "msdb" -Query "EXEC dbo.sp_help_job @job_name = N'<#User TLOG backup Agent Job#>', @job_aspect = N'JOB'" | select -expand enabled
                                IF ($TLOG_ENABLED_CHECK -eq 1 ) 
                                    {
                                        Write-Host "SUCCESS: Job '<#User TLOG backup Agent Job#>' has been verfified as enabled on $INST." 
                                    }

                                ELSE 
                                    {
                                        Throw "ERROR: Job '<#User TLOG backup Agent Job#>' has not been enabled on $INST. Please investigate.`n"
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
            } #end of for each instance loop.
         Write-Host "############################################################################`n" 
    } 


#choice number 9 - schedule freeproccache on Certain instances. 
function schedule_freeproccache_func
    {
        $FREEPCCACHE_ENABLE= $SHORE1, $SHORE6
        #$FREEPCCACHE_ENABLE = $TEST_INST

        Write-Host "`n############################################################################"
        foreach ( $INST in $FREEPCCACHE_ENABLE )
            {
                #Enable Freeproccache jobs on shore1 & shore6.
                $FREEPCCACHE_ENABLE_CHOICE = Read-host "Would you like to schedule job '<#Scheduled free proc cache Agent job#>' on $INST. ( Y / N )"
                if ( $FREEPCCACHE_ENABLE_CHOICE -like "Y" )
                    {
                        $FPC_START_DATE = Read-Host "Please enter the date you want job '<#Scheduled free proc cache Agent job#>' enabled in the format of YYYYMMDD (e.g. 20220116):"
                        Write-Host "`nScheduling job '<#Scheduled free proc cache Agent job#>' to run on $FPC_START_DATE, at 6:00am"
                        Invoke-Sqlcmd -ServerInstance $INST -Database "msdb" -Query "EXEC dbo.sp_update_schedule @name = N'<#Scheduled free proc cache Agent job#>', @active_start_date = $FPC_START_DATE, @enabled = 1, @active_start_time = 060000"

                        Write-Host "`nVerifying that job '<#Scheduled free proc cache Agent job#>' is enabled to run at 6am on $FPC_START_DATE."
                        Invoke-Sqlcmd -ServerInstance $INST -Database "msdb" -Query "EXEC dbo.sp_help_job @job_name = N'<#Scheduled free proc cache Agent job#>', @job_aspect = 'SCHEDULES'"
                        $FPCACHE_VERIFY = Invoke-Sqlcmd -ServerInstance $INST -Database "msdb" -Query "EXEC dbo.sp_help_job @job_name = N'<#Scheduled free proc cache Agent job#>', @job_aspect = 'SCHEDULES'" |select -expand enabled 
                        $FPCACHE_DATE_VERIFY = Invoke-Sqlcmd -ServerInstance $INST -Database "msdb" -Query "EXEC dbo.sp_help_job @job_name = N'<#Scheduled free proc cache Agent job#>', @job_aspect = 'SCHEDULES'" |select -expand active_start_date
                        if ( $FPCACHE_VERIFY -eq 1 -and $FPCACHE_DATE_VERIFY -eq $FPC_START_DATE )
                            {
                                #1 notes that the job is enabled and 
                                Write-Host "SUCCESS: Job '<#Scheduled free proc cache Agent job#>' is enabled to run at 6am on $FPC_START_DATE."
                            }
                        else
                            {
                                # anything else, e.g. 0, means the job is not enabled. Possibly if they put an incorrect date. 
                                throw "ERROR: Issues with trying to validate that job '<#Scheduled free proc cache Agent job#>' is enabled for date $FPC_START_DATE on $INST.`nIt's possible a date from the past was entered."
                            }
                             
                        } # End of if statement if user selects Y.
                elseif ( $FREEPCCACHE_ENABLE_CHOICE -like "N" )
                    {
                        Write-host "WARNING: You selected NOT to run job <#Scheduled free proc cache Agent job#> on $INST. Please remember to run it when ready."
                    }
                else
                    {
                        throw "ERROR: User did not select a valid Y/N choice. Exiting."
                    }
            } #end of for each instance loop.
         Write-Host "############################################################################`n" 
       
    } # end of freeproc cache schedule function

#choice number 10 - perform post-patch check. 
function post_patch_check_func
    {
        Write-Host "################################################"
        Write-Host "Welcome to the post-patch check function."
        Write-Host "################################################"

        Write-Host "Performing post-patching checks."
                foreach ( $INST in $INST_ARRAY )
                {
                    Write-Host "Connecting to $INST"
                    Invoke-Sqlcmd -ServerInstance $INST -Database "master" -Query $CLUS_CHECK_QUERY
                    Invoke-Sqlcmd -ServerInstance $INST -Database "master" -Query $CLUS_CHECK_QUERY >> "$AUDIT_DIR\$(HOSTNAME)_post_cluster_healthcheck_$DATE.txt"
                    
                    Write-Host "`n`n################################################"
                     Write-Host "Performing a database Health Check for instance $INST." 
                     Invoke-Sqlcmd -ServerInstance $INST -Database "master" -Query $DB_HEALTH_CHECK | ft NAME, user_access_desc, STATE_DESC, delayed_durability_desc
                     Invoke-Sqlcmd -ServerInstance $INST -Database "master" -Query $DB_HEALTH_CHECK >> "$AUDIT_DIR\$(HOSTNAME)_post_db_healthcheck_$DATE.txt"
                 }
         
         Write-Host "Performing post-patching MSDTC Check"
            foreach ($server in Get-Content -Path <#MSDTC Server list#>) {
                Invoke-Command -ComputerName $server -ScriptBlock {Test-Dtc -LocalComputerName "$env:COMPUTERNAME" -Verbose} | Out-File "$AUDIT_DIR\$(HOSTNAME)_post_DTC_check_$DATE.txt"
            }
            
             Write-Host "`n################################################"
             Write-Host "Comparing the pre and post patching output files for the Cluster health check."
             Write-Host "Please review the pre & post cluster healthcheck files from <#Audit log directory#>_*post_cluster_healthcheck*.txt files."
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
