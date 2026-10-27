param(
    [string]$ContainerName = 'vistay-keycloak-1',
    [string]$AdminUser = 'vistay-bootstrap-admin',
    [ValidateSet('vistay-backoffice-postman', 'vistay-backoffice-web')]
    [string]$ClientId = 'vistay-backoffice-postman',
    [Parameter(Mandatory = $true)]
    [string]$AdminPassword
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$realmFile = Join-Path $repositoryRoot 'keycloak/realms/vistay-backoffice-realm.json'
$clientId = $ClientId
$containerFile = '/tmp/vistay-backoffice-postman.json'

$inspectionJson = & docker inspect $ContainerName
if ($LASTEXITCODE -ne 0) {
    throw "Could not inspect local container: $ContainerName"
}
$inspection = @($inspectionJson | ConvertFrom-Json)
$serviceName = $inspection[0].Config.Labels.'com.docker.compose.service'
if ($serviceName -ne 'keycloak') {
    throw "Refusing to update a container that is not the local Compose keycloak service: $ContainerName"
}

$realm = Get-Content $realmFile -Raw | ConvertFrom-Json
$client = @($realm.clients | Where-Object clientId -eq $clientId)
if ($client.Count -ne 1) {
    throw "Expected exactly one $clientId definition in $realmFile"
}
$desiredMappers = @($client[0].protocolMappers)
$client[0].PSObject.Properties.Remove('protocolMappers')

$temporaryFile = Join-Path ([System.IO.Path]::GetTempPath()) ("vistay-keycloak-client-{0}.json" -f [guid]::NewGuid())
try {
    & docker exec $ContainerName /opt/keycloak/bin/kcadm.sh config credentials `
        --server http://localhost:8080 --realm master --user $AdminUser --password $AdminPassword
    if ($LASTEXITCODE -ne 0) { throw 'Keycloak admin authentication failed.' }

    $existingJson = & docker exec $ContainerName /opt/keycloak/bin/kcadm.sh get clients `
        -r vistay-backoffice -q "clientId=$clientId" --fields id
    if ($LASTEXITCODE -ne 0) { throw 'Could not inspect the existing Postman client.' }
    $existing = @($existingJson | ConvertFrom-Json)

    $definition = $client[0]
    $clientSettings = @(
        '-r', 'vistay-backoffice',
        '-s', "clientId=$clientId",
        '-s', "name=$($definition.name)",
        '-s', "description=$($definition.description)",
        '-s', 'enabled=true',
        '-s', "protocol=$($definition.protocol)",
        '-s', 'publicClient=true',
        '-s', 'standardFlowEnabled=true',
        '-s', 'implicitFlowEnabled=false',
        '-s', 'directAccessGrantsEnabled=false',
        '-s', 'serviceAccountsEnabled=false',
        '-s', 'fullScopeAllowed=false',
        '-s', "redirectUris[0]=$($definition.redirectUris[0])",
        '-s', "webOrigins[0]=$($definition.webOrigins[0])"
    )
    if ($existing.Count -eq 0) {
        & docker exec $ContainerName /opt/keycloak/bin/kcadm.sh create clients @clientSettings
    } elseif ($existing.Count -eq 1) {
        & docker exec $ContainerName /opt/keycloak/bin/kcadm.sh update "clients/$($existing[0].id)" @clientSettings
    } else {
        throw "More than one $clientId client exists in vistay-backoffice."
    }
    if ($LASTEXITCODE -ne 0) { throw 'Could not synchronize the Postman client.' }

    $clientResultJson = & docker exec $ContainerName /opt/keycloak/bin/kcadm.sh get clients `
        -r vistay-backoffice -q "clientId=$clientId" --fields id
    $clientResult = @($clientResultJson | ConvertFrom-Json)
    if ($LASTEXITCODE -ne 0 -or $clientResult.Count -ne 1) {
        throw 'Could not resolve the synchronized Postman client id.'
    }
    $keycloakClientId = $clientResult[0].id

    $currentClientJson = & docker exec $ContainerName /opt/keycloak/bin/kcadm.sh get `
        "clients/$keycloakClientId" -r vistay-backoffice
    if ($LASTEXITCODE -ne 0) { throw 'Could not read the synchronized Postman client.' }
    $currentClient = $currentClientJson | ConvertFrom-Json
    if ($null -eq $currentClient.attributes) {
        $currentClient | Add-Member -NotePropertyName attributes -NotePropertyValue ([pscustomobject]@{})
    }
    $currentClient.attributes | Add-Member -Force -NotePropertyName 'pkce.code.challenge.method' -NotePropertyValue 'S256'
    $currentClientJson = $currentClient | ConvertTo-Json -Depth 100
    [System.IO.File]::WriteAllText($temporaryFile, $currentClientJson, [System.Text.UTF8Encoding]::new($false))
    & docker cp $temporaryFile "${ContainerName}:$containerFile"
    if ($LASTEXITCODE -ne 0) { throw 'Could not stage the PKCE-enforced Postman client.' }
    & docker exec $ContainerName /opt/keycloak/bin/kcadm.sh update "clients/$keycloakClientId" `
        -r vistay-backoffice -f $containerFile
    if ($LASTEXITCODE -ne 0) { throw 'Could not enforce S256 PKCE on the Postman client.' }

    $realmClientScopesJson = & docker exec $ContainerName /opt/keycloak/bin/kcadm.sh get `
        client-scopes -r vistay-backoffice --fields id,name
    $realmClientScopes = $realmClientScopesJson | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw 'Could not inspect realm client scopes.' }
    foreach ($scopeName in $definition.defaultClientScopes) {
        $matchingScopes = @()
        foreach ($candidateScope in $realmClientScopes) {
            if ($candidateScope.name -eq $scopeName) {
                $matchingScopes += $candidateScope
            }
        }
        if ($matchingScopes.Count -ne 1) {
            throw "Expected exactly one realm client scope named: $scopeName"
        }
        & docker exec $ContainerName /opt/keycloak/bin/kcadm.sh update `
            "clients/$keycloakClientId/default-client-scopes/$($matchingScopes[0].id)" -r vistay-backoffice
        if ($LASTEXITCODE -ne 0) { throw "Could not attach default client scope: $scopeName" }
    }

    $existingMappersJson = & docker exec $ContainerName /opt/keycloak/bin/kcadm.sh get `
        "clients/$keycloakClientId/protocol-mappers/models" -r vistay-backoffice --fields id,name
    $existingMappers = $existingMappersJson | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw 'Could not inspect Postman client protocol mappers.' }

    foreach ($mapper in $desiredMappers) {
        $mapperJson = $mapper | ConvertTo-Json -Depth 100
        [System.IO.File]::WriteAllText($temporaryFile, $mapperJson, [System.Text.UTF8Encoding]::new($false))
        & docker cp $temporaryFile "${ContainerName}:$containerFile"
        if ($LASTEXITCODE -ne 0) { throw "Could not stage protocol mapper: $($mapper.name)" }

        $matchingMappers = @()
        foreach ($candidateMapper in $existingMappers) {
            if ($candidateMapper.name -eq $mapper.name) {
                $matchingMappers += $candidateMapper
            }
        }
        if ($matchingMappers.Count -eq 0) {
            & docker exec $ContainerName /opt/keycloak/bin/kcadm.sh create `
                "clients/$keycloakClientId/protocol-mappers/models" -r vistay-backoffice -f $containerFile
        } elseif ($matchingMappers.Count -eq 1) {
            & docker exec $ContainerName /opt/keycloak/bin/kcadm.sh update `
                "clients/$keycloakClientId/protocol-mappers/models/$($matchingMappers[0].id)" `
                -r vistay-backoffice -f $containerFile
        } else {
            throw "Duplicate protocol mapper on ${clientId}: $($mapper.name)"
        }
        if ($LASTEXITCODE -ne 0) { throw "Could not synchronize protocol mapper: $($mapper.name)" }
    }

    Write-Output "Keycloak client synchronized: $clientId"
} finally {
    if (Test-Path -LiteralPath $temporaryFile) {
        Remove-Item -LiteralPath $temporaryFile -Force
    }
    & docker exec --user 0 $ContainerName rm -f $containerFile 2>$null | Out-Null
}
