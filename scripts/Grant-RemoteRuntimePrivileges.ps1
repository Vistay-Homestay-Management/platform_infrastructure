[CmdletBinding()]
param(
    [string] $SecretsPath,
    [ValidateSet('require', 'verify-ca', 'verify-full', 'disable')]
    [string] $SslMode = 'require',
    [switch] $AllowInsecureTailscaleTransport
)

$ErrorActionPreference = 'Stop'
if (-not $SecretsPath) {
    $SecretsPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) '.secrets\database-credentials.xml'
}
if ($SslMode -eq 'disable' -and -not $AllowInsecureTailscaleTransport) {
    throw 'SslMode=disable requires -AllowInsecureTailscaleTransport. Prefer PostgreSQL TLS even over Tailscale.'
}

$store = Import-Clixml -LiteralPath $SecretsPath
$psql = (Get-Command psql.exe -ErrorAction Stop).Source
$grantSql = Join-Path (Split-Path -Parent $PSScriptRoot) 'database\grant-runtime.sql'
$previousPassword = $env:PGPASSWORD
$previousSslMode = $env:PGSSLMODE
try {
    $env:PGSSLMODE = $SslMode
    foreach ($entry in $store.Services.GetEnumerator()) {
        $serviceName = $entry.Key
        $credential = $entry.Value
        $env:PGPASSWORD = [System.Net.NetworkCredential]::new('', $credential.MigratorPassword).Password
        & $psql -X -v ON_ERROR_STOP=1 -h $store.Host -p $store.Port `
            -U $credential.MigratorUsername -d $credential.Database `
            -v "owner_role=vistay_$($serviceName)_owner" `
            -v "app_role=$($credential.AppUsername)" -f $grantSql | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Runtime grant failed for $serviceName." }
        Write-Output "$serviceName=updated"
    }
}
finally {
    $env:PGPASSWORD = $previousPassword
    $env:PGSSLMODE = $previousSslMode
}
