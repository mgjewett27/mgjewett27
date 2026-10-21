function Invoke-ServerConfigPhase {
    <#
    .SYNOPSIS
        Enables HADR for the AG build that follows, confirms SQL Agent is running, makes the monitor
        account a local admin, and installs SSMS where the environment asks for it.
    #>
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context
    )

    $log = @{ ComputerName = $Context.ComputerName; Phase = 'ServerConfig' }

    if ((Get-DbaAgHadr -SqlInstance $Context.ComputerName -EnableException).IsHadrEnabled) {
        Write-BuildLog @log -Message 'AlwaysOn AG (HADR) already enabled'
    }
    else {
        Write-BuildLog @log -Message 'Enabling AlwaysOn AG (HADR), SQL service will restart'
        Enable-DbaAgHadr -SqlInstance $Context.ComputerName -Force -Confirm:$false -EnableException | Out-Null
    }

    $agent = Get-DbaService -ComputerName $Context.ComputerName -Type Agent -EnableException
    if ($agent.State -ne 'Running') {
        Start-DbaService -ComputerName $Context.ComputerName -Type Agent -EnableException | Out-Null
        $agent = Get-DbaService -ComputerName $Context.ComputerName -Type Agent -EnableException
    }
    if ($agent.State -ne 'Running') {
        throw "SQL Agent is $($agent.State) after HADR restart"
    }
    Write-BuildLog @log -Message 'HADR enabled and SQL Agent running' -Level Success

    $monitorAccount = $Context.Config.Monitoring.ServiceAccount
    $added = Invoke-Command -Session $Context.Session -ScriptBlock {
        param($Account)
        #Get-LocalGroupMember fails on orphaned SIDs, net localgroup does not
        $members = net localgroup Administrators | Select-Object -Skip 6 | Where-Object { $_ -and $_ -notmatch 'command completed' }
        if ($members -contains $Account) { return $false }
        Add-LocalGroupMember -Group Administrators -Member $Account -ErrorAction Stop
        $true
    } -ArgumentList $monitorAccount
    $message = if ($added) { "Added $monitorAccount to local Administrators" } else { "$monitorAccount already in local Administrators" }
    Write-BuildLog @log -Message $message

    if ($Context.Environment.InstallSsms) {
        Write-BuildLog @log -Message 'Installing SSMS via Chocolatey'
        $exitCode = Invoke-Command -Session $Context.Session -ScriptBlock {
            $choco = 'C:\ProgramData\chocolatey\bin\choco.exe'
            if (-not (Test-Path -Path $choco)) {
                [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
                Set-ExecutionPolicy Bypass -Scope Process -Force
                Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
            }
            & $choco install sql-server-management-studio -y --no-progress | Out-Null
            $LASTEXITCODE
        }
        #3010 = installed, reboot required. SSMS does not need the reboot before SQL work continues.
        if ($exitCode -notin 0, 3010) {
            throw "SSMS install failed with Chocolatey exit code $exitCode"
        }
        Write-BuildLog @log -Message 'SSMS installed' -Level Success
    }
}
