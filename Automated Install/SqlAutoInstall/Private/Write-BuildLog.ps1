function Write-BuildLog {
    <#
    .SYNOPSIS
        Writes a colored console line and a structured log entry for the current build.
    .DESCRIPTION
        Adapted from Write-AuditLog in SPN_Tool. The log file is set per run by Invoke-SqlBuild in
        $script:BuildLogFile. Never pass secrets in Message.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Colored console output for interactive DBAs, the log file is the record')]
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('Info', 'Success', 'Warning', 'Error')]
        [string]$Level = 'Info',

        [string]$ComputerName = '-',

        [string]$Phase = '-'
    )

    $colors = @{ Info = 'Gray'; Success = 'Green'; Warning = 'Yellow'; Error = 'Red' }
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

    Write-Host "[$timestamp] [$ComputerName] [$Phase] $Message" -ForegroundColor $colors[$Level]

    if ($script:BuildLogFile) {
        $entry = [ordered]@{
            Timestamp    = $timestamp
            Level        = $Level
            User         = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
            ComputerName = $ComputerName
            Phase        = $Phase
            Message      = $Message
        }
        try {
            Add-Content -Path $script:BuildLogFile -Value ($entry | ConvertTo-Json -Compress) -ErrorAction Stop
        }
        catch {
            Write-Warning "Failed to write build log: $_"
        }
    }
}
