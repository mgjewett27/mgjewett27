function Test-PendingReboot {
    <#
    .SYNOPSIS
        True when Windows has a reboot pending. From CU_Update_2024.ps1, run remotely with
        Invoke-Command -ScriptBlock ${function:Test-PendingReboot}.
    #>
    if (Get-ChildItem 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending' -EA Ignore) { return $true }
    if (Get-Item 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired' -EA Ignore) { return $true }
    if (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -EA Ignore) { return $true }
    try {
        $util = Invoke-CimMethod -Namespace 'root\ccm\clientsdk' -ClassName 'CCM_ClientUtilities' -MethodName 'DetermineIfRebootPending' -ErrorAction Stop
        if ($util -and $util.RebootPending) { return $true }
    }
    catch {
        #No SCCM client on this server
        Write-Verbose 'SCCM client not present, skipping its reboot check'
    }
    return $false
}

function Get-TargetFact {
    <#
    .SYNOPSIS
        Collects read-only facts from the target in one round trip: domain, cluster, volumes, free space,
        pending reboot and installed SQL instances.
    #>
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Runspaces.PSSession]$Session
    )

    $facts = Invoke-Command -Session $Session -ScriptBlock {
        $computer = Get-CimInstance -ClassName Win32_ComputerSystem
        $clusterName = try { (Get-Cluster -ErrorAction Stop).Name } catch { $null }
        $instances = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server' -ErrorAction SilentlyContinue).InstalledInstances

        [pscustomobject]@{
            Name               = $computer.Name
            Domain             = $computer.Domain
            PartOfDomain       = $computer.PartOfDomain
            ClusterName        = $clusterName
            InstalledInstances = @($instances)
            SystemFreeGB       = [math]::Round((Get-Volume -DriveLetter C).SizeRemaining / 1GB, 1)
            Volumes            = @(Get-Volume | Where-Object DriveLetter | Select-Object DriveLetter, FileSystemLabel, FileSystem, AllocationUnitSize, SizeRemaining)
        }
    }
    $facts | Add-Member -NotePropertyName PendingReboot -NotePropertyValue (Invoke-Command -Session $Session -ScriptBlock ${function:Test-PendingReboot}) -PassThru
}

function Get-StagedFileHash {
    <#
    .SYNOPSIS
        SHA256 of a file on the target, computed locally there so the file is not read back over the network.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Path', Justification = 'Used through $using:Path in the remote scriptblock')]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Runspaces.PSSession]$Session,

        [Parameter(Mandatory)]
        [string]$Path
    )

    Invoke-Command -Session $Session -ScriptBlock {
        (Get-FileHash -Path $using:Path -Algorithm SHA256).Hash
    }
}

function Restart-BuildTarget {
    <#
    .SYNOPSIS
        Reboots the target, waits for WinRM and replaces the build context's remoting session.
    #>
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context,

        [string]$Phase = '-'
    )

    Write-BuildLog -ComputerName $Context.ComputerName -Phase $Phase -Message 'Rebooting server and waiting for WinRM' -Level Warning
    Remove-PSSession -Session $Context.Session -ErrorAction SilentlyContinue

    $restart = @{ ComputerName = $Context.ComputerName; Force = $true; Wait = $true; For = 'WinRM'; Timeout = 1800; Delay = 10 }
    if ($Context.Credential) { $restart.Credential = $Context.Credential }
    Restart-Computer @restart -ErrorAction Stop

    $Context.Session = New-BuildSession -ComputerName $Context.ComputerName -Credential $Context.Credential
    Write-BuildLog -ComputerName $Context.ComputerName -Phase $Phase -Message 'Server is back online' -Level Success
}

function New-BuildSession {
    param(
        [Parameter(Mandatory)]
        [string]$ComputerName,

        [pscredential]$Credential
    )

    $sessionArgs = @{ ComputerName = $ComputerName; ErrorAction = 'Stop' }
    if ($Credential) { $sessionArgs.Credential = $Credential }
    New-PSSession @sessionArgs
}
