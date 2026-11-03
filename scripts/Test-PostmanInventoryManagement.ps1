[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$collectionPath = Join-Path $repositoryRoot 'postman\ViStay-Inventory-Management.postman_collection.json'
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
    $match = [regex]::Match($bookingSdl, "(?ms)\b$Kind\s+$Name\s*\{(?<body>.*?)\}")
    if (-not $match.Success) { throw "Booking subgraph is missing $Kind '$Name'." }
    $actual = @($match.Groups['body'].Value -split "`r?`n" |
        ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if (($actual -join "`n") -ne ($ExpectedLines -join "`n")) {
        throw "Booking subgraph $Kind '$Name' does not match inventory management v1."
    }
}

if ($collection.info.name -ne 'ViStay Inventory Management') {
    throw 'Inventory management collection must retain its stable name.'
}
if (@($collection.item).Count -ne 1 -or
    $collection.item[0].name -ne '01 Ordered management query flow') {
    throw 'Inventory management collection must contain one ordered folder.'
}

$requests = @(Get-PostmanRequests -Items @($collection.item))
$expectedOrder = @(
    'List first inventory management page',
    'List next inventory management page',
    'Reject invalid inventory management range',
    'Foreign branch cannot list inventory blocks'
)
if (($requests.name -join "`n") -ne ($expectedOrder -join "`n")) {
    throw 'Inventory management request order changed.'
}

$folderGuard = Get-EventSource -Events @($collection.item[0].event) -Listener 'prerequest'
foreach ($marker in @(
    "pm.environment.get('runInventoryManagementFlow')",
    'pm.execution.skipRequest()',
    'inventoryManagementAccessToken',
    'inventoryManagementForeignAccessToken',
    'inventoryManagementPropertyId'
)) {
    if (-not $folderGuard.Contains($marker)) {
        throw "Inventory management safe-default guard is missing '$marker'."
    }
}

$requestByName = @{}
foreach ($request in $requests) {
    if ($requestByName.ContainsKey($request.name)) { throw "Duplicate request '$($request.name)'." }
    $requestByName[$request.name] = $request
    if ($request.request.method -ne 'POST' -or $request.request.url -ne '{{graphqlUrl}}' -or
        $request.request.body.mode -ne 'raw') {
        throw "Inventory management request '$($request.name)' has a noncanonical transport."
    }
    $headers = @{}
    foreach ($header in @($request.request.header)) { $headers[$header.key] = $header.value }
    if ($headers['Content-Type'] -ne 'application/json' -or
        $headers['X-CSRF-Token'] -ne 'inventory-management') {
        throw "Inventory management request '$($request.name)' is missing required headers."
    }
    $expectedToken = if ($request.name -eq 'Foreign branch cannot list inventory blocks') {
        'Bearer {{inventoryManagementForeignAccessToken}}'
    } else {
        'Bearer {{inventoryManagementAccessToken}}'
    }
    if ($headers['Authorization'] -ne $expectedToken) {
        throw "Inventory management request '$($request.name)' uses the wrong token."
    }
    $body = $request.request.body.raw | ConvertFrom-Json
    if (($body.query -replace '\s+', ' ') -notmatch 'inventoryBlocks\s*\(\s*input:\s*\$input\s*\)') {
        throw "Inventory management request '$($request.name)' does not call inventoryBlocks."
    }
    if ($body.variables.input.propertyId -ne '{{inventoryManagementPropertyId}}') {
        throw "Inventory management request '$($request.name)' uses a noncanonical property fixture."
    }
}

$firstBody = $requestByName[$expectedOrder[0]].request.body.raw | ConvertFrom-Json
$firstFields = @($firstBody.variables.input.PSObject.Properties.Name | Sort-Object)
if (($firstFields -join ',') -ne 'first,fromDate,propertyId,statuses,toDateExclusive,types' -or
    $firstBody.variables.input.first -ne 2) {
    throw 'First page must exercise all filters with a deterministic two-row page.'
}
$nextBody = $requestByName[$expectedOrder[1]].request.body.raw | ConvertFrom-Json
if ($nextBody.variables.input.after -ne '{{inventoryManagementEndCursor}}' -or
    $nextBody.variables.input.first -ne 2) {
    throw 'Next page must reuse the opaque cursor with the same page size.'
}
$invalidBody = $requestByName[$expectedOrder[2]].request.body.raw | ConvertFrom-Json
if ($invalidBody.variables.input.fromDate -le $invalidBody.variables.input.toDateExclusive) {
    throw 'Invalid range scenario must reverse the half-open dates.'
}

$firstTest = Get-EventSource -Events @($requestByName[$expectedOrder[0]].event) -Listener 'test'
foreach ($marker in @(
    'inventoryManagementExpectedBranchId', 'inventoryManagementExpectedMembershipVersion',
    'inventoryManagementRevision', 'inventoryManagementEndCursor', 'BigInt',
    'inventoryManagementPropertyId'
)) {
    if (-not $firstTest.Contains($marker)) { throw "First-page assertions are missing '$marker'." }
}
$nextTest = Get-EventSource -Events @($requestByName[$expectedOrder[1]].event) -Listener 'test'
foreach ($marker in @('inventoryManagementRevision', 'inventoryBlocks')) {
    if (-not $nextTest.Contains($marker)) { throw "Next-page assertions are missing '$marker'." }
}
$invalidTest = Get-EventSource -Events @($requestByName[$expectedOrder[2]].event) -Listener 'test'
if (-not $invalidTest.Contains('INVALID_INVENTORY_MANAGEMENT_INPUT') -or
    -not $invalidTest.Contains('to.be.null')) {
    throw 'Invalid range must assert the stable code and no data.'
}
$foreignTest = Get-EventSource -Events @($requestByName[$expectedOrder[3]].event) -Listener 'test'
if (-not $foreignTest.Contains('INVENTORY_READ_FORBIDDEN') -or
    -not $foreignTest.Contains('to.be.null')) {
    throw 'Foreign branch must assert the stable code and no data.'
}

$rootTest = Get-EventSource -Events @($collection.event) -Listener 'test'
foreach ($privateField in @(
    'bookingId', 'holdId', 'customerId', 'guestId', 'channelExternalBlockId',
    'actorAccountId', 'actorProfileId', 'authorizationEvidence',
    'commercialAmount', 'accessToken'
)) {
    if (-not $rootTest.Contains("'$privateField'")) {
        throw "Privacy assertion is missing '$privateField'."
    }
}

$environmentByKey = @{}
foreach ($value in $environment.values) { $environmentByKey[$value.key] = $value }
if ($environmentByKey['runInventoryManagementFlow'].value -ne 'false') {
    throw 'runInventoryManagementFlow must be checked in false.'
}
foreach ($key in @('inventoryManagementAccessToken', 'inventoryManagementForeignAccessToken')) {
    if ($environmentByKey[$key].type -ne 'secret' -or
        -not [string]::IsNullOrEmpty($environmentByKey[$key].value)) {
        throw "Inventory management token '$key' must be an empty secret."
    }
}
foreach ($key in @(
    'inventoryManagementPropertyId', 'inventoryManagementEndCursor',
    'inventoryManagementRevision', 'inventoryManagementExpectedBranchId',
    'inventoryManagementExpectedMembershipVersion'
)) {
    if (-not [string]::IsNullOrEmpty($environmentByKey[$key].value)) {
        throw "Inventory management evidence '$key' must be checked in empty."
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
$allowedWrites = @('inventoryManagementRevision', 'inventoryManagementEndCursor')
foreach ($script in $scripts) {
    foreach ($match in [regex]::Matches($script.Source, "pm\.environment\.set\('([^']+)'")) {
        if ($match.Groups[1].Value -notin $allowedWrites) {
            throw "Postman script '$($script.Name)' writes unauthorized environment state."
        }
    }
    if ($script.Source -match 'pm\.sendRequest|pm\.environment\.unset') {
        throw "Postman script '$($script.Name)' contains a hidden request or deletion."
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
    $script.Source | & node -e $compiler
    if ($LASTEXITCODE -ne 0) { throw "Postman JavaScript failed: $($script.Name)." }
}

if ($bookingSdl -notmatch 'inventoryBlocks\s*\(\s*input:\s*InventoryBlockManagementInput!\s*\)\s*:\s*InventoryBlockManagementPage!\s*@authenticated') {
    throw 'Booking subgraph must expose authenticated inventoryBlocks.'
}
Assert-SdlBlock -Kind 'input' -Name 'InventoryBlockManagementInput' -ExpectedLines @(
    'propertyId: ID!', 'fromDate: String', 'toDateExclusive: String',
    'types: [InventoryBlockType!] = []', 'statuses: [InventoryBlockStatus!] = []',
    'first: Int = 50', 'after: String'
)
Assert-SdlBlock -Kind 'type' -Name 'InventoryBlockManagementPage' -ExpectedLines @(
    'nodes: [InventoryBlockManagementNode!]!', 'pageInfo: InventoryBlockPageInfo!',
    'inventoryRevision: String!', 'branchId: ID!', 'propertyMembershipVersion: String!'
)
Assert-SdlBlock -Kind 'type' -Name 'InventoryBlockPageInfo' -ExpectedLines @(
    'hasNextPage: Boolean!', 'endCursor: String'
)

Write-Output "Postman inventory management contract passed: $($requests.Count) safe-default scenarios and $($scripts.Count) compiled scripts."
