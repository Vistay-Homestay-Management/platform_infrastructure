[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$collectionPath = Join-Path $repositoryRoot 'postman\ViStay-Authorization.postman_collection.json'
$environmentPath = Join-Path $repositoryRoot 'postman\ViStay-Local.postman_environment.json'
$matrixPath = Join-Path $repositoryRoot 'postman\authorization-security-matrix.json'
$fixturePath = Join-Path $repositoryRoot 'postman\fixtures\authorization-e2e.sql'

$collection = Get-Content -Raw -LiteralPath $collectionPath | ConvertFrom-Json
$environment = Get-Content -Raw -LiteralPath $environmentPath | ConvertFrom-Json
$matrix = Get-Content -Raw -LiteralPath $matrixPath | ConvertFrom-Json
$fixture = Get-Content -Raw -LiteralPath $fixturePath

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
$requestNames = @($requests | ForEach-Object name)
$requiredCases = @(
    'booking.direct-idor',
    'booking.list-filtering',
    'booking.field-leakage',
    'scope.union-own-assigned',
    'scope.all-dominance',
    'assignment.expired-record-relation',
    'authorization.immediate-reduction',
    'authorization.dependency-unavailable',
    'payment-intent.record-idor',
    'scope.partition',
    'authorization.expired-role-grant',
    'export.bulk-access'
)

foreach ($required in $requiredCases) {
    if ($required -notin @($matrix.cases.id)) {
        throw "Authorization matrix is missing required case '$required'."
    }
}

foreach ($case in $matrix.cases) {
    switch ($case.status) {
        'POSTMAN_EXECUTABLE' {
            if ([string]::IsNullOrWhiteSpace($case.postmanRequest) -or
                $case.postmanRequest -notin $requestNames) {
                throw "Executable matrix case '$($case.id)' has no matching Postman request."
            }
            $request = $requests | Where-Object name -eq $case.postmanRequest | Select-Object -First 1
            $testSource = @($request.event | Where-Object listen -eq 'test' |
                ForEach-Object { $_.script.exec }) -join "`n"
            if (-not $testSource.Contains('pm.test(')) {
                throw "Executable request '$($case.postmanRequest)' has no assertion."
            }
        }
        'SERVICE_TEST_ONLY' {
            if ([string]::IsNullOrWhiteSpace($case.evidence) -or
                [string]::IsNullOrWhiteSpace($case.reason)) {
                throw "Service-only case '$($case.id)' must name evidence and its Postman gap."
            }
        }
        'BLOCKED_API' {
            if ([string]::IsNullOrWhiteSpace($case.jiraDependency) -or
                [string]::IsNullOrWhiteSpace($case.reason)) {
                throw "Blocked case '$($case.id)' must name a Jira dependency and reason."
            }
        }
        default { throw "Unknown authorization matrix status '$($case.status)'." }
    }
}

$environmentKeys = @($environment.values.key)
foreach ($requiredKey in @(
    'runAuthorizationE2E',
    'runAuthorizationUnavailable',
    'makerAccessToken',
    'checkerAccessToken',
    'targetAccessToken',
    'expiredAssignmentBookingId'
)) {
    if ($requiredKey -notin $environmentKeys) {
        throw "Postman environment is missing '$requiredKey'."
    }
}

foreach ($secret in @($environment.values | Where-Object type -eq 'secret')) {
    if (-not [string]::IsNullOrEmpty($secret.value)) {
        throw "Checked-in Postman secret '$($secret.key)' must be empty."
    }
}

if (-not $fixture.Contains('AUTHZ-EXPIRED-ASSIGNMENT') -or
    -not $fixture.Contains("now() - interval '1 day'")) {
    throw 'Authorization fixture must include a deterministically expired assignment.'
}

Write-Output "Postman authorization matrix passed: $($matrix.cases.Count) cases, $($requests.Count) executable requests."
