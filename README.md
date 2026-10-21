## Hi there 👋

I'm a SQL Server DBA with a focus on PowerShell and automation. This repo collects PowerShell tools and T-SQL scripts I've built and used day to day to install, patch, troubleshoot and look after SQL Server estates, including Always On Availability Groups and failover clusters.

**LinkedIn:** https://www.linkedin.com/in/michaelgjewett/

**Tools I work with:** SQL Server 2017–2025 · PowerShell · [dbatools](https://dbatools.io) · Windows Server Failover Clustering · Always On AGs · HashiCorp Vault · Redgate Monitor · Azure SQL · Pester · GitHub Actions

---

## Featured: SqlAutoInstall

[![SqlAutoInstall CI](https://github.com/mgjewett27/mgjewett27/actions/workflows/sqlautoinstall-ci.yml/badge.svg)](https://github.com/mgjewett27/mgjewett27/actions/workflows/sqlautoinstall-ci.yml)

[**Automated Install**](Automated%20Install/) is a PowerShell module that turns a blank Windows cluster node into a production-ready SQL Server instance with one command, run from a DBA jump box:

```powershell
Invoke-SqlBuild -ComputerName sqldev01 -SqlVersion 2022
```

- Unattended install from a standard ini file, with service account secrets pulled from HashiCorp Vault
- Patching to the latest CU minus one, with automatic reboots
- HADR enabled and ready for an Availability Group build
- Ola Hallengren maintenance and backup jobs, monitoring access, and `sa` disabled
- Registration in Redgate Monitor
- A pass/fail validation report at the end of every build
- Read-only preflight checks, resume after failure, `-WhatIf` dry runs, Pester tests and CI

See the [SqlAutoInstall README](Automated%20Install/README.md) for the full guide.

---

## What's in the repo

### PowerShell tools

| Folder | What it does |
|---|---|
| [Automated Install](Automated%20Install/) | **SqlAutoInstall** (above): builds a blank VM into a patched, maintained and monitored SQL Server instance. |
| [AG Rebuild](AG%20Rebuild/) | Rebuilds a database that has stopped synchronizing in an Availability Group. It pauses log backups, takes fresh full and log backups, removes the database from the AG, restores it on the secondaries, rejoins it, then turns log backups back on. `AG_Rebuild.ps1 -Instance <listener> -Database <db>` |
| [SPN_Tool](SPN_Tool/) | Checks, registers or removes SQL Server SPNs for a node, named instance, cluster or AG listener. Picks the right domain service account and gets its credentials from Vault. Includes T-SQL helpers that generate the expected SPNs and show the service account. `SPN_Fix_tool.ps1 -Instance_Name SQL01 -Action Check` |
| [CU_Update](CU_Update/) | Brings a standalone instance to the latest Cumulative Update. Checks for a pending reboot, works out the SQL version (2017, 2019 or 2022), copies the newest CU from the repository, installs it with dbatools, then compares the build before and after. |
| [Patching](Patching/) | A menu-driven helper for patch nights on clustered SQL Servers: pre- and post-patch health checks (including MSDTC), pausing and resuming delayed durability, log and full backup jobs, cluster role start/stop/verify, automated cluster failovers, and scheduling a procedure cache flush. `Development/` holds a reworked dbatools version that checks all servers at once. Includes small helpers to find a cluster's FQDN and its SQL and AG roles. |

### T-SQL utility scripts

[Utility_Scripts](Utility_Scripts/) is my everyday troubleshooting kit. It's a mix of my own queries and well-known community ones.

| Area | Scripts |
|---|---|
| **Activity and blocking** | `whoisactive.sql` (calls [sp_WhoIsActive](https://github.com/amachanic/sp_whoisactive)), `DMTablesActiveSessions.sql`, `Long_running_transaction.sql`, `Version_store_transaction.sql`, `number_of_db_connections.sql`, `Auth_Scheme.sql` (Kerberos vs NTLM per session) |
| **Space and growth** | `db_free_space.sql`, `Fill_growth_query.sql`, `Log_space.sql`, `database_log_stats.sql`, `TempDB_size.sql`, `Largest_tables.sql` |
| **Performance** | `Top20_procs.sql`, `Index_fragmentation.sql`, `Most_used_tables.sql`, `table_reads_writes.sql`, `last_proc_execution.sql`, `Query_id_script.sql` (Query Store plan lookup), `Query_snapshot_cleanup.sql` |
| **Operations** | `restore_progress.sql` (backup and restore percent complete with ETA), `last_login_time.sql`, `rev_login.sql` (Microsoft's `sp_help_revlogin`, for moving logins with their SIDs and passwords), `Generate_SPNs.sql` |
| **Azure SQL** | `Azure_DB_foreach.ps1` (runs queries against every database on an Azure SQL server using an Entra ID token), `Azure_Permissions.sql` (template for creating a database user as dbo) |

### Archive

[Archive](Archive/) keeps earlier versions of tools that have been replaced, such as the 2022 and 2025 Automated Install scripts and the first SPN Fix tool, for reference.

---

## Using these scripts

- **Placeholders:** environment-specific values (server names, shares, Vault paths, job names) have been replaced with placeholders like `<#Vault address#>`. Fill them in for your own environment before running anything.
- **Prerequisites:** most PowerShell tools need the [dbatools](https://dbatools.io) module (`Install-Module dbatools`). Run them as an account with the admin rights each script needs.
- **Test first:** try everything in a non-production environment first. These are tools I've used in real environments, shared as-is with no warranty.

More to come...
