param(
    [string]$EnvFile = '.env.example',
    [int]$StartingPort = 4410
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$environment = @{}

foreach ($line in Get-Content -LiteralPath (Join-Path $repositoryRoot $EnvFile)) {
    $trimmed = $line.Trim()
    if (-not $trimmed -or $trimmed.StartsWith('#')) {
        continue
    }

    $parts = $trimmed.Split('=', 2)
    if ($parts.Count -eq 2) {
        $environment[$parts[0]] = $parts[1]
    }
}

$images = @(
    @{ Name = 'current'; Reference = $environment['HIVE_ROUTER_IMAGE'] },
    @{ Name = 'rollback'; Reference = $environment['HIVE_ROUTER_ROLLBACK_IMAGE'] }
)

if ($images.Where({ -not $_.Reference }).Count -gt 0) {
    throw 'Both HIVE_ROUTER_IMAGE and HIVE_ROUTER_ROLLBACK_IMAGE are required.'
}

$immutableImagePattern = '^[^\s:@]+(?:/[^\s:@]+)*:[^\s@]+@sha256:[0-9a-f]{64}$'
foreach ($candidate in $images) {
    if ($candidate.Reference -notmatch $immutableImagePattern -or $candidate.Reference -match '(^|:)latest(@|$)') {
        throw "Hive Router $($candidate.Name) image must use an immutable version tag and sha256 digest."
    }
}

$routerConfig = Join-Path $repositoryRoot 'router/backoffice/router.config.yaml'
$supergraph = Join-Path $repositoryRoot 'router/backoffice/supergraph.graphql'

for ($index = 0; $index -lt $images.Count; $index++) {
    $candidate = $images[$index]
    $containerName = "vistay-hive-$($candidate.Name)-$PID"
    $hostPort = $StartingPort + $index

    try {
        & docker run --detach `
            --name $containerName `
            --read-only `
            --tmpfs /tmp `
            --cap-drop ALL `
            --security-opt no-new-privileges:true `
            --publish "127.0.0.1:${hostPort}:4000" `
            --env ROUTER_CONFIG_FILE_PATH=/app/config/router.config.yaml `
            --env BACKOFFICE_JWKS_URL=http://127.0.0.1:18080/realms/vistay-backoffice/protocol/openid-connect/certs `
            --env BACKOFFICE_JWT_AUDIENCES=vistay-backoffice-api `
            --env BACKOFFICE_JWT_ISSUERS=http://identity.localhost/realms/vistay-backoffice `
            --env BACKOFFICE_CORS_ALLOWED_ORIGINS=http://admin.localhost `
            --mount "type=bind,source=$routerConfig,target=/app/config/router.config.yaml,readonly" `
            --mount "type=bind,source=$supergraph,target=/app/schema/supergraph.graphql,readonly" `
            $candidate.Reference | Out-Null

        if ($LASTEXITCODE -ne 0) {
            throw "Could not start Hive Router $($candidate.Name) image."
        }

        $ready = $false
        for ($attempt = 0; $attempt -lt 40; $attempt++) {
            $running = & docker inspect --format '{{.State.Running}}' $containerName 2>$null
            if ($running -ne 'true') {
                break
            }

            try {
                $response = Invoke-WebRequest -UseBasicParsing -Method Head -Uri "http://127.0.0.1:$hostPort/readiness" -TimeoutSec 2
                if ($response.StatusCode -eq 200) {
                    $ready = $true
                    break
                }
            }
            catch {
                Start-Sleep -Milliseconds 250
            }
        }

        if (-not $ready) {
            $logs = & docker logs $containerName 2>&1
            throw "Hive Router $($candidate.Name) did not become ready.`n$logs"
        }

        try {
            Invoke-WebRequest `
                -UseBasicParsing `
                -Uri "http://127.0.0.1:$hostPort/graphql?query=%7Bviewer%7BaccountId%7D%7D" `
                -Headers @{ 'X-CSRF-Token' = 'compatibility-test' } `
                -TimeoutSec 5 | Out-Null
            throw "Hive Router $($candidate.Name) accepted an unauthenticated GraphQL request."
        }
        catch {
            $statusCode = $null
            if ($_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }
            if ($statusCode -ne 401) {
                throw
            }
        }

        Write-Host "Hive Router $($candidate.Name) compatibility passed ($($candidate.Reference))."
    }
    finally {
        & docker rm --force $containerName 2>$null | Out-Null
    }
}
