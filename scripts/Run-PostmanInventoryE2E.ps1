[CmdletBinding()]
param(
    [uri]$GraphqlUrl = 'http://graphql.localhost/graphql',
    [securestring]$InventoryAccessToken,
    [securestring]$ForeignBranchAccessToken,
    [securestring]$ForbiddenCommandAccessToken,
    [string]$PostgresContainer = 'vistay-postgres-1',
    [switch]$SkipSeed
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$baseEnvironmentPath = Join-Path $repositoryRoot 'postman\ViStay-Local.postman_environment.json'
$collections = @(
    'postman\ViStay-Inventory.postman_collection.json',
    'postman\ViStay-Inventory-Management.postman_collection.json',
    'postman\ViStay-Inventory-Commands.postman_collection.json'
)

function Read-RequiredSecret {
    param([securestring]$Value, [string]$Prompt)

    if ($null -ne $Value -and $Value.Length -gt 0) {
        return $Value
    }
    $entered = Read-Host -Prompt $Prompt -AsSecureString
    if ($null -eq $entered -or $entered.Length -eq 0) {
        throw "$Prompt is required."
    }
    $entered
}

function ConvertFrom-SecureValue {
    param([securestring]$Value)

    [System.Net.NetworkCredential]::new('', $Value).Password
}

function Set-EnvironmentValue {
    param(
        [object]$Environment,
        [string]$Key,
        [string]$Value,
        [switch]$Secret
    )

    $entry = @($Environment.values | Where-Object key -eq $Key)
    if ($entry.Count -ne 1) {
        throw "Expected exactly one Postman environment entry '$Key'."
    }
    $entry[0].value = $Value
    if ($Secret) {
        $entry[0].type = 'secret'
    }
}

$InventoryAccessToken = Read-RequiredSecret -Value $InventoryAccessToken `
    -Prompt 'PKCE token with inventory:read, inventory:block and allowed branch/ALL'
$ForeignBranchAccessToken = Read-RequiredSecret -Value $ForeignBranchAccessToken `
    -Prompt 'PKCE token that cannot access the allowed fixture branch'
$ForbiddenCommandAccessToken = Read-RequiredSecret -Value $ForbiddenCommandAccessToken `
    -Prompt 'PKCE token without inventory:block'

if (-not $SkipSeed) {
    & (Join-Path $PSScriptRoot 'Seed-InventoryE2E.ps1') -PostgresContainer $PostgresContainer
    if ($LASTEXITCODE -ne 0) {
        throw 'Inventory fixture seeding failed.'
    }
}

$npx = Get-Command npx -ErrorAction SilentlyContinue
if (-not $npx) {
    throw 'Node.js with npx is required to run the pinned Newman CLI.'
}

$temporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) `
    ("vistay-inventory-postman-{0}" -f [guid]::NewGuid().ToString('N'))
$temporaryEnvironmentPath = Join-Path $temporaryDirectory 'ViStay-Inventory-Local.runtime.json'

try {
    New-Item -ItemType Directory -Path $temporaryDirectory -ErrorAction Stop | Out-Null
    $environment = Get-Content -Raw -LiteralPath $baseEnvironmentPath | ConvertFrom-Json

    $plainInventoryToken = ConvertFrom-SecureValue -Value $InventoryAccessToken
    $plainForeignToken = ConvertFrom-SecureValue -Value $ForeignBranchAccessToken
    $plainForbiddenToken = ConvertFrom-SecureValue -Value $ForbiddenCommandAccessToken
    try {
        $values = [ordered]@{
            graphqlUrl = $GraphqlUrl.AbsoluteUri
            runInventorySeededScenarios = 'true'
            runInventoryValidationScenarios = 'true'
            runInventoryAuthorizationScenarios = 'false'
            runInventoryDependencyScenarios = 'false'
            runInventoryCommandFlow = 'true'
            runInventoryManagementFlow = 'true'
            inventoryAccessToken = $plainInventoryToken
            inventoryForeignBranchAccessToken = $plainForeignToken
            inventoryCommandAccessToken = $plainInventoryToken
            inventoryCommandForbiddenAccessToken = $plainForbiddenToken
            inventoryManagementAccessToken = $plainInventoryToken
            inventoryManagementForeignAccessToken = $plainForeignToken
            inventoryAvailablePropertyId = '61000000-0000-4000-8000-000000000001'
            inventoryBookingBlockedPropertyId = '61000000-0000-4000-8000-000000000002'
            inventoryMaintenanceBlockedPropertyId = '61000000-0000-4000-8000-000000000003'
            inventoryChannelBlockedPropertyId = '61000000-0000-4000-8000-000000000004'
            inventoryHistoryOnlyPropertyId = '61000000-0000-4000-8000-000000000005'
            inventoryAdjacentPropertyId = '61000000-0000-4000-8000-000000000006'
            inventoryForeignPropertyId = '61000000-0000-4000-8000-000000000007'
            inventoryUnmappedPropertyId = '61000000-0000-4000-8000-000000000008'
            inventoryCommandPropertyId = '61000000-0000-4000-8000-000000000009'
            inventoryManagementPropertyId = '61000000-0000-4000-8000-000000000010'
            inventoryExpectedBranchId = '60000000-0000-4000-8000-000000000001'
            inventoryExpectedMembershipVersion = '7'
            inventoryExpectedRevision = '0'
            inventoryManagementExpectedBranchId = '60000000-0000-4000-8000-000000000001'
            inventoryManagementExpectedMembershipVersion = '7'
        }
        foreach ($entry in $values.GetEnumerator()) {
            Set-EnvironmentValue -Environment $environment -Key $entry.Key -Value $entry.Value `
                -Secret:($entry.Key -like '*Token')
        }
        $environment | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $temporaryEnvironmentPath `
            -Encoding utf8NoBOM
    }
    finally {
        $plainInventoryToken = $null
        $plainForeignToken = $null
        $plainForbiddenToken = $null
    }

    foreach ($relativeCollection in $collections) {
        $collectionPath = Join-Path $repositoryRoot $relativeCollection
        Write-Output "Running $([System.IO.Path]::GetFileName($collectionPath))"
        & $npx.Source --yes newman@6.2.1 run $collectionPath `
            --environment $temporaryEnvironmentPath `
            --reporters cli `
            --bail
        if ($LASTEXITCODE -ne 0) {
            throw "Newman failed for '$relativeCollection' with exit code $LASTEXITCODE."
        }
    }
}
finally {
    if (Test-Path -LiteralPath $temporaryDirectory) {
        Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
    }
}

Write-Output 'Inventory observation, management, and command Newman flows passed.'
