use master
go

DECLARE @Domain NVARCHAR(100)
DECLARE @Port NVARCHAR(100)
declare @AG_Listener nvarchar(15)
EXEC master.dbo.xp_regread 'HKEY_LOCAL_MACHINE', 'SYSTEM\CurrentControlSet\services\Tcpip\Parameters', N'Domain',@Domain OUTPUT
SET @port = (SELECT port FROM sys.dm_tcp_listener_states WHERE listener_id = 1)
set @AG_Listener = (Select dns_name FROM sys.availability_group_listeners AGL JOIN sys.availability_groups AG ON AGL.group_id = AG.group_id WHERE (select SERVERPROPERTY('IsHADREnabled')) = 1)

begin
SELECT 'MSSQLSvc/' + CAST(SERVERPROPERTY('MachineName') AS NVARCHAR) + '.' + @Domain + ':' + @Port
UNION
SELECT 'MSSQLSvc/' + CAST(SERVERPROPERTY('MachineName') AS NVARCHAR) + '.' + @Domain +
CASE WHEN SERVERPROPERTY('InstanceName') IS NULL THEN'' ELSE ':' + CAST(SERVERPROPERTY('InstanceName') AS NVARCHAR) END
UNION
SELECT 'MSSQLSvc/' + @AG_Listener + '.' + @Domain + ':' + @Port WHERE @AG_Listener IS NOT NULL
UNION
SELECT 'MSSQLSvc/' + @AG_Listener + '.' + @Domain WHERE @AG_Listener IS NOT NULL
END
