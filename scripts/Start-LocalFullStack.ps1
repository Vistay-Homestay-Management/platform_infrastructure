[CmdletBinding()]
param(
  [switch]$SkipBuild,
  [switch]$PullBaseImages,
  [switch]$SkipMobile,
  [switch]$SkipMetro,
  [int]$WaitTimeoutSeconds = 900
)

$ErrorActionPreference = 'Stop'
$env:COMPOSE_PARALLEL_LIMIT = '2'
$env:COMPOSE_BAKE = 'false'
$infrastructureRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$workspaceRoot = Split-Path -Parent $infrastructureRoot
$mobileRoot = Join-Path $workspaceRoot 'frontend_admin'
$composeFiles = @(
  '-f', (Join-Path $infrastructureRoot 'compose.yaml'),
  '-f', (Join-Path $infrastructureRoot 'compose.full.yaml'),
  '--profile', 'full'
)

function Invoke-Compose {
  param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
  & docker compose @composeFiles @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "Docker Compose failed: $($Arguments -join ' ')"
  }
}

function Test-HttpEndpoint {
  param([string]$Name, [string]$Url)
  try {
    $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 15
    Write-Host "[OK] $Name -> $($response.StatusCode) $Url" -ForegroundColor Green
  } catch {
    Write-Warning "$Name did not answer at $Url`: $($_.Exception.Message)"
  }
}

if (-not (Test-Path -LiteralPath (Join-Path $infrastructureRoot '.env'))) {
  throw "Missing $infrastructureRoot\.env. Copy and complete .env.example first."
}
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  throw 'docker is not available on PATH.'
}
& docker info *> $null
if ($LASTEXITCODE -ne 0) {
  throw 'Docker Engine is not running. Start Docker Desktop and wait until it is ready.'
}

Push-Location $infrastructureRoot
try {
  Write-Host 'Validating the full Compose model...'
  Invoke-Compose config --quiet

  if ($PullBaseImages) {
    Write-Host 'Pulling published base images...'
    Invoke-Compose pull --ignore-buildable
  }

  if (-not $SkipBuild) {
    $composeModel = (& docker compose @composeFiles config --format json) | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw 'Unable to resolve buildable Compose services.' }
    $buildableServices = @(
      $composeModel.services.PSObject.Properties |
        Where-Object { $_.Value.build } |
        ForEach-Object Name |
        Sort-Object
    )
    Write-Host "Building $($buildableServices.Count) local images sequentially to protect Docker Desktop memory..."
    foreach ($serviceName in $buildableServices) {
      Write-Host "[build] $serviceName"
      Invoke-Compose build $serviceName
    }
  }

  $upArguments = @('up', '-d', '--no-build', '--remove-orphans', '--wait', '--wait-timeout', "$WaitTimeoutSeconds")
  Write-Host 'Starting the full stack...'
  Invoke-Compose @upArguments

  $expectedServices = @(& docker compose @composeFiles config --services)
  $runningServices = @(& docker compose @composeFiles ps --services --status running)
  $missingRuntime = @($expectedServices | Where-Object {
    $_ -notin $runningServices -and $_ -notin @('kafka-init', 'keycloak-profile-link-init', 'vault-init')
  })
  if ($missingRuntime.Count -gt 0) {
    & docker compose @composeFiles ps -a
    throw "Services not running after startup: $($missingRuntime -join ', ')"
  }

  Write-Host "Full stack is running: $($runningServices.Count) long-lived services." -ForegroundColor Green
  Test-HttpEndpoint 'Edge health' 'http://127.0.0.1/healthz'
  Test-HttpEndpoint 'Backoffice OIDC discovery' 'http://identity.localhost/realms/vistay-backoffice/.well-known/openid-configuration'
  Test-HttpEndpoint 'Prometheus readiness' 'http://127.0.0.1:9090/-/ready'
  Test-HttpEndpoint 'Grafana health' 'http://127.0.0.1:3000/api/health'
  Test-HttpEndpoint 'Mailpit' 'http://127.0.0.1:8025/'
} finally {
  Pop-Location
}

if (-not $SkipMobile) {
  if (-not (Get-Command adb -ErrorAction SilentlyContinue)) {
    Write-Warning 'ADB is not on PATH. Containers are ready, but mobile ports were not mapped.'
  } else {
    $authorizedDevices = @(adb devices | Select-String -Pattern "`tdevice$")
    if ($authorizedDevices.Count -eq 0) {
      Write-Warning 'No authorized Android device is connected. Connect USB, enable USB debugging, then rerun with -SkipBuild.'
    } else {
      adb reverse tcp:80 tcp:80 | Out-Null
      adb reverse tcp:8081 tcp:8081 | Out-Null
      Write-Host 'ADB reverse ready: phone 80 -> PC 80; phone 8081 -> PC 8081.' -ForegroundColor Green

      if (-not $SkipMetro) {
        $metroReady = $false
        try {
          $metroStatus = (Invoke-WebRequest -Uri 'http://127.0.0.1:8081/status' -UseBasicParsing -TimeoutSec 3).Content
          $metroReady = $metroStatus -match 'packager-status:running'
        } catch {
          $metroReady = $false
        }

        if ($metroReady) {
          Write-Host 'Metro is already running on port 8081.' -ForegroundColor Green
        } else {
          $metroCommand = "Set-Location -LiteralPath '$mobileRoot'; npm run android:dev --workspace @vistay/admin-mobile"
          Start-Process powershell.exe `
            -ArgumentList @('-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $metroCommand) `
            -WindowStyle Minimized
          Write-Host 'Metro was started in a separate minimized PowerShell window.' -ForegroundColor Green
        }
      }
    }
  }
}

Write-Host ''
Write-Host 'ViStay local endpoints:'
Write-Host '  Admin Web : http://admin.localhost/'
Write-Host '  Customer  : http://customer.localhost/'
Write-Host '  Host      : http://host.localhost/'
Write-Host '  Identity  : http://identity.localhost/'
Write-Host '  Grafana   : http://127.0.0.1:3000/'
Write-Host '  Prometheus: http://127.0.0.1:9090/'
Write-Host '  Mailpit   : http://127.0.0.1:8025/'
Write-Host ''
Write-Host 'Check mobile mapping with: adb reverse --list'
