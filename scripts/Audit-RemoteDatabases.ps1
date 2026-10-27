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
$previousPassword = $env:PGPASSWORD
$previousSslMode = $env:PGSSLMODE
$sql = @'
SELECT current_database() AS database_name,
       current_user AS database_user,
       COALESCE((SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()), false) AS ssl,
       has_schema_privilege(current_user, 'app', 'USAGE') AS app_usage,
       has_schema_privilege(current_user, 'app', 'CREATE') AS app_create,
       has_database_privilege(current_user, current_database(), 'CREATE') AS database_create;

WITH tables AS (
    SELECT schemaname, relname
    FROM pg_stat_user_tables
    WHERE schemaname = 'app' AND relname <> 'flyway_schema_history'
)
SELECT relname AS table_name,
       ((xpath(
           '//n/text()',
           query_to_xml(
               format('SELECT count(*) AS n FROM %I.%I', schemaname, relname),
               false,
               true,
               ''
           )
       ))[1]::text)::bigint AS row_count
FROM tables
ORDER BY relname;
'@

try {
    $env:PGSSLMODE = $SslMode
    foreach ($serviceName in ($store.Services.Keys | Sort-Object)) {
        $service = $store.Services[$serviceName]
        $env:PGPASSWORD = [System.Net.NetworkCredential]::new('', $service.AppPassword).Password
        Write-Output "[$serviceName]"
        & $psql -X -A -F '|' -v ON_ERROR_STOP=1 `
            -h $store.Host -p $store.Port -U $service.AppUsername -d $service.Database `
            -c $sql
        if ($LASTEXITCODE -ne 0) {
            throw "Audit failed for $serviceName."
        }
    }
}
finally {
    $env:PGPASSWORD = $previousPassword
    $env:PGSSLMODE = $previousSslMode
}
