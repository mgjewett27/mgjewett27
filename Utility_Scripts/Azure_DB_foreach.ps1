### Obtain the Access Token: this will bring up the login dialog
Connect-AzAccount -UseDeviceAuthentication
$access_token = (Get-AzAccessToken -ResourceUrl https://database.windows.net).Token

#Set instance variables, server, get databases, and queries to run
$PROD_instance = '<#Azure_SQL_DB_Instance#>'
$PROD_databases = Invoke-sqlcmd -serverinstance $PROD_instance -Database master -AccessToken $access_token -Query "select name from sys.databases"
$PROD_database_names = $PROD_databases | Select-Object -ExpandProperty name
$User_creation_query = "CREATE USER <#User#> FOR LOGIN <#Login#> WITH DEFAULT_SCHEMA=[dbo]"
$User_permission_query = "EXEC sp_addrolemember N'db_owner', N'<#User#>'"
$Enable_cdc = "EXEC sys.sp_cdc_enable_db"

#Loop through database list, running specified query on each database using Service account to authenticate
foreach ($database in $PROD_database_names) {
    Invoke-Sqlcmd -ServerInstance $PROD_instance -Database $database -AccessToken $access_token -Query $emable_cdc  -TrustServerCertificate
}


