[CmdletBinding()]
param(
    [switch]$StaticOnly,
    [switch]$Live,
    [string]$CollectionPath,
    [string]$EnvironmentPath,
    [string]$EvidenceDirectory,
    [securestring]$AdminSiteAccessToken,
    [securestring]$AdminBranchAccessToken,
    [securestring]$AdminOtherSiteAccessToken,
    [securestring]$BackofficeAccessToken,
    [securestring]$WrongAudienceAccessToken,
    [securestring]$HostAccessToken,
    [securestring]$HostAuthorizationCode
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($CollectionPath)) {
    $CollectionPath = Join-Path $repositoryRoot 'postman\ViStay-Host-Identity-v1.postman_collection.json'
}
if ([string]::IsNullOrWhiteSpace($EnvironmentPath)) {
    $EnvironmentPath = Join-Path $repositoryRoot 'postman\ViStay-Host-Identity-local.postman_environment.example.json'
}
if ([string]::IsNullOrWhiteSpace($EvidenceDirectory)) {
    $EvidenceDirectory = Join-Path $repositoryRoot 'artifacts\postman-host-identity'
}

$errorCode = 'HOST_POSTMAN_CONTRACT_INVALID'
$correlationId = "SCRUM-815-HOST-POSTMAN-$([guid]::NewGuid().ToString('N'))"

function Assert-Contract {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw "$errorCode [$correlationId] $Message"
    }
}

function Get-PostmanRequests {
    param([object[]]$Items)

    foreach ($item in $Items) {
        if ($null -ne $item.request) {
            $item
        }
        if ($null -ne $item.item) {
            Get-PostmanRequests -Items @($item.item)
        }
    }
}

function Get-EventSource {
    param(
        [object[]]$Events,
        [string]$Listener
    )

    @($Events | Where-Object listen -eq $Listener |
        ForEach-Object { $_.script.exec }) -join [Environment]::NewLine
}

function Convert-PostmanBodyToJson {
    param(
        [string]$RequestName,
        [object]$Request
    )

    if ($Request.body.mode -ne 'raw') {
        return
    }

    $contentType = @($Request.header | Where-Object key -match '^Content-Type$' |
        Select-Object -First 1).value
    if ($contentType -notmatch 'application/json') {
        return
    }

    $parseable = [string]$Request.body.raw
    # A numeric replacement keeps both quoted string variables and unquoted
    # version variables valid JSON for the static parser.
    $parseable = $parseable -replace '\{\{[^}]+\}\}', '1'
    try {
        $null = $parseable | ConvertFrom-Json
    }
    catch {
        throw "$errorCode [$correlationId] Request '$RequestName' does not contain parseable JSON: $($_.Exception.Message)"
    }
}

function Assert-PostmanScriptSyntax {
    param(
        [object]$Collection,
        [string]$TempDirectory
    )

    $node = Get-Command node -ErrorAction SilentlyContinue
    Assert-Contract ($null -ne $node) 'Node.js is required to syntax-check Postman JavaScript.'
    $ordinal = 0
    foreach ($item in @(Get-PostmanRequests -Items @($Collection.item))) {
        foreach ($event in @($item.event)) {
            $source = @($event.script.exec) -join [Environment]::NewLine
            if ([string]::IsNullOrWhiteSpace($source)) {
                continue
            }

            $ordinal++
            $path = Join-Path $TempDirectory ("postman-script-{0}.js" -f $ordinal)
            Set-Content -LiteralPath $path -Value $source -Encoding UTF8
            $output = & $node.Source --check $path 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "$errorCode [$correlationId] Postman JavaScript syntax failed for '$($item.name)': $($output -join ' ')"
            }
        }
    }
}

function Get-SecretPlainText {
    param(
        [securestring]$Value,
        [string]$Prompt
    )

    if ($null -eq $Value) {
        $Value = Read-Host -Prompt $Prompt -AsSecureString
    }
    $credential = New-Object System.Net.NetworkCredential('', $Value)
    return $credential.Password
}

function Set-EnvironmentValue {
    param(
        [object]$Environment,
        [string]$Key,
        [string]$Value
    )

    $entry = @($Environment.values | Where-Object key -eq $Key | Select-Object -First 1)
    Assert-Contract ($entry.Count -eq 1) "Environment is missing runtime key '$Key'."
    $entry[0].value = $Value
}

function Redact-Report {
    param(
        [string]$Path,
        [hashtable]$Secrets
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return
    }

    $text = Get-Content -Raw -LiteralPath $Path
    foreach ($secret in $Secrets.Values) {
        if (-not [string]::IsNullOrWhiteSpace([string]$secret)) {
            $text = $text.Replace([string]$secret, '[REDACTED]')
        }
    }
    $text = [regex]::Replace($text, '(?i)(Bearer\s+)[^\s"<]+', '$1[REDACTED]')
    $text = [regex]::Replace($text, '(?i)("(?:access_token|refresh_token|id_token_hint|code_verifier|password)"\s*:\s*")[^"]*(")', '$1[REDACTED]$2')
    Set-Content -LiteralPath $Path -Value $text -Encoding UTF8
}

Assert-Contract (-not ($StaticOnly -and $Live)) 'StaticOnly and Live cannot be used together.'
Assert-Contract (Test-Path -LiteralPath $CollectionPath -PathType Leaf) "Missing collection '$CollectionPath'."
Assert-Contract (Test-Path -LiteralPath $EnvironmentPath -PathType Leaf) "Missing environment '$EnvironmentPath'."

$collection = Get-Content -Raw -LiteralPath $CollectionPath | ConvertFrom-Json
$environment = Get-Content -Raw -LiteralPath $EnvironmentPath | ConvertFrom-Json
$collectionRaw = Get-Content -Raw -LiteralPath $CollectionPath
$environmentRaw = Get-Content -Raw -LiteralPath $EnvironmentPath

Assert-Contract ($collection.info.name -eq 'ViStay Host Identity Lifecycle v1') 'Host collection name is not the published v1 name.'
Assert-Contract ($collection.info.schema -eq 'https://schema.getpostman.com/json/collection/v2.1.0/collection.json') 'Host collection must be Postman v2.1.'
foreach ($marker in @('PKCE', 'S256', 'Mailpit', 'repair-safe', 'HOST', 'redacted')) {
    Assert-Contract ($collectionRaw.Contains($marker)) "Host collection is missing contract marker '$marker'."
}

$rootPrerequest = Get-EventSource -Events @($collection.event) -Listener 'prerequest'
Assert-Contract ($rootPrerequest.Contains('runHostIdentity')) 'The collection must have a safe runHostIdentity guard.'
Assert-Contract ($rootPrerequest.Contains('pm.execution.skipRequest()')) 'The collection must skip requests when the run flag is false.'
foreach ($marker in @('pkceCodeVerifier', 'pkceCodeChallenge', 'hostState', 'hostNonce', 'CryptoJS', 'SHA256')) {
    Assert-Contract ($rootPrerequest.Contains($marker)) "The collection pre-request script is missing runtime marker '$marker'."
}

$requests = @(Get-PostmanRequests -Items @($collection.item))
$requestByName = @{}
foreach ($request in $requests) {
    Assert-Contract (-not $requestByName.ContainsKey($request.name)) "Duplicate Postman request name '$($request.name)'."
    $requestByName[$request.name] = $request
    Convert-PostmanBodyToJson -RequestName $request.name -Request $request.request
}
Assert-Contract ($requests.Count -eq 28) "Host collection must contain exactly 28 named scenarios; found $($requests.Count)."

$requiredFolders = @(
    '01 Invite and repair-safe replay',
    '02 Activation and PKCE token claims',
    '03 Host self profile',
    '04 Admin lifecycle and sessions',
    '05 Authorization negatives and recovery'
)
foreach ($folder in $requiredFolders) {
    Assert-Contract (@($collection.item | Where-Object name -eq $folder).Count -eq 1) "Missing Host evidence folder '$folder'."
}

$requiredRequests = [ordered]@{
    'Issue Host invitation' = @{ Url = '{{authBase}}/v1/host/invitations'; Marker = 'hostInvitationId' }
    'Replay exact Host invitation' = @{ Url = '{{authBase}}/v1/host/invitations'; Marker = 'replayed' }
    'Reject changed invitation payload for reused key' = @{ Url = '{{authBase}}/v1/host/invitations'; Marker = 'IDEMPOTENCY' }
    'Find captured Host invitation email' = @{ Url = '{{mailpitApiBase}}/api/v1/messages?limit=100'; Marker = 'hostMailMessageId' }
    'Read captured Host activation action link' = @{ Url = '{{mailpitApiBase}}/api/v1/message/{{hostMailMessageId}}'; Marker = 'KEYCLOAK_ACTIVATION_REF' }
    'Begin Host authorization code with PKCE' = @{ Url = '{{identityBase}}/realms/vistay-host/protocol/openid-connect/auth?client_id=vistay-host-web&response_type=code&redirect_uri={{hostRedirectUri}}&scope=openid%20profile%20email&state={{hostState}}&nonce={{hostNonce}}&code_challenge={{pkceCodeChallenge}}&code_challenge_method=S256&login_hint={{hostInvitationEmail}}'; Marker = 'code_challenge_method=S256' }
    'Activate Host invitation' = @{ Url = '{{authBase}}/v1/host/invitations/{{hostInvitationId}}/activate'; Marker = 'hostAccountId' }
    'Replay Host activation' = @{ Url = '{{authBase}}/v1/host/invitations/{{hostInvitationId}}/activate'; Marker = 'repair-safe' }
    'Exchange authorization code for Host token' = @{ Url = '{{identityBase}}/realms/vistay-host/protocol/openid-connect/token'; Marker = 'code_verifier' }
    'Assert Host token claims' = @{ Url = '{{identityBase}}/realms/vistay-host/protocol/openid-connect/userinfo'; Marker = 'vistay-host-api' }
    'Find captured Host recovery email' = @{ Url = '{{mailpitApiBase}}/api/v1/messages?limit=100'; Marker = 'hostRecoveryMessageId' }
    'Host viewer' = @{ Url = '{{hostGraphqlUrl}}'; Marker = 'myProfile' }
    'Update Host profile' = @{ Url = '{{hostGraphqlUrl}}'; Marker = 'updateMyProfile' }
    'Replay exact Host profile update' = @{ Url = '{{hostGraphqlUrl}}'; Marker = 'replayed' }
    'Reject stale Host profile version' = @{ Url = '{{hostGraphqlUrl}}'; Marker = 'STALE_VERSION' }
    'Reject restricted Host profile field' = @{ Url = '{{hostGraphqlUrl}}'; Marker = 'FIELD_GROUP_DENIED' }
    'Admin lists Host sessions' = @{ Url = '{{authBase}}/api/v1/backoffice/accounts/{{hostAccountId}}/sessions'; Marker = 'sessions' }
    'Suspend Host account' = @{ Url = '{{authBase}}/v1/host/lifecycle/commands'; Marker = 'SUSPENDED' }
    'Replay exact Host suspension command' = @{ Url = '{{authBase}}/v1/host/lifecycle/commands'; Marker = 'idempotent' }
    'Reactivate Host account' = @{ Url = '{{authBase}}/v1/host/lifecycle/commands'; Marker = 'ACTIVE' }
    'Admin revokes Host session' = @{ Url = '{{authBase}}/v1/host/sessions/{{hostSessionId}}/revoke'; Marker = 'REVOKED' }
    'Host logout' = @{ Url = '{{identityBase}}/realms/vistay-host/protocol/openid-connect/logout'; Marker = 'id_token_hint' }
    'Reject Backoffice token on Host viewer' = @{ Url = '{{hostGraphqlUrl}}'; Marker = 'HOST_WRONG_REALM_OR_AUDIENCE' }
    'Reject wrong audience Host token' = @{ Url = '{{hostGraphqlUrl}}'; Marker = 'HOST_WRONG_REALM_OR_AUDIENCE' }
    'Reject Host subject from wrong partition' = @{ Url = '{{authBase}}/v1/host/lifecycle/commands'; Marker = 'HOST_PARTITION_FORBIDDEN' }
    'Reject Host access to foreign profile' = @{ Url = '{{hostGraphqlUrl}}'; Marker = 'HOST_PARTITION_FORBIDDEN' }
    'Anonymous Host viewer is rejected' = @{ Url = '{{hostGraphqlUrl}}'; Marker = 'UNAUTHENTICATED' }
    'Reject restricted field group' = @{ Url = '{{hostGraphqlUrl}}'; Marker = 'FIELD_GROUP_DENIED' }
}

foreach ($entry in $requiredRequests.GetEnumerator()) {
    Assert-Contract ($requestByName.ContainsKey($entry.Key)) "Missing Host scenario '$($entry.Key)'."
    $request = $requestByName[$entry.Key]
    Assert-Contract ($request.request.url -eq $entry.Value.Url) "Host scenario '$($entry.Key)' must use '$($entry.Value.Url)'."
    $testSource = Get-EventSource -Events @($request.event) -Listener 'test'
    $evidence = ([string]$request.request.body.raw) + [Environment]::NewLine + $testSource
    Assert-Contract ($testSource.Contains('pm.test(')) "Host scenario '$($entry.Key)' has no executable pm.test assertion."
    Assert-Contract ($evidence.Contains($entry.Value.Marker)) "Host scenario '$($entry.Key)' is missing evidence marker '$($entry.Value.Marker)'."
}

foreach ($pair in @(
    @{ Original = 'Issue Host invitation'; Replay = 'Replay exact Host invitation' },
    @{ Original = 'Activate Host invitation'; Replay = 'Replay Host activation' },
    @{ Original = 'Update Host profile'; Replay = 'Replay exact Host profile update' },
    @{ Original = 'Suspend Host account'; Replay = 'Replay exact Host suspension command' }
)) {
    $originalBody = [string]$requestByName[$pair.Original].request.body.raw
    $replayBody = [string]$requestByName[$pair.Replay].request.body.raw
    Assert-Contract ($originalBody -ceq $replayBody) "The repair-safe replay '$($pair.Replay)' must use a byte-identical body."
}

$changedBody = [string]$requestByName['Reject changed invitation payload for reused key'].request.body.raw
$inviteBody = [string]$requestByName['Issue Host invitation'].request.body.raw
Assert-Contract ($changedBody -cne $inviteBody) 'Changed invitation replay must alter the canonical payload.'
$changedKey = @($requestByName['Reject changed invitation payload for reused key'].request.header |
    Where-Object key -eq 'Idempotency-Key' | Select-Object -First 1).value
$inviteKey = @($requestByName['Issue Host invitation'].request.header |
    Where-Object key -eq 'Idempotency-Key' | Select-Object -First 1).value
Assert-Contract ($changedKey -eq '{{hostInvitationKey}}' -and $changedKey -eq $inviteKey) 'Changed invitation replay must reuse the original idempotency key.'

$hostIdentityEnvironmentKeys = @(
    'authBase', 'identityBase', 'hostGraphqlUrl', 'mailpitApiBase', 'hostRedirectUri',
    'hostLogoutRedirectUri', 'runHostIdentity', 'adminSiteAccessToken',
    'adminBranchAccessToken', 'adminOtherSiteAccessToken', 'backofficeAccessToken',
    'wrongAudienceAccessToken', 'hostAccessToken', 'hostAuthorizationCode',
    'hostActivationReference', 'hostActionLink', 'hostIdTokenHint', 'hostInvitationEmail',
    'hostInvitationKey', 'hostActivationKey', 'hostProfileUpdateKey', 'hostLifecycleKey',
    'hostSessionRevokeKey', 'hostForeignPartitionKey', 'hostForeignProfileKey',
    'hostStaleProfileKey', 'pkceCodeVerifier', 'pkceCodeChallenge', 'hostState', 'hostNonce'
)
$environmentByKey = @{}
foreach ($entry in @($environment.values)) {
    Assert-Contract (-not $environmentByKey.ContainsKey($entry.key)) "Duplicate environment key '$($entry.key)'."
    $environmentByKey[$entry.key] = $entry
}
foreach ($key in $hostIdentityEnvironmentKeys) {
    Assert-Contract ($environmentByKey.ContainsKey($key)) "Environment is missing key '$key'."
}

$secretKeys = @(
    'adminSiteAccessToken', 'adminBranchAccessToken', 'adminOtherSiteAccessToken',
    'backofficeAccessToken', 'wrongAudienceAccessToken', 'hostAccessToken',
    'hostAuthorizationCode', 'hostActivationReference', 'hostActionLink', 'hostIdTokenHint',
    'pkceCodeVerifier', 'pkceCodeChallenge', 'hostState', 'hostNonce'
)
foreach ($key in $secretKeys) {
    Assert-Contract ($environmentByKey[$key].type -eq 'secret') "Runtime secret '$key' must be marked as a Postman secret variable."
    Assert-Contract ([string]::IsNullOrEmpty([string]$environmentByKey[$key].value)) "Secret environment variable '$key' must have an empty checked-in value."
}
Assert-Contract ($environmentByKey['runHostIdentity'].value -eq 'false') 'Host evidence must be disabled by default.'
Assert-Contract ($environmentByKey['mailpitApiBase'].value -eq 'http://mailpit:8025') 'Mailpit must use its internal Compose alias and port.'
Assert-Contract ($environmentByKey['hostRedirectUri'].value -eq 'http://host.localhost/oidc/callback') 'Host redirect URI must match the exact local PKCE client contract.'
Assert-Contract ($environmentByKey['hostLogoutRedirectUri'].value -eq 'http://host.localhost/oidc/logout/callback') 'Host logout redirect URI must match the exact local client contract.'

Assert-Contract ($collectionRaw -notmatch '(?i)Bearer\s+(?!\{\{)[A-Za-z0-9._-]{12,}') 'Collection contains a hard-coded bearer value.'
Assert-Contract ($collectionRaw -notmatch '(?i)eyJ[A-Za-z0-9_-]{20,}') 'Collection contains a JWT-like literal.'
Assert-Contract ($environmentRaw -notmatch '(?i)eyJ[A-Za-z0-9_-]{20,}') 'Environment contains a JWT-like literal.'
Assert-Contract ($environmentRaw -notmatch '(?i)postgres(?:ql)?://|password\s*=\s*[^\r\n]+') 'Environment contains a connection credential.'
Assert-Contract ($collectionRaw -notmatch '(?i)"(?:password|refresh_token|access_token|cookie)"\s*:\s*"(?!\{\{)[^"]+"') 'Collection contains a checked-in credential value.'

$tempSyntaxDirectory = Join-Path ([IO.Path]::GetTempPath()) ("vistay-host-postman-$([guid]::NewGuid().ToString('N'))")
New-Item -ItemType Directory -Path $tempSyntaxDirectory -Force | Out-Null
try {
    Assert-PostmanScriptSyntax -Collection $collection -TempDirectory $tempSyntaxDirectory
}
finally {
    if (Test-Path -LiteralPath $tempSyntaxDirectory) {
        Remove-Item -LiteralPath $tempSyntaxDirectory -Recurse -Force
    }
}

$staticReport = [ordered]@{
    status = 'STATIC_VALIDATED'
    correlationId = $correlationId
    errorCode = 'HOST_POSTMAN_CONTRACT_OK'
    failureCode = $errorCode
    contract = 'HOST_IDENTITY_LIFECYCLE_POSTMAN_V1'
    collection = Split-Path -Leaf $CollectionPath
    environmentTemplate = Split-Path -Leaf $EnvironmentPath
    requestCount = $requests.Count
    pkce = 'S256_RUNTIME_VERIFIER_CHALLENGE_STATE_NONCE'
    mailCapture = 'MAILPIT_INTERNAL_API_NO_PUBLIC_PORT'
    partitions = @('ADMIN:SITE', 'ADMIN:BRANCH', 'ADMIN:OTHER-SITE_NEGATIVE', 'HOST:SELF')
    secrets = 'NO_CHECKED_IN_VALUES; LIVE_REPORTS_REDACTED'
    replay = 'INVITATION_ACTIVATION_PROFILE_LIFECYCLE_BYTE_IDENTICAL'
    acceptanceCriteria = [ordered]@{
        AC01 = 'Positive invitation, activation, PKCE claims, profile, lifecycle/session and named negative/replay scenarios are present and asserted.'
        AC02 = 'Missing contract markers, leaked values, duplicate effects and wrong realm/audience/partition fail with stable diagnostics.'
        AC03 = 'Safe defaults, deterministic keys, byte-identical replay and isolated runtime evidence prevent duplicate fixture effects.'
    }
}

$staticReportPath = Join-Path ([IO.Path]::GetTempPath()) ("vistay-host-postman-static-$($correlationId).json")
$staticReport | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $staticReportPath -Encoding UTF8
Write-Output ('Host identity Postman static report: ' + ($staticReport | ConvertTo-Json -Compress))

if ($StaticOnly) {
    Write-Output "HOST_POSTMAN_STATIC_OK [$correlationId] report=$staticReportPath"
    exit 0
}

if (-not $Live -and $env:VISTAY_HOST_POSTMAN_LIVE -ne 'true') {
    $skipReport = [ordered]@{
        status = 'STATIC_VALIDATED_LIVE_NOT_RUN'
        correlationId = $correlationId
        live = 'Set VISTAY_HOST_POSTMAN_LIVE=true or pass -Live after supplying short-lived secure tokens.'
        report = $staticReportPath
    }
    Write-Output ('Host identity Postman live status: ' + ($skipReport | ConvertTo-Json -Compress))
    exit 0
}

$runtimeEnvironment = Get-Content -Raw -LiteralPath $EnvironmentPath | ConvertFrom-Json
$secretsForRedaction = @{}
$runtimeSecrets = [ordered]@{
    adminSiteAccessToken = Get-SecretPlainText -Value $AdminSiteAccessToken -Prompt 'Admin SITE access token'
    adminBranchAccessToken = Get-SecretPlainText -Value $AdminBranchAccessToken -Prompt 'Admin BRANCH access token'
    adminOtherSiteAccessToken = Get-SecretPlainText -Value $AdminOtherSiteAccessToken -Prompt 'Admin other-site access token'
    backofficeAccessToken = Get-SecretPlainText -Value $BackofficeAccessToken -Prompt 'Backoffice wrong-realm token'
    wrongAudienceAccessToken = Get-SecretPlainText -Value $WrongAudienceAccessToken -Prompt 'Wrong-audience token'
    hostAccessToken = Get-SecretPlainText -Value $HostAccessToken -Prompt 'Host access token'
    hostAuthorizationCode = Get-SecretPlainText -Value $HostAuthorizationCode -Prompt 'Host PKCE authorization code'
}
foreach ($entry in $runtimeSecrets.GetEnumerator()) {
    Assert-Contract (-not [string]::IsNullOrWhiteSpace($entry.Value)) "Live token/code '$($entry.Key)' cannot be empty."
    Set-EnvironmentValue -Environment $runtimeEnvironment -Key $entry.Key -Value $entry.Value
    $secretsForRedaction[$entry.Key] = $entry.Value
}
Set-EnvironmentValue -Environment $runtimeEnvironment -Key 'runHostIdentity' -Value 'true'

$npx = Get-Command npx -ErrorAction SilentlyContinue
Assert-Contract ($null -ne $npx) 'npx is required for live Newman evidence.'
New-Item -ItemType Directory -Path $EvidenceDirectory -Force | Out-Null
$tempEnvironmentPath = Join-Path ([IO.Path]::GetTempPath()) ("vistay-host-postman-$([guid]::NewGuid().ToString('N')).json")
$jsonReportPath = Join-Path $EvidenceDirectory ("host-identity-$($correlationId).json")
$junitReportPath = Join-Path $EvidenceDirectory ("host-identity-$($correlationId).xml")
$runtimeEnvironment | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $tempEnvironmentPath -Encoding UTF8
try {
    & $npx.Source --yes newman@6.2.1 run $CollectionPath `
        --environment $tempEnvironmentPath `
        --reporters cli,json,junit `
        --reporter-json-export $jsonReportPath `
        --reporter-junit-export $junitReportPath `
        --bail
    $newmanExitCode = $LASTEXITCODE
}
finally {
    if (Test-Path -LiteralPath $tempEnvironmentPath) {
        Remove-Item -LiteralPath $tempEnvironmentPath -Force
    }
}
Redact-Report -Path $jsonReportPath -Secrets $secretsForRedaction
Redact-Report -Path $junitReportPath -Secrets $secretsForRedaction

Assert-Contract ($newmanExitCode -eq 0) "Newman Host identity flow failed; redacted evidence is at '$EvidenceDirectory'."
$liveReport = [ordered]@{
    status = 'LIVE_VALIDATED'
    correlationId = $correlationId
    errorCode = 'HOST_POSTMAN_LIVE_OK'
    collection = Split-Path -Leaf $CollectionPath
    jsonEvidence = Split-Path -Leaf $jsonReportPath
    junitEvidence = Split-Path -Leaf $junitReportPath
    redaction = 'Bearer/access_token/refresh_token/id_token_hint/code_verifier/password values replaced before handoff.'
    cleanup = 'Temporary Postman environment removed; fixture replay keys remain runtime-scoped.'
}
Write-Output ('Host identity Postman live report: ' + ($liveReport | ConvertTo-Json -Compress))
