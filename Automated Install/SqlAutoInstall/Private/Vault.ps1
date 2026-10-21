#Vault access over the HTTP API, so the jump box does not need the vault CLI and secrets are parsed as JSON
#rather than scraped from CLI text output.

function Connect-Vault {
    <#
    .SYNOPSIS
        Logs in to Vault with AppRole and returns a session object for Get-VaultSecret.
    #>
    param(
        [Parameter(Mandatory)]
        [hashtable]$VaultConfig
    )

    $roleId = (Get-Content -Path $VaultConfig.RoleIdPath -Raw -ErrorAction Stop).Trim()
    $secretId = (Get-Content -Path $VaultConfig.SecretIdPath -Raw -ErrorAction Stop).Trim()

    $login = Invoke-RestMethod -Method Post -Uri "$($VaultConfig.Address.TrimEnd('/'))/v1/auth/approle/login" `
        -Headers @{ 'X-Vault-Namespace' = $VaultConfig.AuthNamespace } `
        -Body (@{ role_id = $roleId; secret_id = $secretId } | ConvertTo-Json) `
        -ContentType 'application/json' -ErrorAction Stop

    [pscustomobject]@{
        Address         = $VaultConfig.Address.TrimEnd('/')
        AuthNamespace   = $VaultConfig.AuthNamespace
        SecretNamespace = $VaultConfig.SecretNamespace
        Token           = $login.auth.client_token
    }
}

function Get-VaultSecret {
    <#
    .SYNOPSIS
        Reads a KV secret and returns its fields as a PSCustomObject. Property lookups on it are
        case-insensitive, so 'Password' and 'password' fields both resolve.
    #>
    param(
        [Parameter(Mandatory)]
        [object]$Session,

        [Parameter(Mandatory)]
        [string]$Mount,

        [Parameter(Mandatory)]
        [string]$Name,

        [ValidateSet(1, 2)]
        [int]$KvVersion = 2
    )

    $path = if ($KvVersion -eq 2) { "$Mount/data/$Name" } else { "$Mount/$Name" }
    $response = Invoke-RestMethod -Method Get -Uri "$($Session.Address)/v1/$path" `
        -Headers @{ 'X-Vault-Token' = $Session.Token; 'X-Vault-Namespace' = $Session.SecretNamespace } -ErrorAction Stop

    if ($KvVersion -eq 2) { $response.data.data } else { $response.data }
}

function Get-SecretField {
    <#
    .SYNOPSIS
        Returns one field from a Vault secret, throwing if it is missing or empty.
    #>
    param(
        [Parameter(Mandatory)]
        [object]$Secret,

        [Parameter(Mandatory)]
        [string]$Field,

        [Parameter(Mandatory)]
        [string]$SecretName
    )

    $property = $Secret.PSObject.Properties | Where-Object { $_.Name -eq $Field } | Select-Object -First 1
    if (-not $property -or [string]::IsNullOrWhiteSpace($property.Value)) {
        throw "Vault secret '$SecretName' has no value for field '$Field'"
    }
    $property.Value
}

function Disconnect-Vault {
    <#
    .SYNOPSIS
        Revokes the session token so it cannot be reused after the run.
    #>
    param(
        [Parameter(Mandatory)]
        [object]$Session
    )

    try {
        Invoke-RestMethod -Method Post -Uri "$($Session.Address)/v1/auth/token/revoke-self" `
            -Headers @{ 'X-Vault-Token' = $Session.Token; 'X-Vault-Namespace' = $Session.AuthNamespace } -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Warning "Vault token revoke failed, it will expire at its TTL: $_"
    }
    $Session.Token = $null
}
