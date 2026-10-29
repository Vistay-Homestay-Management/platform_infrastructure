[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$collectionPath = Join-Path $repositoryRoot 'postman\ViStay-Inventory-Commands.postman_collection.json'
$environmentPath = Join-Path $repositoryRoot 'postman\ViStay-Local.postman_environment.json'
$bookingSdlPath = Join-Path $repositoryRoot 'router\backoffice\subgraphs\booking.graphql'

$collection = Get-Content -Raw -LiteralPath $collectionPath | ConvertFrom-Json
$environment = Get-Content -Raw -LiteralPath $environmentPath | ConvertFrom-Json
$bookingSdl = Get-Content -Raw -LiteralPath $bookingSdlPath

function Get-PostmanRequests {
    param([object[]] $Items)
    foreach ($item in $Items) {
        if ($null -ne $item.request) { $item }
        if ($null -ne $item.item) { Get-PostmanRequests -Items @($item.item) }
    }
}

function Get-EventSource {
    param([object[]] $Events, [string] $Listener)
    @($Events | Where-Object listen -eq $Listener | ForEach-Object { $_.script.exec }) -join "`n"
}

function Assert-SdlBlock {
    param([string] $Kind, [string] $Name, [string[]] $ExpectedLines)
    $pattern = "(?ms)\b$Kind\s+$Name\s*\{(?<body>.*?)\}"
    $match = [regex]::Match($bookingSdl, $pattern)
    if (-not $match.Success) { throw "Booking subgraph is missing $Kind '$Name'." }
    $actual = @($match.Groups['body'].Value -split "`r?`n" |
        ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if (($actual -join "`n") -ne ($ExpectedLines -join "`n")) {
        throw "Booking subgraph $Kind '$Name' does not match inventory command v1.`nActual:`n$($actual -join "`n")"
    }
}

if ($collection.info.name -ne 'ViStay Inventory Block Commands') {
    throw 'Inventory command collection must retain its dedicated stable name.'
}
if (@($collection.item).Count -ne 1 -or
    $collection.item[0].name -ne '01 Ordered create and release flow') {
    throw 'Inventory command collection must contain one explicitly ordered folder.'
}

$requests = @(Get-PostmanRequests -Items @($collection.item))
$expectedOrder = @(
    'Observe command property revision',
    'Create active maintenance block',
    'Replay exact create command',
    'Reject changed payload for create key',
    'Reject stale inventory revision',
    'Release active maintenance block',
    'Replay exact release command',
    'Forbidden role cannot create block',
    'Equal command dates are invalid'
)
if (($requests.name -join "`n") -ne ($expectedOrder -join "`n")) {
    throw "Inventory command requests must retain the normative order.`nActual:`n$($requests.name -join "`n")"
}

$folderGuard = Get-EventSource -Events @($collection.item[0].event) -Listener 'prerequest'
foreach ($evidence in @(
    "pm.environment.get('runInventoryCommandFlow')",
    'pm.execution.skipRequest()',
    'inventoryCommandAccessToken',
    'inventoryCommandForbiddenAccessToken',
    'inventoryCommandPropertyId'
)) {
    if (-not $folderGuard.Contains($evidence)) {
        throw "Ordered inventory folder is missing safe-default prerequisite '$evidence'."
    }
}

$requestByName = @{}
foreach ($request in $requests) {
    if ($requestByName.ContainsKey($request.name)) {
        throw "Duplicate inventory command request '$($request.name)'."
    }
    $requestByName[$request.name] = $request
    if ($request.request.method -ne 'POST' -or $request.request.url -ne '{{graphqlUrl}}') {
        throw "Inventory command '$($request.name)' must POST only to {{graphqlUrl}}."
    }
    if ($request.request.body.mode -ne 'raw') {
        throw "Inventory command '$($request.name)' must have an inspectable raw GraphQL body."
    }
}

$selection = 'commandId idempotencyKey requestHash inventoryBlockId action propertyId blockType status startDate endDateExclusive blockVersion inventoryRevision branchId propertyMembershipVersion occurredAt releasedAt'
$observeQuery = 'query InventoryCommandAvailability($input: PropertyAvailabilityInput!) { propertyAvailability(input: $input) { propertyId checkInDate checkOutDate available inventoryRevision branchId propertyMembershipVersion observedAt overlaps { type status startDate endDateExclusive channelProvider } } }'
$createQuery = "mutation CreateInventoryBlock(`$input: CreateInventoryBlockInput!) { createInventoryBlock(input: `$input) { $selection } }"
$releaseQuery = "mutation ReleaseInventoryBlock(`$input: ReleaseInventoryBlockInput!) { releaseInventoryBlock(input: `$input) { $selection } }"

$bodies = @{}
foreach ($request in $requests) {
    $body = $request.request.body.raw | ConvertFrom-Json
    $bodies[$request.name] = $body
    $normalized = $body.query -replace '\s+', ' '
    $expectedQuery = if ($request.name -eq 'Observe command property revision') {
        $observeQuery
    } elseif ($request.name -in @('Release active maintenance block', 'Replay exact release command')) {
        $releaseQuery
    } else {
        $createQuery
    }
    if ($normalized -ne ($expectedQuery -replace '\s+', ' ')) {
        throw "Inventory command '$($request.name)' does not use the canonical operation/selection set."
    }
}

$observeFields = @($bodies['Observe command property revision'].variables.input.PSObject.Properties.Name | Sort-Object)
if (($observeFields -join ',') -ne 'checkInDate,checkOutDate,propertyId') {
    throw 'Inventory command observation input is noncanonical.'
}
foreach ($name in $expectedOrder | Where-Object { $_ -notin @(
    'Observe command property revision', 'Release active maintenance block', 'Replay exact release command') }) {
    $fields = @($bodies[$name].variables.input.PSObject.Properties.Name | Sort-Object)
    $expected = 'blockType,correlationId,endDateExclusive,expectedInventoryRevision,idempotencyKey,propertyId,reason,startDate'
    if (($fields -join ',') -ne $expected) {
        throw "Create command '$name' has noncanonical input fields: $($fields -join ',')."
    }
}
foreach ($name in @('Release active maintenance block', 'Replay exact release command')) {
    $fields = @($bodies[$name].variables.input.PSObject.Properties.Name | Sort-Object)
    $expected = 'correlationId,expectedInventoryRevision,idempotencyKey,inventoryBlockId,propertyId,reason'
    if (($fields -join ',') -ne $expected) {
        throw "Release command '$name' has noncanonical input fields: $($fields -join ',')."
    }
}

$createRaw = $requestByName['Create active maintenance block'].request.body.raw
if ($requestByName['Replay exact create command'].request.body.raw -ne $createRaw) {
    throw 'Exact create replay must resend the byte-identical GraphQL request body.'
}
$releaseRaw = $requestByName['Release active maintenance block'].request.body.raw
if ($requestByName['Replay exact release command'].request.body.raw -ne $releaseRaw) {
    throw 'Exact release replay must resend the byte-identical GraphQL request body.'
}
$createInput = $bodies['Create active maintenance block'].variables.input
$changedInput = $bodies['Reject changed payload for create key'].variables.input
if ($changedInput.idempotencyKey -ne $createInput.idempotencyKey -or
    $changedInput.correlationId -ne $createInput.correlationId -or
    $changedInput.reason -eq $createInput.reason) {
    throw 'Changed-payload scenario must retain the create identity and change a hashed field.'
}
if ($bodies['Reject stale inventory revision'].variables.input.expectedInventoryRevision -ne
        '{{inventoryCommandInitialRevision}}') {
    throw 'Stale scenario must deliberately retain the pre-create inventory revision.'
}
if ($bodies['Forbidden role cannot create block'].variables.input.expectedInventoryRevision -ne
        '{{inventoryCommandInitialRevision}}') {
    throw 'Forbidden scenario must carry a stale revision to remain mutation-safe if authorization regresses.'
}
if ($bodies['Equal command dates are invalid'].variables.input.startDate -ne
        $bodies['Equal command dates are invalid'].variables.input.endDateExclusive) {
    throw 'Validation scenario must use an empty half-open range.'
}

foreach ($name in $expectedOrder) {
    $headers = @{}
    foreach ($header in @($requestByName[$name].request.header)) { $headers[$header.key] = $header.value }
    if ($headers['Content-Type'] -ne 'application/json' -or
        $headers['X-CSRF-Token'] -ne 'inventory-command') {
        throw "Inventory command '$name' is missing the canonical content/CSRF headers."
    }
    $expectedToken = if ($name -eq 'Forbidden role cannot create block') {
        'Bearer {{inventoryCommandForbiddenAccessToken}}'
    } else {
        'Bearer {{inventoryCommandAccessToken}}'
    }
    if ($headers['Authorization'] -ne $expectedToken) {
        throw "Inventory command '$name' uses the wrong token boundary."
    }
}

$expectedErrorCodes = [ordered]@{
    'Reject changed payload for create key' = 'IDEMPOTENCY_KEY_REUSED'
    'Reject stale inventory revision' = 'STALE_INVENTORY_REVISION'
    'Forbidden role cannot create block' = 'INVENTORY_BLOCK_FORBIDDEN'
    'Equal command dates are invalid' = 'INVALID_INVENTORY_RANGE'
}
foreach ($entry in $expectedErrorCodes.GetEnumerator()) {
    $source = Get-EventSource -Events @($requestByName[$entry.Key].event) -Listener 'test'
    if (-not $source.Contains("'$($entry.Value)'") -or
        -not $source.Contains("to.not.be.an('object')")) {
        throw "Negative scenario '$($entry.Key)' must assert '$($entry.Value)' and no mutation result."
    }
}
foreach ($entry in ([ordered]@{
    'Observe command property revision' = @('available', 'inventoryCommandInitialRevision', 'overlaps')
    'Create active maintenance block' = @('CREATED', 'ACTIVE', 'inventoryCommandCreateSnapshot', 'BigInt')
    'Replay exact create command' = @('inventoryCommandCreateSnapshot', 'to.eql')
    'Release active maintenance block' = @(
        'RELEASED', 'inventoryCommandReleaseSnapshot', 'BigInt',
        'inventoryCommandPropertyId', 'inventoryCommandStartDate',
        'inventoryCommandEndDateExclusive', 'inventoryCommandBranchId',
        'inventoryCommandMembershipVersion'
    )
    'Replay exact release command' = @('inventoryCommandReleaseSnapshot', 'to.eql')
}).GetEnumerator()) {
    $source = Get-EventSource -Events @($requestByName[$entry.Key].event) -Listener 'test'
    foreach ($marker in $entry.Value) {
        if (-not $source.Contains($marker)) {
            throw "Positive scenario '$($entry.Key)' is missing assertion/evidence '$marker'."
        }
    }
}

$rootTestSource = Get-EventSource -Events @($collection.event) -Listener 'test'
foreach ($privateField in @(
    'bookingId', 'holdId', 'channelExternalBlockId', 'channelExternalReference',
    'externalBlockReference', 'externalReference', 'notes', 'actorId',
    'actorAccountId', 'actorProfileId', 'guestId', 'customerId', 'hostId',
    'totalAmount', 'commercialAmount', 'credential', 'accessToken',
    'authorizationEvidence'
)) {
    if (-not $rootTestSource.Contains("'$privateField'")) {
        throw "Inventory command privacy assertion is missing excluded field '$privateField'."
    }
}
if ($rootTestSource.Contains("'inventoryBlockId'")) {
    throw 'Command collection must allow its explicit inventoryBlockId result; observation privacy remains separate.'
}
foreach ($sensitivePattern in @(
    'jdbc:', 'postgres', 'https?', 'bearer', 'select', 'insert', 'update',
    'delete', 'password', 'client_secret'
)) {
    if (-not $rootTestSource.Contains($sensitivePattern)) {
        throw "Inventory command sanitized-error assertion is missing pattern '$sensitivePattern'."
    }
}

$environmentByKey = @{}
foreach ($value in $environment.values) {
    if ($environmentByKey.ContainsKey($value.key)) {
        throw "Postman environment contains duplicate key '$($value.key)'."
    }
    $environmentByKey[$value.key] = $value
}
if (-not $environmentByKey.ContainsKey('runInventoryCommandFlow') -or
    $environmentByKey['runInventoryCommandFlow'].value -ne 'false') {
    throw 'runInventoryCommandFlow must be checked in as false.'
}
foreach ($tokenKey in @('inventoryCommandAccessToken', 'inventoryCommandForbiddenAccessToken')) {
    if (-not $environmentByKey.ContainsKey($tokenKey) -or
        $environmentByKey[$tokenKey].type -ne 'secret' -or
        -not [string]::IsNullOrEmpty($environmentByKey[$tokenKey].value)) {
        throw "Inventory command token '$tokenKey' must be typed secret and checked in empty."
    }
}
$emptyVariables = @(
    'inventoryCommandPropertyId', 'inventoryCommandInitialRevision',
    'inventoryCommandBranchId', 'inventoryCommandMembershipVersion',
    'inventoryCommandCreateIdempotencyKey', 'inventoryCommandCreateCorrelationId',
    'inventoryCommandCreateSnapshot', 'inventoryCommandBlockId',
    'inventoryCommandCreatedRevision', 'inventoryCommandCreatedBlockVersion',
    'inventoryCommandStaleIdempotencyKey', 'inventoryCommandStaleCorrelationId',
    'inventoryCommandReleaseIdempotencyKey', 'inventoryCommandReleaseCorrelationId',
    'inventoryCommandReleaseSnapshot', 'inventoryCommandReleasedRevision',
    'inventoryCommandForbiddenIdempotencyKey', 'inventoryCommandForbiddenCorrelationId',
    'inventoryCommandValidationIdempotencyKey', 'inventoryCommandValidationCorrelationId'
)
foreach ($key in $emptyVariables) {
    if (-not $environmentByKey.ContainsKey($key) -or
        -not [string]::IsNullOrEmpty($environmentByKey[$key].value)) {
        throw "Inventory command fixture/evidence '$key' must exist and be checked in empty."
    }
}
foreach ($key in @('inventoryCommandStartDate', 'inventoryCommandEndDateExclusive', 'graphqlUrl')) {
    if (-not $environmentByKey.ContainsKey($key) -or
        [string]::IsNullOrWhiteSpace($environmentByKey[$key].value)) {
        throw "Inventory command environment is missing '$key'."
    }
}

$scripts = [System.Collections.Generic.List[object]]::new()
foreach ($event in @($collection.event)) {
    $scripts.Add([pscustomobject]@{ Name = "collection:$($event.listen)"; Source = (@($event.script.exec) -join "`n") })
}
foreach ($event in @($collection.item[0].event)) {
    $scripts.Add([pscustomobject]@{ Name = "folder:$($event.listen)"; Source = (@($event.script.exec) -join "`n") })
}
foreach ($request in $requests) {
    foreach ($event in @($request.event)) {
        $scripts.Add([pscustomobject]@{ Name = "$($request.name):$($event.listen)"; Source = (@($event.script.exec) -join "`n") })
    }
}
$allowedEnvironmentWrites = @(
    'inventoryCommandInitialRevision', 'inventoryCommandBranchId',
    'inventoryCommandMembershipVersion', 'inventoryCommandCreateIdempotencyKey',
    'inventoryCommandCreateCorrelationId', 'inventoryCommandCreateSnapshot',
    'inventoryCommandBlockId', 'inventoryCommandCreatedRevision',
    'inventoryCommandCreatedBlockVersion', 'inventoryCommandStaleIdempotencyKey',
    'inventoryCommandStaleCorrelationId', 'inventoryCommandReleaseIdempotencyKey',
    'inventoryCommandReleaseCorrelationId', 'inventoryCommandReleaseSnapshot',
    'inventoryCommandReleasedRevision', 'inventoryCommandForbiddenIdempotencyKey',
    'inventoryCommandForbiddenCorrelationId', 'inventoryCommandValidationIdempotencyKey',
    'inventoryCommandValidationCorrelationId'
)
foreach ($script in $scripts) {
    foreach ($match in [regex]::Matches($script.Source, "pm\.environment\.set\('([^']+)'")) {
        $key = $match.Groups[1].Value
        if ($key -notin $allowedEnvironmentWrites) {
            throw "Postman script '$($script.Name)' writes unauthorized environment key '$key'."
        }
    }
    if ($script.Source -match 'pm\.sendRequest|pm\.environment\.unset') {
        throw "Postman script '$($script.Name)' may not issue hidden requests or delete environment keys."
    }
}

$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) { throw 'Node.js is required to compile Postman JavaScript assertions.' }
$compiler = @'
let source = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => source += chunk);
process.stdin.on('end', () => {
  try { new Function(source); }
  catch (error) { console.error(error.stack || error.message); process.exitCode = 1; }
});
'@
foreach ($script in $scripts) {
    $script.Source | & $node.Source -e $compiler
    if ($LASTEXITCODE -ne 0) {
        throw "Postman JavaScript failed to compile: $($script.Name)."
    }
}

if ($bookingSdl -notmatch 'createInventoryBlock\s*\(\s*input:\s*CreateInventoryBlockInput!\s*\)\s*:\s*InventoryBlockCommandResult!\s*@authenticated') {
    throw 'Booking subgraph must expose authenticated createInventoryBlock.'
}
if ($bookingSdl -notmatch 'releaseInventoryBlock\s*\(\s*input:\s*ReleaseInventoryBlockInput!\s*\)\s*:\s*InventoryBlockCommandResult!\s*@authenticated') {
    throw 'Booking subgraph must expose authenticated releaseInventoryBlock.'
}
Assert-SdlBlock -Kind 'input' -Name 'CreateInventoryBlockInput' -ExpectedLines @(
    'idempotencyKey: String!', 'propertyId: ID!', 'blockType: OperatorInventoryBlockType!',
    'startDate: String!', 'endDateExclusive: String!', 'expectedInventoryRevision: String!',
    'reason: String!', 'correlationId: String!'
)
Assert-SdlBlock -Kind 'input' -Name 'ReleaseInventoryBlockInput' -ExpectedLines @(
    'idempotencyKey: String!', 'propertyId: ID!', 'inventoryBlockId: ID!',
    'expectedInventoryRevision: String!', 'reason: String!', 'correlationId: String!'
)
Assert-SdlBlock -Kind 'type' -Name 'InventoryBlockCommandResult' -ExpectedLines @(
    'commandId: ID!', 'idempotencyKey: String!', 'requestHash: String!',
    'inventoryBlockId: ID!', 'action: InventoryBlockCommandAction!', 'propertyId: ID!',
    'blockType: InventoryBlockType!', 'status: InventoryBlockStatus!', 'startDate: String!',
    'endDateExclusive: String!', 'blockVersion: String!', 'inventoryRevision: String!',
    'branchId: ID!', 'propertyMembershipVersion: String!', 'occurredAt: String!',
    'releasedAt: String'
)
Assert-SdlBlock -Kind 'enum' -Name 'OperatorInventoryBlockType' -ExpectedLines @(
    'MAINTENANCE', 'CLEANING', 'OWNER_USE', 'MANUAL'
)
Assert-SdlBlock -Kind 'enum' -Name 'InventoryBlockCommandAction' -ExpectedLines @(
    'CREATED', 'RELEASED'
)

$requestWireText = @($requests | ForEach-Object {
    ($_.request | ConvertTo-Json -Depth 20 -Compress)
}) -join "`n"
foreach ($forbidden in @('client_secret', 'refresh_token', 'postgresql://', 'jdbc:', 'DELETE FROM', 'TRUNCATE ')) {
    if ($requestWireText.Contains($forbidden)) {
        throw "Inventory command requests contain forbidden secret/database marker '$forbidden'."
    }
}

Write-Output "Postman inventory command contract passed: $($requests.Count) ordered safe-default scenarios and $($scripts.Count) compiled scripts."
