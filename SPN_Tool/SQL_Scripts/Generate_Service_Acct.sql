USE master
GO

DECLARE @Service_Account NVARCHAR(100) = (SELECT service_account FROM sys.dm_server_services WHERE servicename LIKE 'SQL Server%' AND servicename NOT LIKE '%Agent%')
SELECT @Service_Account
