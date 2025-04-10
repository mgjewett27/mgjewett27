SELECT GETDATE() AS runtime
	,a.*
	,b.kpid
	,b.blocked
	,b.lastwaittype
	,b.waitresource
	,db_name(b.dbid) AS database_name
	,b.cpu
	,b.physical_io
	,b.memusage
	,b.login_time
	,b.last_batch
	,b.open_tran
	,b.STATUS
	,b.hostname
	,b.program_name
	,b.cmd
	,b.loginame
	,request_id
FROM sys.dm_tran_active_snapshot_database_transactions a
INNER JOIN sys.sysprocesses b ON a.session_id = b.spid