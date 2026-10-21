function Get-BuildConfig {
    <#
    .SYNOPSIS
        Loads config.psd1, checks required keys and resolves relative ini paths against the config folder.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -Path $Path -PathType Leaf)) {
        throw "Config file not found at '$Path'. Copy config.example.psd1 to config.psd1 and fill in your values."
    }

    $config = Import-PowerShellDataFile -Path $Path
    $configRoot = Split-Path -Path (Resolve-Path -Path $Path).Path -Parent

    $required = 'TargetWorkingPath', 'LogPath', 'CuCachePath', 'InstanceName', 'CuMaxBehind', 'VolumeLabels',
        'AllocationUnitSize', 'MinFreeSpaceSystemGB', 'DomainMap', 'Vault', 'Monitoring', 'MaintenanceDatabase',
        'MaintenanceScripts', 'JobsToEnable', 'Environments'
    $missing = $required | Where-Object { -not $config.ContainsKey($_) }
    if ($missing) {
        throw "Config '$Path' is missing required keys: $($missing -join ', ')"
    }

    foreach ($environment in $config.Environments) {
        foreach ($key in 'Name', 'HostnamePattern', 'IsProduction', 'MonitorGroup', 'Vault', 'Media') {
            if (-not $environment.ContainsKey($key)) {
                throw "Environment '$($environment.Name)' in '$Path' is missing '$key'"
            }
        }
        foreach ($media in $environment.Media.Values) {
            if ($media.Sha256 -and $media.Sha256 -notmatch '^[0-9A-Fa-f]{64}$') {
                throw "Environment '$($environment.Name)' has an invalid Sha256 for $($media.Iso), expected 64 hex characters"
            }
            if (-not [System.IO.Path]::IsPathRooted($media.Ini)) {
                $media.Ini = [System.IO.Path]::GetFullPath((Join-Path $configRoot $media.Ini))
            }
        }
    }

    $config.ConfigRoot = $configRoot
    $config
}

function Resolve-BuildEnvironment {
    <#
    .SYNOPSIS
        Returns the environment block for a server, by explicit name or the first matching HostnamePattern.
    #>
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config,

        [Parameter(Mandatory)]
        [string]$ComputerName,

        [string]$Name
    )

    if ($Name) {
        $match = $Config.Environments | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
        if (-not $match) {
            throw "Environment '$Name' is not defined in config. Defined: $($Config.Environments.Name -join ', ')"
        }
        return $match
    }

    $match = $Config.Environments | Where-Object { $ComputerName -match $_.HostnamePattern } | Select-Object -First 1
    if (-not $match) {
        throw "No environment HostnamePattern matches '$ComputerName'. Pass -Environment explicitly."
    }
    $match
}

function Resolve-NetBiosDomain {
    <#
    .SYNOPSIS
        Maps the server's DNS domain to the AD NetBIOS domain used for the service account.
    #>
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config,

        [Parameter(Mandatory)]
        [string]$DnsDomain
    )

    foreach ($pattern in $Config.DomainMap.Keys) {
        if ($DnsDomain -match $pattern) {
            return $Config.DomainMap[$pattern]
        }
    }
    throw "No DomainMap entry matches DNS domain '$DnsDomain'"
}

function Expand-IniTemplate {
    <#
    .SYNOPSIS
        Replaces {{TOKEN}} values in an ini template and fails if any token is left unresolved.
    .DESCRIPTION
        The legacy ##MyUser## token from the original ini files is mapped to SQLSVCACCOUNT.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Template,

        [Parameter(Mandatory)]
        [hashtable]$Tokens
    )

    $content = $Template
    foreach ($key in $Tokens.Keys) {
        $content = $content.Replace("{{$key}}", [string]$Tokens[$key])
    }
    if ($Tokens.ContainsKey('SQLSVCACCOUNT')) {
        $content = $content.Replace('##MyUser##', [string]$Tokens['SQLSVCACCOUNT'])
    }

    $unresolved = [regex]::Matches($content, '\{\{(\w+)\}\}') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
    if ($unresolved) {
        throw "Ini template has unresolved tokens: $($unresolved -join ', ')"
    }
    $content
}

function Expand-ScriptToken {
    <#
    .SYNOPSIS
        Replaces environment ScriptTokens in a maintenance SQL script, in memory only.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Content,

        [hashtable]$Tokens = @{}
    )

    foreach ($key in $Tokens.Keys) {
        $Content = $Content.Replace($key, [string]$Tokens[$key])
    }
    $Content
}

function Resolve-SqlDirectory {
    <#
    .SYNOPSIS
        Finds the Data, Log and TempDB volumes by label and returns the SQL directory layout.
    .OUTPUTS
        Hashtable of Data, Log, TempDBData, TempDBLog paths plus the matched volume objects.
    #>
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config,

        [Parameter(Mandatory)]
        [object[]]$Volumes
    )

    $found = @{}
    foreach ($role in 'Data', 'Log', 'TempDB') {
        $volume = $Volumes | Where-Object { $_.DriveLetter -and $_.FileSystemLabel -in $Config.VolumeLabels[$role] } | Select-Object -First 1
        if (-not $volume) {
            throw "No volume labelled $($Config.VolumeLabels[$role] -join ' or ') found for $role"
        }
        $found[$role] = $volume
    }

    @{
        Volumes    = $found
        Data       = "$($found.Data.DriveLetter):\MSSQL\SQLDATA"
        Log        = "$($found.Log.DriveLetter):\MSSQL\SQLLOG"
        TempDBData = "$($found.TempDB.DriveLetter):\MSSQL\TEMPDB_SQLDATA"
        TempDBLog  = "$($found.TempDB.DriveLetter):\MSSQL\TEMPDB_SQLLOG"
    }
}

function ConvertTo-AdminSharePath {
    <#
    .SYNOPSIS
        Converts a local path on the target (C:\Folder) into its admin share UNC path (\\server\C$\Folder).
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        [string]$LocalPath
    )

    if ($LocalPath -notmatch '^([A-Za-z]):\\(.*)$') {
        throw "'$LocalPath' is not a local drive path"
    }
    "\\$ComputerName\$($Matches[1])`$\$($Matches[2])".TrimEnd('\')
}
