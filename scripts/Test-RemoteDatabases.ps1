[CmdletBinding()]
param([string] $SecretsPath)

$ErrorActionPreference = 'Stop'
if (-not $SecretsPath) {
    $SecretsPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) '.secrets\database-credentials.xml'
}
$store = Import-Clixml -LiteralPath $SecretsPath
$psql = (Get-Command psql.exe -ErrorAction Stop).Source
$previousPassword = $env:PGPASSWORD

try {
    foreach ($entry in $store.Services.GetEnumerator()) {
        $service = $entry.Key
        $credential = $entry.Value
        $env:PGPASSWORD = [System.Net.NetworkCredential]::new('', $credential.AppPassword).Password
        $query = @"
SELECT
    '$service' AS service,
    (SELECT version FROM app.flyway_schema_history WHERE success ORDER BY installed_rank DESC LIMIT 1) AS schema_version,
    has_schema_privilege(current_user, 'app', 'USAGE') AS app_usage,
    has_schema_privilege(current_user, 'app', 'CREATE') AS app_create,
    has_database_privilege(current_user, current_database(), 'CREATE') AS database_create;
"@
        $arguments = @(
            '-X', '-A', '-t', '-v', 'ON_ERROR_STOP=1',
            '-h', $store.Host, '-p', $store.Port,
            '-U', $credential.AppUsername, '-d', $credential.Database,
            '-c', $query
        )
        $output = & $psql @arguments
        if ($LASTEXITCODE -ne 0) { throw "Verification failed for $service." }
        Write-Output $output
    }
}
finally {
    $env:PGPASSWORD = $previousPassword
}
