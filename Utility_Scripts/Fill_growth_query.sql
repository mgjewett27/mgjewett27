USE PerfDB
GO

declare @Drive table(DriveName char, FreeSpaceInMegabytes int)
insert @Drive execute xp_fixeddrives

SELECT d.name AS 'Database Name',
	   dfm.file_type_desc AS 'File Type',
	   dfm.file_name AS 'File Name',
	   dfm.phsyical_file_path AS 'File Path',
	   dfm.size * 8 / 1024 AS 'File Size (MB)',
	   CASE WHEN dfm.is_percent_growth = 0
	        THEN dfm.growth * 8 / 1024
			ELSE CAST(dfm.size AS DECIMAL) / dfm.growth
		END AS 'File Growth Rate (MB)',
	   drv.FreeSpaceInMegabytes AS 'Free Space remaining (MB)',
	   CASE WHEN dfm.is_percent_growth = 0
			AND dfm.growth NOT LIKE '0'
	        THEN CAST(drv.FreeSpaceInMegabytes AS DECIMAL) / (dfm.growth * 8 / 1024)
			WHEN dfm.is_percent_growth = 0
			AND dfm.growth LIKE '0'
			THEN 'No autogrowth set for this database, please fix'
			ELSE CAST(drv.FreeSpaceInMegabytes AS DECIMAL) / (CAST(dfm.size AS DECIMAL) / dfm.growth)
		END AS 'File Growth Events Remaining'
FROM dbo.db_file_monitoring dfm
INNER JOIN sys.databases AS d
	ON d.database_id = dfm.database_ID
	LEFT JOIN @Drive drv ON
		LEFT(dfm.phsyical_file_path,1) = drv.DriveName
--WHERE d.name = 'tempdb'

