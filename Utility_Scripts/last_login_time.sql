SELECT login_name [Login] , MAX(login_time) AS [Last Login Time]
FROM sys.dm_exec_sessions
WHERE login_name IN ('')
GROUP BY login_name
