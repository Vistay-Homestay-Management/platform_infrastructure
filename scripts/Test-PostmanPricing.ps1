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
    'Read override pricing profile' = 'propertyRateProfileVersion'
    'Calculate override base quote' = 'calculatePropertyPriceQuote'
    'Apply pricing override at twenty percent' = 'applyPropertyPriceOverride'
    'Replay exact pricing override' = 'pricingOverrideSnapshot'
    'Reject changed payload for used override key' = 'IDEMPOTENCY_KEY_REUSED'
    'Apply large pricing override with approval' = 'largeApprovalRequired'
    'Preview authored pricing publication' = 'previewPropertyRateProfilePublication'
    'Publish pricing version with expected head' = 'pricing:approve'
    'Replay exact pricing publication' = 'pricingPublicationSnapshot'
    'Preview quote from active published pricing' = 'previewPublishedPropertyPriceQuote'
    'Create immutable pricing quote snapshot' = 'createPropertyPriceQuoteSnapshot'
    'Replay exact pricing quote snapshot' = 'pricingSnapshotSnapshot'
    'Read immutable pricing quote snapshot' = 'propertyPriceQuoteSnapshot'
    'Reject stale base quote snapshot' = 'STALE_BASE_QUOTE'
    'Consume exact manual override in pricing snapshot' = 'manualOverrideId'
    'Replay override-consuming pricing snapshot' = 'pricingOverrideConsumptionSnapshot'
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
    $parseableBody = $parseableBody.Replace('{{pricingPublicationExpectedHeadJson}}', 'null')
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

$overrideFolder = $collection.item |
    Where-Object name -eq '04 Apply audited manual pricing override' |
    Select-Object -First 1
if ($null -eq $overrideFolder) {
    throw 'The collection is missing the SCRUM-356 manual override folder.'
}
$overridePrerequest = @($overrideFolder.event |
    Where-Object listen -eq 'prerequest' | ForEach-Object { $_.script.exec }) -join "`n"
if (-not $overridePrerequest.Contains('runPricingOverride')) {
    throw 'The manual override folder must remain guarded by runPricingOverride.'
}

$applyOverride = $requests | Where-Object name -eq 'Apply pricing override at twenty percent' |
    Select-Object -First 1
$overrideReplay = $requests | Where-Object name -eq 'Replay exact pricing override' |
    Select-Object -First 1
$changedOverride = $requests |
    Where-Object name -eq 'Reject changed payload for used override key' |
    Select-Object -First 1
$largeOverride = $requests |
    Where-Object name -eq 'Apply large pricing override with approval' |
    Select-Object -First 1

if ($applyOverride.request.body.raw -cne $overrideReplay.request.body.raw) {
    throw 'The exact pricing override replay must send a byte-identical GraphQL body.'
}
if (($changedOverride.request.body.raw -ceq $applyOverride.request.body.raw) -or
    (-not $changedOverride.request.body.raw.Contains('{{pricingOverrideIdempotencyKey}}')) -or
    (-not $changedOverride.request.body.raw.Contains('{{pricingOverrideConflictingTargetAmount}}'))) {
    throw 'The idempotency conflict proof must reuse the key with a changed target payload.'
}

$overrideEvidence = $applyOverride.request.body.raw + (@($applyOverride.event |
    Where-Object listen -eq 'test' | ForEach-Object { $_.script.exec }) -join "`n")
foreach ($evidence in @(
    'expectedBaseQuoteFingerprint', 'manualOverride', 'reductionBps',
    'largeApprovalRequired', 'overrideScopeType', 'finalPrecedence',
    'finalComponents', 'pricingOverrideSnapshot',
    'COMMISSION:recalculated-after-manual-override'
)) {
    if (-not $overrideEvidence.Contains($evidence)) {
        throw "The <=20% override proof does not assert '$evidence'."
    }
}

$largePrerequest = @($largeOverride.event |
    Where-Object listen -eq 'prerequest' | ForEach-Object { $_.script.exec }) -join "`n"
if (-not $largePrerequest.Contains('runPricingLargeOverride')) {
    throw 'The large-override proof must remain separately opt-in.'
}
$largeEvidence = $largeOverride.request.body.raw + (@($largeOverride.event |
    Where-Object listen -eq 'test' | ForEach-Object { $_.script.exec }) -join "`n")
foreach ($evidence in @(
    'pricing:approve-large-override', 'largeApprovalRequired',
    'largeApprovalAuthorizationVersion', 'largeApprovalScopeType',
    'pricingLargeOverrideTargetAmount'
)) {
    if (-not $largeEvidence.Contains($evidence)) {
        throw "The large-override proof does not assert '$evidence'."
    }
}

foreach ($name in @(
    'Apply pricing override at twenty percent', 'Replay exact pricing override',
    'Reject changed payload for used override key',
    'Apply large pricing override with approval'
)) {
    $raw = ($requests | Where-Object name -eq $name | Select-Object -First 1).request.body.raw
    if (-not $raw.Contains('mutation ') -or -not $raw.Contains('applyPropertyPriceOverride')) {
        throw "SCRUM-356 request '$name' must call the audited override mutation."
    }
    foreach ($outOfScope in @(
        'publishPricing', 'activeRateProfile', 'persistQuote', 'bookingSnapshot'
    )) {
        if ($raw.Contains($outOfScope)) {
            throw "SCRUM-356 request '$name' crosses the SCRUM-357 boundary via '$outOfScope'."
        }
    }
}

$overrideAuthorization = $applyOverride.request.header |
    Where-Object key -eq 'Authorization' | Select-Object -First 1
if ($overrideAuthorization.value -ne 'Bearer {{makerAccessToken}}') {
    throw 'The override proof must use the SUPER_ADMIN maker token.'
}

$publicationFolder = $collection.item |
    Where-Object name -eq '05 Publish pricing and preserve immutable snapshots' |
    Select-Object -First 1
if ($null -eq $publicationFolder) {
    throw 'The collection is missing the SCRUM-357 publication and snapshot folder.'
}
$publicationPrerequest = @($publicationFolder.event |
    Where-Object listen -eq 'prerequest' | ForEach-Object { $_.script.exec }) -join [Environment]::NewLine
if (-not $publicationPrerequest.Contains('runPricingPublication')) {
    throw 'The publication and snapshot folder must remain guarded by runPricingPublication.'
}

$previewPublication = $requests |
    Where-Object name -eq 'Preview authored pricing publication' |
    Select-Object -First 1
$publish = $requests |
    Where-Object name -eq 'Publish pricing version with expected head' |
    Select-Object -First 1
$publishReplay = $requests |
    Where-Object name -eq 'Replay exact pricing publication' |
    Select-Object -First 1
$publishedPreview = $requests |
    Where-Object name -eq 'Preview quote from active published pricing' |
    Select-Object -First 1
$createSnapshot = $requests |
    Where-Object name -eq 'Create immutable pricing quote snapshot' |
    Select-Object -First 1
$snapshotReplay = $requests |
    Where-Object name -eq 'Replay exact pricing quote snapshot' |
    Select-Object -First 1
$readSnapshot = $requests |
    Where-Object name -eq 'Read immutable pricing quote snapshot' |
    Select-Object -First 1
$staleSnapshot = $requests |
    Where-Object name -eq 'Reject stale base quote snapshot' |
    Select-Object -First 1
$consumeOverride = $requests |
    Where-Object name -eq 'Consume exact manual override in pricing snapshot' |
    Select-Object -First 1
$consumeOverrideReplay = $requests |
    Where-Object name -eq 'Replay override-consuming pricing snapshot' |
    Select-Object -First 1

if (-not $previewPublication.request.body.raw.Contains('$rateProfileVersionId: ID!') -or
    -not $previewPublication.request.body.raw.Contains(
        'previewPropertyRateProfilePublication(rateProfileVersionId: $rateProfileVersionId)') -or
    -not $previewPublication.request.body.raw.Contains(
        '"rateProfileVersionId":"{{pricingVersionId}}"')) {
    throw 'Publication preview must use the normative rateProfileVersionId wire field.'
}
foreach ($publicationCommand in @($publish, $publishReplay)) {
    if (-not $publicationCommand.request.body.raw.Contains(
            '"rateProfileVersionId":"{{pricingVersionId}}"') -or
        $publicationCommand.request.body.raw.Contains('"profileVersionId"')) {
        throw "Publication command '$($publicationCommand.name)' must use the normative rateProfileVersionId input field."
    }
}

if ($publish.request.body.raw -cne $publishReplay.request.body.raw) {
    throw 'The exact pricing publication replay must send a byte-identical GraphQL body.'
}
if ($createSnapshot.request.body.raw -cne $snapshotReplay.request.body.raw) {
    throw 'The exact pricing snapshot replay must send a byte-identical GraphQL body.'
}
if ($consumeOverride.request.body.raw -cne $consumeOverrideReplay.request.body.raw) {
    throw 'The exact override-consuming snapshot replay must send a byte-identical GraphQL body.'
}

$previewPublicationEvidence = $previewPublication.request.body.raw +
    (@($previewPublication.event | Where-Object listen -eq 'test' |
        ForEach-Object { $_.script.exec }) -join [Environment]::NewLine)
foreach ($evidence in @(
    'rateProfileVersionId', 'profileFingerprint', 'currentPublication', 'published',
    'pricingPublicationExpectedHeadJson'
)) {
    if (-not $previewPublicationEvidence.Contains($evidence)) {
        throw "Publication preview does not preserve '$evidence'."
    }
}

$publishEvidence = $publish.request.body.raw + (@($publish.event |
    Where-Object listen -eq 'test' | ForEach-Object { $_.script.exec }) -join [Environment]::NewLine)
foreach ($evidence in @(
    'rateProfileVersionId', 'expectedProfileFingerprint', 'expectedCurrentPublicationId',
    'pricingPublicationExpectedHeadJson', 'PRICING_PUBLICATION_V1',
    'pricing:approve', 'publicationRevision', 'previousPublicationId',
    'pricingPublicationSnapshot'
)) {
    if (-not $publishEvidence.Contains($evidence)) {
        throw "Publication compare-and-set proof does not cover '$evidence'."
    }
}

$publishedPreviewEvidence = $publishedPreview.request.body.raw +
    (@($publishedPreview.event | Where-Object listen -eq 'test' |
        ForEach-Object { $_.script.exec }) -join [Environment]::NewLine)
foreach ($evidence in @(
    'PublishedPropertyPriceQuoteInput', 'previewPublishedPropertyPriceQuote',
    'pricingPublicationId', 'pricingPublishedQuoteFingerprint',
    'pricingPublishedQuoteProfileId', 'pricingPublishedQuoteSnapshot'
)) {
    if (-not $publishedPreviewEvidence.Contains($evidence)) {
        throw "Published quote preview does not cover '$evidence'."
    }
}

$snapshotEvidence = $createSnapshot.request.body.raw + (@($createSnapshot.event |
    Where-Object listen -eq 'test' | ForEach-Object { $_.script.exec }) -join [Environment]::NewLine)
foreach ($evidence in @(
    'expectedRateProfileVersionId', 'expectedBaseQuoteFingerprint',
    'pricingPublicationId', 'manualOverrideId', 'baseQuoteFingerprint',
    'finalQuote', 'pricing:read', 'ACTIVE', 'createdAt', 'expiresAt',
    'pricingSnapshotSnapshot'
)) {
    if (-not $snapshotEvidence.Contains($evidence)) {
        throw "Immutable pricing snapshot proof does not cover '$evidence'."
    }
}
if (-not $readSnapshot.request.body.raw.Contains('propertyPriceQuoteSnapshot') -or
    -not ((@($readSnapshot.event | Where-Object listen -eq 'test' |
        ForEach-Object { $_.script.exec }) -join [Environment]::NewLine).Contains('pricingSnapshotSnapshot'))) {
    throw 'The historical snapshot read must compare the complete stored evidence.'
}
if (-not $staleSnapshot.request.body.raw.Contains('{{pricingSnapshotStaleFingerprint}}') -or
    -not $staleSnapshot.request.body.raw.Contains('{{pricingSnapshotStaleIdempotencyKey}}')) {
    throw 'The stale snapshot proof must use a separate command and changed base fingerprint.'
}

foreach ($optional in @($consumeOverride, $consumeOverrideReplay)) {
    $guard = @($optional.event | Where-Object listen -eq 'prerequest' |
        ForEach-Object { $_.script.exec }) -join [Environment]::NewLine
    if (-not $guard.Contains('runPricingOverrideConsumption')) {
        throw "Optional request '$($optional.name)' must remain separately opt-in."
    }
}
$consumptionEvidence = $consumeOverride.request.body.raw +
    (@($consumeOverride.event | Where-Object listen -eq 'test' |
        ForEach-Object { $_.script.exec }) -join [Environment]::NewLine)
foreach ($evidence in @(
    'manualOverrideId', '{{pricingOverrideId}}',
    'pricingOverrideTargetAmount', 'MANUAL_OVERRIDE:whole-stay-lodging-reduction',
    'pricingOverrideConsumptionSnapshot'
)) {
    if (-not $consumptionEvidence.Contains($evidence)) {
        throw "Exact manual-override consumption does not cover '$evidence'."
    }
}

foreach ($name in @(
    'Preview authored pricing publication',
    'Preview quote from active published pricing',
    'Read immutable pricing quote snapshot'
)) {
    $raw = ($requests | Where-Object name -eq $name | Select-Object -First 1).request.body.raw
    if (-not $raw.Contains('query ') -or $raw.Contains('mutation ')) {
        throw "SCRUM-357 read '$name' must remain non-mutating."
    }
}
foreach ($name in @(
    'Publish pricing version with expected head',
    'Replay exact pricing publication',
    'Create immutable pricing quote snapshot',
    'Replay exact pricing quote snapshot',
    'Reject stale base quote snapshot',
    'Consume exact manual override in pricing snapshot',
    'Replay override-consuming pricing snapshot'
)) {
    $request = $requests | Where-Object name -eq $name | Select-Object -First 1
    if (-not $request.request.body.raw.Contains('mutation ')) {
        throw "SCRUM-357 command '$name' must use a GraphQL mutation."
    }
    $authorization = $request.request.header |
        Where-Object key -eq 'Authorization' | Select-Object -First 1
    if ($authorization.value -ne 'Bearer {{makerAccessToken}}') {
        throw "SCRUM-357 command '$name' must use the SUPER_ADMIN maker token."
    }
}

$collectionPrerequest = @($collection.event |
    Where-Object listen -eq 'prerequest' | ForEach-Object { $_.script.exec }) -join [Environment]::NewLine
foreach ($uuidCorrelation in @(
    'pm.environment.set(''pricingOverrideCorrelationId'', pm.variables.replaceIn(''{{$guid}}''))',
    'pm.environment.set(''pricingLargeOverrideCorrelationId'', pm.variables.replaceIn(''{{$guid}}''))',
    'pm.environment.set(''pricingPublicationCorrelationId'', pm.variables.replaceIn(''{{$guid}}''))',
    'pm.environment.set(''pricingSnapshotCorrelationId'', pm.variables.replaceIn(''{{$guid}}''))',
    'pm.environment.set(''pricingSnapshotStaleCorrelationId'', pm.variables.replaceIn(''{{$guid}}''))',
    'pm.environment.set(''pricingOverrideConsumptionCorrelationId'', pm.variables.replaceIn(''{{$guid}}''))'
)) {
    if (-not $collectionPrerequest.Contains($uuidCorrelation)) {
        throw "Correlation generation must use a canonical UUID: $uuidCorrelation"
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
    'runPricingAuthoring', 'runPricingCalculation', 'runPricingOverride',
    'runPricingLargeOverride', 'makerAccessToken', 'targetAccessToken',
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
    'pricingQuoteShortTotal', 'pricingQuoteShortSnapshot',
    'pricingOverrideIdempotencyKey', 'pricingOverrideCorrelationId',
    'pricingOverrideBaseFingerprint', 'pricingOverrideBaseLodging',
    'pricingOverrideBaseTotal', 'pricingOverrideTargetAmount',
    'pricingOverrideConflictingTargetAmount', 'pricingOverrideId',
    'pricingOverrideSnapshot', 'pricingLargeOverrideIdempotencyKey',
    'pricingLargeOverrideCorrelationId', 'pricingLargeOverrideTargetAmount',
    'pricingLargeOverrideId', 'runPricingPublication',
    'runPricingOverrideConsumption', 'pricingPublicationIdempotencyKey',
    'pricingPublicationCorrelationId', 'pricingPublicationProfileFingerprint',
    'pricingPublicationExpectedHeadJson', 'pricingPublicationId',
    'pricingPublicationRevision', 'pricingPublicationSnapshot',
    'pricingPublishedQuoteFingerprint', 'pricingPublishedQuoteProfileId',
    'pricingPublishedQuoteSnapshot', 'pricingSnapshotIdempotencyKey',
    'pricingSnapshotCorrelationId', 'pricingSnapshotId',
    'pricingSnapshotSnapshot', 'pricingSnapshotStaleIdempotencyKey',
    'pricingSnapshotStaleCorrelationId', 'pricingSnapshotStaleFingerprint',
    'pricingOverrideConsumptionIdempotencyKey',
    'pricingOverrideConsumptionCorrelationId',
    'pricingOverrideConsumptionSnapshotId',
    'pricingOverrideConsumptionSnapshot'
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
if ($environmentValues['runPricingOverride'] -ne 'false') {
    throw 'Pricing override must remain opt-in in the checked-in environment.'
}
if ($environmentValues['runPricingLargeOverride'] -ne 'false') {
    throw 'Large pricing override must remain separately opt-in in the checked-in environment.'
}
if ($environmentValues['runPricingPublication'] -ne 'false') {
    throw 'Pricing publication and snapshot persistence must remain opt-in.'
}
if ($environmentValues['runPricingOverrideConsumption'] -ne 'false') {
    throw 'Manual-override consumption must remain separately opt-in.'
}
foreach ($key in @(
    'pricingPropertyId', 'pricingIdempotencyKey', 'pricingInvalidCommissionIdempotencyKey',
    'pricingInvalidRuleIdempotencyKey', 'pricingDeniedIdempotencyKey', 'pricingVersionId',
    'pricingVersionNumber', 'pricingCreatedSnapshot', 'pricingQuoteShortFingerprint',
    'pricingQuoteShortTotal', 'pricingQuoteShortSnapshot',
    'pricingOverrideIdempotencyKey', 'pricingOverrideCorrelationId',
    'pricingOverrideBaseFingerprint', 'pricingOverrideBaseLodging',
    'pricingOverrideBaseTotal', 'pricingOverrideTargetAmount',
    'pricingOverrideConflictingTargetAmount', 'pricingOverrideId',
    'pricingOverrideSnapshot', 'pricingLargeOverrideIdempotencyKey',
    'pricingLargeOverrideCorrelationId', 'pricingLargeOverrideTargetAmount',
    'pricingLargeOverrideId', 'pricingPublicationIdempotencyKey',
    'pricingPublicationCorrelationId', 'pricingPublicationProfileFingerprint',
    'pricingPublicationExpectedHeadJson', 'pricingPublicationId',
    'pricingPublicationRevision', 'pricingPublicationSnapshot',
    'pricingPublishedQuoteFingerprint', 'pricingPublishedQuoteProfileId',
    'pricingPublishedQuoteSnapshot', 'pricingSnapshotIdempotencyKey',
    'pricingSnapshotCorrelationId', 'pricingSnapshotId',
    'pricingSnapshotSnapshot', 'pricingSnapshotStaleIdempotencyKey',
    'pricingSnapshotStaleCorrelationId', 'pricingSnapshotStaleFingerprint',
    'pricingOverrideConsumptionIdempotencyKey',
    'pricingOverrideConsumptionCorrelationId',
    'pricingOverrideConsumptionSnapshotId',
    'pricingOverrideConsumptionSnapshot'
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
    'applyPropertyPriceOverride(input: ApplyPropertyPriceOverrideInput!)',
    'type PropertyRateProfileVersion',
    'type PropertyPriceQuote',
    'type AppliedPropertyPriceOverride',
    'type PricingManualOverride',
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
    'enum PricingOverrideScopeType',
    'input PricingRuleVersionInput',
    'input ApplyPropertyPriceOverrideInput',
    'previewPropertyRateProfilePublication(rateProfileVersionId: ID!)',
    'activePropertyRateProfileVersion(propertyId: ID!, checkInDate: String!, checkOutDate: String!)',
    'previewPublishedPropertyPriceQuote(input: PublishedPropertyPriceQuoteInput!)',
    'propertyPriceQuoteSnapshot(id: ID!)',
    'publishPropertyRateProfileVersion(input: PublishPropertyRateProfileVersionInput!)',
    'createPropertyPriceQuoteSnapshot(input: CreatePropertyPriceQuoteSnapshotInput!)',
    'type PricingProfilePublicationPreview',
    'type PricingProfilePublication',
    'type PublishedPropertyPriceQuotePreview',
    'type PropertyPriceFinalQuote',
    'type PropertyPriceQuoteSnapshot',
    'input PublishPropertyRateProfileVersionInput',
    'input PublishedPropertyPriceQuoteInput',
    'input CreatePropertyPriceQuoteSnapshotInput',
    'MANUAL_OVERRIDE',
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
$publishInputType = [regex]::Match(
    $bookingSchema,
    '(?s)input PublishPropertyRateProfileVersionInput\s*\{.*?\}'
).Value
if (-not $publishInputType.Contains('rateProfileVersionId: ID!') -or
    $publishInputType.Contains('profileVersionId: ID!')) {
    throw 'Booking publication input must expose rateProfileVersionId, not the obsolete profileVersionId alias.'
}

Write-Output "Postman pricing contract passed: $($requests.Count) requests with immutable authoring, deterministic quote explanation, audited override, publication CAS, and historical snapshot assertions."
