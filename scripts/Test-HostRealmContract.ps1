param(
    [string]$RealmFile = 'keycloak/realms/vistay-host-realm.json',
    [string]$EnvFile = '.env.example',
    [string]$ComposeFile = 'compose.full.yaml'
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$contractErrorCode = 'HOST_REALM_CONTRACT_INVALID'
$correlationId = "SCRUM-808-HOST-REALM-$([guid]::NewGuid().ToString('N'))"

function Assert-Contract {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw "$contractErrorCode [$correlationId] $Message"
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

function Get-Client {
    param(
        [object[]]$Clients,
        [string]$ClientId
    )

    $client = @($Clients | Where-Object clientId -eq $ClientId)
    Assert-Contract ($client.Count -eq 1) "Expected exactly one Host client '$ClientId'; found $($client.Count)."
    return $client[0]
}

$realmPath = Join-Path $repositoryRoot $RealmFile
$envPath = Join-Path $repositoryRoot $EnvFile
$composePath = Join-Path $repositoryRoot $ComposeFile
$realm = Get-Content -Raw -LiteralPath $realmPath | ConvertFrom-Json
$envValues = Read-EnvFile -Path $envPath
$realmFingerprint = (Get-FileHash -LiteralPath $realmPath -Algorithm SHA256).Hash.ToLowerInvariant()

Assert-Contract ($realm.realm -eq 'vistay-host') 'The Host realm contract must target vistay-host.'
Assert-Contract ($realm.enabled -eq $false) 'The checked-in Host realm must remain disabled until the edge/JWT/smoke gate passes.'
Assert-Contract ($envValues.VISTAY_HOST_REALM_ENABLED -eq 'false') 'The baseline Host realm enablement signal must be false.'
Assert-Contract ($realm.registrationAllowed -eq $false) 'Host self-registration must remain disabled.'
Assert-Contract ($realm.sslRequired -eq 'external') 'Host realm transport must require external TLS.'
Assert-Contract ($realm.verifyEmail -eq $true) 'Host activation must require verified email.'
Assert-Contract ($realm.loginWithEmailAllowed -eq $true) 'Host login must permit the verified email identifier.'
Assert-Contract ($realm.duplicateEmailsAllowed -eq $false) 'Host normalized email must be unique.'
Assert-Contract ($realm.resetPasswordAllowed -eq $true) 'Host recovery must be enabled through Keycloak.'
Assert-Contract ($realm.editUsernameAllowed -eq $false) 'Host usernames must not be changed through the portal.'
Assert-Contract ($realm.bruteForceProtected -eq $true) 'Host brute-force protection must be enabled.'
Assert-Contract ($realm.failureFactor -eq 5) 'Host brute-force failureFactor must be five.'
Assert-Contract ($realm.waitIncrementSeconds -eq 60) 'Host brute-force waitIncrementSeconds must be 60.'
Assert-Contract ($realm.maxFailureWaitSeconds -eq 900) 'Host brute-force maxFailureWaitSeconds must be 900.'
Assert-Contract ($realm.revokeRefreshToken -eq $true) 'Host refresh tokens must rotate after use.'
Assert-Contract ($realm.refreshTokenMaxReuse -eq 0) 'A rotated Host refresh token must not be reusable.'
Assert-Contract ($realm.ssoSessionIdleTimeout -eq 1800) 'Host sessions must expire after 30 idle minutes.'
Assert-Contract ($realm.ssoSessionMaxLifespan -eq 28800) 'Host sessions must not exceed an eight-hour lifespan.'
Assert-Contract ($realm.clientSessionIdleTimeout -eq 1800) 'Host client sessions must expire after 30 idle minutes.'
Assert-Contract ($realm.clientSessionMaxLifespan -eq 28800) 'Host client sessions must not exceed an eight-hour lifespan.'
Assert-Contract ($realm.accessTokenLifespan -eq 300) 'Host access tokens must be bounded to five minutes.'
Assert-Contract ($realm.accessCodeLifespan -eq 60) 'Host authorization codes must be bounded to one minute.'
Assert-Contract ($realm.accessCodeLifespanUserAction -eq 300) 'Host user-action codes must be bounded to five minutes.'
Assert-Contract ($realm.actionTokenGeneratedByAdminLifespan -eq 900) 'Host admin action tokens must be bounded to 15 minutes.'
Assert-Contract ($realm.actionTokenGeneratedByUserLifespan -eq 900) 'Host user action tokens must be bounded to 15 minutes.'

$requiredActions = @($realm.requiredActions)
$verifyEmail = @($requiredActions | Where-Object alias -eq 'VERIFY_EMAIL')
$updatePassword = @($requiredActions | Where-Object alias -eq 'UPDATE_PASSWORD')
Assert-Contract ($verifyEmail.Count -eq 1 -and $verifyEmail[0].enabled -eq $true -and $verifyEmail[0].defaultAction -eq $true) 'VERIFY_EMAIL must be enabled and required for new Host identities.'
Assert-Contract ($updatePassword.Count -eq 1 -and $updatePassword[0].enabled -eq $true -and $updatePassword[0].defaultAction -eq $true) 'UPDATE_PASSWORD must be enabled and required for new Host identities.'
Assert-Contract ($verifyEmail[0].priority -lt $updatePassword[0].priority) 'Host required actions must verify email before password setup.'

$clients = @($realm.clients)
$hostApi = Get-Client -Clients $clients -ClientId 'vistay-host-api'
$hostWeb = Get-Client -Clients $clients -ClientId 'vistay-host-web'
Assert-Contract ($hostApi.bearerOnly -eq $true) 'Host API must be bearer-only.'
Assert-Contract ($hostApi.standardFlowEnabled -eq $false -and $hostApi.implicitFlowEnabled -eq $false -and $hostApi.directAccessGrantsEnabled -eq $false) 'Host API must not expose browser or password grants.'
Assert-Contract ($hostApi.serviceAccountsEnabled -eq $false) 'Host API must not create a service-account credential.'
Assert-Contract ($hostWeb.publicClient -eq $true) 'Host Web must be a public PKCE client.'
Assert-Contract ($hostWeb.standardFlowEnabled -eq $true) 'Host Web must use Authorization Code flow.'
Assert-Contract ($hostWeb.implicitFlowEnabled -eq $false -and $hostWeb.directAccessGrantsEnabled -eq $false) 'Host Web must disable implicit and direct grants.'
Assert-Contract ($hostWeb.serviceAccountsEnabled -eq $false) 'Host Web must not create a service-account credential.'
Assert-Contract (@($hostWeb.redirectUris).Count -eq 1 -and $hostWeb.redirectUris[0] -eq '${VISTAY_HOST_WEB_REDIRECT_URI}') 'Host Web must use one environment-backed exact redirect URI.'
Assert-Contract (-not $hostWeb.redirectUris[0].Contains('*')) 'Host Web redirect URIs must not contain wildcards.'
Assert-Contract (@($hostWeb.webOrigins).Count -eq 1 -and $hostWeb.webOrigins[0] -eq '${VISTAY_HOST_WEB_ORIGIN}') 'Host Web must use one environment-backed exact origin.'
Assert-Contract ($hostWeb.attributes.'pkce.code.challenge.method' -eq 'S256') 'Host Web must require PKCE S256.'
Assert-Contract ($hostWeb.attributes.'post.logout.redirect.uris' -eq '${VISTAY_HOST_POST_LOGOUT_REDIRECT_URI}') 'Host logout must use one environment-backed exact redirect.'
Assert-Contract ($envValues.VISTAY_HOST_WEB_REDIRECT_URI -eq 'http://host.localhost/oidc/callback') 'The local Host redirect URI must be exact and deterministic.'
Assert-Contract ($envValues.VISTAY_HOST_WEB_ORIGIN -eq 'http://host.localhost') 'The local Host origin must be exact and deterministic.'
Assert-Contract ($envValues.VISTAY_HOST_POST_LOGOUT_REDIRECT_URI -eq 'http://host.localhost/oidc/logout/callback') 'The local Host logout redirect must be exact and deterministic.'

$audienceMappers = @($hostWeb.protocolMappers | Where-Object name -eq 'host-api-audience')
Assert-Contract ($audienceMappers.Count -eq 1) 'Host Web must have exactly one API audience mapper.'
Assert-Contract ($audienceMappers[0].protocolMapper -eq 'oidc-audience-mapper') 'Host Web must use the OIDC audience mapper.'
Assert-Contract ($audienceMappers[0].config.'included.client.audience' -eq 'vistay-host-api') 'Host Web must emit the Host API audience.'
Assert-Contract ($audienceMappers[0].config.'access.token.claim' -eq 'true') 'Host API audience must be included in access tokens.'

Assert-Contract ($realm.smtpServer.host -eq '${VISTAY_HOST_SMTP_HOST}') 'Host SMTP host must be environment-backed.'
Assert-Contract ($realm.smtpServer.port -eq '${VISTAY_HOST_SMTP_PORT}') 'Host SMTP port must be environment-backed.'
Assert-Contract ($realm.smtpServer.from -eq '${VISTAY_HOST_SMTP_FROM}') 'Host SMTP sender must be environment-backed.'
Assert-Contract ($realm.smtpServer.auth -eq '${VISTAY_HOST_SMTP_AUTH}') 'Host SMTP auth setting must be environment-backed.'
Assert-Contract ($realm.smtpServer.starttls -eq '${VISTAY_HOST_SMTP_STARTTLS}') 'Host SMTP STARTTLS setting must be environment-backed.'
Assert-Contract ($realm.smtpServer.ssl -eq '${VISTAY_HOST_SMTP_SSL}') 'Host SMTP TLS setting must be environment-backed.'
Assert-Contract ($realm.smtpServer.password -eq '${VISTAY_HOST_SMTP_PASSWORD}') 'Host SMTP password must be a secret reference placeholder.'
Assert-Contract ($envValues.VISTAY_HOST_SMTP_HOST -eq 'mailpit') 'The local Host SMTP sink must be Mailpit.'
Assert-Contract ($envValues.VISTAY_HOST_SMTP_PORT -eq '1025') 'The local Host SMTP sink must use port 1025.'
Assert-Contract ($envValues.VISTAY_HOST_SMTP_AUTH -eq 'false' -and $envValues.VISTAY_HOST_SMTP_STARTTLS -eq 'false' -and $envValues.VISTAY_HOST_SMTP_SSL -eq 'false') 'The local Mailpit profile must not require production SMTP credentials.'

$composeArguments = @(
    'compose',
    '-f', (Join-Path $repositoryRoot 'compose.yaml'),
    '-f', $composePath,
    '--env-file', $envPath,
    '--profile', 'full',
    'config',
    '--format', 'json'
)
$configurationJson = & docker @composeArguments
if ($LASTEXITCODE -ne 0) {
    throw 'Full Compose configuration could not be rendered for the Host identity profile.'
}
$configuration = $configurationJson | ConvertFrom-Json
$mailpit = $configuration.services.mailpit
Assert-Contract ($null -ne $mailpit) 'Full Compose must define the local Mailpit service.'
Assert-Contract (@($mailpit.profiles) -contains 'epic01' -and @($mailpit.profiles) -contains 'full') 'Mailpit must be limited to the local Epic 01/full profiles.'
Assert-Contract ($mailpit.image -notmatch '(^|:)latest(@|$)') 'Mailpit must not use the latest image tag.'
Assert-Contract (@($mailpit.ports | Where-Object { $null -ne $_ }).Count -eq 1) 'Mailpit must publish exactly one loopback-only UI port.'
$mailpitUiPort = @($mailpit.ports | Where-Object { $null -ne $_ })[0]
Assert-Contract ($mailpitUiPort.host_ip -eq '127.0.0.1' -and $mailpitUiPort.target -eq 8025 -and $mailpitUiPort.published -eq '8025') 'Mailpit UI must bind to 127.0.0.1:8025 only.'
Assert-Contract (@($mailpit.expose) -contains '1025' -and @($mailpit.expose) -contains '8025') 'Mailpit must expose only its internal SMTP and UI ports.'
Assert-Contract ($mailpit.environment.MP_SMTP_BIND_ADDR -eq '0.0.0.0:1025') 'Mailpit SMTP must bind only to the Compose network port.'
Assert-Contract ($mailpit.environment.MP_UI_BIND_ADDR -eq '0.0.0.0:8025') 'Mailpit UI must bind only to the Compose network port.'
Assert-Contract ($mailpit.environment.MP_MAX_MESSAGES -eq '1000') 'Mailpit retention must be bounded.'
Assert-Contract ($null -ne $configuration.services.keycloak.depends_on.mailpit) 'Full Keycloak must wait for the local Mailpit profile.'
Assert-Contract ($configuration.services.keycloak.environment.VISTAY_HOST_SMTP_HOST -eq 'mailpit') 'Full Keycloak must use the internal Mailpit hostname.'

$report = [ordered]@{
    status = 'VALIDATED'
    correlationId = $correlationId
    errorCode = 'HOST_REALM_CONTRACT_OK'
    failureCode = $contractErrorCode
    contract = 'HOST_REALM_SESSION_RECOVERY_V1'
    realm = $realm.realm
    realmFingerprint = $realmFingerprint
    repeatability = 'CANONICAL_REALM_FINGERPRINT'
    baselineEnabled = $realm.enabled
    redirectPolicy = 'EXACT_ENVIRONMENT_BACKED_URI'
    pkce = 'S256_ONLY'
    sessionIdleSeconds = $realm.ssoSessionIdleTimeout
    sessionMaximumSeconds = $realm.ssoSessionMaxLifespan
    accessTokenSeconds = $realm.accessTokenLifespan
    mailCapture = 'MAILPIT_INTERNAL_ONLY'
    acceptanceCriteria = [ordered]@{
        AC01 = 'PKCE, verify-email, password setup, bounded sessions, recovery and local mail capture are validated.'
        AC02 = 'Wildcard redirects, implicit/direct grants, missing PKCE, unbound SMTP values and premature enablement fail closed.'
        AC03 = 'Realm/client/action configuration is deterministic and the disabled baseline is rollback-safe.'
    }
}
Write-Host ('Host realm contract report: ' + ($report | ConvertTo-Json -Compress))
