[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$MakerAccountId,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$TargetAccountId,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$TargetProfileId,
    [string]$PostgresContainer = 'vistay-postgres-1'
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$fixture = Join-Path $repositoryRoot 'postman\fixtures\authorization-e2e.sql'

if ($PostgresContainer -ne 'vistay-postgres-1') {
    throw 'Authorization E2E fixtures are restricted to the local ViStay PostgreSQL container.'
}

$running = & docker inspect --format '{{.State.Running}}' $PostgresContainer
if ($LASTEXITCODE -ne 0 -or $running -ne 'true') {
    throw "Local PostgreSQL container '$PostgresContainer' is not running."
}

Get-Content -Raw -LiteralPath $fixture | & docker exec -i $PostgresContainer `
    psql --username vistay --dbname vistay_booking_db --set ON_ERROR_STOP=1 `
    --set maker_account_id=$MakerAccountId `
    --set target_account_id=$TargetAccountId `
    --set target_profile_id=$TargetProfileId
if ($LASTEXITCODE -ne 0) {
    throw "Authorization E2E fixture failed with exit code $LASTEXITCODE."
}

Write-Output 'Authorization E2E bookings are ready in the local Booking database.'
