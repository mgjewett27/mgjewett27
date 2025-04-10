DECLARE @procedureName NVARCHAR(128) = 'YourStoredProcedureName';

SELECT TOP 1
    ps.last_execution_time AS LastExecutionTime,
    ps.execution_count AS ExecutionCount,
    ps.total_elapsed_time AS TotalElapsedTime,
    ps.total_logical_reads AS TotalLogicalReads,
    ps.total_physical_reads AS TotalPhysicalReads,
    ps.total_logical_writes AS TotalLogicalWrites
FROM sys.dm_exec_procedure_stats ps
CROSS APPLY sys.dm_exec_sql_text(ps.plan_handle) st
WHERE st.objectid = OBJECT_ID(@procedureName)
ORDER BY ps.last_execution_time DESC;