param(
    [string]$EnvFile = '.env',
    [switch]$StaticOnly
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$composeArguments = @(
    'compose',
    '-f', (Join-Path $repositoryRoot 'compose.yaml'),
    '-f', (Join-Path $repositoryRoot 'compose.full.yaml'),
    '--env-file', (Join-Path $repositoryRoot $EnvFile),
    '--profile', 'epic01'
)

$configurationJson = & docker @composeArguments 'config' '--format' 'json'
if ($LASTEXITCODE -ne 0) {
    throw 'Docker Compose observability configuration could not be rendered.'
}
$configuration = $configurationJson | ConvertFrom-Json

$collector = $configuration.services.'otel-collector'
if ($null -eq $collector) {
    throw 'Epic 01 must include the OpenTelemetry Collector.'
}
if ($collector.image -notmatch '^otel/opentelemetry-collector:[^@]+@sha256:[0-9a-f]{64}$' -or
    $collector.image -match '(^|:)latest(@|$)') {
    throw "OpenTelemetry Collector must use an immutable non-latest image; got '$($collector.image)'."
}

$expectedServices = @{
    authentication = 'vistay-authentication-service'
    user = 'vistay-user-service'
    notification = 'vistay-notification-service'
}
foreach ($entry in $expectedServices.GetEnumerator()) {
    $service = $configuration.services.($entry.Key)
    if ($service.environment.OTEL_SERVICE_NAME -ne $entry.Value) {
        throw "$($entry.Key) must export the stable service name '$($entry.Value)'."
    }
    if ($service.environment.OTEL_EXPORTER_OTLP_ENDPOINT -ne 'http://otel-collector:4318') {
        throw "$($entry.Key) must export traces to the internal collector OTLP/HTTP endpoint."
    }
    if ($service.environment.MANAGEMENT_OTLP_METRICS_EXPORT_ENABLED -ne 'false') {
        throw "$($entry.Key) must keep OTLP metrics disabled because Prometheus is the metrics baseline."
    }
    $sampling = [double]$service.environment.MANAGEMENT_TRACING_SAMPLING_PROBABILITY
    if ($sampling -lt 0 -or $sampling -gt 1) {
        throw "$($entry.Key) trace sampling probability must be between zero and one."
    }
}

$collectorConfig = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'observability/otel-collector.yaml')
foreach ($requiredSetting in @('health_check:', 'otlp:', 'memory_limiter:', 'batch:', 'debug:', 'traces:')) {
    if (-not $collectorConfig.Contains($requiredSetting)) {
        throw "Collector configuration is missing '$requiredSetting'."
    }
}

if ($StaticOnly) {
    Write-Host 'Observability static contract passed.'
    exit 0
}

$healthPort = if ($env:OTEL_HEALTH_PORT) { $env:OTEL_HEALTH_PORT } else { '13133' }
$health = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$healthPort/" -TimeoutSec 10
if ($health.StatusCode -ne 200) {
    throw "Collector health endpoint returned $($health.StatusCode)."
}

function Get-InternalEndpoint([string]$ServiceName, [string]$Path) {
    foreach ($attempt in 1..30) {
        $previousErrorPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $response = & docker @composeArguments 'exec' '-T' 'nginx' 'wget' '-qO-' "http://${ServiceName}:8080${Path}" 2>$null
        $ErrorActionPreference = $previousErrorPreference
        if ($LASTEXITCODE -eq 0) {
            return $response
        }
        Start-Sleep -Seconds 2
    }
    throw "$ServiceName$Path did not become available within 60 seconds."
}

foreach ($serviceName in $expectedServices.Keys) {
    $readiness = Get-InternalEndpoint $serviceName '/actuator/health/readiness'
    if (($readiness | ConvertFrom-Json).status -ne 'UP') {
        throw "$serviceName readiness probe is not UP."
    }
    $metrics = Get-InternalEndpoint $serviceName '/actuator/prometheus'
    if (-not ($metrics -match '(?m)^jvm_info')) {
        throw "$serviceName does not expose Prometheus JVM metrics."
    }
}

$null = Get-InternalEndpoint 'authentication' '/actuator/health/readiness'
$traceObserved = $false
foreach ($attempt in 1..15) {
    $collectorLogs = & docker @composeArguments 'logs' '--no-color' '--since' '2m' 'otel-collector' 2>&1
    if ($LASTEXITCODE -eq 0 -and $collectorLogs -match 'resource spans') {
        $traceObserved = $true
        break
    }
    Start-Sleep -Seconds 1
}
if (-not $traceObserved) {
    throw 'Collector did not receive an application trace during the smoke window.'
}

Write-Host 'Observability runtime contract passed: readiness, metrics, and OTLP traces are available.'
