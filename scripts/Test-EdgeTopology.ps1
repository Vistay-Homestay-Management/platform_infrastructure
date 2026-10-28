param(
    [string]$EnvFile = '.env.example',
    [switch]$IncludeFullStack,
    [switch]$IncludeEpic01
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot

if ($IncludeFullStack -and $IncludeEpic01) {
    throw 'Choose either IncludeFullStack or IncludeEpic01, not both.'
}

$composeArguments = @(
    'compose',
    '-f', (Join-Path $repositoryRoot 'compose.yaml')
)

if ($IncludeFullStack -or $IncludeEpic01) {
    $composeArguments += @('-f', (Join-Path $repositoryRoot 'compose.full.yaml'))
}

$composeArguments += @(
    '--env-file', (Join-Path $repositoryRoot $EnvFile),
    '--profile', $(if ($IncludeFullStack) { 'full' } elseif ($IncludeEpic01) { 'epic01' } else { 'edge' }),
    'config',
    '--format', 'json'
)

$configurationJson = & docker @composeArguments
if ($LASTEXITCODE -ne 0) {
    throw 'Docker Compose configuration could not be rendered.'
}

$configuration = $configurationJson | ConvertFrom-Json
$serviceNames = @($configuration.services.PSObject.Properties.Name)

foreach ($requiredService in @('nginx', 'keycloak', 'router-backoffice')) {
    if ($requiredService -notin $serviceNames) {
        throw "Missing required edge service: $requiredService"
    }
}

if ($IncludeEpic01) {
    foreach ($requiredService in @('authentication', 'user', 'notification', 'finance', 'payment', 'frontend-admin', 'kafka-init')) {
        if ($requiredService -notin $serviceNames) {
            throw "Missing required Epic 01 service: $requiredService"
        }
    }

    foreach ($excludedService in @('property', 'booking', 'operations', 'ota', 'media', 'warehouse')) {
        if ($excludedService -in $serviceNames) {
            throw "Epic 01 must not start unrelated bounded context: $excludedService"
        }
    }
}

if ('gateway' -in $serviceNames) {
    throw 'The deprecated Spring gateway must not be part of the Compose topology.'
}

$immutableImagePattern = '^[^\s:@]+(?:/[^\s:@]+)*:[^\s@]+@sha256:[0-9a-f]{64}$'
foreach ($edgeService in @('nginx', 'keycloak', 'router-backoffice')) {
    $image = $configuration.services.$edgeService.image
    if ($image -notmatch $immutableImagePattern) {
        throw "$edgeService must use an immutable version tag and sha256 digest; got '$image'."
    }
    if ($image -match '(^|:)latest(@|$)') {
        throw "$edgeService must never use a latest tag."
    }
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
            throw "$($serviceProperty.Name) publishes a port on unexpected address '$($port.host_ip)'."
        }
    }
}

$publicServices = @($publicServices | Sort-Object -Unique)
if ($publicServices.Count -ne 1 -or $publicServices[0] -ne 'nginx') {
    throw "Nginx must be the sole public ingress; found: $($publicServices -join ', ')."
}

foreach ($internalService in @('keycloak', 'router-backoffice')) {
    $publishedPorts = @($configuration.services.$internalService.ports | Where-Object { $null -ne $_ })
    if ($publishedPorts.Count -ne 0) {
        throw "$internalService must not publish host ports."
    }
}

$nginxTargets = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'nginx/templates/default.conf.template')
foreach ($expectedTarget in @('router-backoffice:4000', 'keycloak:8080', 'authentication:8080', 'minio:9000', 'ota:8080', 'payment:8080')) {
    if (-not $nginxTargets.Contains($expectedTarget)) {
        throw "Nginx route is missing expected internal target '$expectedTarget'."
    }
}

if ($IncludeEpic01 -or $IncludeFullStack) {
    $kafkaListeners = $configuration.services.kafka.environment.KAFKA_LISTENERS
    $kafkaAdvertisedListeners = $configuration.services.kafka.environment.KAFKA_ADVERTISED_LISTENERS
    if (-not $kafkaListeners.Contains('CLIENT://:9094')) {
        throw 'Kafka must expose a container-only CLIENT listener on port 9094.'
    }
    if (-not $kafkaAdvertisedListeners.Contains('CLIENT://kafka:9094')) {
        throw 'Kafka CLIENT listener must advertise kafka:9094 inside the Compose network.'
    }

    $expectedKafkaPrincipals = @{
        authentication = 'vistay-authentication'
        user = 'vistay-user'
        notification = 'vistay-notification'
        finance = 'vistay-finance'
        payment = 'vistay-payment'
    }
    $expectedDatabasePrincipals = @{
        authentication = @{
            App = 'vistay_authentication_app'
            Migrator = 'vistay_authentication_migrator'
        }
        user = @{
            App = 'vistay_user_app'
            Migrator = 'vistay_user_migrator'
        }
        notification = @{
            App = 'vistay_notification_app'
            Migrator = 'vistay_notification_migrator'
        }
        finance = @{
            App = 'vistay_finance_app'
            Migrator = 'vistay_finance_migrator'
        }
        payment = @{
            App = 'vistay_payment_app'
            Migrator = 'vistay_payment_migrator'
        }
    }
    $renderedKafkaCredentials = @()
    foreach ($serviceName in @('authentication', 'user', 'notification', 'finance', 'payment')) {
        $service = $configuration.services.$serviceName
        if ($service.environment.KEYCLOAK_BACKOFFICE_ISSUER -ne 'http://identity.localhost/realms/vistay-backoffice') {
            throw "$serviceName must validate the public Backoffice issuer."
        }
        if ($service.environment.KEYCLOAK_BACKOFFICE_JWKS_URI -ne 'http://keycloak:8080/realms/vistay-backoffice/protocol/openid-connect/certs') {
            throw "$serviceName must fetch JWKS from the internal Keycloak address."
        }
        if ($service.environment.KAFKA_BOOTSTRAP_SERVERS -ne 'kafka:9094') {
            throw "$serviceName must use the internal Kafka CLIENT listener."
        }
        if ($service.environment.KAFKA_SECURITY_PROTOCOL -ne 'SASL_SSL') {
            throw "$serviceName must use Kafka SASL_SSL."
        }
        if ($service.environment.KAFKA_SASL_MECHANISM -ne 'SCRAM-SHA-512') {
            throw "$serviceName must use Kafka SCRAM-SHA-512."
        }
        if (-not $service.environment.KAFKA_SASL_JAAS_CONFIG.Contains(
            "username=`"$($expectedKafkaPrincipals[$serviceName])`""
        )) {
            throw "$serviceName must authenticate with its own Kafka principal."
        }
        if ($service.environment.DB_USERNAME -ne $expectedDatabasePrincipals[$serviceName].App) {
            throw "$serviceName must connect at runtime with its app database role."
        }
        if ($service.environment.SPRING_FLYWAY_USER -ne
            $expectedDatabasePrincipals[$serviceName].Migrator) {
            throw "$serviceName must migrate with its dedicated migrator database role."
        }
        if ($service.environment.DB_USERNAME -eq $service.environment.SPRING_FLYWAY_USER) {
            throw "$serviceName database runtime and migrator roles must differ."
        }
        $renderedKafkaCredentials += $service.environment.KAFKA_SASL_JAAS_CONFIG
        $kafkaMount = @($service.volumes | Where-Object target -eq '/run/secrets/kafka')
        if ($kafkaMount.Count -ne 1 -or $kafkaMount[0].read_only -ne $true) {
            throw "$serviceName must mount the Kafka trust bundle read-only."
        }
        if ((Split-Path -Leaf $kafkaMount[0].source) -ne 'client') {
            throw "$serviceName may mount only the role-scoped Kafka client trust bundle."
        }
    }
    if (@($renderedKafkaCredentials | Sort-Object -Unique).Count -ne 5) {
        throw 'Epic 01 services must not share Kafka SCRAM credentials.'
    }

    $kafkaInitializer = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'kafka/init.sh')
    if (-not $kafkaInitializer.Contains(
        'grant_consumer vistay-authentication vistay.user.authorization-changed.v1 vistay-authentication-service-authorization-cache'
    )) {
        throw 'Kafka ACLs must cover the Authentication authorization-cache consumer group exactly.'
    }

    $user = $configuration.services.user
    foreach ($expected in @(
        @{ Name = 'GRPC_TLS_ENABLED'; Value = 'true' },
        @{ Name = 'GRPC_SERVER_CERT'; Value = 'file:/run/secrets/grpc/server.crt' },
        @{ Name = 'GRPC_SERVER_KEY'; Value = 'file:/run/secrets/grpc/server.key' },
        @{ Name = 'GRPC_CLIENT_CA_CERT'; Value = 'file:/run/secrets/grpc/ca.crt' },
        @{ Name = 'GRPC_ALLOWED_CALLER_URIS'; Value = 'spiffe://vistay/service/authentication,spiffe://vistay/service/booking' },
        @{ Name = 'GRPC_MAXIMUM_DEADLINE'; Value = '2s' }
    )) {
        if ($user.environment.($expected.Name) -ne $expected.Value) {
            throw "User service $($expected.Name) must equal '$($expected.Value)'."
        }
    }
    $grpcMount = @($user.volumes | Where-Object target -eq '/run/secrets/grpc')
    if ($grpcMount.Count -ne 1 -or $grpcMount[0].read_only -ne $true) {
        throw 'User service must mount the gRPC certificate bundle read-only.'
    }
    if ((Split-Path -Leaf $grpcMount[0].source) -ne 'user-server') {
        throw 'User service may mount only its role-scoped gRPC server bundle.'
    }

    $authenticationGrpcMount = @($configuration.services.authentication.volumes |
        Where-Object target -eq '/run/secrets/grpc')
    if ($authenticationGrpcMount.Count -ne 1 -or
        $authenticationGrpcMount[0].read_only -ne $true -or
        (Split-Path -Leaf $authenticationGrpcMount[0].source) -ne 'authentication-client') {
        throw 'Authentication may mount only its role-scoped gRPC client bundle read-only.'
    }

    if ($IncludeFullStack) {
        $bookingGrpcMount = @($configuration.services.booking.volumes |
            Where-Object target -eq '/run/secrets/grpc')
        if ($bookingGrpcMount.Count -ne 1 -or
            $bookingGrpcMount[0].read_only -ne $true -or
            (Split-Path -Leaf $bookingGrpcMount[0].source) -ne 'booking-client') {
            throw 'Booking may mount only its role-scoped gRPC client bundle read-only.'
        }
    }

    $brokerBundle = @($configuration.services.kafka.volumes |
        Where-Object target -eq '/etc/kafka/broker')
    $adminBundle = @($configuration.services.'kafka-init'.volumes |
        Where-Object target -eq '/etc/kafka/admin')
    if ($brokerBundle.Count -ne 1 -or (Split-Path -Leaf $brokerBundle[0].source) -ne 'broker') {
        throw 'Kafka broker may mount only the broker certificate bundle.'
    }
    if ($adminBundle.Count -ne 1 -or (Split-Path -Leaf $adminBundle[0].source) -ne 'admin') {
        throw 'Kafka initializer may mount only the admin certificate bundle.'
    }
}

$routerConfiguration = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'router/backoffice/router.config.yaml')
foreach ($requiredSetting in @('enabled: true', 'require_authentication: true', 'allowed_algorithms:', 'subscriptions:', 'introspection: false')) {
    if (-not $routerConfiguration.Contains($requiredSetting)) {
        throw "Backoffice router is missing security setting '$requiredSetting'."
    }
}

if (-not $nginxTargets.Contains('^/(realms/vistay-backoffice/|resources/)')) {
    throw 'Nginx must allowlist only the active Backoffice realm and resource paths.'
}
if ($nginxTargets -match '(?m)^\s*location\s+/\s*\{\s*proxy_pass\s+http://keycloak:8080') {
    throw 'Nginx must not expose the entire Keycloak surface, including /admin.'
}

Write-Host 'Edge topology policy passed: Nginx is the only public ingress and all edge images are immutable.'
