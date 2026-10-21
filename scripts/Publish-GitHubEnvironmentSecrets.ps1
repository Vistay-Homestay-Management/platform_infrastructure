[CmdletBinding()]
param(
    [string] $Organization = 'Vistay-Homestay-Management',
    [string] $Environment = 'tailscale',
    [string] $SecretsPath
)

$ErrorActionPreference = 'Stop'
if (-not $SecretsPath) {
    $SecretsPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) '.secrets\database-credentials.xml'
}

$store = Import-Clixml -LiteralPath $SecretsPath
$repositories = @{
    authentication = 'service_authentication'
    user = 'service_user'
    property = 'service_property'
    booking = 'service_booking'
    finance = 'service_finance'
    operations = 'service_operations'
    ota = 'service_ota'
    notification = 'service_notification'
    media = 'service_media'
    warehouse = 'service_data_warehouse'
}

function ConvertTo-PlainText([securestring] $value) {
    return [System.Net.NetworkCredential]::new('', $value).Password
}

foreach ($entry in $repositories.GetEnumerator()) {
    $credential = $store.Services[$entry.Key]
    $repository = "$Organization/$($entry.Value)"
    & gh api --method PUT "repos/$repository/environments/$Environment" --silent
    if ($LASTEXITCODE -ne 0) { throw "Could not create environment for $repository" }

    ConvertTo-PlainText $credential.AppPassword |
        & gh secret set DB_PASSWORD --repo $repository --env $Environment
    if ($LASTEXITCODE -ne 0) { throw "Could not set DB_PASSWORD for $repository" }

    & gh variable set DB_HOST --repo $repository --env $Environment --body ([string]$store.Host)
    & gh variable set DB_PORT --repo $repository --env $Environment --body ([string]$store.Port)
    & gh variable set DB_NAME --repo $repository --env $Environment --body $credential.Database
    & gh variable set DB_USERNAME --repo $repository --env $Environment --body $credential.AppUsername
}

Write-Host "Published database runtime configuration to $($repositories.Count) GitHub environments."
