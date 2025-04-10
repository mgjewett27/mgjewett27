--find query id
SELECT	p.plan_id
		,p.query_id
		,OBJECT_NAME(q.object_id) AS containing_object_id
		,p.is_forced_plan
		,p.plan_forcing_type_desc
		,q.query_parameterization_type_desc
		,p.initial_compile_start_time  AT TIME ZONE 'US Eastern Standard Time' AS [initial_compile_start_time]
		,p.last_compile_start_time  AT TIME ZONE 'US Eastern Standard Time' AS [last_compile_start_time]
		,p.last_execution_time AT TIME ZONE 'US Eastern Standard Time' AS [last_execution_time]
		,p.count_compiles
		,p.force_failure_count
		,p.last_force_failure_reason_desc
		,p.query_plan

		--,q.*
FROM
	sys.query_store_plan AS p
	JOIN sys.query_store_query AS q
		ON p.query_id = q.query_id
WHERE
	1=1
AND OBJECT_NAME(q.object_id) LIKE '%stored_proc%'
 
 
ORDER BY 
	p.last_execution_time AT TIME ZONE 'US Eastern Standard Time' desc