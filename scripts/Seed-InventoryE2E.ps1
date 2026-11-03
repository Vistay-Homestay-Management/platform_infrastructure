[CmdletBinding()]
param(
    [string]$PostgresContainer = 'vistay-postgres-1'
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$propertyFixture = Join-Path $repositoryRoot 'postman\fixtures\inventory-property-e2e.sql'
$bookingFixture = Join-Path $repositoryRoot 'postman\fixtures\inventory-booking-e2e.sql'

if ($PostgresContainer -ne 'vistay-postgres-1') {
    throw 'Inventory E2E fixtures are restricted to the local ViStay PostgreSQL container.'
}

$running = & docker inspect --format '{{.State.Running}}' $PostgresContainer
if ($LASTEXITCODE -ne 0 -or $running -ne 'true') {
    throw "Local PostgreSQL container '$PostgresContainer' is not running."
}

foreach ($fixture in @(
    [pscustomobject]@{ Path = $propertyFixture; Database = 'vistay_property_db'; Label = 'Property topology' },
    [pscustomobject]@{ Path = $bookingFixture; Database = 'vistay_booking_db'; Label = 'Booking inventory' }
)) {
    if (-not (Test-Path -LiteralPath $fixture.Path -PathType Leaf)) {
        throw "Missing inventory fixture '$($fixture.Path)'."
    }

    Get-Content -Raw -LiteralPath $fixture.Path | & docker exec -i $PostgresContainer `
        psql --username vistay --dbname $fixture.Database --set ON_ERROR_STOP=1
    if ($LASTEXITCODE -ne 0) {
        throw "$($fixture.Label) fixture failed with exit code $LASTEXITCODE."
    }
}

Write-Output 'Inventory E2E fixtures are ready in the local Property and Booking databases.'
Write-Output 'Allowed branch: 60000000-0000-4000-8000-000000000001; membership version: 7.'
Write-Output 'Available revision: 0; management revision: 4; command revision: 0.'
