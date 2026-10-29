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
    'Calculate SHORT quote with explanation' = 'PRICING_V1'
    'Replay identical SHORT quote' = 'pricingQuoteShortFingerprint'
    'Calculate MEDIUM quote' = 'MEDIUM'
    'Calculate LONG quote' = 'LONG'
    'Reject zero-night quote' = 'INVALID_STAY_RANGE'
    'Reject profile property mismatch' = 'PRICING_PROFILE_PROPERTY_MISMATCH'
    'Anonymous caller cannot calculate quote' = '401'
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
    $parseableBody = $body.Replace('{{pricingQuoteGuestCount}}', '2')
    $parseableBody = $parseableBody.Replace('{{pricingQuoteCommissionBps}}', '500')
    $null = $parseableBody | ConvertFrom-Json
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

$shortQuote = $requests | Where-Object name -eq 'Calculate SHORT quote with explanation' |
    Select-Object -First 1
$shortReplay = $requests | Where-Object name -eq 'Replay identical SHORT quote' |
    Select-Object -First 1
if ($shortQuote.request.body.raw -cne $shortReplay.request.body.raw) {
    throw 'The deterministic SHORT replay must send a byte-identical GraphQL body.'
}
$shortTests = @($shortReplay.event | Where-Object listen -eq 'test' |
    ForEach-Object { $_.script.exec }) -join "`n"
foreach ($evidence in @(
    'pricingQuoteShortFingerprint', 'pricingQuoteShortTotal', 'pricingQuoteShortSnapshot'
)) {
    if (-not $shortTests.Contains($evidence)) {
        throw "The deterministic replay does not assert '$evidence'."
    }
}
$shortEvidence = $shortQuote.request.body.raw + (@($shortQuote.event |
    Where-Object listen -eq 'test' | ForEach-Object { $_.script.exec }) -join "`n")
foreach ($evidence in @(
    'calculationVersion', 'roundingPolicy', 'requestedCommissionBps',
    'commissionDefaultBps', 'commissionMaxBps', 'commissionBaseAmount',
    'precedence', 'evaluatedRules', 'components', '3360000'
)) {
    if (-not $shortEvidence.Contains($evidence)) {
        throw "The SHORT explanation does not cover '$evidence'."
    }
}

$calculationFolder = $collection.item |
    Where-Object name -eq '03 Calculate and explain deterministic quotes' |
    Select-Object -First 1
$calculationPrerequest = @($calculationFolder.event |
    Where-Object listen -eq 'prerequest' | ForEach-Object { $_.script.exec }) -join "`n"
if (-not $calculationPrerequest.Contains('runPricingCalculation')) {
    throw 'The calculation folder must remain guarded by runPricingCalculation.'
}

$quoteRequestNames = @(
    'Calculate SHORT quote with explanation', 'Replay identical SHORT quote',
    'Calculate MEDIUM quote', 'Calculate LONG quote', 'Reject zero-night quote',
    'Reject profile property mismatch', 'Anonymous caller cannot calculate quote'
)
foreach ($name in $quoteRequestNames) {
    $request = $requests | Where-Object name -eq $name | Select-Object -First 1
    $raw = $request.request.body.raw
    if (-not $raw.Contains('query ') -or $raw.Contains('mutation ')) {
        throw "SCRUM-355 request '$name' must be a non-persisting GraphQL query."
    }
    foreach ($outOfScope in @(
        'manualOverride', 'applyOverride', 'publishPricing', 'activeRateProfile',
        'quoteId', 'expiresAt', 'persistQuote', 'bookingSnapshot'
    )) {
        if ($raw.Contains($outOfScope)) {
            throw "SCRUM-355 request '$name' crosses the SCRUM-356/357 boundary via '$outOfScope'."
        }
    }
}

$anonymous = $requests | Where-Object name -eq 'Anonymous caller cannot calculate quote' |
    Select-Object -First 1
if (@($anonymous.request.header | Where-Object key -eq 'Authorization').Count -ne 0) {
    throw 'The anonymous pricing denial proof must not send an Authorization header.'
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
    'runPricingAuthoring', 'runPricingCalculation', 'makerAccessToken', 'targetAccessToken',
    'pricingPropertyId',
    'pricingEffectiveFrom', 'pricingEffectiveToExclusive', 'pricingBaseDailyRate',
    'pricingIdempotencyKey', 'pricingInvalidCommissionIdempotencyKey',
    'pricingInvalidRuleIdempotencyKey', 'pricingDeniedIdempotencyKey',
    'pricingVersionId', 'pricingVersionNumber', 'pricingCreatedSnapshot',
    'pricingQuoteShortCheckIn', 'pricingQuoteShortCheckOut',
    'pricingQuoteMediumCheckIn', 'pricingQuoteMediumCheckOut',
    'pricingQuoteLongCheckIn', 'pricingQuoteLongCheckOut',
    'pricingQuoteGuestCount', 'pricingQuoteChannel', 'pricingQuoteCommissionBps',
    'pricingQuoteOtherPropertyId', 'pricingQuoteShortFingerprint',
    'pricingQuoteShortTotal', 'pricingQuoteShortSnapshot'
)
foreach ($key in $requiredEnvironment) {
    if (-not $environmentValues.ContainsKey($key)) {
        throw "Postman environment is missing pricing variable '$key'."
    }
}
if ($environmentValues['runPricingAuthoring'] -ne 'false') {
    throw 'Pricing authoring must remain opt-in in the checked-in environment.'
}
if ($environmentValues['runPricingCalculation'] -ne 'false') {
    throw 'Pricing calculation must remain opt-in in the checked-in environment.'
}
foreach ($key in @(
    'pricingPropertyId', 'pricingIdempotencyKey', 'pricingInvalidCommissionIdempotencyKey',
    'pricingInvalidRuleIdempotencyKey', 'pricingDeniedIdempotencyKey', 'pricingVersionId',
    'pricingVersionNumber', 'pricingCreatedSnapshot', 'pricingQuoteShortFingerprint',
    'pricingQuoteShortTotal', 'pricingQuoteShortSnapshot'
)) {
    if (-not [string]::IsNullOrEmpty($environmentValues[$key])) {
        throw "Checked-in pricing variable '$key' must be empty."
    }
}

foreach ($schemaMarker in @(
    'createPropertyRateProfileVersion(input: CreatePropertyRateProfileVersionInput!)',
    'propertyRateProfileVersion(id: ID!)',
    'propertyRateProfileVersions(propertyId: ID!)',
    'calculatePropertyPriceQuote(input: CalculatePropertyPriceQuoteInput!)',
    'type PropertyRateProfileVersion',
    'type PropertyPriceQuote',
    'type PricingRuleEvaluation',
    'type PriceComponent',
    'input CalculatePropertyPriceQuoteInput',
    'requestedCommissionBps: Int',
    'commissionDefaultBps: Int!',
    'commissionMaxBps: Int!',
    'commissionBaseAmount: String!',
    'enum StayProduct',
    'enum PricingRuleEvaluationStatus',
    'enum PriceComponentType',
    'input PricingRuleVersionInput',
    'totalAmount: String'
)) {
    if (-not $bookingSchema.Contains($schemaMarker)) {
        throw "Booking subgraph is missing pricing contract '$schemaMarker'."
    }
}
$bookingType = [regex]::Match($bookingSchema, '(?s)type Booking\s*\{.*?\}').Value
if ($bookingType.Contains('totalAmount: String!')) {
    throw 'Booking totalAmount must remain nullable because authorization can mask it.'
}

Write-Output "Postman pricing contract passed: $($requests.Count) requests with immutable authoring and deterministic quote explanation assertions."
