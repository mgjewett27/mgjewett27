Set-ExecutionPolicy "Unrestricted"
$cluster_name = Get-Cluster | select -ExpandProperty Name 
$domain_name = Get-WmiObject -Namespace root\cimv2 -Class Win32_ComputerSystem | Select -ExpandProperty Domain

$FQDN_cluster = "$cluster_name.$domain_name"

$FQDN_cluster
