[CmdletBinding()]
param(
    [string] $BackupRoot,
    [string] $CredentialStore,
    [string] $BootstrapPasswordStore,
    [ValidateSet('require', 'verify-ca', 'verify-full', 'disable')]
    [string] $SslMode = 'require',
    [switch] $AllowInsecureTailscaleTransport
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security
$workspaceRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $BackupRoot) { $BackupRoot = Join-Path $workspaceRoot '.backups' }
if (-not $CredentialStore) { $CredentialStore = Join-Path $workspaceRoot '.secrets\database-credentials.xml' }
if (-not $BootstrapPasswordStore) { $BootstrapPasswordStore = Join-Path $workspaceRoot '.secrets\postgres-bootstrap.xml' }
if ($SslMode -eq 'disable' -and -not $AllowInsecureTailscaleTransport) {
    throw 'SslMode=disable requires -AllowInsecureTailscaleTransport. Prefer PostgreSQL TLS even over Tailscale.'
}

function ConvertTo-PlainText([securestring] $Value) {
    [System.Net.NetworkCredential]::new('', $Value).Password
}

function Join-Bytes([byte[][]] $Parts) {
    $length = ($Parts | Measure-Object -Property Length -Sum).Sum
    $result = [byte[]]::new($length)
    $offset = 0
    foreach ($part in $Parts) {
        [Array]::Copy($part, 0, $result, $offset, $part.Length)
        $offset += $part.Length
    }
    $result
}

function Protect-Dump([string] $InputPath, [string] $OutputPath, [byte[]] $KeyMaterial) {
    $plain = [IO.File]::ReadAllBytes($InputPath)
    $aes = [Security.Cryptography.Aes]::Create()
    try {
        $aes.KeySize = 256
        $aes.Mode = [Security.Cryptography.CipherMode]::CBC
        $aes.Padding = [Security.Cryptography.PaddingMode]::PKCS7
        $aes.Key = $KeyMaterial[0..31]
        $aes.GenerateIV()
        $encryptor = $aes.CreateEncryptor()
        try {
            $ciphertext = $encryptor.TransformFinalBlock($plain, 0, $plain.Length)
        }
        finally {
            $encryptor.Dispose()
        }
        $authenticated = Join-Bytes @($aes.IV, $ciphertext)
        $hmac = [Security.Cryptography.HMACSHA256]::new($KeyMaterial[32..63])
        try { $tag = $hmac.ComputeHash($authenticated) } finally { $hmac.Dispose() }
        [IO.File]::WriteAllBytes(
            $OutputPath,
            (Join-Bytes @([Text.Encoding]::ASCII.GetBytes('VISTAY01'), $aes.IV, $tag, $ciphertext))
        )
    }
    finally {
        $aes.Dispose()
        [Array]::Clear($plain, 0, $plain.Length)
    }
}

function Unprotect-Dump([string] $InputPath, [string] $OutputPath, [byte[]] $KeyMaterial) {
    $content = [IO.File]::ReadAllBytes($InputPath)
    if ([Text.Encoding]::ASCII.GetString($content[0..7]) -ne 'VISTAY01') {
        throw 'Unsupported encrypted dump format.'
    }
    $iv = [byte[]]$content[8..23]
    $expectedTag = [byte[]]$content[24..55]
    $ciphertext = [byte[]]$content[56..($content.Length - 1)]
    $hmac = [Security.Cryptography.HMACSHA256]::new($KeyMaterial[32..63])
    try { $actualTag = $hmac.ComputeHash((Join-Bytes @($iv, $ciphertext))) } finally { $hmac.Dispose() }
    $difference = 0
    for ($index = 0; $index -lt $expectedTag.Length; $index++) {
        $difference = $difference -bor ($expectedTag[$index] -bxor $actualTag[$index])
    }
    if ($difference -ne 0) { throw 'Encrypted dump integrity check failed.' }

    $aes = [Security.Cryptography.Aes]::Create()
    try {
        $aes.KeySize = 256
        $aes.Mode = [Security.Cryptography.CipherMode]::CBC
        $aes.Padding = [Security.Cryptography.PaddingMode]::PKCS7
        $aes.Key = $KeyMaterial[0..31]
        $aes.IV = $iv
        $decryptor = $aes.CreateDecryptor()
        try {
            $plain = $decryptor.TransformFinalBlock($ciphertext, 0, $ciphertext.Length)
            [IO.File]::WriteAllBytes($OutputPath, $plain)
            [Array]::Clear($plain, 0, $plain.Length)
        }
        finally { $decryptor.Dispose() }
    }
    finally { $aes.Dispose() }
}

$store = Import-Clixml -LiteralPath $CredentialStore
New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
$resolvedRoot = (Resolve-Path -LiteralPath $BackupRoot).Path
$timestamp = [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$snapshotDirectory = Join-Path $resolvedRoot "epic01-gate-$timestamp"
New-Item -ItemType Directory -Path $snapshotDirectory -Force | Out-Null
$snapshotDirectory = (Resolve-Path -LiteralPath $snapshotDirectory).Path
if (-not $snapshotDirectory.StartsWith($resolvedRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Resolved backup directory escaped BackupRoot.'
}

$keyMaterial = [byte[]]::new(64)
$generator = [Security.Cryptography.RandomNumberGenerator]::Create()
try { $generator.GetBytes($keyMaterial) } finally { $generator.Dispose() }
$protectedKey = [Security.Cryptography.ProtectedData]::Protect(
    $keyMaterial, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser
)
[IO.File]::WriteAllBytes((Join-Path $snapshotDirectory 'snapshot-key.dpapi'), $protectedKey)

$previousPassword = $env:PGPASSWORD
$previousSslMode = $env:PGSSLMODE
$plainPaths = [Collections.Generic.List[string]]::new()
$manifestEntries = @()
$restoreDatabase = "vistay_restore_verify_$([DateTimeOffset]::UtcNow.ToString('yyyyMMddHHmmss'))"
try {
    $env:PGSSLMODE = $SslMode
    foreach ($serviceName in ($store.Services.Keys | Sort-Object)) {
        $service = $store.Services[$serviceName]
        $plainPath = Join-Path $snapshotDirectory "$serviceName.dump.tmp"
        $encryptedPath = Join-Path $snapshotDirectory "$serviceName.dump.aes"
        $plainPaths.Add($plainPath)
        $env:PGPASSWORD = ConvertTo-PlainText $service.MigratorPassword
        & pg_dump.exe -Fc --no-owner --no-privileges -h $store.Host -p $store.Port `
            -U $service.MigratorUsername -d $service.Database -f $plainPath
        if ($LASTEXITCODE -ne 0) { throw "pg_dump failed for $serviceName." }
        & pg_restore.exe --list $plainPath | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Archive validation failed for $serviceName." }
        Protect-Dump $plainPath $encryptedPath $keyMaterial
        Remove-Item -LiteralPath $plainPath -Force
        $manifestEntries += [ordered]@{
            service = $serviceName
            database = $service.Database
            encryptedFile = [IO.Path]::GetFileName($encryptedPath)
            sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $encryptedPath).Hash
            bytes = (Get-Item -LiteralPath $encryptedPath).Length
        }
    }

    $restoreDump = Join-Path $snapshotDirectory 'restore-smoke.dump.tmp'
    $plainPaths.Add($restoreDump)
    Unprotect-Dump (Join-Path $snapshotDirectory 'authentication.dump.aes') $restoreDump $keyMaterial
    $env:PGPASSWORD = ConvertTo-PlainText (Import-Clixml -LiteralPath $BootstrapPasswordStore)
    & psql.exe -X -v ON_ERROR_STOP=1 -h $store.Host -p $store.Port -U vistay -d vistay `
        -c "CREATE DATABASE $restoreDatabase;"
    if ($LASTEXITCODE -ne 0) { throw 'Could not create restore verification database.' }
    try {
        & pg_restore.exe --exit-on-error --no-owner --no-privileges -h $store.Host -p $store.Port `
            -U vistay -d $restoreDatabase $restoreDump
        if ($LASTEXITCODE -ne 0) { throw 'Restore smoke failed.' }
        $restoredTableCount = & psql.exe -X -A -t -v ON_ERROR_STOP=1 -h $store.Host -p $store.Port `
            -U vistay -d $restoreDatabase -c "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'app';"
        if ($LASTEXITCODE -ne 0 -or [int]$restoredTableCount -lt 1) {
            throw 'Restore smoke produced no app tables.'
        }
    }
    finally {
        & psql.exe -X -v ON_ERROR_STOP=1 -h $store.Host -p $store.Port -U vistay -d vistay `
            -c "DROP DATABASE IF EXISTS $restoreDatabase WITH (FORCE);" | Out-Null
    }

    $manifest = [ordered]@{
        createdAt = [DateTimeOffset]::UtcNow.ToString('o')
        sslMode = $SslMode
        encryption = 'AES-256-CBC plus HMAC-SHA256; key protected by Windows DPAPI CurrentUser'
        restoreSmoke = @{ source = 'authentication'; result = 'PASS'; restoredAppTableCount = [int]$restoredTableCount }
        databases = $manifestEntries
    }
    $manifestPath = Join-Path $snapshotDirectory 'manifest.json'
    [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
    Write-Output "snapshot=$snapshotDirectory"
    Write-Output "manifestSha256=$((Get-FileHash -Algorithm SHA256 -LiteralPath $manifestPath).Hash)"
    Write-Output "restoreSmoke=PASS;appTables=$restoredTableCount"
}
finally {
    foreach ($plainPath in $plainPaths) {
        if (Test-Path -LiteralPath $plainPath) {
            $resolved = (Resolve-Path -LiteralPath $plainPath).Path
            if ($resolved.StartsWith($snapshotDirectory, [StringComparison]::OrdinalIgnoreCase)) {
                Remove-Item -LiteralPath $resolved -Force
            }
        }
    }
    [Array]::Clear($keyMaterial, 0, $keyMaterial.Length)
    $env:PGPASSWORD = $previousPassword
    $env:PGSSLMODE = $previousSslMode
}
