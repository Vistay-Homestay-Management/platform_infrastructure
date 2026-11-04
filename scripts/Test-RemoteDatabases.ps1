[CmdletBinding()]
param(
    [string] $SecretsPath,
    [ValidateSet('require', 'verify-ca', 'verify-full', 'disable')]
    [string] $SslMode = 'require',
    [switch] $AllowInsecureTailscaleTransport
)

$ErrorActionPreference = 'Stop'
if ($SslMode -eq 'disable' -and -not $AllowInsecureTailscaleTransport) {
    throw 'SslMode=disable requires -AllowInsecureTailscaleTransport. Prefer PostgreSQL TLS even over Tailscale.'
}
if (-not $SecretsPath) {
    $SecretsPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) '.secrets\database-credentials.xml'
}
$store = Import-Clixml -LiteralPath $SecretsPath
$psql = (Get-Command psql.exe -ErrorAction Stop).Source
$previousPassword = $env:PGPASSWORD
$previousSslMode = $env:PGSSLMODE

try {
    $env:PGSSLMODE = $SslMode
    foreach ($entry in $store.Services.GetEnumerator()) {
        $service = $entry.Key
        $credential = $entry.Value
        $env:PGPASSWORD = [System.Net.NetworkCredential]::new('', $credential.MigratorPassword).Password
        $schemaVersion = & $psql -X -A -t -v ON_ERROR_STOP=1 `
            -h $store.Host -p $store.Port -U $credential.MigratorUsername -d $credential.Database `
            -c 'SELECT version FROM app.flyway_schema_history WHERE success ORDER BY installed_rank DESC LIMIT 1;'
        if ($LASTEXITCODE -ne 0) { throw "Migration history verification failed for $service." }

        $env:PGPASSWORD = [System.Net.NetworkCredential]::new('', $credential.AppPassword).Password
        $query = @"
SELECT
    '$service' AS service,
    '$schemaVersion' AS schema_version,
    has_schema_privilege(current_user, 'app', 'USAGE') AS app_usage,
    has_schema_privilege(current_user, 'app', 'CREATE') AS app_create,
    has_database_privilege(current_user, current_database(), 'CREATE') AS database_create,
    has_table_privilege(current_user, 'app.flyway_schema_history', 'INSERT,UPDATE,DELETE') AS flyway_history_write;
"@
        $arguments = @(
            '-X', '-A', '-t', '-v', 'ON_ERROR_STOP=1',
            '-h', $store.Host, '-p', $store.Port,
            '-U', $credential.AppUsername, '-d', $credential.Database,
            '-c', $query
        )
        $output = & $psql @arguments
        if ($LASTEXITCODE -ne 0) { throw "Verification failed for $service." }
        $fields = @($output -split '\|')
        if ($fields.Count -ne 6 -or $fields[2] -ne 't' -or $fields[3] -ne 'f' -or
            $fields[4] -ne 'f' -or $fields[5] -ne 'f') {
            throw "Least-privilege verification failed for $service`: $output"
        }
        Write-Output $output
    }
}
finally {
    $env:PGPASSWORD = $previousPassword
    $env:PGSSLMODE = $previousSslMode
}
