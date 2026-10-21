#Per-server state file on the jump box, records completed phases so a rerun resumes where it stopped.

function Get-BuildStatePath {
    param(
        [Parameter(Mandatory)]
        [string]$LogPath,

        [Parameter(Mandatory)]
        [string]$ComputerName
    )

    Join-Path $LogPath "$ComputerName.state.json"
}

function Get-BuildState {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (Test-Path -Path $Path) {
        $state = Get-Content -Path $Path -Raw | ConvertFrom-Json
        return @{
            SqlVersion      = $state.SqlVersion
            CompletedPhases = @($state.CompletedPhases)
        }
    }
    @{ SqlVersion = $null; CompletedPhases = @() }
}

function Add-CompletedPhase {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [hashtable]$State,

        [Parameter(Mandatory)]
        [string]$Phase
    )

    $State.CompletedPhases = @($State.CompletedPhases | Where-Object { $_.Name -ne $Phase }) +
        [pscustomobject]@{ Name = $Phase; CompletedAt = (Get-Date).ToString('s') }
    $State | ConvertTo-Json -Depth 4 | Set-Content -Path $Path
}

function Test-PhaseCompleted {
    param(
        [Parameter(Mandatory)]
        [hashtable]$State,

        [Parameter(Mandatory)]
        [string]$Phase
    )

    [bool]($State.CompletedPhases | Where-Object { $_.Name -eq $Phase })
}
