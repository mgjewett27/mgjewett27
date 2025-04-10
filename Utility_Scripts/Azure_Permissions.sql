-- =======================================================================================
-- Create User as DBO template for Azure SQL Database and Azure Synapse Analytics Database
-- =======================================================================================
-- For login login_name, create a user in the database
CREATE USER <user_name, sysname, user_name>
	FOR LOGIN <login_name, sysname, login_name>
	WITH DEFAULT_SCHEMA = <default_schema, sysname, dbo>
GO

-- =======================================================================================
-- Create Azure Active Directory User for Azure SQL Database and Azure Synapse Analytics Database
-- =======================================================================================
-- For login <login_name, sysname, login_name>, create a user in the database
-- CREATE USER <Azure_Active_Directory_Principal_User, sysname, user_name>
--    [   { FOR | FROM } LOGIN <Azure_Active_Directory_Principal_Login, sysname, login_name>  ]  
--    | FROM EXTERNAL PROVIDER
--    [ WITH DEFAULT_SCHEMA = <default_schema, sysname, dbo> ]
-- GO

--Used to see what accounts have access to the database, as well as the account type of level of access granted
SELECT DISTINCT pr.principal_id, pr.name, pr.type_desc, 
    pr.authentication_type_desc, pe.state_desc, pe.permission_name
FROM sys.database_principals AS pr
JOIN sys.database_permissions AS pe
    ON pe.grantee_principal_id = pr.principal_id;