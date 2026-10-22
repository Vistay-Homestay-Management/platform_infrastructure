[CmdletBinding()]
param(
    [string] $HostName = '100.82.162.104',
    [int] $Port = 5172,
    [string] $BootstrapDatabase = 'vistay',
    [string] $BootstrapUser = 'vistay',
    [securestring] $BootstrapPassword,
    [ValidateSet('require', 'verify-ca', 'verify-full', 'disable')]
    [string] $SslMode = 'require',
    [switch] $AllowInsecureTailscaleTransport,
    [string] $WorkspaceRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
    [string] $SecretsPath = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) '.secrets\database-credentials.xml')
)

$ErrorActionPreference = 'Stop'

if ($SslMode -eq 'disable' -and -not $AllowInsecureTailscaleTransport) {
    throw 'SslMode=disable requires -AllowInsecureTailscaleTransport. Prefer PostgreSQL TLS even over Tailscale.'
}

if (-not $BootstrapPassword) {
    $BootstrapPassword = Read-Host 'PostgreSQL bootstrap password' -AsSecureString
}

$psql = (Get-Command psql.exe -ErrorAction Stop).Source
$bootstrapSql = Join-Path (Split-Path -Parent $PSScriptRoot) 'database\bootstrap.sql'
$grantSql = Join-Path (Split-Path -Parent $PSScriptRoot) 'database\grant-runtime.sql'
$migrationInit = Join-Path $PSScriptRoot 'migrate.init.gradle'

$services = @(
    @{ Name = 'authentication'; Repo = 'service_authentication'; Database = 'vistay_authentication_db' },
    @{ Name = 'user'; Repo = 'service_user'; Database = 'vistay_user_db' },
    @{ Name = 'property'; Repo = 'service_property'; Database = 'vistay_property_db' },
    @{ Name = 'booking'; Repo = 'service_booking'; Database = 'vistay_booking_db' },
    @{ Name = 'finance'; Repo = 'service_finance'; Database = 'vistay_finance_db' },
    @{ Name = 'operations'; Repo = 'service_operations'; Database = 'vistay_operations_db' },
    @{ Name = 'ota'; Repo = 'service_ota'; Database = 'vistay_ota_db' },
    @{ Name = 'notification'; Repo = 'service_notification'; Database = 'vistay_notification_db' },
    @{ Name = 'media'; Repo = 'service_media'; Database = 'vistay_media_db' },
    @{ Name = 'warehouse'; Repo = 'service_data_warehouse'; Database = 'vistay_warehouse_db' }
)

function New-RandomPassword {
    $bytes = [byte[]]::new(36)
    $generator = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $generator.GetBytes($bytes)
    }
    finally {
        $generator.Dispose()
    }
    return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function ConvertTo-PlainText([securestring] $Value) {
    return [System.Net.NetworkCredential]::new('', $Value).Password
}

$credentialStore = [ordered]@{
    Host = $HostName
    Port = $Port
    CreatedAt = [DateTimeOffset]::UtcNow
    Services = [ordered]@{}
}

foreach ($service in $services) {
    $credentialStore.Services[$service.Name] = [ordered]@{
        Database = $service.Database
        MigratorUsername = "vistay_$($service.Name)_migrator"
        MigratorPassword = ConvertTo-SecureString (New-RandomPassword) -AsPlainText -Force
        AppUsername = "vistay_$($service.Name)_app"
        AppPassword = ConvertTo-SecureString (New-RandomPassword) -AsPlainText -Force
    }
}

$secretsDirectory = Split-Path -Parent $SecretsPath
New-Item -ItemType Directory -Path $secretsDirectory -Force | Out-Null
$credentialStore | Export-Clixml -LiteralPath $SecretsPath -Force

$previousPassword = $env:PGPASSWORD
$previousSslMode = $env:PGSSLMODE
try {
    $env:PGPASSWORD = ConvertTo-PlainText $BootstrapPassword
    $env:PGSSLMODE = $SslMode
    $bootstrapArgs = @(
        '-v', 'ON_ERROR_STOP=1',
        '-h', $HostName, '-p', $Port, '-U', $BootstrapUser,
        '-d', $BootstrapDatabase, '-f', $bootstrapSql
    )
    foreach ($service in $services) {
        $stored = $credentialStore.Services[$service.Name]
        $bootstrapArgs += @('-v', "$($service.Name)_migrator_password=$(ConvertTo-PlainText $stored.MigratorPassword)")
        $bootstrapArgs += @('-v', "$($service.Name)_app_password=$(ConvertTo-PlainText $stored.AppPassword)")
    }
    & $psql @bootstrapArgs
    if ($LASTEXITCODE -ne 0) { throw 'Database bootstrap failed.' }

    foreach ($service in $services) {
        $stored = $credentialStore.Services[$service.Name]
        $env:DB_MIGRATION_URL = "jdbc:postgresql://${HostName}:$Port/$($service.Database)?sslmode=$SslMode"
        $env:DB_MIGRATION_USERNAME = $stored.MigratorUsername
        $env:DB_MIGRATION_PASSWORD = ConvertTo-PlainText $stored.MigratorPassword

        $repoPath = Join-Path $WorkspaceRoot $service.Repo
        & (Join-Path $repoPath 'gradlew.bat') --init-script $migrationInit migrateRemoteDatabase --no-daemon -p $repoPath
        if ($LASTEXITCODE -ne 0) { throw "Migration failed for $($service.Name)." }

        $env:PGPASSWORD = $env:DB_MIGRATION_PASSWORD
        $grantArgs = @(
            '-v', 'ON_ERROR_STOP=1', '-h', $HostName, '-p', $Port,
            '-U', $stored.MigratorUsername, '-d', $service.Database,
            '-v', "owner_role=vistay_$($service.Name)_owner",
            '-v', "app_role=$($stored.AppUsername)", '-f', $grantSql
        )
        & $psql @grantArgs
        if ($LASTEXITCODE -ne 0) { throw "Runtime grants failed for $($service.Name)." }
    }
}
finally {
    $env:PGPASSWORD = $previousPassword
    $env:PGSSLMODE = $previousSslMode
    Remove-Item Env:DB_MIGRATION_URL, Env:DB_MIGRATION_USERNAME, Env:DB_MIGRATION_PASSWORD -ErrorAction SilentlyContinue
}

Write-Host "Provisioned $($services.Count) databases. DPAPI credentials: $SecretsPath"
