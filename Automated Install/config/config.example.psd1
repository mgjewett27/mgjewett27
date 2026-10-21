#####################################################################################
# SqlAutoInstall configuration template
#
# Copy this file to config.psd1 in the same folder and fill in real values.
# config.psd1 is gitignored, never commit environment specific values.
#
# Paths below are read from the jump box running Invoke-SqlBuild, not the target server.
#####################################################################################
@{
    # Folder created on each target server, files are pushed to it over the C$ admin share
    TargetWorkingPath = 'C:\SqlAutoInstall'

    # Logs, state files and validation reports are written here on the jump box
    LogPath           = 'C:\SqlAutoInstall\Logs'

    # Downloaded CU files are cached here on the jump box and reused across builds
    CuCachePath       = 'C:\SqlAutoInstall\CU_Cache'

    InstanceName      = 'MSSQLSERVER'

    # How far behind the latest CU a new build should be, passed to Test-DbaBuild -MaxBehind
    CuMaxBehind       = '1CU'

    # Volume labels used to find the SQL drives, first match wins
    VolumeLabels      = @{
        Data   = @('SQLData', 'SQL_Data')
        Log    = @('SQLLog', 'SQL_Log')
        TempDB = @('TempDB')
    }

    # Expected NTFS allocation unit size for SQL volumes, Preflight fails on anything else
    AllocationUnitSize = 65536

    # Minimum free space on C: (GB) for the ISO copy and setup
    MinFreeSpaceSystemGB = 15

    # Active Directory NetBIOS domain for service accounts, keyed by a regex on the server's DNS domain
    DomainMap = @{
        'domaina\.example\.com$' = 'DOMAINA'
        'domainb\.example\.com$' = 'DOMAINB'
    }

    Vault = @{
        # KV secrets engine mount and version (1 or 2)
        KvMount   = 'kv'
        KvVersion = 2

        # Field names are matched case-insensitively
        UsernameField = 'Username'
        PasswordField = 'Password'

        # Secret holding the sa password, service account secret is looked up by cluster name
        SaSecretName      = 'sa'
        RedgateSecretName = 'RedGateMonitor'
        RedgateTokenField = 'Auth_Token'
    }

    Monitoring = @{
        # Folder containing the Redgate Monitor PowerShell API module
        ModulePath      = '\\fileshare\DBA\RedgateMonitor'
        ServerUrl       = 'https://redgate-monitor.example.com'
        # Default base monitor, used when an environment does not set its own BaseMonitorName
        BaseMonitorName = 'localhost'
        ServiceAccount  = 'DOMAINA\svc_redgate'

        # Server roles granted to the monitor login, Redgate Monitor requires sysadmin
        ServerRoles     = @('sysadmin')

        MissionCriticalGroup = '0 - Mission Critical'
    }

    # Database the maintenance objects are deployed to
    MaintenanceDatabase = 'PerfDB'

    # Run in order. Path is read from the jump box, Database is the target database.
    # Tokens from the environment's ScriptTokens are replaced in memory, the source file is never changed.
    MaintenanceScripts = @(
        @{ Path = '\\fileshare\DBA\Maintenance\MaintenanceSolution.sql'; Database = 'PerfDB' }
        @{ Path = '\\fileshare\DBA\Maintenance\Backup_Jobs.sql';         Database = 'msdb' }
        @{ Path = '\\fileshare\DBA\Maintenance\Custom_Jobs.sql';         Database = 'PerfDB' }
    )

    # Agent jobs enabled once the maintenance scripts have run
    JobsToEnable = @(
        'DatabaseBackup - SYSTEM_DATABASES - FULL'
        'DatabaseBackup - USER_DATABASES - FULL'
        'DatabaseBackup - USER_DATABASES - LOG'
        'IndexOptimize - USER_DATABASES'
    )

    # Checked first to last, the first HostnamePattern (regex on the FQDN) that matches is used.
    # Checked first to last, the first HostnamePattern (regex on the FQDN) that matches is used.
    # Override with Invoke-SqlBuild -Environment <Name>.
    #
    # Media: one entry per SQL version. Developer ISOs for non-prod, Enterprise for prod.
    #   Sha256 is optional but recommended, the staged ISO is checked against it before setup runs.
    #   Get it with: (Get-FileHash \\fileshare\DBA\ISO\SQL2022_Developer.iso).Hash
    # BaseMonitorName: optional, overrides Monitoring.BaseMonitorName for this environment.
    Environments = @(
        @{
            Name            = 'Dev'
            HostnamePattern = '^sqldev'
            IsProduction    = $false
            InstallSsms     = $true
            MonitorGroup    = '4 - Development'
            BaseMonitorName = 'nonprod-monitor'
            Vault           = @{
                Address         = 'https://vault.example.com'
                AuthNamespace   = 'admin'
                SecretNamespace = 'admin/dba'
                RoleIdPath      = 'C:\SqlAutoInstall\Secrets\dev_role_id.txt'
                SecretIdPath    = 'C:\SqlAutoInstall\Secrets\dev_secret_id.txt'
            }
            Media           = @{
                '2017' = @{ Iso = '\\fileshare\DBA\ISO\SQL2017_Developer.iso'; Ini = '..\ini\ConfigurationFile_2017.ini'; Sha256 = '' }
                '2019' = @{ Iso = '\\fileshare\DBA\ISO\SQL2019_Developer.iso'; Ini = '..\ini\ConfigurationFile_2019.ini'; Sha256 = '' }
                '2022' = @{ Iso = '\\fileshare\DBA\ISO\SQL2022_Developer.iso'; Ini = '..\ini\ConfigurationFile_2022.ini'; Sha256 = '' }
                '2025' = @{ Iso = '\\fileshare\DBA\ISO\SQL2025_Developer.iso'; Ini = '..\ini\ConfigurationFile_2025.ini'; Sha256 = '' }
            }
            ScriptTokens    = @{
                '##BACKUP_LOCATION##' = "@Directory = N''\\backupserver\SQLBackups\Dev''"
            }
        }
        @{
            Name            = 'Int'
            HostnamePattern = '^sqlint'
            IsProduction    = $false
            InstallSsms     = $true
            MonitorGroup    = '3 - Integration'
            BaseMonitorName = 'nonprod-monitor'
            Vault           = @{
                Address         = 'https://vault.example.com'
                AuthNamespace   = 'admin'
                SecretNamespace = 'admin/dba'
                RoleIdPath      = 'C:\SqlAutoInstall\Secrets\int_role_id.txt'
                SecretIdPath    = 'C:\SqlAutoInstall\Secrets\int_secret_id.txt'
            }
            Media           = @{
                '2017' = @{ Iso = '\\fileshare\DBA\ISO\SQL2017_Developer.iso'; Ini = '..\ini\ConfigurationFile_2017.ini'; Sha256 = '' }
                '2019' = @{ Iso = '\\fileshare\DBA\ISO\SQL2019_Developer.iso'; Ini = '..\ini\ConfigurationFile_2019.ini'; Sha256 = '' }
                '2022' = @{ Iso = '\\fileshare\DBA\ISO\SQL2022_Developer.iso'; Ini = '..\ini\ConfigurationFile_2022.ini'; Sha256 = '' }
                '2025' = @{ Iso = '\\fileshare\DBA\ISO\SQL2025_Developer.iso'; Ini = '..\ini\ConfigurationFile_2025.ini'; Sha256 = '' }
            }
            ScriptTokens    = @{
                '##BACKUP_LOCATION##' = "@Directory = N''\\backupserver\SQLBackups\Int''"
            }
        }
        @{
            Name            = 'Stg'
            HostnamePattern = '^sqlstg'
            IsProduction    = $false
            InstallSsms     = $false
            MonitorGroup    = '2 - Staging'
            BaseMonitorName = 'nonprod-monitor'
            Vault           = @{
                Address         = 'https://vault.example.com'
                AuthNamespace   = 'admin'
                SecretNamespace = 'admin/dba'
                RoleIdPath      = 'C:\SqlAutoInstall\Secrets\stg_role_id.txt'
                SecretIdPath    = 'C:\SqlAutoInstall\Secrets\stg_secret_id.txt'
            }
            Media           = @{
                '2017' = @{ Iso = '\\fileshare\DBA\ISO\SQL2017_Developer.iso'; Ini = '..\ini\ConfigurationFile_2017.ini'; Sha256 = '' }
                '2019' = @{ Iso = '\\fileshare\DBA\ISO\SQL2019_Developer.iso'; Ini = '..\ini\ConfigurationFile_2019.ini'; Sha256 = '' }
                '2022' = @{ Iso = '\\fileshare\DBA\ISO\SQL2022_Developer.iso'; Ini = '..\ini\ConfigurationFile_2022.ini'; Sha256 = '' }
                '2025' = @{ Iso = '\\fileshare\DBA\ISO\SQL2025_Developer.iso'; Ini = '..\ini\ConfigurationFile_2025.ini'; Sha256 = '' }
            }
            ScriptTokens    = @{
                '##BACKUP_LOCATION##' = "@Directory = N''\\backupserver\SQLBackups\Stg''"
            }
        }
        @{
            Name            = 'Prd'
            HostnamePattern = '^sqlprd'
            IsProduction    = $true
            InstallSsms     = $false
            MonitorGroup    = '1 - Production'
            BaseMonitorName = 'prod-monitor'
            Vault           = @{
                Address         = 'https://vault.example.com'
                AuthNamespace   = 'admin'
                SecretNamespace = 'admin/dba'
                RoleIdPath      = 'C:\SqlAutoInstall\Secrets\prd_role_id.txt'
                SecretIdPath    = 'C:\SqlAutoInstall\Secrets\prd_secret_id.txt'
            }
            Media           = @{
                '2017' = @{ Iso = '\\fileshare\DBA\ISO\SQL2017_Enterprise.iso'; Ini = '..\ini\ConfigurationFile_2017.ini'; Sha256 = '' }
                '2019' = @{ Iso = '\\fileshare\DBA\ISO\SQL2019_Enterprise.iso'; Ini = '..\ini\ConfigurationFile_2019.ini'; Sha256 = '' }
                '2022' = @{ Iso = '\\fileshare\DBA\ISO\SQL2022_Enterprise.iso'; Ini = '..\ini\ConfigurationFile_2022.ini'; Sha256 = '' }
                '2025' = @{ Iso = '\\fileshare\DBA\ISO\SQL2025_Enterprise.iso'; Ini = '..\ini\ConfigurationFile_2025.ini'; Sha256 = '' }
            }
            ScriptTokens    = @{
                '##BACKUP_LOCATION##' = "@Directory = N''\\backupserver\SQLBackups\Prd''"
            }
        }
    )
}