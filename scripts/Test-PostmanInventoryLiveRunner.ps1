[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$propertyFixturePath = Join-Path $repositoryRoot 'postman\fixtures\inventory-property-e2e.sql'
$bookingFixturePath = Join-Path $repositoryRoot 'postman\fixtures\inventory-booking-e2e.sql'
$seedPath = Join-Path $repositoryRoot 'scripts\Seed-InventoryE2E.ps1'
$runnerPath = Join-Path $repositoryRoot 'scripts\Run-PostmanInventoryE2E.ps1'

foreach ($path in @($propertyFixturePath, $bookingFixturePath, $seedPath, $runnerPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing inventory live-test artifact '$path'."
    }
}

$propertyFixture = Get-Content -Raw -LiteralPath $propertyFixturePath
$bookingFixture = Get-Content -Raw -LiteralPath $bookingFixturePath
$seed = Get-Content -Raw -LiteralPath $seedPath
$runner = Get-Content -Raw -LiteralPath $runnerPath

foreach ($sql in @($propertyFixture, $bookingFixture)) {
    if (-not $sql.Contains('\set ON_ERROR_STOP on') -or
        -not $sql.Contains('BEGIN;') -or
        -not $sql.Contains('COMMIT;')) {
        throw 'Every inventory fixture must be transactional and fail on the first SQL error.'
    }
    foreach ($forbidden in @('DROP DATABASE', 'DROP SCHEMA', 'TRUNCATE ', 'postgresql://', 'password=')) {
        if ($sql.Contains($forbidden)) {
            throw "Inventory fixture contains unsafe marker '$forbidden'."
        }
    }
}

foreach ($ordinal in 1..10) {
    $propertyId = '61000000-0000-4000-8000-{0}' -f $ordinal.ToString('000000000000')
    if (-not $propertyFixture.Contains($propertyId)) {
        throw "Property fixture is missing reserved exact unit '$propertyId'."
    }
}
foreach ($marker in @(
    'property_branch_memberships',
    'membership_version',
    'Deterministic local Postman inventory fixture',
    '61000000-0000-4000-8000-000000000008'
)) {
    if (-not $propertyFixture.Contains($marker)) {
        throw "Property fixture is missing topology marker '$marker'."
    }
}

foreach ($marker in @(
    "'BOOKING', 'TENTATIVE'",
    "'MAINTENANCE', 'ACTIVE'",
    "'CHANNEL', 'ACTIVE'",
    "'MAINTENANCE', 'RELEASED'",
    "'CLEANING', 'CANCELLED'",
    "'CHANNEX'",
    'inventory_property_revisions',
    'inventory_block_commands',
    'command_idempotency'
)) {
    if (-not $bookingFixture.Contains($marker)) {
        throw "Booking fixture is missing deterministic state '$marker'."
    }
}
if ($bookingFixture -notmatch "'61000000-0000-4000-8000-000000000010',\s+4,") {
    throw 'Management fixture must reset to deterministic revision 4.'
}

foreach ($script in @($seed, $runner)) {
    if (-not $script.Contains("'vistay-postgres-1'")) {
        throw 'Inventory scripts must default to the local ViStay PostgreSQL container.'
    }
}
if (-not $seed.Contains("if (`$PostgresContainer -ne 'vistay-postgres-1')")) {
    throw 'Inventory seeding must reject every non-local PostgreSQL container.'
}
foreach ($database in @('vistay_property_db', 'vistay_booking_db')) {
    if (-not $seed.Contains($database)) {
        throw "Inventory seed runner is missing database '$database'."
    }
}

foreach ($collection in @(
    'ViStay-Inventory.postman_collection.json',
    'ViStay-Inventory-Management.postman_collection.json',
    'ViStay-Inventory-Commands.postman_collection.json'
)) {
    if (-not $runner.Contains($collection)) {
        throw "Live runner is missing collection '$collection'."
    }
}
foreach ($marker in @(
    'newman@6.2.1',
    '[System.IO.Path]::GetTempPath()',
    'New-Item -ItemType Directory',
    'Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force',
    "runInventorySeededScenarios = 'true'",
    "runInventoryValidationScenarios = 'true'",
    "runInventoryAuthorizationScenarios = 'false'",
    "runInventoryDependencyScenarios = 'false'",
    "runInventoryCommandFlow = 'true'",
    "runInventoryManagementFlow = 'true'",
    'Read-Host -Prompt $Prompt -AsSecureString',
    "-Secret:(`$entry.Key -like '*Token')"
)) {
    if (-not $runner.Contains($marker)) {
        throw "Live runner is missing safety/coverage marker '$marker'."
    }
}
if ($runner -match 'Set-Content\s+[^\r\n]*ViStay-Local\.postman_environment') {
    throw 'Live runner must never write secrets into the checked-in environment.'
}

$tokens = [regex]::Matches($runner, '(?im)^\s*\[securestring\]\$(\w+AccessToken)')
if ($tokens.Count -ne 3) {
    throw 'Live runner must accept exactly three secure token boundaries.'
}

Write-Output 'Inventory fixture/live-runner contract passed: 10 exact units, 2 owned databases, 3 Newman collections, and no tracked secrets.'
