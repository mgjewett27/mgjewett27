#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Join-Path $PSScriptRoot '..\SqlAutoInstall'
    $script:exampleConfig = Join-Path $PSScriptRoot '..\config\config.example.psd1'
    Import-Module (Join-Path $moduleRoot 'SqlAutoInstall.psd1') -Force
}

Describe 'Get-BuildConfig' {
    It 'loads the example config and resolves ini paths against the config folder' {
        InModuleScope SqlAutoInstall -Parameters @{ Path = $exampleConfig } {
            $config = Get-BuildConfig -Path $Path
            $config.Environments.Count | Should -BeGreaterThan 0
            $ini = $config.Environments[0].Media['2022'].Ini
            [System.IO.Path]::IsPathRooted($ini) | Should -BeTrue
            $ini | Should -Match '\\ini\\ConfigurationFile_2022\.ini$'
        }
    }

    It 'throws a helpful error when the config file is missing' {
        InModuleScope SqlAutoInstall {
            { Get-BuildConfig -Path 'TestDrive:\nope.psd1' } | Should -Throw '*config.example.psd1*'
        }
    }

    It 'throws when a required key is missing' {
        InModuleScope SqlAutoInstall {
            Set-Content -Path 'TestDrive:\bad.psd1' -Value "@{ LogPath = 'C:\x' }"
            { Get-BuildConfig -Path 'TestDrive:\bad.psd1' } | Should -Throw '*missing required keys*'
        }
    }
}

Describe 'Resolve-BuildEnvironment' {
    BeforeAll {
        $script:config = @{
            Environments = @(
                @{ Name = 'Dev'; HostnamePattern = '^sqldev' }
                @{ Name = 'Prd'; HostnamePattern = '^sqlprd' }
            )
        }
    }

    It 'matches on hostname pattern' {
        InModuleScope SqlAutoInstall -Parameters @{ Config = $config } {
            (Resolve-BuildEnvironment -Config $Config -ComputerName 'sqlprd01.corp.example.com').Name | Should -Be 'Prd'
        }
    }

    It 'uses an explicit name over the hostname' {
        InModuleScope SqlAutoInstall -Parameters @{ Config = $config } {
            (Resolve-BuildEnvironment -Config $Config -ComputerName 'sqlprd01' -Name 'Dev').Name | Should -Be 'Dev'
        }
    }

    It 'throws when nothing matches' {
        InModuleScope SqlAutoInstall -Parameters @{ Config = $config } {
            { Resolve-BuildEnvironment -Config $Config -ComputerName 'web01' } | Should -Throw '*-Environment*'
        }
    }
}

Describe 'Resolve-NetBiosDomain' {
    It 'maps the DNS domain to the NetBIOS domain' {
        InModuleScope SqlAutoInstall {
            $config = @{ DomainMap = @{ 'domaina\.example\.com$' = 'DOMAINA' } }
            Resolve-NetBiosDomain -Config $config -DnsDomain 'domaina.example.com' | Should -Be 'DOMAINA'
            { Resolve-NetBiosDomain -Config $config -DnsDomain 'other.local' } | Should -Throw
        }
    }
}

Describe 'Expand-IniTemplate' {
    It 'replaces tokens and the legacy ##MyUser## token' {
        InModuleScope SqlAutoInstall {
            $result = Expand-IniTemplate -Template 'A="{{SQLSVCACCOUNT}}" B="##MyUser##" C="{{SQLUSERDBDIR}}"' -Tokens @{ SQLSVCACCOUNT = 'DOM\svc'; SQLUSERDBDIR = 'E:\MSSQL\SQLDATA' }
            $result | Should -Be 'A="DOM\svc" B="DOM\svc" C="E:\MSSQL\SQLDATA"'
        }
    }

    It 'throws on unresolved tokens' {
        InModuleScope SqlAutoInstall {
            { Expand-IniTemplate -Template '{{SQLSVCACCOUNT}} {{MISSING}}' -Tokens @{ SQLSVCACCOUNT = 'x' } } | Should -Throw '*MISSING*'
        }
    }

    It 'renders the shipped <_> example ini with the tokens StageMedia supplies' -ForEach '2017', '2019', '2022', '2025' {
        InModuleScope SqlAutoInstall -Parameters @{ Root = $moduleRoot; Version = $_ } {
            $template = Get-Content -Path (Join-Path $Root "..\ini\ConfigurationFile_$Version.example.ini") -Raw
            $tokens = @{ INSTANCENAME = 'MSSQLSERVER'; SQLSVCACCOUNT = 'D\s'; SQLUSERDBDIR = 'E:\'; SQLUSERDBLOGDIR = 'F:\'; SQLTEMPDBDIR = 'G:\'; SQLTEMPDBLOGDIR = 'G:\' }
            { Expand-IniTemplate -Template $template -Tokens $tokens } | Should -Not -Throw
        }
    }

    It 'leaves 2019+ only options out of the 2017 ini, setup fails on them' {
        $ini = Get-Content -Path (Join-Path $moduleRoot '..\ini\ConfigurationFile_2017.example.ini')
        $settings = $ini | Where-Object { $_ -notmatch '^\s*;' }
        $settings | Should -Not -Match '^\s*(SQLMAXDOP|SQLMAXMEMORY|SQLMINMEMORY|USESQLRECOMMENDEDMEMORYLIMITS)\s*='
    }
}

Describe 'Example config' {
    It 'defines Dev, Int, Stg and Prd, each with a base monitor and media for every version' {
        InModuleScope SqlAutoInstall -Parameters @{ Path = $exampleConfig } {
            $config = Get-BuildConfig -Path $Path
            $config.Environments.Name | Should -Be @('Dev', 'Int', 'Stg', 'Prd')
            foreach ($environment in $config.Environments) {
                $environment.BaseMonitorName | Should -Not -BeNullOrEmpty
                $environment.Media.Keys | Sort-Object | Should -Be @('2017', '2019', '2022', '2025')
            }
        }
    }

    It 'rejects a malformed Sha256' {
        InModuleScope SqlAutoInstall -Parameters @{ Path = $exampleConfig } {
            (Get-Content -Path $Path -Raw).Replace("Sha256 = ''", "Sha256 = 'not-a-hash'") | Set-Content -Path 'TestDrive:\badhash.psd1'
            { Get-BuildConfig -Path 'TestDrive:\badhash.psd1' } | Should -Throw '*invalid Sha256*'
        }
    }
}

Describe 'Invoke-StageMediaPhase' {
    BeforeEach {
        InModuleScope SqlAutoInstall {
            $script:goodHash = 'A' * 64
            $script:stageContext = @{
                ComputerName      = 'sqldev01'
                Session           = 'session'
                SqlVersion        = '2022'
                Config            = @{ TargetWorkingPath = 'C:\SqlAutoInstall'; InstanceName = 'MSSQLSERVER' }
                Directories       = @{ Data = 'E:\D'; Log = 'F:\L'; TempDBData = 'G:\T'; TempDBLog = 'G:\TL' }
                Media             = @{ Iso = '\\share\SQL2022.iso'; Ini = '\\share\2022.ini'; Sha256 = $goodHash }
                ServiceCredential = [pscredential]::new('D\svc', (New-Object System.Security.SecureString))
            }
            Mock Invoke-Command {} -RemoveParameterType Session
            Mock Write-BuildLog {}
            Mock Copy-Item {}
            Mock Set-Content {}
            Mock Get-Content { 'SQLSVCACCOUNT="{{SQLSVCACCOUNT}}"' }
            Mock Get-Item { [pscustomobject]@{ Name = 'SQL2022.iso'; Length = 100; FullName = '\\share\SQL2022.iso' } }
        }
    }

    It 'skips the copy when the staged ISO matches size and hash' {
        InModuleScope SqlAutoInstall {
            Mock Test-Path { $true }
            Mock Get-StagedFileHash { $goodHash } -RemoveParameterType Session
            Invoke-StageMediaPhase -Context $stageContext
            Should -Invoke Copy-Item -Times 0 -ParameterFilter { $Path -like '*.iso' }
        }
    }

    It 'copies again when the staged ISO hash is wrong' {
        InModuleScope SqlAutoInstall {
            Mock Test-Path { $true }
            $script:hashCalls = 0
            Mock Get-StagedFileHash { $script:hashCalls++; if ($script:hashCalls -eq 1) { 'B' * 64 } else { $goodHash } } -RemoveParameterType Session
            Invoke-StageMediaPhase -Context $stageContext
            Should -Invoke Copy-Item -Times 1 -Exactly
        }
    }

    It 'fails when the copied ISO does not match its hash' {
        InModuleScope SqlAutoInstall {
            Mock Test-Path { $false }
            Mock Get-StagedFileHash { 'B' * 64 } -RemoveParameterType Session
            { Invoke-StageMediaPhase -Context $stageContext } | Should -Throw '*corrupt*'
            Should -Invoke Set-Content -Times 0
        }
    }

    It 'warns but continues when no hash is configured' {
        InModuleScope SqlAutoInstall {
            Mock Test-Path { $false }
            Mock Get-StagedFileHash {} -RemoveParameterType Session
            $stageContext.Media.Sha256 = ''
            Invoke-StageMediaPhase -Context $stageContext
            Should -Invoke Get-StagedFileHash -Times 0
            Should -Invoke Write-BuildLog -ParameterFilter { $Level -eq 'Warning' -and $Message -like '*integrity not checked*' }
        }
    }
}

Describe 'Invoke-MonitoringPhase' {
    BeforeEach {
        InModuleScope SqlAutoInstall {
            #Redgate's module is not installed on build agents, stub its commands so they can be mocked
            function script:Connect-RedgateMonitor { param($ServerUrl, $AuthToken) }
            function script:Get-SqlMonitorBaseMonitor { param($Name) }
            function script:Get-SqlMonitorGroup { param([Parameter(Position = 0)]$Name, $BaseMonitor) }
            function script:New-SqlMonitorWindowsHost { param($HostName, $BaseMonitor, $Group) }
            function script:Add-SqlMonitorMonitoredObject { param([Parameter(ValueFromPipeline)]$InputObject) process {} }
            Mock Import-Module {}
            Mock Write-BuildLog {}
            Mock Connect-RedgateMonitor {}
            Mock Get-SqlMonitorBaseMonitor { [pscustomobject]@{ Name = $Name } }
            Mock Get-SqlMonitorGroup { [pscustomobject]@{ Name = $Name } }
            Mock New-SqlMonitorWindowsHost { [pscustomobject]@{ HostName = $HostName } }
            Mock Add-SqlMonitorMonitoredObject {}
            $script:monitorContext = @{
                ComputerName    = 'sqlprd01'
                MissionCritical = $false
                RedgateToken    = (ConvertTo-SecureString -String 'tok' -AsPlainText -Force)
                Config          = @{ Monitoring = @{ ModulePath = 'x'; ServerUrl = 'https://rg'; BaseMonitorName = 'default-monitor'; MissionCriticalGroup = '0 - Mission Critical' } }
                Environment     = @{ MonitorGroup = '1 - Production'; BaseMonitorName = 'prod-monitor' }
            }
        }
    }

    It 'uses the environment base monitor over the global default' {
        InModuleScope SqlAutoInstall {
            Invoke-MonitoringPhase -Context $monitorContext
            Should -Invoke Get-SqlMonitorBaseMonitor -ParameterFilter { $Name -eq 'prod-monitor' }
            Should -Invoke Get-SqlMonitorGroup -ParameterFilter { $Name -eq '1 - Production' }
        }
    }

    It 'falls back to the global base monitor and uses the Mission Critical group' {
        InModuleScope SqlAutoInstall {
            $monitorContext.Environment.Remove('BaseMonitorName')
            $monitorContext.MissionCritical = $true
            Invoke-MonitoringPhase -Context $monitorContext
            Should -Invoke Get-SqlMonitorBaseMonitor -ParameterFilter { $Name -eq 'default-monitor' }
            Should -Invoke Get-SqlMonitorGroup -ParameterFilter { $Name -eq '0 - Mission Critical' }
        }
    }

    It 'fails when the base monitor does not exist' {
        InModuleScope SqlAutoInstall {
            Mock Get-SqlMonitorBaseMonitor { $null }
            { Invoke-MonitoringPhase -Context $monitorContext } | Should -Throw "*base monitor 'prod-monitor' not found*"
            Should -Invoke Add-SqlMonitorMonitoredObject -Times 0
        }
    }
}

Describe 'Expand-ScriptToken' {
    It 'replaces tokens in memory' {
        InModuleScope SqlAutoInstall {
            Expand-ScriptToken -Content 'EXEC x ##BACKUP_LOCATION##' -Tokens @{ '##BACKUP_LOCATION##' = "@Directory = N'\\b'" } |
                Should -Be "EXEC x @Directory = N'\\b'"
        }
    }
}

Describe 'Resolve-SqlDirectory' {
    BeforeAll {
        $script:labels = @{ VolumeLabels = @{ Data = @('SQLData', 'SQL_Data'); Log = @('SQLLog'); TempDB = @('TempDB') } }
    }

    It 'builds paths from labelled volumes, matching labels case-insensitively' {
        InModuleScope SqlAutoInstall -Parameters @{ Config = $labels } {
            $volumes = @(
                [pscustomobject]@{ DriveLetter = 'E'; FileSystemLabel = 'sql_data' }
                [pscustomobject]@{ DriveLetter = 'F'; FileSystemLabel = 'SQLLog' }
                [pscustomobject]@{ DriveLetter = 'G'; FileSystemLabel = 'TempDB' }
            )
            $dirs = Resolve-SqlDirectory -Config $Config -Volumes $volumes
            $dirs.Data | Should -Be 'E:\MSSQL\SQLDATA'
            $dirs.Log | Should -Be 'F:\MSSQL\SQLLOG'
            $dirs.TempDBData | Should -Be 'G:\MSSQL\TEMPDB_SQLDATA'
        }
    }

    It 'throws when a volume label is missing instead of building ":\MSSQL"' {
        InModuleScope SqlAutoInstall -Parameters @{ Config = $labels } {
            $volumes = @([pscustomobject]@{ DriveLetter = 'E'; FileSystemLabel = 'SQLData' })
            { Resolve-SqlDirectory -Config $Config -Volumes $volumes } | Should -Throw '*Log*'
        }
    }
}

Describe 'ConvertTo-AdminSharePath' {
    It 'converts local paths to admin share paths' {
        InModuleScope SqlAutoInstall {
            ConvertTo-AdminSharePath -ComputerName 'sql01' -LocalPath 'C:\SqlAutoInstall\Media' | Should -Be '\\sql01\C$\SqlAutoInstall\Media'
            ConvertTo-AdminSharePath -ComputerName 'sql01' -LocalPath 'C:\' | Should -Be '\\sql01\C$'
        }
    }
}

Describe 'Vault' {
    It 'reads KV v2 secrets from data.data' {
        InModuleScope SqlAutoInstall {
            Mock Invoke-RestMethod { [pscustomobject]@{ data = [pscustomobject]@{ data = [pscustomobject]@{ password = 'p$ss' } } } } -ParameterFilter { $Uri -like '*/v1/kv/data/CLUSTER01' }
            $session = [pscustomobject]@{ Address = 'https://vault'; Token = 't'; SecretNamespace = 'ns' }
            $secret = Get-VaultSecret -Session $session -Mount kv -Name CLUSTER01 -KvVersion 2
            $secret.password | Should -Be 'p$ss'
        }
    }

    It 'reads KV v1 secrets from data' {
        InModuleScope SqlAutoInstall {
            Mock Invoke-RestMethod { [pscustomobject]@{ data = [pscustomobject]@{ Username = 'svc' } } } -ParameterFilter { $Uri -like '*/v1/kv/CLUSTER01' }
            $session = [pscustomobject]@{ Address = 'https://vault'; Token = 't'; SecretNamespace = 'ns' }
            (Get-VaultSecret -Session $session -Mount kv -Name CLUSTER01 -KvVersion 1).Username | Should -Be 'svc'
        }
    }

    It 'finds fields regardless of case and throws on missing or empty fields' {
        InModuleScope SqlAutoInstall {
            $secret = [pscustomobject]@{ password = 'x'; Username = '' }
            Get-SecretField -Secret $secret -Field 'Password' -SecretName 's' | Should -Be 'x'
            { Get-SecretField -Secret $secret -Field 'Username' -SecretName 's' } | Should -Throw '*Username*'
            { Get-SecretField -Secret $secret -Field 'Other' -SecretName 's' } | Should -Throw
        }
    }
}

Describe 'Build state' {
    It 'records completed phases and reads them back' {
        InModuleScope SqlAutoInstall {
            $path = Get-BuildStatePath -LogPath 'TestDrive:\' -ComputerName 'sql01.example.com'
            $state = Get-BuildState -Path $path
            Test-PhaseCompleted -State $state -Phase 'StageMedia' | Should -BeFalse

            $state.SqlVersion = '2022'
            Add-CompletedPhase -Path $path -State $state -Phase 'StageMedia'
            Add-CompletedPhase -Path $path -State $state -Phase 'StageMedia'

            $reloaded = Get-BuildState -Path $path
            $reloaded.SqlVersion | Should -Be '2022'
            Test-PhaseCompleted -State $reloaded -Phase 'StageMedia' | Should -BeTrue
            @($reloaded.CompletedPhases).Count | Should -Be 1
        }
    }
}

Describe 'Invoke-PreflightPhase' {
    BeforeEach {
        InModuleScope SqlAutoInstall -Parameters @{ Path = $exampleConfig } {
            $script:testConfig = Get-BuildConfig -Path $Path
            $script:goodFacts = [pscustomobject]@{
                Domain = 'domaina.example.com'; PartOfDomain = $true; ClusterName = 'CLUSTER01'; PendingReboot = $false
                SystemFreeGB = 50; InstalledInstances = @()
                Volumes = @(
                    [pscustomobject]@{ DriveLetter = 'E'; FileSystemLabel = 'SQLData'; FileSystem = 'NTFS'; AllocationUnitSize = 65536 }
                    [pscustomobject]@{ DriveLetter = 'F'; FileSystemLabel = 'SQLLog'; FileSystem = 'NTFS'; AllocationUnitSize = 65536 }
                    [pscustomobject]@{ DriveLetter = 'G'; FileSystemLabel = 'TempDB'; FileSystem = 'NTFS'; AllocationUnitSize = 65536 }
                )
            }
            Mock Test-Path { $true }
            Mock Connect-Vault { [pscustomobject]@{ Token = 't' } }
            Mock Disconnect-Vault {}
            Mock Get-VaultSecret { [pscustomobject]@{ username = 'svc_sql'; password = 'pw'; Auth_Token = 'tok' } }
            Mock Write-BuildLog {}
        }
    }

    It 'fills the context with directories and credentials when every check passes' {
        InModuleScope SqlAutoInstall {
            Mock Get-TargetFact { $goodFacts } -RemoveParameterType Session
            $context = @{ ComputerName = 'sqldev01.domaina.example.com'; Session = 'session'; Config = $testConfig; Environment = $testConfig.Environments[0]; SqlVersion = '2022'; MissionCritical = $false }
            Invoke-PreflightPhase -Context $context -State @{ CompletedPhases = @() }
            $context.Directories.Data | Should -Be 'E:\MSSQL\SQLDATA'
            $context.ServiceCredential.UserName | Should -Be 'DOMAINA\svc_sql'
            Should -Invoke Disconnect-Vault -Times 1
        }
    }

    It 'collects every failure and throws before any change' {
        InModuleScope SqlAutoInstall {
            $badFacts = $goodFacts.PSObject.Copy()
            $badFacts.ClusterName = $null
            $badFacts.PendingReboot = $true
            $badFacts.Volumes = @($goodFacts.Volumes[0])
            Mock Get-TargetFact { $badFacts } -RemoveParameterType Session
            $context = @{ ComputerName = 'sqldev01.domaina.example.com'; Session = 'session'; Config = $testConfig; Environment = $testConfig.Environments[0]; SqlVersion = '2022'; MissionCritical = $true }
            { Invoke-PreflightPhase -Context $context -State @{ CompletedPhases = @() } } | Should -Throw '*Preflight failed with 4 issue*'
            Should -Invoke Connect-Vault -Times 0
        }
    }

    It 'fails on the wrong allocation unit size' {
        InModuleScope SqlAutoInstall {
            $facts = $goodFacts.PSObject.Copy()
            $facts.Volumes = @($goodFacts.Volumes[0], $goodFacts.Volumes[1], [pscustomobject]@{ DriveLetter = 'G'; FileSystemLabel = 'TempDB'; FileSystem = 'NTFS'; AllocationUnitSize = 4096 })
            Mock Get-TargetFact { $facts } -RemoveParameterType Session
            $context = @{ ComputerName = 'sqldev01.domaina.example.com'; Session = 'session'; Config = $testConfig; Environment = $testConfig.Environments[0]; SqlVersion = '2022'; MissionCritical = $false }
            { Invoke-PreflightPhase -Context $context -State @{ CompletedPhases = @() } } | Should -Throw '*1 issue*'
            Should -Invoke Write-BuildLog -ParameterFilter { $Message -like '*allocation unit is 4096*' }
        }
    }
}

Describe 'Invoke-SqlBuild' {
    BeforeEach {
        InModuleScope SqlAutoInstall {
            Mock Start-Transcript {}
            Mock Stop-Transcript {}
            Mock Write-BuildLog {}
            Mock New-BuildSession { $null }
            Mock Remove-PSSession {}
            Mock Invoke-PreflightPhase {}
            foreach ($name in 'StageMedia', 'InstallSql', 'Patch', 'ServerConfig', 'InstanceSetup', 'Monitoring') {
                Mock "Invoke-$($name)Phase" {}
            }
            Mock Test-SqlBuild { [pscustomobject]@{ Status = 'Pass'; Check = 'x'; Expected = ''; Actual = '' } }
        }
        #TestDrive is shared by every It in a Describe, start each test without a state file
        Remove-Item -Path (Join-Path $TestDrive 'Logs') -Recurse -Force -ErrorAction SilentlyContinue
        $script:config = Join-Path $TestDrive 'config.psd1'
        (Get-Content $exampleConfig -Raw).Replace("'C:\SqlAutoInstall\Logs'", "'$TestDrive\Logs'").Replace('..\ini\', "$PSScriptRoot\..\ini\") | Set-Content $config
    }

    It 'runs Preflight but no changing phase under -WhatIf' {
        $result = Invoke-SqlBuild -ComputerName localhost -SqlVersion 2022 -Environment Dev -ConfigPath $config -WhatIf
        $result.Result | Should -Be 'Succeeded'
        Should -Invoke Invoke-PreflightPhase -ModuleName SqlAutoInstall -Times 1
        Should -Invoke Invoke-InstallSqlPhase -ModuleName SqlAutoInstall -Times 0
        Should -Invoke Test-SqlBuild -ModuleName SqlAutoInstall -Times 0
    }

    It 'skips completed phases on a rerun' {
        Invoke-SqlBuild -ComputerName localhost -SqlVersion 2022 -Environment Dev -ConfigPath $config | Out-Null
        Invoke-SqlBuild -ComputerName localhost -SqlVersion 2022 -Environment Dev -ConfigPath $config | Out-Null
        Should -Invoke Invoke-InstallSqlPhase -ModuleName SqlAutoInstall -Times 1 -Exactly
        Should -Invoke Test-SqlBuild -ModuleName SqlAutoInstall -Times 2 -Exactly
    }

    It 'resumes at the failed phase' {
        InModuleScope SqlAutoInstall { Mock Invoke-PatchPhase { throw 'CU failed' } }
        $first = Invoke-SqlBuild -ComputerName localhost -SqlVersion 2022 -Environment Dev -ConfigPath $config
        $first.Result | Should -Be 'Failed'
        $first.Phase | Should -Be 'Patch'

        InModuleScope SqlAutoInstall { Mock Invoke-PatchPhase {} }
        $second = Invoke-SqlBuild -ComputerName localhost -SqlVersion 2022 -Environment Dev -ConfigPath $config
        $second.Result | Should -Be 'Succeeded'
        #Phases before Patch ran once, Patch ran on the failed run and again on resume
        Should -Invoke Invoke-InstallSqlPhase -ModuleName SqlAutoInstall -Times 1 -Exactly
        Should -Invoke Invoke-PatchPhase -ModuleName SqlAutoInstall -Times 2 -Exactly
        Should -Invoke Invoke-ServerConfigPhase -ModuleName SqlAutoInstall -Times 1 -Exactly
    }

    It 'fails the build when validation has a failed check' {
        InModuleScope SqlAutoInstall { Mock Test-SqlBuild { [pscustomobject]@{ Status = 'Fail'; Check = 'sa disabled'; Expected = ''; Actual = '' } } }
        $result = Invoke-SqlBuild -ComputerName localhost -SqlVersion 2022 -Environment Dev -ConfigPath $config
        $result.Result | Should -Be 'Failed'
        $result.Error | Should -BeLike '*sa disabled*'
    }

    It 'refuses to continue a build that was started with another SQL version' {
        Invoke-SqlBuild -ComputerName localhost -SqlVersion 2022 -Environment Dev -ConfigPath $config | Out-Null
        $result = Invoke-SqlBuild -ComputerName localhost -SqlVersion 2019 -Environment Dev -ConfigPath $config
        $result.Result | Should -Be 'Failed'
        $result.Error | Should -BeLike '*-Force*'
    }
}
