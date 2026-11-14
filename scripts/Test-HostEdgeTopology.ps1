param(
    [string]$EnvFile = '.env.example'
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$errorCode = 'HOST_EDGE_CONTRACT_INVALID'
$correlationId = "SCRUM-816-HOST-EDGE-$([guid]::NewGuid().ToString('N'))"

function Assert-Contract {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw "$errorCode [$correlationId] $Message"
    }
}

function Read-EnvFile {
    param([string]$Path)

    $values = @{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match '^\s*#' -or $line -notmatch '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
            continue
        }
        $values[$Matches[1]] = $Matches[2]
    }
    return $values
}

$envPath = Join-Path $repositoryRoot $EnvFile
$envValues = Read-EnvFile -Path $envPath
$composeArguments = @(
    'compose',
    '-f', (Join-Path $repositoryRoot 'compose.yaml'),
    '-f', (Join-Path $repositoryRoot 'compose.full.yaml'),
    '--env-file', $envPath,
    '--profile', 'full',
    'config',
    '--format', 'json'
)

$configurationJson = & docker @composeArguments
if ($LASTEXITCODE -ne 0) {
    throw "$errorCode [$correlationId] Full Compose configuration could not be rendered."
}
$configuration = $configurationJson | ConvertFrom-Json
$serviceNames = @($configuration.services.PSObject.Properties.Name)

foreach ($requiredService in @(
    'nginx', 'keycloak', 'router-backoffice', 'router-host',
    'authentication', 'user', 'frontend-host'
)) {
    Assert-Contract ($requiredService -in $serviceNames) "Missing required Host edge service '$requiredService'."
}

$immutableImagePattern = '^[^\s:@]+(?:/[^\s:@]+)*:[^\s@]+@sha256:[0-9a-f]{64}$'
foreach ($edgeService in @('nginx', 'keycloak', 'router-backoffice', 'router-host')) {
    $image = $configuration.services.$edgeService.image
    Assert-Contract ($image -match $immutableImagePattern) "$edgeService must use an immutable image digest."
    Assert-Contract ($image -notmatch '(^|:)latest(@|$)') "$edgeService must not use a latest image tag."
}

$publicServices = @()
foreach ($serviceProperty in $configuration.services.PSObject.Properties) {
    foreach ($port in @($serviceProperty.Value.ports)) {
        if ($null -eq $port) {
            continue
        }
        if ($port.host_ip -in @('0.0.0.0', '::', '')) {
            $publicServices += $serviceProperty.Name
        }
        elseif ($port.host_ip -notin @('127.0.0.1', '::1')) {
            throw "$errorCode [$correlationId] $($serviceProperty.Name) publishes on '$($port.host_ip)'."
        }
    }
}
$publicServices = @($publicServices | Sort-Object -Unique)
Assert-Contract ($publicServices.Count -eq 1 -and $publicServices[0] -eq 'nginx') 'Nginx must remain the sole public ingress.'

foreach ($internalService in @('keycloak', 'router-backoffice', 'router-host')) {
    $publishedPorts = @($configuration.services.$internalService.ports | Where-Object { $null -ne $_ })
    Assert-Contract ($publishedPorts.Count -eq 0) "$internalService must not publish host ports."
}

$router = $configuration.services.'router-host'
foreach ($expected in @(
    @{ Name = 'HOST_JWKS_URL'; Value = 'http://keycloak:8080/realms/vistay-host/protocol/openid-connect/certs' },
    @{ Name = 'HOST_JWT_ISSUERS'; Value = 'http://identity.localhost/realms/vistay-host' },
    @{ Name = 'HOST_JWT_AUDIENCES'; Value = 'vistay-host-api' },
    @{ Name = 'HOST_CORS_ALLOWED_ORIGINS'; Value = 'http://host.localhost' }
)) {
    Assert-Contract ($router.environment.($expected.Name) -eq $expected.Value) `
        "Host router $($expected.Name) must equal '$($expected.Value)'."
}
$routerConfigMount = @($router.volumes | Where-Object target -eq '/app/config/router.config.yaml')
$routerSchemaMount = @($router.volumes | Where-Object target -eq '/app/schema/supergraph.graphql')
Assert-Contract ($routerConfigMount.Count -eq 1 -and $routerConfigMount[0].read_only -eq $true) `
    'Host router config must be mounted read-only.'
Assert-Contract ((Split-Path -Leaf $routerConfigMount[0].source) -eq 'router.config.yaml') `
    'Host router must mount its own router configuration.'
Assert-Contract ($routerSchemaMount.Count -eq 1 -and $routerSchemaMount[0].read_only -eq $true) `
    'Host router supergraph must be mounted read-only.'
Assert-Contract ((Split-Path -Leaf $routerSchemaMount[0].source) -eq 'supergraph.graphql') `
    'Host router must mount its own Host supergraph.'

$nginxTargets = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'nginx/templates/default.conf.template')
foreach ($expectedTarget in @(
    'server_name ${HOST_GRAPHQL_HOST};',
    'server_name ${HOST_WEB_HOST};',
    'router-host:4000',
    'frontend-host:8080',
    '^/realms/vistay-host/',
    '^/(realms/vistay-(?:backoffice|customer)/|resources/)',
    'set $host_realm_enabled ${VISTAY_HOST_REALM_ENABLED};',
    'X-Request-ID $request_id',
    'X-Content-Type-Options nosniff',
    'Referrer-Policy no-referrer'
)) {
    Assert-Contract ($nginxTargets.Contains($expectedTarget)) "Nginx is missing Host edge control '$expectedTarget'."
}
$hostGraphqlMarker = 'server_name ${HOST_GRAPHQL_HOST};'
$hostGraphqlStart = $nginxTargets.IndexOf($hostGraphqlMarker)
Assert-Contract ($hostGraphqlStart -ge 0) 'Host GraphQL server block is missing.'
$hostGraphqlEnd = $nginxTargets.IndexOf("`nserver {", $hostGraphqlStart + $hostGraphqlMarker.Length)
if ($hostGraphqlEnd -lt 0) {
    $hostGraphqlEnd = $nginxTargets.Length
}
$hostGraphqlBlock = $nginxTargets.Substring($hostGraphqlStart, $hostGraphqlEnd - $hostGraphqlStart)
Assert-Contract ($nginxTargets.Contains('location / { return 404; }')) `
    'Host GraphQL must deny unlisted paths instead of exposing internal services.'
Assert-Contract ($hostGraphqlBlock -notmatch 'proxy_pass .*actuator') `
    'Host GraphQL must not expose actuator or internal management routes.'

$hostRouterConfig = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'router/host/router.config.yaml')
foreach ($requiredSetting in @(
    'enabled: true',
    'require_authentication: true',
    'from_env: HOST_JWKS_URL',
    'from_env: HOST_JWT_AUDIENCES',
    'from_env: HOST_JWT_ISSUERS',
    'allowed_algorithms:',
    '- RS256',
    'introspection: false',
    'from_env: HOST_CORS_ALLOWED_ORIGINS'
)) {
    Assert-Contract ($hostRouterConfig.Contains($requiredSetting)) `
        "Host router is missing security setting '$requiredSetting'."
}
Assert-Contract ($hostRouterConfig -notmatch 'BACKOFFICE|CUSTOMER') `
    'Host router configuration must not fall back to another realm or audience.'

$hostSupergraph = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'router/host/supergraph.graphql')
foreach ($approvedField in @('myProfile', 'updateMyProfile', '@authenticated')) {
    Assert-Contract ($hostSupergraph.Contains($approvedField)) "Host supergraph is missing approved field metadata '$approvedField'."
}
foreach ($forbiddenField in @('viewer', 'authorizationCatalog', 'authorizationSubject', 'BackofficeViewer')) {
    Assert-Contract ($hostSupergraph -notmatch "(?m)^\s*$forbiddenField(?:\s|\()") `
        "Host supergraph must not expose Backoffice field '$forbiddenField'."
}

foreach ($serviceName in @('authentication', 'user')) {
    $service = $configuration.services.$serviceName
    Assert-Contract ($service.environment.KEYCLOAK_HOST_ISSUER -eq 'http://identity.localhost/realms/vistay-host') `
        "$serviceName must receive the trusted Host issuer explicitly."
    Assert-Contract ($service.environment.KEYCLOAK_HOST_JWKS_URI -eq `
        'http://keycloak:8080/realms/vistay-host/protocol/openid-connect/certs') `
        "$serviceName must receive the internal Host JWKS endpoint explicitly."
    Assert-Contract ($service.environment.KEYCLOAK_HOST_AUDIENCE -eq 'vistay-host-api') `
        "$serviceName must receive the Host API audience explicitly."
}

$realm = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'keycloak/realms/vistay-host-realm.json') |
    ConvertFrom-Json
Assert-Contract ($envValues.VISTAY_HOST_REALM_ENABLED -eq 'false' -and $realm.enabled -eq $true) `
    'The Host realm import must support registration while the baseline edge exposure remains disabled.'
Assert-Contract ($envValues.HOST_GRAPHQL_HOST -eq 'host-api.localhost' -and
    $envValues.HOST_WEB_HOST -eq 'host.localhost') `
    'Host Web and GraphQL hosts must remain exact and deterministic in the local environment.'

$report = [ordered]@{
    status = 'VALIDATED'
    correlationId = $correlationId
    errorCode = 'HOST_EDGE_CONTRACT_OK'
    failureCode = $errorCode
    contract = 'HOST_EDGE_FEDERATION_JWT_V1'
    hostWeb = $envValues.HOST_WEB_HOST
    hostGraphql = $envValues.HOST_GRAPHQL_HOST
    issuer = $envValues.HOST_JWT_ISSUERS
    audience = $envValues.HOST_JWT_AUDIENCES
    approvedFields = @('myProfile', 'updateMyProfile')
    baselineRealmEnabled = $realm.enabled
    rollback = 'Disable Host ingress and registration; retain users and audit history; Backoffice routes remain unchanged.'
    acceptanceCriteria = [ordered]@{
        AC01 = 'Host Web and Host GraphQL have separate allow-listed routes with trusted issuer/audience configuration and correlation propagation.'
        AC02 = 'Host router accepts only vistay-host JWT settings and a profile-only supergraph; Backoffice/customer fallback and internal routes are absent.'
        AC03 = 'The disabled edge baseline and documented ingress/registration rollback preserve Backoffice topology and data.'
    }
}
Write-Host ('Host edge topology report: ' + ($report | ConvertTo-Json -Compress))
