use PerfDB
GO

DECLARE 
	 @DeleteDate DATETIME
	,@DeleteCnt INT
	,@row_count INT
	,@history_count INT

SET @DeleteDate = DATEADD(DAY,-366,GETDATE());
SET @DeleteCnt = 4000;
SET @row_count = 1;
SET @history_count = 0;

WHILE @row_count > 0
BEGIN
	BEGIN TRANSACTION;

DELETE TOP (@DeleteCnt)
FROM --Target table
WHERE /*Date Column*/ < @DeleteDate

set @row_count = @@ROWCOUNT
set @history_count = @history_count + @row_count

COMMIT TRANSACTION;
END

PRINT 'Removed ' + CAST(@history_count as VARCHAR(15)) + ' rows successfully'

set @history_count = 0;
set @row_count = 1;