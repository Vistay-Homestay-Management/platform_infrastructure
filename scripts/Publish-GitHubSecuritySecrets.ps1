[CmdletBinding()]
param(
    [string] $Organization = 'Vistay-Homestay-Management',
    [string] $Environment = 'tailscale',
    [string] $SecretsPath
)

$ErrorActionPreference = 'Stop'
if (-not $SecretsPath) {
    $SecretsPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) '.secrets\security-credentials.xml'
}

if (Test-Path -LiteralPath $SecretsPath) {
    $secureSecret = Import-Clixml -LiteralPath $SecretsPath
}
else {
    $bytes = [byte[]]::new(48)
    $generator = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $generator.GetBytes($bytes) } finally { $generator.Dispose() }
    $plainSecret = [Convert]::ToBase64String($bytes)
    $secureSecret = ConvertTo-SecureString $plainSecret -AsPlainText -Force
    Remove-Variable plainSecret
    New-Item -ItemType Directory -Path (Split-Path -Parent $SecretsPath) -Force | Out-Null
    $secureSecret | Export-Clixml -LiteralPath $SecretsPath -Force
}

$plainSecret = [System.Net.NetworkCredential]::new('', $secureSecret).Password
foreach ($name in @('gateway_api', 'service_authentication', 'service_notification')) {
    $repository = "$Organization/$name"
    & gh api --method PUT "repos/$repository/environments/$Environment" --silent
    $plainSecret | & gh secret set VISTAY_JWT_SECRET --repo $repository --env $Environment
    if ($LASTEXITCODE -ne 0) { throw "Could not set VISTAY_JWT_SECRET for $repository" }
}
Remove-Variable plainSecret
Write-Host 'Published the shared JWT verification secret to 3 GitHub environments.'
