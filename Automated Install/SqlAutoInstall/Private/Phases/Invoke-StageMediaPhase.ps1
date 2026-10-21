function Invoke-StageMediaPhase {
    <#
    .SYNOPSIS
        Creates the SQL directories and pushes the ISO and rendered ini to the target.
    .DESCRIPTION
        Files are copied from the jump box straight to the target's admin share, so the target never
        reads a UNC path itself (no Kerberos double hop).
    #>
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context
    )

    $log = @{ ComputerName = $Context.ComputerName; Phase = 'StageMedia' }
    $dirs = $Context.Directories
    $mediaPath = Join-Path $Context.Config.TargetWorkingPath 'Media'

    Invoke-Command -Session $Context.Session -ScriptBlock {
        param($Paths)
        foreach ($path in $Paths) {
            New-Item -Path $path -ItemType Directory -Force | Out-Null
        }
    } -ArgumentList (, @($mediaPath, $dirs.Data, $dirs.Log, $dirs.TempDBData, $dirs.TempDBLog))
    Write-BuildLog @log -Message "Created $mediaPath and SQL directories"

    $mediaShare = ConvertTo-AdminSharePath -ComputerName $Context.ComputerName -LocalPath $mediaPath
    $iso = Get-Item -Path $Context.Media.Iso
    $remoteIso = Join-Path $mediaShare $iso.Name
    $targetIso = Join-Path $mediaPath $iso.Name
    $expectedHash = $Context.Media.Sha256

    #The hash is computed on the target, so it checks both the source ISO and the copy
    $staged = (Test-Path -Path $remoteIso) -and (Get-Item -Path $remoteIso).Length -eq $iso.Length
    if ($staged -and $expectedHash -and (Get-StagedFileHash -Session $Context.Session -Path $targetIso) -ne $expectedHash) {
        Write-BuildLog @log -Message "Staged $($iso.Name) does not match its SHA256, copying again" -Level Warning
        $staged = $false
    }

    if ($staged) {
        Write-BuildLog @log -Message "$($iso.Name) already staged, skipping copy"
    }
    else {
        Write-BuildLog @log -Message "Copying $($iso.Name) ($([math]::Round($iso.Length / 1GB, 1)) GB) to $mediaShare"
        Copy-Item -Path $iso.FullName -Destination $mediaShare -Force -ErrorAction Stop

        if ($expectedHash) {
            $actualHash = Get-StagedFileHash -Session $Context.Session -Path $targetIso
            if ($actualHash -ne $expectedHash) {
                throw "$($iso.Name) SHA256 is $actualHash, expected $expectedHash. The source ISO or the copy is corrupt."
            }
            Write-BuildLog @log -Message "$($iso.Name) SHA256 verified"
        }
    }

    if (-not $expectedHash) {
        Write-BuildLog @log -Message "No Sha256 configured for SQL $($Context.SqlVersion) media, ISO integrity not checked" -Level Warning
    }

    $tokens = @{
        INSTANCENAME    = $Context.Config.InstanceName
        SQLSVCACCOUNT   = $Context.ServiceCredential.UserName
        SQLUSERDBDIR    = $dirs.Data
        SQLUSERDBLOGDIR = $dirs.Log
        SQLTEMPDBDIR    = $dirs.TempDBData
        SQLTEMPDBLOGDIR = $dirs.TempDBLog
    }
    $ini = Expand-IniTemplate -Template (Get-Content -Path $Context.Media.Ini -Raw) -Tokens $tokens
    Set-Content -Path (Join-Path $mediaShare 'ConfigurationFile.ini') -Value $ini -ErrorAction Stop

    Write-BuildLog @log -Message 'Media and ConfigurationFile.ini staged' -Level Success
}
