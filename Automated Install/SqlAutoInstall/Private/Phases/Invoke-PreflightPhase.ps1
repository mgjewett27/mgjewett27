function Invoke-PreflightPhase {
    <#
    .SYNOPSIS
        Read-only checks that must all pass before anything on the target changes. Also pulls every
        secret the build needs from Vault in one login, then revokes the token.
    .DESCRIPTION
        Fills $Context.Facts, Directories, ServiceCredential, SaCredential and RedgateToken.
        Every failed check is collected and reported together rather than one at a time.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Vault returns plain text, it is wrapped in a SecureString immediately and the plain variables are removed')]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context,

        [Parameter(Mandatory)]
        [hashtable]$State
    )

    $log = @{ ComputerName = $Context.ComputerName; Phase = 'Preflight' }
    $config = $Context.Config
    $failures = [System.Collections.Generic.List[string]]::new()

    $facts = Get-TargetFact -Session $Context.Session
    $Context.Facts = $facts

    if (-not $facts.PartOfDomain) { $failures.Add('Server is not domain joined') }
    if (-not $facts.ClusterName) { $failures.Add('Server is not a WSFC node (Get-Cluster failed), the service account is looked up by cluster name') }
    if ($facts.SystemFreeGB -lt $config.MinFreeSpaceSystemGB) {
        $failures.Add("C: has $($facts.SystemFreeGB) GB free, $($config.MinFreeSpaceSystemGB) GB required")
    }

    #A pending reboot only blocks a fresh install. Later phases reboot as part of their own work.
    if ($facts.PendingReboot) {
        if (Test-PhaseCompleted -State $State -Phase 'InstallSql') {
            Write-BuildLog @log -Message 'Reboot pending, the next phase that needs one will reboot' -Level Warning
        }
        else {
            $failures.Add('Reboot pending, reboot the server before installing SQL')
        }
    }

    if ($Context.MissionCritical -and -not $Context.Environment.IsProduction) {
        $failures.Add("-MissionCritical only applies to production, '$($Context.Environment.Name)' is not production")
    }

    try {
        $Context.Directories = Resolve-SqlDirectory -Config $config -Volumes $facts.Volumes
        foreach ($role in $Context.Directories.Volumes.Keys) {
            $volume = $Context.Directories.Volumes[$role]
            if ($volume.FileSystem -ne 'NTFS' -and $volume.FileSystem -ne 'ReFS') {
                $failures.Add("$role volume $($volume.DriveLetter): is $($volume.FileSystem), expected NTFS or ReFS")
            }
            if ($volume.AllocationUnitSize -ne $config.AllocationUnitSize) {
                $failures.Add("$role volume $($volume.DriveLetter): allocation unit is $($volume.AllocationUnitSize), expected $($config.AllocationUnitSize)")
            }
        }
    }
    catch {
        $failures.Add($_.Exception.Message)
    }

    $media = $Context.Environment.Media[$Context.SqlVersion]
    if (-not $media) {
        $failures.Add("No media configured for SQL $($Context.SqlVersion) in environment '$($Context.Environment.Name)'")
    }
    else {
        if (-not (Test-Path -Path $media.Iso -PathType Leaf)) { $failures.Add("ISO not found: $($media.Iso)") }
        if (-not (Test-Path -Path $media.Ini -PathType Leaf)) { $failures.Add("Ini template not found: $($media.Ini)") }
        $Context.Media = $media
    }

    try {
        $netBiosDomain = Resolve-NetBiosDomain -Config $config -DnsDomain $facts.Domain
    }
    catch {
        $failures.Add($_.Exception.Message)
    }

    $adminShare = ConvertTo-AdminSharePath -ComputerName $Context.ComputerName -LocalPath 'C:\'
    if (-not (Test-Path -Path $adminShare)) { $failures.Add("Admin share $adminShare is not reachable from this jump box") }

    #Secrets: one Vault login for everything this build needs
    if ($facts.ClusterName -and $netBiosDomain) {
        $vault = $null
        try {
            $vault = Connect-Vault -VaultConfig $Context.Environment.Vault
            $vaultArgs = @{ Session = $vault; Mount = $config.Vault.KvMount; KvVersion = $config.Vault.KvVersion }

            $serviceSecret = Get-VaultSecret @vaultArgs -Name $facts.ClusterName
            $serviceUser = Get-SecretField -Secret $serviceSecret -Field $config.Vault.UsernameField -SecretName $facts.ClusterName
            $servicePassword = Get-SecretField -Secret $serviceSecret -Field $config.Vault.PasswordField -SecretName $facts.ClusterName
            $Context.ServiceCredential = [pscredential]::new("$netBiosDomain\$serviceUser", (ConvertTo-SecureString -String $servicePassword -AsPlainText -Force))

            $saSecret = Get-VaultSecret @vaultArgs -Name $config.Vault.SaSecretName
            $saPassword = Get-SecretField -Secret $saSecret -Field $config.Vault.PasswordField -SecretName $config.Vault.SaSecretName
            $Context.SaCredential = [pscredential]::new('sa', (ConvertTo-SecureString -String $saPassword -AsPlainText -Force))

            $redgateSecret = Get-VaultSecret @vaultArgs -Name $config.Vault.RedgateSecretName
            $redgateToken = Get-SecretField -Secret $redgateSecret -Field $config.Vault.RedgateTokenField -SecretName $config.Vault.RedgateSecretName
            $Context.RedgateToken = ConvertTo-SecureString -String $redgateToken -AsPlainText -Force

            Write-BuildLog @log -Message "Retrieved service account $($Context.ServiceCredential.UserName), sa and Redgate secrets from Vault"
        }
        catch {
            $failures.Add("Vault: $($_.Exception.Message)")
        }
        finally {
            Remove-Variable -Name servicePassword, saPassword, redgateToken -ErrorAction SilentlyContinue
            if ($vault) { Disconnect-Vault -Session $vault }
        }
    }

    if ($failures.Count) {
        foreach ($failure in $failures) {
            Write-BuildLog @log -Message $failure -Level Error
        }
        throw "Preflight failed with $($failures.Count) issue(s), nothing was changed on $($Context.ComputerName)"
    }

    Write-BuildLog @log -Message "Preflight passed. Cluster $($facts.ClusterName), data $($Context.Directories.Data), log $($Context.Directories.Log), TempDB $($Context.Directories.TempDBData)" -Level Success
}
