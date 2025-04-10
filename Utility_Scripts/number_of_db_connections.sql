USE MASTER
GO
 
DECLARE @DML nvarchar(MAX)
DECLARE @SQLShackUserConn TABLE
(
DBName [nvarchar](128) NULL,
No_Of_Connections [int] NULL
)
 
SET @DML='
SELECT DB_NAME(dbid) DBName,COUNT(*) No_Of_Connections FROM sys.sysprocesses --where kpid>0
group by DB_NAME(dbid)
ORDER BY DB_NAME(dbid) DESC OPTION (RECOMPILE)
'
 
INSERT INTO @SQLShackUserConn
EXEC sp_executesql @DML
 
select * from @SQLShackUserConn
ORDER BY No_Of_Connections DESC
