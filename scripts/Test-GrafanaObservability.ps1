param(
    [string]$EnvFile = '.env',
    [switch]$StaticOnly
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$envPath = Join-Path $root $EnvFile
$compose = @(
    'compose',
    '-f', (Join-Path $root 'compose.yaml'),
    '-f', (Join-Path $root 'compose.full.yaml'),
    '--env-file', $envPath,
    '--profile', 'full'
)

$dashboardContracts = @(
    @{ Path = 'observability/grafana/dashboards/vistay-platform-overview.json'; Uid = 'vistay-platform-overview'; MinimumPanels = 20 },
    @{ Path = 'observability/grafana/dashboards/vistay-system-health.json'; Uid = 'vistay-system-health'; MinimumPanels = 25 },
    @{ Path = 'observability/grafana/dashboards/vistay-edge-dependencies.json'; Uid = 'vistay-edge-dependencies'; MinimumPanels = 11 }
)
foreach ($contract in $dashboardContracts) {
    $dashboardPath = Join-Path $root $contract.Path
    $dashboard = Get-Content -Raw -LiteralPath $dashboardPath | ConvertFrom-Json
    if ($dashboard.uid -ne $contract.Uid -or $dashboard.panels.Count -lt $contract.MinimumPanels) {
        throw "The ViStay Grafana dashboard $($contract.Uid) is missing required panels."
    }
}

& docker @compose config -q
if ($LASTEXITCODE -ne 0) { throw 'Grafana observability compose configuration is invalid.' }
if ($StaticOnly) {
    Write-Host 'Grafana observability static contract passed.'
    exit 0
}

function Wait-ForHttp([string]$Url) {
    foreach ($attempt in 1..30) {
        try {
            $response = Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec 5
            if ($response.StatusCode -eq 200) { return }
        } catch {}
        Start-Sleep -Seconds 2
    }
    throw "$Url did not become ready."
}

$grafanaPortLine = Get-Content -LiteralPath $envPath | Where-Object { $_ -like 'GRAFANA_PORT=*' } | Select-Object -First 1
$grafanaPort = if ($env:GRAFANA_PORT) { $env:GRAFANA_PORT } elseif ($grafanaPortLine) { ($grafanaPortLine -split '=', 2)[1] } else { '3000' }
$grafanaBaseUrl = "http://127.0.0.1:$grafanaPort"
Wait-ForHttp "$grafanaBaseUrl/api/health"

$grafanaUserLine = Get-Content -LiteralPath $envPath | Where-Object { $_ -like 'GRAFANA_ADMIN_USER=*' } | Select-Object -First 1
$grafanaPasswordLine = Get-Content -LiteralPath $envPath | Where-Object { $_ -like 'GRAFANA_ADMIN_PASSWORD=*' } | Select-Object -First 1
if (-not $grafanaUserLine -or -not $grafanaPasswordLine) {
    throw 'GRAFANA_ADMIN_USER and GRAFANA_ADMIN_PASSWORD are required for dashboard verification.'
}
$grafanaUser = ($grafanaUserLine -split '=', 2)[1]
$grafanaPassword = ($grafanaPasswordLine -split '=', 2)[1]
$basicValue = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($grafanaUser + ':' + $grafanaPassword))
$headers = @{ Authorization = "Basic $basicValue" }
$datasourceUid = 'vistay-prometheus'
$prometheusProxy = "$grafanaBaseUrl/api/datasources/proxy/uid/$datasourceUid"

$targets = Invoke-RestMethod -Uri "$prometheusProxy/api/v1/targets" -Headers $headers -TimeoutSec 10
if ($targets.status -ne 'success') { throw 'Prometheus target API is unavailable through Grafana.' }
$requiredInstances = @(
    'authentication:8080',
    'user:8080',
    'notification:8080',
    'property:8080',
    'booking:8080',
    'finance:8080',
    'payment:8080',
    'operations:8080',
    'ota:8080',
    'media:8080',
    'warehouse:8080',
    'keycloak:9000',
    'nginx-exporter:9113',
    'router-backoffice:9100',
    'router-host:9100',
    'router-customer:9100'
)
$activeTargets = @($targets.data.activeTargets)
foreach ($instance in $requiredInstances) {
    $target = $activeTargets | Where-Object { $_.labels.instance -eq $instance } | Select-Object -First 1
    if (-not $target -or $target.health -ne 'up') {
        throw "Prometheus target $instance is not UP."
    }
}

function Assert-NoPrometheusResults([string]$Query, [string]$Message) {
    $encoded = [uri]::EscapeDataString($Query)
    $result = Invoke-RestMethod -Uri "$prometheusProxy/api/v1/query?query=$encoded" -Headers $headers -TimeoutSec 10
    if ($result.status -ne 'success') {
        throw "Prometheus query failed: $Query"
    }
    if (@($result.data.result).Count -gt 0) {
        throw $Message
    }
}
Assert-NoPrometheusResults 'up{job=~"backoffice-services|keycloak|postgres|redis|nginx|frontends|routers|router-metrics"} == 0' 'One or more Prometheus scrape targets are DOWN.'
Assert-NoPrometheusResults 'probe_success{job=~"frontends|routers"} == 0' 'One or more frontend or router probes are failing.'

foreach ($contract in $dashboardContracts) {
    $dashboardResponse = Invoke-WebRequest -UseBasicParsing -Uri "$grafanaBaseUrl/api/dashboards/uid/$($contract.Uid)" -Headers $headers -TimeoutSec 10
    if ($dashboardResponse.StatusCode -ne 200) { throw "Provisioned Grafana dashboard $($contract.Uid) is unavailable." }
}

Write-Host 'Grafana observability runtime contract passed.'
