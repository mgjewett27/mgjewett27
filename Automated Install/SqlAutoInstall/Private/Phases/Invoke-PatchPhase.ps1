function Invoke-PatchPhase {
    <#
    .SYNOPSIS
        Brings the instance to the configured CU level (N-1 by default) and verifies the build.
    .DESCRIPTION
        The CU is downloaded once to the jump box cache, pushed to the target over the admin share and
        run locally there, so the target never reads a UNC path. The server is rebooted afterwards.
    #>
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context
    )

    $log = @{ ComputerName = $Context.ComputerName; Phase = 'Patch' }
    $config = $Context.Config

    Update-DbaBuildReference -EnableException
    $build = Test-DbaBuild -SqlInstance $Context.ComputerName -MaxBehind $config.CuMaxBehind -EnableException
    if ($build.Compliant) {
        Write-BuildLog @log -Message "Build $($build.Build) is within $($config.CuMaxBehind) of latest, no CU needed" -Level Success
        return
    }

    $kb = (Get-DbaBuild -Build $build.BuildTarget -EnableException).KBLevel | Select-Object -First 1
    Write-BuildLog @log -Message "Current build $($build.Build), target $($build.BuildTarget) ($($build.CUTarget), KB$kb)"

    New-Item -Path $config.CuCachePath -ItemType Directory -Force | Out-Null
    $cuFile = Get-ChildItem -Path $config.CuCachePath -Filter "*KB$kb*.exe" | Select-Object -First 1
    if (-not $cuFile) {
        Write-BuildLog @log -Message "Downloading KB$kb to $($config.CuCachePath)"
        $cuFile = Save-DbaKbUpdate -Name "KB$kb" -Path $config.CuCachePath -Architecture x64 -EnableException | Select-Object -First 1
    }

    $cuPath = Join-Path $config.TargetWorkingPath 'CU'
    $cuShare = ConvertTo-AdminSharePath -ComputerName $Context.ComputerName -LocalPath $cuPath
    New-Item -Path $cuShare -ItemType Directory -Force | Out-Null
    Copy-Item -Path $cuFile.FullName -Destination $cuShare -Force -ErrorAction Stop

    Write-BuildLog @log -Message "Installing $($build.CUTarget) on $($config.InstanceName)"
    $exitCode = Invoke-Command -Session $Context.Session -ScriptBlock {
        param($CuExe, $InstanceName)
        & $CuExe /quiet /IAcceptSQLServerLicenseTerms /Action=Patch "/InstanceName=$InstanceName" | Out-Null
        $LASTEXITCODE
    } -ArgumentList (Join-Path $cuPath $cuFile.Name), $config.InstanceName

    if ($exitCode -notin 0, 3010) {
        throw "CU install failed with exit code $exitCode, see Setup Bootstrap\Log on $($Context.ComputerName)"
    }

    Restart-BuildTarget -Context $Context -Phase 'Patch'

    $after = Test-DbaBuild -SqlInstance $Context.ComputerName -MaxBehind $config.CuMaxBehind -EnableException
    if (-not $after.Compliant) {
        throw "CU install reported success but build is $($after.Build), expected $($build.BuildTarget)"
    }
    Write-BuildLog @log -Message "Patched to $($after.Build) ($($build.CUTarget))" -Level Success
}
