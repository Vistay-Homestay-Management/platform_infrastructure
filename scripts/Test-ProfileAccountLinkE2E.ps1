[CmdletBinding()]
param(
    [string]$CustomerGraphQlUrl = 'http://customer-api.localhost/graphql',
    [string]$IdentityUrl = 'http://identity.localhost',
    [string]$MailpitUrl = 'http://127.0.0.1:8025',
    [int]$TimeoutSeconds = 90,
    [switch]$KeepEvidence
)

$ErrorActionPreference = 'Stop'
$runId = [guid]::NewGuid().ToString('N').Substring(0, 12)
$clientId = "vistay-profile-link-e2e-$runId"
$email = "profile-link-$runId@example.test"
$password = "Vistay-E2E-$runId!"
$customerId = [guid]::NewGuid()
$documentId = [guid]::NewGuid()
$cccd = '099' + (([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() % 1000000000).ToString('000000000'))
$clientUuid = $null
$userUuid = $null
$linkId = $null
$challengeId = $null

function Invoke-GraphQl([string]$Token, [string]$Query, [hashtable]$Variables) {
    $headers = @{
        Authorization = "Bearer $Token"
        'X-CSRF-Token' = 'profile-link-e2e'
    }
    $body = @{ query = $Query; variables = $Variables } | ConvertTo-Json -Depth 12
    $response = Invoke-RestMethod -Method Post -Uri $CustomerGraphQlUrl -Headers $headers `
        -ContentType 'application/json' -Body $body
    if ($response.errors) {
        throw "GraphQL failed: $($response.errors | ConvertTo-Json -Depth 8 -Compress)"
    }
    return $response.data
}

function Invoke-UserSql([string]$Sql) {
    $Sql | & docker exec -i vistay-postgres-1 sh -c 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d vistay_user_db -At'
    if ($LASTEXITCODE -ne 0) { throw 'User database command failed.' }
}

function Invoke-AuthenticationSql([string]$Sql) {
    $Sql | & docker exec -i vistay-postgres-1 sh -c 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d vistay_authentication_db -At'
    if ($LASTEXITCODE -ne 0) { throw 'Authentication database command failed.' }
}

function Invoke-NotificationSql([string]$Sql) {
    $Sql | & docker exec -i vistay-postgres-1 sh -c 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d vistay_notification_db -At'
    if ($LASTEXITCODE -ne 0) { throw 'Notification database command failed.' }
}

try {
    $canonicalDocument = "VN:CCCD:v1:$cccd"
    $lookupHmac = (& docker exec vistay-vault-1 sh -ec `
        'export VAULT_ADDR=http://127.0.0.1:8200; export VAULT_TOKEN="$VAULT_DEV_ROOT_TOKEN_ID"; encoded=$(printf "%s" "$1" | base64 | tr -d "\n"); vault write -field=hmac transit/hmac/vistay-profile-lookup/sha2-256 input="$encoded"' `
        -- $canonicalDocument).Trim()
    if ($LASTEXITCODE -ne 0 -or !$lookupHmac.StartsWith('vault:v')) { throw 'Vault HMAC failed.' }

    $encryptedDocument = (& docker exec vistay-vault-1 sh -ec `
        'export VAULT_ADDR=http://127.0.0.1:8200; export VAULT_TOKEN="$VAULT_DEV_ROOT_TOKEN_ID"; encoded=$(printf "%s" "$1" | base64 | tr -d "\n"); vault write -field=ciphertext transit/encrypt/vistay-profile-document plaintext="$encoded"' `
        -- $canonicalDocument).Trim()
    if ($LASTEXITCODE -ne 0 -or !$encryptedDocument.StartsWith('vault:v')) { throw 'Vault encryption failed.' }

    $lookupVersion = [int](($lookupHmac -split ':')[1].Substring(1))
    $encryptionVersion = [int](($encryptedDocument -split ':')[1].Substring(1))
    Invoke-UserSql @"
SET search_path TO app, extensions, public;
INSERT INTO customers(id, full_name, email, profile_status, version)
VALUES ('$customerId', 'Profile Link E2E', '$email', 'ACTIVE', 1);
INSERT INTO profile_identity_documents(
    id, profile_type, profile_id, lookup_hmac, lookup_key_version,
    encrypted_value, encryption_key_version, assurance_level
) VALUES (
    '$documentId', 'CUSTOMER', '$customerId', '$lookupHmac', $lookupVersion,
    '$encryptedDocument', $encryptionVersion, 'CONTACT_VERIFIED'
);
"@

    $audienceMapper = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"name":"customer-api-audience","protocol":"openid-connect","protocolMapper":"oidc-audience-mapper","config":{"included.client.audience":"vistay-customer-api","access.token.claim":"true","id.token.claim":"false"}}'))
    $accountTypeMapper = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"name":"account_type","protocol":"openid-connect","protocolMapper":"oidc-hardcoded-claim-mapper","config":{"claim.name":"account_type","claim.value":"CUSTOMER","jsonType.label":"String","access.token.claim":"true"}}'))
    $keycloakScript = @'
set -euo pipefail
client_id="$1"
email="$2"
password="$3"
kcadm=/opt/keycloak/bin/kcadm.sh
$kcadm config credentials --server http://localhost:8080 --realm master --user "$KC_BOOTSTRAP_ADMIN_USERNAME" --password "$KC_BOOTSTRAP_ADMIN_PASSWORD" >/dev/null
client_uuid=$($kcadm create clients -r vistay-customer -s clientId="$client_id" -s enabled=true -s publicClient=true -s standardFlowEnabled=false -s directAccessGrantsEnabled=true -i)
roles_scope=$($kcadm get client-scopes -r vistay-customer --fields id,name --format csv --noquotes | grep ',roles$' | head -n 1 | cut -d, -f1)
test -z "$roles_scope" || $kcadm delete "clients/$client_uuid/default-client-scopes/$roles_scope" -r vistay-customer >/dev/null
printf '%s' "$4" | base64 -d | \
  $kcadm create "clients/$client_uuid/protocol-mappers/models" -r vistay-customer -f - >/dev/null
printf '%s' "$5" | base64 -d | \
  $kcadm create "clients/$client_uuid/protocol-mappers/models" -r vistay-customer -f - >/dev/null
user_uuid=$($kcadm create users -r vistay-customer -s username="$email" -s email="$email" \
  -s firstName=Profile -s lastName=Link -s emailVerified=true -s enabled=true -s 'requiredActions=[]' -i)
$kcadm set-password -r vistay-customer --userid "$user_uuid" --new-password "$password" --temporary=false >/dev/null
printf '%s\n%s\n' "$client_uuid" "$user_uuid"
'@
    $created = @(& docker exec vistay-keycloak-1 sh -ec $keycloakScript -- $clientId $email $password $audienceMapper $accountTypeMapper)
    if ($LASTEXITCODE -ne 0 -or $created.Count -lt 2) { throw 'Keycloak E2E identity creation failed.' }
    $clientUuid = $created[-2].Trim()
    $userUuid = $created[-1].Trim()

    $tokenResponse = Invoke-RestMethod -Method Post `
        -Uri "$IdentityUrl/realms/vistay-customer/protocol/openid-connect/token" `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body @{ grant_type = 'password'; client_id = $clientId; username = $email; password = $password; scope = 'openid email profile' }
    $token = $tokenResponse.access_token
    if (!$token) { throw 'Keycloak did not return an access token.' }
    $payloadSegment = ($token -split '\.')[1].Replace('-', '+').Replace('_', '/')
    $payloadSegment = $payloadSegment.PadRight($payloadSegment.Length + ((4 - $payloadSegment.Length % 4) % 4), '=')
    $tokenClaims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payloadSegment)) | ConvertFrom-Json
    $tokenAudience = @($tokenClaims.aud)
    if ($tokenAudience -notcontains 'vistay-customer-api') {
        throw "Customer API audience mapper failed. Token audiences: $($tokenAudience -join ',')"
    }
    Write-Verbose "JWT issuer=$($tokenClaims.iss) audience=$($tokenAudience -join ',') accountType=$($tokenClaims.account_type)"

    $null = Invoke-GraphQl $token `
        'query { myProfileLinkStatus { status profileType } }' @{}
    $requested = Invoke-GraphQl $token @'
mutation Request($input: RequestProfileLinkInput!) {
  requestMyProfileLink(input: $input) {
    linkId challengeId profileType status maskedRecipient expiresAt requiresApproval
  }
}
'@ @{ input = @{ displayName = 'Profile Link E2E'; cccd = $cccd } }
    $link = $requested.requestMyProfileLink
    if ($link.status -ne 'CHALLENGE_ISSUED') { throw "Unexpected request status: $($link.status)" }
    $linkId = $link.linkId
    $challengeId = $link.challengeId

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $otp = $null
    do {
        Start-Sleep -Milliseconds 750
        $messages = Invoke-RestMethod -Uri "$MailpitUrl/api/v1/messages"
        $message = @($messages.messages | Where-Object {
            ($_.To | ConvertTo-Json -Compress) -match [regex]::Escape($email)
        } | Select-Object -First 1)
        if ($message) {
            $detail = Invoke-RestMethod -Uri "$MailpitUrl/api/v1/message/$($message[0].ID)"
            $content = "$($detail.Text) $($detail.HTML)"
            $match = [regex]::Match($content, '(?<!\d)(\d{6})(?!\d)')
            if ($match.Success) { $otp = $match.Groups[1].Value }
        }
    } while (!$otp -and [DateTime]::UtcNow -lt $deadline)
    if (!$otp) { throw 'Mailpit did not receive the profile-link OTP in time.' }

    $verified = Invoke-GraphQl $token @'
mutation Verify($input: VerifyProfileLinkInput!) {
  verifyMyProfileLink(input: $input) {
    linkId profileType status requiresApproval
  }
}
'@ @{ input = @{ challengeId = $challengeId; code = $otp } }
    if ($verified.verifyMyProfileLink.status -ne 'LINKED') {
        throw "Unexpected verify status: $($verified.verifyMyProfileLink.status)"
    }

    $userEvidence = (Invoke-UserSql @"
SET search_path TO app, extensions, public;
SELECT l.status || '|' || c.status || '|' || (p.auth_account_id = '$userUuid')
FROM profile_account_links l
JOIN profile_link_challenges c ON c.link_id = l.id
JOIN customers p ON p.id = l.profile_id
WHERE l.id = '$linkId' AND c.id = '$challengeId';
"@ | Select-Object -Last 1).Trim()
    if ($userEvidence -ne 'LINKED|VERIFIED|true') { throw "User projection mismatch: $userEvidence" }

    $projectionDeadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $authEvidence = $null
    do {
        Start-Sleep -Milliseconds 750
        $authEvidence = (Invoke-AuthenticationSql @"
SET search_path TO app, extensions, public;
SELECT status || '|' || COALESCE(profile_id::text, '')
FROM identity_accounts
WHERE id = '$userUuid';
"@ | Select-Object -Last 1).Trim()
    } while ($authEvidence -ne "ACTIVE|$customerId" -and [DateTime]::UtcNow -lt $projectionDeadline)
    if ($authEvidence -ne "ACTIVE|$customerId") {
        throw "Authentication projection mismatch: $authEvidence"
    }

    $keycloakProfileJson = (& docker exec vistay-keycloak-1 sh -ec `
        'kcadm=/opt/keycloak/bin/kcadm.sh; $kcadm config credentials --server http://localhost:8080 --realm master --user "$KC_BOOTSTRAP_ADMIN_USERNAME" --password "$KC_BOOTSTRAP_ADMIN_PASSWORD" >/dev/null; $kcadm get "users/$1" -r vistay-customer' `
        -- $userUuid) | Out-String
    if ($LASTEXITCODE -ne 0) { throw 'Keycloak profile projection query failed.' }
    $keycloakProfile = $keycloakProfileJson | ConvertFrom-Json
    $keycloakProfileId = @($keycloakProfile.attributes.vistay_profile_id)[0]
    if ($keycloakProfileId -ne $customerId.ToString()) {
        throw "Keycloak profile attribute mismatch: $keycloakProfileId; payload=$($keycloakProfileJson.Trim())"
    }

    Write-Output ([pscustomobject]@{
        result = 'PASS'
        accountId = $userUuid
        profileId = $customerId
        linkId = $linkId
        challengeId = $challengeId
        mailRecipient = $email
        userProjection = $userEvidence
        authenticationProjection = $authEvidence
        keycloakProfileId = $keycloakProfileId
    } | ConvertTo-Json -Compress)
}
finally {
    if ($clientId) {
        $cleanupScript = @'
set +e
kcadm=/opt/keycloak/bin/kcadm.sh
$kcadm config credentials --server http://localhost:8080 --realm master --user "$KC_BOOTSTRAP_ADMIN_USERNAME" --password "$KC_BOOTSTRAP_ADMIN_PASSWORD" >/dev/null 2>&1
test -z "$1" || $kcadm delete "users/$1" -r vistay-customer >/dev/null 2>&1
if test -n "$2"; then
  $kcadm delete "clients/$2" -r vistay-customer >/dev/null 2>&1
elif test -n "$3"; then
  discovered=$($kcadm get clients -r vistay-customer -q clientId="$3" --fields id --format csv --noquotes 2>/dev/null | head -n 1)
  test -z "$discovered" || $kcadm delete "clients/$discovered" -r vistay-customer >/dev/null 2>&1
fi
'@
        & docker exec vistay-keycloak-1 sh -ec $cleanupScript -- "$userUuid" "$clientUuid" "$clientId" | Out-Null
    }
    if (!$KeepEvidence) {
        try {
            if ($challengeId) {
                Invoke-NotificationSql @"
SET search_path TO app, extensions, public;
DELETE FROM profile_link_email_deliveries WHERE challenge_id = '$challengeId';
"@ | Out-Null
            }
            Invoke-UserSql @"
SET search_path TO app, extensions, public;
BEGIN;
CREATE TEMP TABLE e2e_subject AS
SELECT authorization_subject_id FROM customers WHERE id = '$customerId';
DELETE FROM profile_link_challenges
WHERE link_id IN (SELECT id FROM profile_account_links WHERE profile_type = 'CUSTOMER' AND profile_id = '$customerId');
DELETE FROM profile_account_links WHERE profile_type = 'CUSTOMER' AND profile_id = '$customerId';
DELETE FROM profile_identity_documents WHERE profile_type = 'CUSTOMER' AND profile_id = '$customerId';
DELETE FROM customers WHERE id = '$customerId';
DELETE FROM authorization_subjects
WHERE id IN (SELECT authorization_subject_id FROM e2e_subject WHERE authorization_subject_id IS NOT NULL);
COMMIT;
"@ | Out-Null
            if ($userUuid) {
                Invoke-AuthenticationSql @"
SET search_path TO app, extensions, public;
DELETE FROM identity_accounts WHERE id = '$userUuid';
DELETE FROM pending_profile_link_completions WHERE account_id = '$userUuid';
"@ | Out-Null
            }
        }
        catch {
            Write-Warning "E2E evidence cleanup needs attention: $($_.Exception.Message)"
        }
    }
}
