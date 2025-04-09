Set-ExecutionPolicy Unrestricted
Get-ClusterGroup -Name "SQL Server*", "*_AG*", "*AG_*" | Select -ExpandProperty Name 
