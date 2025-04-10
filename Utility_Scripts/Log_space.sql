SET NOCOUNT ON
DECLARE @SQL VARCHAR (8000), @log_reuse_wait tinyint, @log_reuse_wait_desc nvarchar(120), @dbname sysname, @database_id int, @recovery_model_desc varchar (24)

IF ( OBJECT_id (N'tempdb..#CannotTruncateLog_Db') is not null)
BEGIN
    DROP TABLE #CannotTruncateLog_Db
END

--get info about transaction logs in each database.

IF ( OBJECT_id (N'tempdb..#dm_db_log_space_usage') is not null)
BEGIN
    DROP TABLE #dm_db_log_space_usage
END
SELECT * INTO #dm_db_log_space_usage FROM sys.dm_db_log_space_usage where 1=0

DECLARE log_space CURSOR FOR SELECT NAME FROM sys.databases
OPEN log_space

FETCH NEXT FROM log_space into @dbname

WHILE @@FETCH_STATUS = 0
BEGIN

    set @SQL = '
    insert into #dm_db_log_space_usage (
    database_id,
    total_log_size_in_bytes,
    used_log_space_in_bytes,
    used_log_space_in_percent,
    log_space_in_bytes_since_last_backup
    )
    select
    database_id,
    total_log_size_in_bytes,
    used_log_space_in_bytes,
    used_log_space_in_percent,
    log_space_in_bytes_since_last_backup
    from ' + @dbname +'.sys.dm_db_log_space_usage'

    BEGIN TRY
        exec (@SQL)
    END TRY

    BEGIN CATCH
        SELECT ERROR_MESSAGE() AS ErrorMessage;
    END CATCH;

    FETCH NEXT FROM log_space into @dbname
END

CLOSE log_space
DEALLOCATE log_space

--select the affected databases
SELECT
    sdb.name as DbName,
    sdb.log_reuse_wait, sdb.log_reuse_wait_desc,
    log_reuse_wait_explanation = CASE

        WHEN log_reuse_wait = 1 THEN 'No checkpoint has occurred since the last log truncation, or the head of the log has not yet moved beyond'
        WHEN log_reuse_wait = 2 THEN 'A log backup is required before the transaction log can be truncated.'
        WHEN log_reuse_wait = 3 THEN 'A data backup or a restore is in progress (all recovery models). Please wait or cancel backup'
        WHEN log_reuse_wait = 4 THEN 'A long-running active transaction or a deferred transaction is keeping log from being truncated. You can attempt a log backup to free space or complete/rollback long transaction'
        WHEN log_reuse_wait = 5 THEN 'Database mirroring is paused, or under high-performance mode, the mirror database is significantly behind the principal database. (Full recovery model only)'
        WHEN log_reuse_wait = 6 THEN 'During transactional replication, transactions relevant to the publications are still undelivered to the distribution database. Investigate the status of agents involved in replication or Changed Data Capture (CDC). (Full recovery model only.)'
        WHEN log_reuse_wait = 7 THEN 'A database snapshot is being created. This is a routine, and typically brief, cause of delayed log truncation.'
        WHEN log_reuse_wait = 8 THEN 'A transaction log scan is occurring. This is a routine, and typically a brief cause of delayed log truncation.'
        WHEN log_reuse_wait = 9 THEN 'A secondary replica of an availability group is applying transaction log records of this database to a corresponding secondary database. (Full recovery model only.)'
        WHEN log_reuse_wait = 13 THEN 'If a database is configured to use indirect checkpoints, the oldest page on the database might be older than the checkpoint log sequence number (LSN).'
        WHEN log_reuse_wait = 16 THEN 'An In-Memory OLTP checkpoint has not occurred since the last log truncation, or the head of the log has not yet moved beyond a VLF.'
    ELSE 'None' END,

    sdb.database_id,
    sdb.recovery_model_desc,
    lsu.used_log_space_in_bytes / 1024 as Used_log_size_MB,
    lsu.total_log_size_in_bytes / 1024 as Total_log_size_MB,
    100 - lsu.used_log_space_in_percent as Percent_Free_Space
INTO #CannotTruncateLog_Db
FROM sys.databases AS sdb INNER JOIN #dm_db_log_space_usage lsu ON sdb.database_id = lsu.database_id
WHERE log_reuse_wait > 0

SELECT * FROM #CannotTruncateLog_Db

DECLARE no_truncate_db CURSOR FOR
    SELECT log_reuse_wait, log_reuse_wait_desc, DbName, database_id, recovery_model_desc FROM #CannotTruncateLog_Db;

OPEN no_truncate_db

FETCH NEXT FROM no_truncate_db into @log_reuse_wait, @log_reuse_wait_desc, @dbname, @database_id, @recovery_model_desc

WHILE @@FETCH_STATUS = 0
BEGIN
    if (@log_reuse_wait > 0)
        select '-- ''' + @dbname +  ''' database has log_reuse_wait = ' + @log_reuse_wait_desc + ' --'  as 'Individual Database Report'

    if (@log_reuse_wait = 1)
    BEGIN
        select 'Consider running the checkpoint command to attempt resolving this issue or further t-shooting may be required on the checkpoint process. Also, examine the log for active VLFs at the end of file' as Recommendation
        select 'USE ''' + @dbname+ '''; CHECKPOINT' as CheckpointCommand
        select 'select * from sys.dm_db_log_info(' + CONVERT(varchar,@database_id)+ ')' as VLF_LogInfo
    END
    else if (@log_reuse_wait = 2)
    BEGIN
        select 'Is '+ @recovery_model_desc +' recovery model the intended choice for ''' + @dbname+ ''' database? Review recovery models and determine if you need to change it. https://learn.microsoft.com/sql/relational-databases/backup-restore/recovery-models-sql-server' as RecoveryModelChoice
        select 'To truncate the log consider performing a transaction log backup on database ''' + @dbname+ ''' which is in ' + @recovery_model_desc +' recovery model. Be mindful of any existing log backup chains that could be broken' as Recommendation
        select 'BACKUP LOG [' + @dbname + '] TO DISK = ''some_volume:\some_folder\' + @dbname + '_LOG.trn ''' as BackupLogCommand
    END
    else if (@log_reuse_wait = 3)
    BEGIN
        select 'Either wait for or cancel any active backups currently running for database ''' +@dbname+ '''. To check for backups, run this command:' as Recommendation
        select 'select * from sys.dm_exec_requests where command like ''backup%'' or command like ''restore%''' as FindBackupOrRestore
    END
    else if (@log_reuse_wait = 4)
    BEGIN
        select 'Active transactions currently running  for database ''' +@dbname+ '''. To check for active transactions, run these commands:' as Recommendation
        select 'DBCC OPENTRAN (''' +@dbname+ ''')' as FindOpenTran
        select 'select database_id, db_name(database_id) dbname, database_transaction_begin_time, database_transaction_state, database_transaction_log_record_count, database_transaction_log_bytes_used, database_transaction_begin_lsn, stran.session_id from sys.dm_tran_database_transactions dbtran left outer join sys.dm_tran_session_transactions stran on dbtran.transaction_id = stran.transaction_id where database_id = ' + CONVERT(varchar, @database_id) as FindOpenTransAndSession
    END

    else if (@log_reuse_wait = 5)
    BEGIN
        select 'Database Mirroring for database ''' +@dbname+ ''' is behind on synchronization. To check the state of DBM, run the commands below:' as Recommendation
        select 'select db_name(database_id), mirroring_state_desc, mirroring_role_desc, mirroring_safety_level_desc from sys.database_mirroring where mirroring_guid is not null and mirroring_state <> 4 and database_id = ' + convert(sysname, @database_id)  as CheckMirroringStatus

        select 'Database Mirroring for database ''' +@dbname+ ''' may be behind: check unsent_log, send_rate, unrestored_log, recovery_rate, average_delay in this output' as Recommendation
        select 'exec msdb.sys.sp_dbmmonitoraddmonitoring 1; exec msdb.sys.sp_dbmmonitorresults ''' + @dbname+ ''', 5, 0; waitfor delay ''00:01:01''; exec msdb.sys.sp_dbmmonitorresults ''' + @dbname+ '''; exec msdb.sys.sp_dbmmonitordropmonitoring'   as CheckMirroringStatusAnd
    END

    else if (@log_reuse_wait = 6)
    BEGIN
        select 'Replication transactions still undelivered from publisher database ''' +@dbname+ ''' to Distribution database. Check the oldest non-distributed replication transaction. Also check if the Log Reader Agent is running and if it has encountered any errors' as Recommendation
        select 'DBCC OPENTRAN  (''' + @dbname + ''')' as CheckOldestNonDistributedTran
        select 'select top 5 * from distribution..MSlogreader_history where runstatus in (6, 5) or error_id <> 0 and agent_id = find_in_mslogreader_agents_table  order by time desc ' as LogReaderAgentState
    END

    else if (@log_reuse_wait = 9)
    BEGIN
        select 'Always On transactions still undelivered from primary database ''' +@dbname+ ''' to Secondary replicas. Check the Health of AG nodes and if there is latency is Log block movement to Secondaries' as Recommendation
        select 'select availability_group=cast(ag.name as varchar(30)), primary_replica=cast(ags.primary_replica as varchar(30)),primary_recovery_health_desc=cast(ags.primary_recovery_health_desc as varchar(30)), synchronization_health_desc=cast(ags.synchronization_health_desc as varchar(30)),ag.failure_condition_level, ag.health_check_timeout, automated_backup_preference_desc=cast(ag.automated_backup_preference_desc as varchar(10))  from sys.availability_groups ag join sys.dm_hadr_availability_group_states ags on ag.group_id=ags.group_id' as CheckAGHealth
        select 'SELECT  group_name=cast(arc.group_name as varchar(30)), replica_server_name=cast(arc.replica_server_name as varchar(30)), node_name=cast(arc.node_name as varchar(30)),role_desc=cast(ars.role_desc as varchar(30)), ar.availability_mode_Desc, operational_state_desc=cast(ars.operational_state_desc as varchar(30)), connected_state_desc=cast(ars.connected_state_desc as varchar(30)), recovery_health_desc=cast(ars.recovery_health_desc as varchar(30)), synchronization_health_desc=cast(ars.synchronization_health_desc as varchar(30)), ars.last_connect_error_number, last_connect_error_description=cast(ars.last_connect_error_description as varchar(30)), ars.last_connect_error_timestamp, primary_role_allow_connections_desc=cast(ar.primary_role_allow_connections_desc as varchar(30)) from sys.dm_hadr_availability_replica_cluster_nodes arc join sys.dm_hadr_availability_replica_cluster_states arcs on arc.replica_server_name=arcs.replica_server_name join sys.dm_hadr_availability_replica_states ars on arcs.replica_id=ars.replica_id join sys.availability_replicas ar on ars.replica_id=ar.replica_id join sys.availability_groups ag on ag.group_id = arcs.group_id and ag.name = arc.group_name ORDER BY cast(arc.group_name as varchar(30)), cast(ars.role_desc as varchar(30))' as CheckReplicaHealth
        select 'select database_name=cast(drcs.database_name as varchar(30)), drs.database_id, drs.group_id, drs.replica_id, drs.is_local,drcs.is_failover_ready,drcs.is_pending_secondary_suspend, drcs.is_database_joined, drs.is_suspended, drs.is_commit_participant, suspend_reason_desc=cast(drs.suspend_reason_desc as varchar(30)), synchronization_state_desc=cast(drs.synchronization_state_desc as varchar(30)), synchronization_health_desc=cast(drs.synchronization_health_desc as varchar(30)), database_state_desc=cast(drs.database_state_desc as varchar(30)), drs.last_sent_lsn, drs.last_sent_time, drs.last_received_lsn, drs.last_received_time, drs.last_hardened_lsn, drs.last_hardened_time,drs.last_redone_lsn, drs.last_redone_time, drs.log_send_queue_size, drs.log_send_rate, drs.redo_queue_size, drs.redo_rate, drs.filestream_send_rate, drs.end_of_log_lsn, drs.last_commit_lsn, drs.last_commit_time, drs.low_water_mark_for_ghosts, drs.recovery_lsn, drs.truncation_lsn, pr.file_id, pr.error_type, pr.page_id, pr.page_status, pr.modification_time from sys.dm_hadr_database_replica_cluster_states drcs join sys.dm_hadr_database_replica_states drs on drcs.replica_id=drs.replica_id and drcs.group_database_id=drs.group_database_id left outer join sys.dm_hadr_auto_page_repair pr on drs.database_id=pr.database_id  order by drs.database_id' as LogMovementHealth
        select 'For more information see https://learn.microsoft.com/troubleshoot/sql/availability-groups/error-9002-transaction-log-large' as OnlineDOCResource
    END
    else if (@log_reuse_wait in (10, 11, 12, 14))
    BEGIN
        select 'This state is not documented and is expected to be rare and short-lived' as Recommendation
    END
    else if (@log_reuse_wait = 13)
    BEGIN
        select 'The oldest page on the database might be older than the checkpoint log sequence number (LSN). In this case, the oldest page can delay log truncation.' as Finding
        select 'This state should be short-lived, but if you find it is taking a long time, you can consider disabling Indirect Checkpoint temporarily' as Recommendation
        select 'ALTER DATABASE [' +@dbname+ '] SET TARGET_RECOVERY_TIME = 0 SECONDS' as DisableIndirectCheckpointTemporarily
    END
    else if (@log_reuse_wait = 16)
    BEGIN
        select 'For memory-optimized tables, an automatic checkpoint is taken when transaction log file becomes bigger than 1.5 GB since the last checkpoint (includes both disk-based and memory-optimized tables)' as Finding
        select 'Review https://blogs.msdn.microsoft.com/sqlcat/2016/05/20/logging-and-checkpoint-process-for-memory-optimized-tables-2/' as ReviewBlog
        select 'use ' +@dbname+ ' CHECKPOINT' as RunCheckpoint
    END

    FETCH NEXT FROM no_truncate_db into @log_reuse_wait, @log_reuse_wait_desc, @dbname, @database_id, @recovery_model_desc

END

CLOSE no_truncate_db
DEALLOCATE no_truncate_db