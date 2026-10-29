[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$collectionPath = Join-Path $repositoryRoot 'postman\ViStay-Inventory.postman_collection.json'
$environmentPath = Join-Path $repositoryRoot 'postman\ViStay-Local.postman_environment.json'
$bookingSdlPath = Join-Path $repositoryRoot 'router\backoffice\subgraphs\booking.graphql'

$collection = Get-Content -Raw -LiteralPath $collectionPath | ConvertFrom-Json
$environment = Get-Content -Raw -LiteralPath $environmentPath | ConvertFrom-Json
$bookingSdl = Get-Content -Raw -LiteralPath $bookingSdlPath

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

function Get-EventSource {
    param(
        [object[]] $Events,
        [string] $Listener
    )

    @($Events | Where-Object listen -eq $Listener | ForEach-Object { $_.script.exec }) -join "`n"
}

function Assert-SdlBlock {
    param(
        [string] $Kind,
        [string] $Name,
        [string[]] $ExpectedLines
    )

    $pattern = "(?ms)\b$Kind\s+$Name\s*\{(?<body>.*?)\}"
    $match = [regex]::Match($bookingSdl, $pattern)
    if (-not $match.Success) {
        throw "Booking subgraph is missing $Kind '$Name'."
    }

    $actual = @($match.Groups['body'].Value -split "`r?`n" |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ })
    if (($actual -join "`n") -ne ($ExpectedLines -join "`n")) {
        throw "Booking subgraph $Kind '$Name' does not match the inventory-v1 wire contract.`nActual:`n$($actual -join "`n")"
    }
}

$requests = @(Get-PostmanRequests -Items @($collection.item))
$requestByName = @{}
foreach ($request in $requests) {
    if ($requestByName.ContainsKey($request.name)) {
        throw "Duplicate inventory Postman request name '$($request.name)'."
    }
    $requestByName[$request.name] = $request
}

$scenarioGuards = [ordered]@{
    'Available exact unit' = 'runInventorySeededScenarios'
    'BOOKING tentative block is unavailable' = 'runInventorySeededScenarios'
    'MAINTENANCE active block is unavailable' = 'runInventorySeededScenarios'
    'CHANNEL active block is unavailable and sanitized' = 'runInventorySeededScenarios'
    'Released and cancelled history is nonblocking' = 'runInventorySeededScenarios'
    'Adjacent blocks do not overlap' = 'runInventorySeededScenarios'
    'Equal dates are invalid' = 'runInventoryValidationScenarios'
    'Reversed dates are invalid' = 'runInventoryValidationScenarios'
    'Timestamp input is invalid' = 'runInventoryValidationScenarios'
    'Malformed property ID is invalid' = 'runInventoryValidationScenarios'
    'Missing property fails closed' = 'runInventoryValidationScenarios'
    'Unmapped property fails closed' = 'runInventoryValidationScenarios'
    'Missing identity is unauthenticated' = 'runInventoryAuthorizationScenarios'
    'Foreign branch property is forbidden' = 'runInventoryAuthorizationScenarios'
    'Revoked assignment is forbidden' = 'runInventoryAuthorizationScenarios'
    'OWN SELF or ASSIGNED without branch partition is forbidden' = 'runInventoryAuthorizationScenarios'
    'Property partition dependency unavailable' = 'runInventoryDependencyScenarios'
    'Authorization dependency unavailable' = 'runInventoryDependencyScenarios'
}

if ($collection.info.name -ne 'ViStay Inventory Observation') {
    throw 'Inventory collection must retain its dedicated stable name.'
}
if ($requests.Count -ne $scenarioGuards.Count) {
    throw "Inventory collection has $($requests.Count) requests; expected exactly $($scenarioGuards.Count)."
}

$canonicalQuery = 'query InventoryAvailability($input: PropertyAvailabilityInput!) { propertyAvailability(input: $input) { propertyId checkInDate checkOutDate available inventoryRevision branchId propertyMembershipVersion observedAt overlaps { type status startDate endDateExclusive channelProvider } } }'
$canonicalQueryNormalized = $canonicalQuery -replace '\s+', ' '
$canonicalInputFields = @('checkInDate', 'checkOutDate', 'propertyId')

foreach ($entry in $scenarioGuards.GetEnumerator()) {
    if (-not $requestByName.ContainsKey($entry.Key)) {
        throw "Inventory collection is missing scenario '$($entry.Key)'."
    }

    $request = $requestByName[$entry.Key]
    if ($request.request.method -ne 'POST' -or $request.request.url -ne '{{graphqlUrl}}') {
        throw "Inventory scenario '$($entry.Key)' must POST only to {{graphqlUrl}}."
    }
    if ($request.request.body.mode -ne 'raw') {
        throw "Inventory scenario '$($entry.Key)' must use an inspectable raw GraphQL JSON body."
    }

    $body = $request.request.body.raw | ConvertFrom-Json
    $queryNormalized = $body.query -replace '\s+', ' '
    if ($queryNormalized -ne $canonicalQueryNormalized) {
        throw "Inventory scenario '$($entry.Key)' does not use the canonical inventory-v1 selection set."
    }
    $inputFields = @($body.variables.input.PSObject.Properties.Name | Sort-Object)
    if (($inputFields -join ',') -ne ($canonicalInputFields -join ',')) {
        throw "Inventory scenario '$($entry.Key)' has noncanonical input fields: $($inputFields -join ',')."
    }

    $preRequestSource = Get-EventSource -Events @($request.event) -Listener 'prerequest'
    if (-not $preRequestSource.Contains("pm.environment.get('$($entry.Value)')") -or
        -not $preRequestSource.Contains('pm.execution.skipRequest()')) {
        throw "Inventory scenario '$($entry.Key)' is not protected by safe-default flag '$($entry.Value)'."
    }

    $testSource = Get-EventSource -Events @($request.event) -Listener 'test'
    if (-not $testSource.Contains('pm.test(')) {
        throw "Inventory scenario '$($entry.Key)' has no executable assertion."
    }
    if ($preRequestSource.Contains('pm.environment.set(') -or $testSource.Contains('pm.environment.set(')) {
        throw "Inventory scenario '$($entry.Key)' must not mutate the checked-in environment."
    }
}

$expectedErrorCodes = [ordered]@{
    'Equal dates are invalid' = 'INVALID_INVENTORY_RANGE'
    'Reversed dates are invalid' = 'INVALID_INVENTORY_RANGE'
    'Timestamp input is invalid' = 'INVALID_INVENTORY_RANGE'
    'Malformed property ID is invalid' = 'INVALID_INVENTORY_RANGE'
    'Missing property fails closed' = 'PROPERTY_NOT_FOUND'
    'Unmapped property fails closed' = 'PROPERTY_PARTITION_UNMAPPED'
    'Missing identity is unauthenticated' = 'UNAUTHENTICATED'
    'Foreign branch property is forbidden' = 'INVENTORY_READ_FORBIDDEN'
    'Revoked assignment is forbidden' = 'INVENTORY_READ_FORBIDDEN'
    'OWN SELF or ASSIGNED without branch partition is forbidden' = 'INVENTORY_READ_FORBIDDEN'
    'Property partition dependency unavailable' = 'PROPERTY_PARTITION_UNAVAILABLE'
    'Authorization dependency unavailable' = 'AUTHORIZATION_UNAVAILABLE'
}

foreach ($entry in $expectedErrorCodes.GetEnumerator()) {
    $testSource = Get-EventSource -Events @($requestByName[$entry.Key].event) -Listener 'test'
    if (-not $testSource.Contains("'$($entry.Value)'")) {
        throw "Inventory scenario '$($entry.Key)' must assert exact stable code '$($entry.Value)'."
    }
    if (-not $testSource.Contains('payload.data && payload.data.propertyAvailability') -or
        -not $testSource.Contains("to.not.be.an('object')")) {
        throw "Inventory failure scenario '$($entry.Key)' must reject any observation object."
    }
}

$unauthenticatedSource = Get-EventSource -Events @($requestByName['Missing identity is unauthenticated'].event) -Listener 'test'
foreach ($expected in @("to.eql(['UNAUTHENTICATED'])", "to.eql('Authentication is required.')", 'to.have.status(401)')) {
    if (-not $unauthenticatedSource.Contains($expected)) {
        throw "Missing-identity scenario must assert sanitized edge behavior '$expected'."
    }
}

$positiveEvidence = [ordered]@{
    'Available exact unit' = @('available', 'inventoryExpectedRevision', 'inventoryExpectedMembershipVersion', 'inventoryExpectedBranchId', 'observedAt')
    'BOOKING tentative block is unavailable' = @('BOOKING', 'TENTATIVE', 'false')
    'MAINTENANCE active block is unavailable' = @('MAINTENANCE', 'ACTIVE', 'false')
    'CHANNEL active block is unavailable and sanitized' = @('CHANNEL', 'ACTIVE', 'channelProvider', 'false')
    'Released and cancelled history is nonblocking' = @('RELEASED', 'CANCELLED', 'true', 'sort')
    'Adjacent blocks do not overlap' = @('available', 'true', 'overlaps')
}
foreach ($entry in $positiveEvidence.GetEnumerator()) {
    $testSource = Get-EventSource -Events @($requestByName[$entry.Key].event) -Listener 'test'
    foreach ($evidence in $entry.Value) {
        if (-not $testSource.Contains($evidence)) {
            throw "Inventory scenario '$($entry.Key)' is missing assertion evidence '$evidence'."
        }
    }
}

$environmentByKey = @{}
foreach ($value in $environment.values) {
    if ($environmentByKey.ContainsKey($value.key)) {
        throw "Postman environment contains duplicate key '$($value.key)'."
    }
    $environmentByKey[$value.key] = $value
}

foreach ($flag in @($scenarioGuards.Values | Select-Object -Unique)) {
    if (-not $environmentByKey.ContainsKey($flag) -or $environmentByKey[$flag].value -ne 'false') {
        throw "Safe-default inventory flag '$flag' must exist and be checked in as false."
    }
}

$requiredVariables = @(
    'graphqlUrl',
    'inventoryAccessToken',
    'inventoryForeignBranchAccessToken',
    'inventoryRevokedAccessToken',
    'inventoryScopeDeniedAccessToken',
    'inventoryAvailablePropertyId',
    'inventoryBookingBlockedPropertyId',
    'inventoryMaintenanceBlockedPropertyId',
    'inventoryChannelBlockedPropertyId',
    'inventoryHistoryOnlyPropertyId',
    'inventoryAdjacentPropertyId',
    'inventoryForeignPropertyId',
    'inventoryUnmappedPropertyId',
    'inventoryMissingPropertyId',
    'inventoryExpectedBranchId',
    'inventoryExpectedMembershipVersion',
    'inventoryExpectedRevision',
    'inventoryCheckInDate',
    'inventoryCheckOutDate'
)
foreach ($key in $requiredVariables) {
    if (-not $environmentByKey.ContainsKey($key)) {
        throw "Postman environment is missing inventory variable '$key'."
    }
}

foreach ($tokenKey in @('inventoryAccessToken', 'inventoryForeignBranchAccessToken', 'inventoryRevokedAccessToken', 'inventoryScopeDeniedAccessToken')) {
    $token = $environmentByKey[$tokenKey]
    if ($token.type -ne 'secret' -or -not [string]::IsNullOrEmpty($token.value)) {
        throw "Inventory token '$tokenKey' must be typed secret and checked in empty."
    }
}

foreach ($fixtureKey in @(
    'inventoryAvailablePropertyId',
    'inventoryBookingBlockedPropertyId',
    'inventoryMaintenanceBlockedPropertyId',
    'inventoryChannelBlockedPropertyId',
    'inventoryHistoryOnlyPropertyId',
    'inventoryAdjacentPropertyId',
    'inventoryForeignPropertyId',
    'inventoryUnmappedPropertyId',
    'inventoryExpectedBranchId',
    'inventoryExpectedMembershipVersion',
    'inventoryExpectedRevision'
)) {
    if (-not [string]::IsNullOrEmpty($environmentByKey[$fixtureKey].value)) {
        throw "Optional fixture variable '$fixtureKey' must be checked in empty."
    }
}

$rootTestSource = Get-EventSource -Events @($collection.event) -Listener 'test'
foreach ($privateField in @(
    'blockId', 'inventoryBlockId', 'bookingId', 'holdId',
    'channelExternalBlockId', 'channelExternalReference',
    'externalBlockReference', 'externalReference', 'reason', 'notes',
    'actorIdentity', 'guestId', 'customerId', 'hostId', 'totalAmount',
    'credential', 'accessToken', 'authorizationEvidence'
)) {
    if (-not $rootTestSource.Contains("'$privateField'")) {
        throw "Inventory collection privacy assertion is missing excluded field '$privateField'."
    }
}
foreach ($sensitivePattern in @('jdbc:', 'postgres', 'https?', 'bearer', 'select', 'insert', 'update', 'delete', 'password', 'client_secret')) {
    if (-not $rootTestSource.Contains($sensitivePattern)) {
        throw "Inventory collection sanitized-error assertion is missing pattern '$sensitivePattern'."
    }
}

if ($bookingSdl -notmatch 'propertyAvailability\s*\(\s*input:\s*PropertyAvailabilityInput!\s*\)\s*:\s*PropertyAvailabilityObservation!\s*@authenticated') {
    throw 'Booking subgraph Query must expose the authenticated canonical propertyAvailability field.'
}
Assert-SdlBlock -Kind 'input' -Name 'PropertyAvailabilityInput' -ExpectedLines @(
    'propertyId: ID!',
    'checkInDate: String!',
    'checkOutDate: String!'
)
Assert-SdlBlock -Kind 'type' -Name 'PropertyAvailabilityObservation' -ExpectedLines @(
    'propertyId: ID!',
    'checkInDate: String!',
    'checkOutDate: String!',
    'available: Boolean!',
    'inventoryRevision: String!',
    'branchId: ID!',
    'propertyMembershipVersion: String!',
    'observedAt: String!',
    'overlaps: [InventoryAvailabilityOverlap!]!'
)
Assert-SdlBlock -Kind 'type' -Name 'InventoryAvailabilityOverlap' -ExpectedLines @(
    'type: InventoryBlockType!',
    'status: InventoryBlockStatus!',
    'startDate: String!',
    'endDateExclusive: String!',
    'channelProvider: String'
)
Assert-SdlBlock -Kind 'enum' -Name 'InventoryBlockType' -ExpectedLines @(
    'BOOKING', 'MAINTENANCE', 'CLEANING', 'OWNER_USE', 'MANUAL', 'CHANNEL'
)
Assert-SdlBlock -Kind 'enum' -Name 'InventoryBlockStatus' -ExpectedLines @(
    'TENTATIVE', 'ACTIVE', 'RELEASED', 'CANCELLED'
)

$scripts = [System.Collections.Generic.List[object]]::new()
foreach ($event in @($collection.event)) {
    $scripts.Add([pscustomobject]@{ Name = "collection:$($event.listen)"; Source = (@($event.script.exec) -join "`n") })
}
foreach ($request in $requests) {
    foreach ($event in @($request.event)) {
        $scripts.Add([pscustomobject]@{ Name = "$($request.name):$($event.listen)"; Source = (@($event.script.exec) -join "`n") })
    }
}

$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) {
    throw 'Node.js is required to compile Postman JavaScript assertions.'
}
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

Write-Output "Postman inventory contract passed: $($requests.Count) safe-default read-only scenarios and $($scripts.Count) compiled scripts."
