
--EXECUTE perfdb.dbo.sp_WhoIsActive  @find_block_leaders  = 0, @sort_order = 'session_id'



SELECT
	'--KILL ' + CONVERT(VARCHAR(10), r.session_id) + ';' AS [KILL_SPID]
	,r.session_id AS SPID
	,r.total_elapsed_time/1000/60 AS [run_time_minutes]
	,r.total_elapsed_time AS [run_time_ms]
	,ses.status
	,r.command
	,r.last_wait_type
	,p.waitresource
	
	--,p.blocked AS [blocked_by]
	,r.blocking_session_id
	,DB_NAME(r.database_id) AS [database]
	,ses.login_name
	,ses.host_name-----*-*-*-*-*-*-*-*-*-*
	                                                 


	,a.text AS query
	--,CAST('<?query -- ' + a.text + '--? >' AS XML) AS query

	 ,ses.is_user_process
	,r.dop
	
	
	,start_time
	,percent_complete
	,dateadd(second,r.estimated_completion_time/1000, getdate()) AS estimated_completion_time
	,ses.program_name
	
	,r.dop
	,r.cpu_time
	,r.granted_query_memory
	--,p.physical_io
	,r.reads
	,r.writes
	,r.logical_reads
	,r.transaction_isolation_level
	,r.open_transaction_count
	,r.row_count

	,r.sql_handle
	--,r.query_hash
	--,r.query_plan_hash

	--,os_wait.*
	
FROM
	sys.dm_exec_requests AS r 
	INNER JOIN sys.dm_exec_sessions AS ses ON ses.session_id = r.session_id
	CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) AS a
	LEFT JOIN sys.sysprocesses AS p ON p.spid = r.session_id	--adds threads view

	--LEFT JOIN sys.databases AS db ON db.database_id = r.database_id
	--LEFT JOIN sys.dm_os_waiting_tasks AS os_wait ON os_wait.session_id = r.session_id

WHERE
1=1




--AND ses.is_user_process = 1

--AND	ses.login_name = '<login>'
--	r.session_id <> @@SPID

--AND db.name = 'db_name'

--AND p.blocked <> 0
--AND a.text LIKE '%settoken%'
--AND a.text LIKE '%<text>%'



ORDER BY  r.last_wait_type DESC
	--r.blocking_session_id DESC
	--,r.total_elapsed_time DESC
	--,DB_NAME(r.database_id)
	--r.command
	--p.spid

	

	
	
