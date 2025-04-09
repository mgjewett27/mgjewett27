Set-ExecutionPolicy Unrestricted
$cluster_group = Get-ClusterGroup -Name "SQL Server*", "*_AG*", "*AG_*" | Select -ExpandProperty OwnerNode | Select -ExpandProperty Name
$domain_name = Get-WmiObject -Namespace root\cimv2 -Class Win32_ComputerSystem | Select -ExpandProperty Domain

$FQDN_cluster = "$cluster_group.$domain_name"

$FQDN_cluster
