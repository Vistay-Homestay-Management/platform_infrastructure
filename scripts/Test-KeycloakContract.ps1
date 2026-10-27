param(
    [string]$RealmFile = 'keycloak/realms/vistay-backoffice-realm.json',
    [string]$EnvFile = '.env.example',
    [string]$RuntimeBaseUri,
    [string]$HostHeader = 'identity.localhost',
    [string]$AdminUsername,
    [string]$AdminPassword
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot

function Assert-Contract {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Get-EnvFileValue {
    param(
        [string]$Path,
        [string]$Name
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $line = Get-Content -LiteralPath $Path |
        Where-Object { $_ -match "^$([regex]::Escape($Name))=" } |
        Select-Object -Last 1

    if ($null -eq $line) {
        return $null
    }

    return ($line -split '=', 2)[1]
}

function Get-Client {
    param(
        [object[]]$Clients,
        [string]$ClientId
    )

    $candidates = @()
    foreach ($candidate in $Clients) {
        $candidates += @($candidate)
    }

    $client = @($candidates | Where-Object clientId -eq $ClientId)
    Assert-Contract ($client.Count -eq 1) "Expected exactly one Keycloak client '$ClientId'; found $($client.Count)."
    return $client[0]
}

function Assert-BackofficeClient {
    param(
        [pscustomobject]$Client,
        [object[]]$ProtocolMappers,
        [string[]]$DefaultScopeNames
    )

    $mappers = @()
    foreach ($mapper in $ProtocolMappers) {
        $mappers += @($mapper)
    }

    $scopeNames = @()
    foreach ($scopeName in $DefaultScopeNames) {
        $scopeNames += @($scopeName)
    }

    Assert-Contract ($Client.publicClient -eq $true) "$($Client.clientId) must be a public client."
    Assert-Contract ($Client.directAccessGrantsEnabled -eq $false) "$($Client.clientId) must disable password grants."
    Assert-Contract ($Client.attributes.'pkce.code.challenge.method' -eq 'S256') "$($Client.clientId) must require PKCE S256."
    Assert-Contract ($scopeNames -contains 'notifications:read') "$($Client.clientId) must receive notifications:read by default."

    $audienceMapper = @($mappers | Where-Object name -eq 'backoffice-api-audience')
    Assert-Contract ($audienceMapper.Count -eq 1) "$($Client.clientId) must have one API audience mapper."
    Assert-Contract ($audienceMapper[0].protocolMapper -eq 'oidc-audience-mapper') "$($Client.clientId) uses the wrong audience mapper type."
    Assert-Contract ($audienceMapper[0].config.'included.client.audience' -eq 'vistay-backoffice-api') "$($Client.clientId) must emit the vistay-backoffice-api audience."
    Assert-Contract ($audienceMapper[0].config.'access.token.claim' -eq 'true') "$($Client.clientId) audience must be included in access tokens."

    $accountTypeMapper = @($mappers | Where-Object name -eq 'backoffice-account-type')
    Assert-Contract ($accountTypeMapper.Count -eq 1) "$($Client.clientId) must have one account_type mapper."
    Assert-Contract ($accountTypeMapper[0].protocolMapper -eq 'oidc-hardcoded-claim-mapper') "$($Client.clientId) account_type must be a hardcoded claim."
    Assert-Contract ($accountTypeMapper[0].config.'claim.name' -eq 'account_type') "$($Client.clientId) uses the wrong account type claim name."
    Assert-Contract ($accountTypeMapper[0].config.'claim.value' -ceq 'ADMIN') "$($Client.clientId) account_type must be ADMIN."
    Assert-Contract ($accountTypeMapper[0].config.'jsonType.label' -eq 'String') "$($Client.clientId) account_type must be a JSON string."
    Assert-Contract ($accountTypeMapper[0].config.'access.token.claim' -eq 'true') "$($Client.clientId) account_type must be included in access tokens."
}

$realmPath = Join-Path $repositoryRoot $RealmFile
$realm = Get-Content -Raw -LiteralPath $realmPath | ConvertFrom-Json
Assert-Contract ($realm.realm -eq 'vistay-backoffice') 'The realm contract test must target vistay-backoffice.'
Assert-Contract ($realm.enabled -eq $true) 'The Backoffice realm must be active for Epic 01.'

foreach ($deferredRealmFile in @(
    'keycloak/realms/vistay-host-realm.json',
    'keycloak/realms/vistay-customer-realm.json'
)) {
    $deferredRealm = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot $deferredRealmFile) |
        ConvertFrom-Json
    Assert-Contract ($deferredRealm.enabled -eq $false) `
        "$($deferredRealm.realm) must remain disabled until its release is activated."
    Assert-Contract ($deferredRealm.registrationAllowed -eq $false) `
        "$($deferredRealm.realm) must not accept registration during Epic 01."
}

$notificationScopes = @($realm.clientScopes | Where-Object name -eq 'notifications:read')
Assert-Contract ($notificationScopes.Count -eq 1) 'The realm must define exactly one notifications:read client scope.'
Assert-Contract ($notificationScopes[0].attributes.'include.in.token.scope' -eq 'true') 'notifications:read must appear in the OAuth scope claim.'

$realmClients = @($realm.clients)
foreach ($clientId in @('vistay-backoffice-web', 'vistay-backoffice-mobile')) {
    $client = Get-Client -Clients $realmClients -ClientId $clientId
    Assert-BackofficeClient -Client $client -ProtocolMappers @($client.protocolMappers) -DefaultScopeNames @($client.defaultClientScopes)
}

$postman = Get-Client -Clients $realmClients -ClientId 'vistay-backoffice-postman'
Assert-Contract ($postman.publicClient -eq $true) 'Postman must be a public client.'
Assert-Contract ($postman.standardFlowEnabled -eq $true) 'Postman must enable Authorization Code flow.'
Assert-Contract ($postman.directAccessGrantsEnabled -eq $false) 'Postman must disable password grants.'
Assert-Contract ($postman.serviceAccountsEnabled -eq $false) 'Postman must not have a service account.'
Assert-Contract ($postman.attributes.'pkce.code.challenge.method' -eq 'S256') 'Postman must require PKCE S256.'
Assert-Contract (@($postman.redirectUris) -contains 'https://oauth.pstmn.io/v1/browser-callback') `
    'Postman must allow only the documented browser callback.'
$postmanMappers = @($postman.protocolMappers)
Assert-Contract (@($postmanMappers | Where-Object name -eq 'backoffice-api-audience').Count -eq 1) `
    'Postman must emit the Backoffice API audience.'
Assert-Contract (@($postmanMappers | Where-Object name -eq 'backoffice-account-type').Count -eq 1) `
    'Postman must emit account_type.'

$facade = Get-Client -Clients $realmClients -ClientId 'vistay-auth-facade'
Assert-Contract ($facade.publicClient -eq $false) 'The Auth facade must be confidential.'
Assert-Contract ($facade.serviceAccountsEnabled -eq $true) 'The Auth facade service account must be enabled.'
Assert-Contract ($facade.standardFlowEnabled -eq $false) 'The Auth facade must disable browser login.'
Assert-Contract ($facade.directAccessGrantsEnabled -eq $false) 'The Auth facade must disable password grants.'
Assert-Contract (@($facade.defaultClientScopes) -contains 'roles') 'The Auth facade must include mapped roles in service-account tokens.'
Assert-Contract (@($facade.defaultClientScopes) -contains 'service_account') 'The Auth facade must include Keycloak service-account token claims.'
Assert-Contract ($facade.secret -ceq '${KEYCLOAK_ADMIN_CLIENT_SECRET}') 'The realm bootstrap must reference the Auth facade secret only through its environment placeholder.'

$serviceUsers = @($realm.users | Where-Object serviceAccountClientId -eq 'vistay-auth-facade')
Assert-Contract ($serviceUsers.Count -eq 1) 'The realm must define exactly one Auth facade service account user.'
$configuredRoles = @($serviceUsers[0].clientRoles.'realm-management' | Sort-Object)
Assert-Contract (($configuredRoles -join ',') -eq 'manage-users,query-users') 'The Auth facade must have exactly manage-users and query-users realm-management roles.'

if ([string]::IsNullOrWhiteSpace($RuntimeBaseUri)) {
    Write-Host 'Keycloak Backoffice contract passed (static realm definition).'
    exit 0
}

$envPath = Join-Path $repositoryRoot $EnvFile
if ([string]::IsNullOrWhiteSpace($AdminUsername)) {
    $AdminUsername = if ($env:KEYCLOAK_BOOTSTRAP_ADMIN_USERNAME) {
        $env:KEYCLOAK_BOOTSTRAP_ADMIN_USERNAME
    }
    else {
        Get-EnvFileValue -Path $envPath -Name 'KEYCLOAK_BOOTSTRAP_ADMIN_USERNAME'
    }
}
if ([string]::IsNullOrWhiteSpace($AdminPassword)) {
    $AdminPassword = if ($env:KEYCLOAK_BOOTSTRAP_ADMIN_PASSWORD) {
        $env:KEYCLOAK_BOOTSTRAP_ADMIN_PASSWORD
    }
    else {
        Get-EnvFileValue -Path $envPath -Name 'KEYCLOAK_BOOTSTRAP_ADMIN_PASSWORD'
    }
}

Assert-Contract (-not [string]::IsNullOrWhiteSpace($AdminUsername)) 'A Keycloak bootstrap admin username is required for runtime verification.'
Assert-Contract (-not [string]::IsNullOrWhiteSpace($AdminPassword)) 'A Keycloak bootstrap admin password is required for runtime verification.'

$baseUri = $RuntimeBaseUri.TrimEnd('/')
$hostHeaders = @{ Host = $HostHeader }
$adminToken = (Invoke-RestMethod `
    -Method Post `
    -Uri "$baseUri/realms/master/protocol/openid-connect/token" `
    -Headers $hostHeaders `
    -ContentType 'application/x-www-form-urlencoded' `
    -Body @{
        client_id = 'admin-cli'
        username = $AdminUsername
        password = $AdminPassword
        grant_type = 'password'
    }).access_token
Assert-Contract (-not [string]::IsNullOrWhiteSpace($adminToken)) 'Keycloak did not issue a bootstrap admin token.'

$adminHeaders = @{
    Host = $HostHeader
    Authorization = "Bearer $adminToken"
}
$importedClients = @(Invoke-RestMethod -Uri "$baseUri/admin/realms/vistay-backoffice/clients" -Headers $adminHeaders)

foreach ($clientId in @('vistay-backoffice-web', 'vistay-backoffice-mobile')) {
    $client = Get-Client -Clients $importedClients -ClientId $clientId
    $mappers = @(Invoke-RestMethod -Uri "$baseUri/admin/realms/vistay-backoffice/clients/$($client.id)/protocol-mappers/models" -Headers $adminHeaders)
    $defaultScopes = @(Invoke-RestMethod -Uri "$baseUri/admin/realms/vistay-backoffice/clients/$($client.id)/default-client-scopes" -Headers $adminHeaders)
    Assert-BackofficeClient -Client $client -ProtocolMappers $mappers -DefaultScopeNames @($defaultScopes.name)
}

$importedFacade = Get-Client -Clients $importedClients -ClientId 'vistay-auth-facade'
$facadeDefaultScopes = @(Invoke-RestMethod -Uri "$baseUri/admin/realms/vistay-backoffice/clients/$($importedFacade.id)/default-client-scopes" -Headers $adminHeaders)
$facadeDefaultScopeNames = @()
foreach ($defaultScope in $facadeDefaultScopes) {
    $facadeDefaultScopeNames += @($defaultScope.name)
}
$realmClientScopes = @(Invoke-RestMethod -Uri "$baseUri/admin/realms/vistay-backoffice/client-scopes" -Headers $adminHeaders)
$realmClientScopeNames = @()
foreach ($realmClientScope in $realmClientScopes) {
    $realmClientScopeNames += @($realmClientScope.name)
}
Assert-Contract ($facadeDefaultScopeNames -contains 'roles') "The imported Auth facade is missing the roles client scope; got '$($facadeDefaultScopeNames -join ',')'; available='$($realmClientScopeNames -join ',')'."
Assert-Contract ($facadeDefaultScopeNames -contains 'service_account') "The imported Auth facade is missing the service_account client scope; got '$($facadeDefaultScopeNames -join ',')'; available='$($realmClientScopeNames -join ',')'."
$serviceUser = Invoke-RestMethod -Uri "$baseUri/admin/realms/vistay-backoffice/clients/$($importedFacade.id)/service-account-user" -Headers $adminHeaders
$realmManagement = Get-Client -Clients $importedClients -ClientId 'realm-management'
$mappedRoles = @(Invoke-RestMethod -Uri "$baseUri/admin/realms/vistay-backoffice/users/$($serviceUser.id)/role-mappings/clients/$($realmManagement.id)" -Headers $adminHeaders)
$mappedRoleNames = @($mappedRoles.name | Sort-Object)
Assert-Contract (($mappedRoleNames -join ',') -eq 'manage-users,query-users') 'Imported Auth facade roles do not match the least-privilege contract.'

$generatedSecret = (Invoke-RestMethod -Uri "$baseUri/admin/realms/vistay-backoffice/clients/$($importedFacade.id)/client-secret" -Headers $adminHeaders).value
Assert-Contract (-not [string]::IsNullOrWhiteSpace($generatedSecret)) 'Keycloak did not import an Auth facade client secret.'
$expectedSecret = if ($env:KEYCLOAK_ADMIN_CLIENT_SECRET) {
    $env:KEYCLOAK_ADMIN_CLIENT_SECRET
}
else {
    Get-EnvFileValue -Path $envPath -Name 'KEYCLOAK_ADMIN_CLIENT_SECRET'
}
Assert-Contract ($generatedSecret -ceq $expectedSecret) 'The imported Auth facade secret does not match the provisioned environment value.'
$serviceAccessToken = (Invoke-RestMethod `
    -Method Post `
    -Uri "$baseUri/realms/vistay-backoffice/protocol/openid-connect/token" `
    -Headers $hostHeaders `
    -ContentType 'application/x-www-form-urlencoded' `
    -Body @{
        client_id = 'vistay-auth-facade'
        client_secret = $generatedSecret
        grant_type = 'client_credentials'
    }).access_token
Assert-Contract (-not [string]::IsNullOrWhiteSpace($serviceAccessToken)) 'The Auth facade client credentials grant failed.'

$payload = $serviceAccessToken.Split('.')[1].Replace('-', '+').Replace('_', '/')
while ($payload.Length % 4) {
    $payload += '='
}
$serviceClaims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
$tokenRoles = @($serviceClaims.resource_access.'realm-management'.roles | Sort-Object)
Assert-Contract (($tokenRoles -join ',') -eq 'manage-users,query-users') "The Auth facade token roles do not match the contract; got '$($tokenRoles -join ',')'."

Write-Host 'Keycloak Backoffice contract passed (imported realm and service-account token).'
