SELECT 
(SUM(unallocated_extent_page_count)*1.0/128) AS [Free space(MB)]
,(SUM(version_store_reserved_page_count)*1.0/128)  AS [Used Space by VersionStore(MB)]
,(SUM(internal_object_reserved_page_count)*1.0/128)  AS [Used Space by InternalObjects(MB)]
,(SUM(user_object_reserved_page_count)*1.0/128)  AS [Used Space by UserObjects(MB)]
FROM tempdb.sys.dm_db_file_space_usage;