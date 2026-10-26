[CmdletBinding()]
param(
    [string] $CredentialStore,
    [string] $BootstrapPasswordStore,
    [ValidateSet('require', 'verify-ca', 'verify-full', 'disable')]
    [string] $SslMode = 'require',
    [switch] $AllowInsecureTailscaleTransport
)

$ErrorActionPreference = 'Stop'
$workspaceRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $CredentialStore) { $CredentialStore = Join-Path $workspaceRoot '.secrets\database-credentials.xml' }
if (-not $BootstrapPasswordStore) { $BootstrapPasswordStore = Join-Path $workspaceRoot '.secrets\postgres-bootstrap.xml' }
if ($SslMode -eq 'disable' -and -not $AllowInsecureTailscaleTransport) {
    throw 'SslMode=disable requires -AllowInsecureTailscaleTransport.'
}

function New-RandomPassword {
    $bytes = [byte[]]::new(36)
    $generator = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $generator.GetBytes($bytes) } finally { $generator.Dispose() }
    [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function ConvertTo-PlainText([securestring] $Value) {
    [System.Net.NetworkCredential]::new('', $Value).Password
}

$store = Import-Clixml -LiteralPath $CredentialStore
if (-not $store.Services.Contains('payment')) {
    $store.Services['payment'] = [ordered]@{
        Database = 'vistay_payment_db'
        MigratorUsername = 'vistay_payment_migrator'
        MigratorPassword = ConvertTo-SecureString (New-RandomPassword) -AsPlainText -Force
        AppUsername = 'vistay_payment_app'
        AppPassword = ConvertTo-SecureString (New-RandomPassword) -AsPlainText -Force
    }
    $store | Export-Clixml -LiteralPath $CredentialStore -Force
}

$payment = $store.Services['payment']
$bootstrapPassword = Import-Clixml -LiteralPath $BootstrapPasswordStore
$psql = (Get-Command psql.exe -ErrorAction Stop).Source
$bootstrapSql = Join-Path (Split-Path -Parent $PSScriptRoot) 'database\payment-bootstrap.sql'
$grantSql = Join-Path (Split-Path -Parent $PSScriptRoot) 'database\grant-runtime.sql'
$migrationInit = Join-Path $PSScriptRoot 'migrate.init.gradle'
$repoPath = Join-Path $workspaceRoot 'service_payment'
$previousPassword = $env:PGPASSWORD
$previousSslMode = $env:PGSSLMODE

try {
    $env:PGSSLMODE = $SslMode
    $env:PGPASSWORD = ConvertTo-PlainText $bootstrapPassword
    & $psql -X -v ON_ERROR_STOP=1 -h $store.Host -p $store.Port -U vistay -d vistay `
        -v "payment_migrator_password=$(ConvertTo-PlainText $payment.MigratorPassword)" `
        -v "payment_app_password=$(ConvertTo-PlainText $payment.AppPassword)" `
        -f $bootstrapSql
    if ($LASTEXITCODE -ne 0) { throw 'Payment database bootstrap failed.' }

    $env:DB_MIGRATION_URL = "jdbc:postgresql://$($store.Host):$($store.Port)/$($payment.Database)?sslmode=$SslMode"
    $env:DB_MIGRATION_USERNAME = $payment.MigratorUsername
    $env:DB_MIGRATION_PASSWORD = ConvertTo-PlainText $payment.MigratorPassword
    & (Join-Path $repoPath 'gradlew.bat') --init-script $migrationInit migrateRemoteDatabase --no-daemon -p $repoPath
    if ($LASTEXITCODE -ne 0) { throw 'Payment migration failed.' }

    $env:PGPASSWORD = $env:DB_MIGRATION_PASSWORD
    & $psql -X -v ON_ERROR_STOP=1 -h $store.Host -p $store.Port `
        -U $payment.MigratorUsername -d $payment.Database `
        -v owner_role=vistay_payment_owner -v app_role=$($payment.AppUsername) -f $grantSql
    if ($LASTEXITCODE -ne 0) { throw 'Payment runtime grants failed.' }
}
finally {
    $env:PGPASSWORD = $previousPassword
    $env:PGSSLMODE = $previousSslMode
    Remove-Item Env:DB_MIGRATION_URL, Env:DB_MIGRATION_USERNAME, Env:DB_MIGRATION_PASSWORD -ErrorAction SilentlyContinue
}

Write-Output 'Payment database provisioned and credentials stored with DPAPI.'
