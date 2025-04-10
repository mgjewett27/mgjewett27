SELECT name, database_id
FROM sys.databases
WHERE name = 'db_name'
--Update to database you need id from

--Specific database view
--select 
--	 db_NAME(database_id) dbname,
--	 recovery_model,
--	 current_vlf_size_mb,
--	 total_vlf_count,
--	 active_vlf_count,
--	 active_log_size_mb,
--	 log_truncation_holdup_reason,
--	 log_since_last_checkpoint_mb
--  from 
--	sys.dm_db_log_Stats(68)
--	--Replace number with datbase_id



--See all databases in instance
select 
 dbs.name,
 b2.recovery_model,
 b2.current_vlf_size_mb,
 b2.total_vlf_count,
 b2.active_vlf_count,
 b2.active_log_size_mb,
 b2.log_truncation_holdup_reason,
 b2.log_since_last_checkpoint_mb
 from 
 sys.databases AS dbs
 CROSS APPLY sys.dm_db_log_Stats(dbs.database_id) b2
 where dbs.database_id=b2.database_id