use master
go

DECLARE @Domain NVARCHAR(100)
DECLARE @Port NVARCHAR(100)
DECLARE @Service_Account NVARCHAR(100)
declare @AG_Listener nvarchar(15)
EXEC master.dbo.xp_regread 'HKEY_LOCAL_MACHINE', 'SYSTEM\CurrentControlSet\services\Tcpip\Parameters', N'Domain',@Domain OUTPUT
SET @port = (SELECT port FROM sys.dm_tcp_listener_states WHERE listener_id = 1)
SET @Service_Account = (SELECT service_account FROM sys.dm_server_services WHERE servicename LIKE 'SQL Server%' AND servicename NOT LIKE '%Agent%')
set @AG_Listener = (Select dns_name FROM sys.availability_group_listeners AGL JOIN sys.availability_groups AG ON AGL.group_id = AG.group_id WHERE (select SERVERPROPERTY('IsHADREnabled')) = 1)

begin
SELECT 'setSPN -S "MSSQLSvc/' + CAST(SERVERPROPERTY('MachineName') AS NVARCHAR) + '.' + @Domain + ':' + @Port + '"' +
' "' + @Service_Account + '"'
UNION
SELECT 'setSPN -S "MSSQLSvc/' + CAST(SERVERPROPERTY('MachineName') AS NVARCHAR) + '.' + @Domain +
CASE WHEN SERVERPROPERTY('InstanceName') IS NULL THEN '" ' ELSE ':' + CAST(SERVERPROPERTY('InstanceName') AS NVARCHAR) + '"' END + 
' "' + @Service_Account + '"'
UNION
SELECT 'setSPN -S "MSSQLSvc/' + @AG_Listener + '.' + @Domain + ':' + @Port + '"' +
' "' + @Service_Account + '"'
UNION
SELECT 'setSPN -S "MSSQLSvc/' + @AG_Listener + '.' + @Domain + '"' +
' "' + @Service_Account + '"'

END