[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$collectionPath = Join-Path $repositoryRoot 'postman\ViStay-Pricing.postman_collection.json'
$environmentPath = Join-Path $repositoryRoot 'postman\ViStay-Local.postman_environment.json'
$bookingSchemaPath = Join-Path $repositoryRoot 'router\backoffice\subgraphs\booking.graphql'

$collection = Get-Content -Raw -LiteralPath $collectionPath | ConvertFrom-Json
$environment = Get-Content -Raw -LiteralPath $environmentPath | ConvertFrom-Json
$bookingSchema = Get-Content -Raw -LiteralPath $bookingSchemaPath

function Get-PostmanRequests {
    param([object[]] $Items)
    foreach ($item in $Items) {
        if ($null -ne $item.request) {
            $item
        }
        if ($null -ne $item.item) {
            Get-PostmanRequests -Items @($item.item)
        }
    }
}

$requests = @(Get-PostmanRequests -Items @($collection.item))
$requiredRequests = @{
    'Create property pricing version' = 'createPropertyRateProfileVersion'
    'Replay exact pricing command' = 'createPropertyRateProfileVersion'
    'Reject commission above v1 ceiling' = 'INVALID_COMMISSION_POLICY'
    'Reject non-short-stay pricing rule' = 'INVALID_RULE_STAY_RANGE'
    'CTV cannot author property pricing' = 'FORBIDDEN_PERMISSION'
    'Read authored pricing version' = 'propertyRateProfileVersion'
    'List property pricing versions' = 'propertyRateProfileVersions'
}

foreach ($entry in $requiredRequests.GetEnumerator()) {
    $request = $requests | Where-Object name -eq $entry.Key | Select-Object -First 1
    if ($null -eq $request) {
        throw "Pricing collection is missing request '$($entry.Key)'."
    }
    if ($request.request.url -ne '{{graphqlUrl}}') {
        throw "Pricing request '$($entry.Key)' must use the public GraphQL URL."
    }
    $body = $request.request.body.raw
    $null = $body | ConvertFrom-Json
    $testSource = @($request.event | Where-Object listen -eq 'test' |
        ForEach-Object { $_.script.exec }) -join "`n"
    if (-not $testSource.Contains('pm.test(') -or -not ($body + $testSource).Contains($entry.Value)) {
        throw "Pricing request '$($entry.Key)' is missing its '$($entry.Value)' operation or assertion."
    }
}

$create = $requests | Where-Object name -eq 'Create property pricing version' | Select-Object -First 1
$replay = $requests | Where-Object name -eq 'Replay exact pricing command' | Select-Object -First 1
if ($create.request.body.raw -cne $replay.request.body.raw) {
    throw 'The exact idempotency replay must send a byte-identical GraphQL body.'
}

$denied = $requests | Where-Object name -eq 'CTV cannot author property pricing' | Select-Object -First 1
$deniedAuthorization = $denied.request.header | Where-Object key -eq 'Authorization' | Select-Object -First 1
if ($deniedAuthorization.value -ne 'Bearer {{targetAccessToken}}') {
    throw 'The pricing denial proof must use the scoped CTV target token.'
}

$environmentValues = @{}
foreach ($value in $environment.values) {
    $environmentValues[$value.key] = $value.value
}
$requiredEnvironment = @(
    'runPricingAuthoring', 'makerAccessToken', 'targetAccessToken', 'pricingPropertyId',
    'pricingEffectiveFrom', 'pricingEffectiveToExclusive', 'pricingBaseDailyRate',
    'pricingIdempotencyKey', 'pricingInvalidCommissionIdempotencyKey',
    'pricingInvalidRuleIdempotencyKey', 'pricingDeniedIdempotencyKey',
    'pricingVersionId', 'pricingVersionNumber', 'pricingCreatedSnapshot'
)
foreach ($key in $requiredEnvironment) {
    if (-not $environmentValues.ContainsKey($key)) {
        throw "Postman environment is missing pricing variable '$key'."
    }
}
if ($environmentValues['runPricingAuthoring'] -ne 'false') {
    throw 'Pricing authoring must remain opt-in in the checked-in environment.'
}
foreach ($key in @(
    'pricingPropertyId', 'pricingIdempotencyKey', 'pricingInvalidCommissionIdempotencyKey',
    'pricingInvalidRuleIdempotencyKey', 'pricingDeniedIdempotencyKey', 'pricingVersionId',
    'pricingVersionNumber', 'pricingCreatedSnapshot'
)) {
    if (-not [string]::IsNullOrEmpty($environmentValues[$key])) {
        throw "Checked-in pricing variable '$key' must be empty."
    }
}

foreach ($schemaMarker in @(
    'createPropertyRateProfileVersion(input: CreatePropertyRateProfileVersionInput!)',
    'propertyRateProfileVersion(id: ID!)',
    'propertyRateProfileVersions(propertyId: ID!)',
    'type PropertyRateProfileVersion',
    'input PricingRuleVersionInput',
    'totalAmount: String'
)) {
    if (-not $bookingSchema.Contains($schemaMarker)) {
        throw "Booking subgraph is missing pricing contract '$schemaMarker'."
    }
}
if ($bookingSchema.Contains('totalAmount: String!')) {
    throw 'Booking totalAmount must remain nullable because authorization can mask it.'
}

Write-Output "Postman pricing contract passed: $($requests.Count) requests with immutable replay, validation, authorization and read assertions."
