[CmdletBinding()]
param(
    [string]$GraphQlUrl = 'http://graphql.localhost/graphql',
    [string]$IdentityUrl = 'http://identity.localhost',
    [string]$PropertyId = '61000000-0000-4000-8000-000000000001'
)

$ErrorActionPreference = 'Stop'
$runId = [guid]::NewGuid().ToString('N').Substring(0, 12)
$clientId = "vistay-property-authority-e2e-$runId"
$email = "property-authority-$runId@example.test"
$password = "Vistay-E2E-$runId!"
$clientUuid = $null
$userUuid = $null

function Invoke-UserSql([string]$Sql) {
    $Sql | & docker exec -i vistay-postgres-1 sh -c `
        'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d vistay_user_db -At'
    if ($LASTEXITCODE -ne 0) { throw 'User database command failed.' }
}

try {
    $audienceMapper = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(
        '{"name":"backoffice-api-audience","protocol":"openid-connect","protocolMapper":"oidc-audience-mapper","config":{"included.client.audience":"vistay-backoffice-api","access.token.claim":"true","id.token.claim":"false"}}'))
    $accountTypeMapper = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(
        '{"name":"account_type","protocol":"openid-connect","protocolMapper":"oidc-hardcoded-claim-mapper","config":{"claim.name":"account_type","claim.value":"ADMIN","jsonType.label":"String","access.token.claim":"true"}}'))
    $roleMapper = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(
        '{"name":"vistay-api-client-roles","protocol":"openid-connect","protocolMapper":"oidc-usermodel-client-role-mapper","config":{"user.attribute":"foo","usermodel.clientRoleMapping.clientId":"vistay-backoffice-api","claim.name":"resource_access.${client_id}.roles","jsonType.label":"String","multivalued":"true","access.token.claim":"true"}}'))
    $subjectMapper = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(
        '{"name":"subject","protocol":"openid-connect","protocolMapper":"oidc-sub-mapper","config":{"access.token.claim":"true","introspection.token.claim":"true"}}'))

    $keycloakScript = @'
set -eu
client_id="$1"
email="$2"
password="$3"
kcadm=/opt/keycloak/bin/kcadm.sh
$kcadm config credentials --server http://localhost:8080 --realm master --user "$KC_BOOTSTRAP_ADMIN_USERNAME" --password "$KC_BOOTSTRAP_ADMIN_PASSWORD" >/dev/null
client_uuid=$($kcadm create clients -r vistay-backoffice -s clientId="$client_id" -s enabled=true -s publicClient=true -s standardFlowEnabled=false -s directAccessGrantsEnabled=true -s fullScopeAllowed=true -i)
printf '%s' "$4" | base64 -d | $kcadm create "clients/$client_uuid/protocol-mappers/models" -r vistay-backoffice -f - >/dev/null
printf '%s' "$5" | base64 -d | $kcadm create "clients/$client_uuid/protocol-mappers/models" -r vistay-backoffice -f - >/dev/null
printf '%s' "$6" | base64 -d | $kcadm create "clients/$client_uuid/protocol-mappers/models" -r vistay-backoffice -f - >/dev/null
printf '%s' "$7" | base64 -d | $kcadm create "clients/$client_uuid/protocol-mappers/models" -r vistay-backoffice -f - >/dev/null
user_uuid=$($kcadm create users -r vistay-backoffice -s username="$email" -s email="$email" -s firstName=Property -s lastName=Authority -s emailVerified=true -s enabled=true -s 'requiredActions=[]' -i)
$kcadm set-password -r vistay-backoffice --userid "$user_uuid" --new-password "$password" --temporary=false >/dev/null
$kcadm add-roles -r vistay-backoffice --uid "$user_uuid" --cclientid vistay-backoffice-api --rolename SUPER_ADMIN >/dev/null
printf '%s\n%s\n' "$client_uuid" "$user_uuid"
'@
    $created = @(& docker exec vistay-keycloak-1 sh -ec $keycloakScript -- `
        $clientId $email $password $audienceMapper $accountTypeMapper $roleMapper $subjectMapper)
    if ($LASTEXITCODE -ne 0 -or $created.Count -lt 2) {
        throw 'Keycloak authority-test identity creation failed.'
    }
    $clientUuid = $created[-2].Trim()
    $userUuid = $created[-1].Trim()

    Invoke-UserSql @"
SET search_path TO app, extensions, public;
WITH inserted_subject AS (
    INSERT INTO authorization_subjects(account_type, auth_account_id)
    VALUES ('ADMIN', '$userUuid')
    RETURNING id
), inserted_profile AS (
    INSERT INTO admin_users(auth_account_id, full_name, email, user_type,
        authorization_subject_id)
    SELECT '$userUuid', 'Property Authority E2E', '$email', 'ADMIN', id
    FROM inserted_subject
    RETURNING authorization_subject_id
)
INSERT INTO subject_role_assignments(subject_id, role_id)
SELECT inserted_profile.authorization_subject_id, roles.id
FROM inserted_profile
JOIN roles ON roles.code = 'SUPER_ADMIN' AND roles.audience = 'ADMIN';
INSERT INTO subject_role_permission_scopes(assignment_id, permission_id, scope_type)
SELECT assignment.id, policy.permission_id, policy.scope_type
FROM authorization_subjects subject
JOIN subject_role_assignments assignment ON assignment.subject_id = subject.id
JOIN role_permission_policies policy ON policy.role_id = assignment.role_id
WHERE subject.auth_account_id = '$userUuid'
ON CONFLICT DO NOTHING;
"@

    $tokenResponse = Invoke-RestMethod -Method Post `
        -Uri "$IdentityUrl/realms/vistay-backoffice/protocol/openid-connect/token" `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body @{ grant_type = 'password'; client_id = $clientId; username = $email; password = $password }
    $token = $tokenResponse.access_token
    if (!$token) { throw 'Keycloak did not return an authority-test access token.' }
    $payloadSegment = ($token -split '\.')[1].Replace('-', '+').Replace('_', '/')
    $payloadSegment = $payloadSegment.PadRight(
        $payloadSegment.Length + ((4 - $payloadSegment.Length % 4) % 4), '=')
    $tokenClaims = [Text.Encoding]::UTF8.GetString(
        [Convert]::FromBase64String($payloadSegment)) | ConvertFrom-Json
    $headerSegment = ($token -split '\.')[0].Replace('-', '+').Replace('_', '/')
    $headerSegment = $headerSegment.PadRight(
        $headerSegment.Length + ((4 - $headerSegment.Length % 4) % 4), '=')
    $tokenHeader = [Text.Encoding]::UTF8.GetString(
        [Convert]::FromBase64String($headerSegment)) | ConvertFrom-Json
    if ($tokenHeader.alg -ne 'RS256') {
        throw "Authority-test token has unsupported algorithm: $($tokenHeader.alg)"
    }
    if ('vistay-backoffice-api' -notin @($tokenClaims.aud)) {
        throw "Authority-test token has invalid audience: $(@($tokenClaims.aud) -join ',')"
    }
    if ('SUPER_ADMIN' -notin @($tokenClaims.resource_access.'vistay-backoffice-api'.roles)) {
        throw 'Authority-test token is missing SUPER_ADMIN.'
    }
    Write-Verbose ("JWT alg={0}; iss={1}; aud={2}; sub={3}" -f `
        $tokenHeader.alg, $tokenClaims.iss, (@($tokenClaims.aud) -join ','), $tokenClaims.sub)

    $query = @'
query PropertyAuthoritySmoke($propertyId: ID!) {
  propertyAvailability(input: {
    propertyId: $propertyId,
    checkInDate: "2027-01-10",
    checkOutDate: "2027-01-11"
  }) {
    propertyId
    available
    inventoryRevision
  }
  propertyOperationalSummary {
    activeProperties
    maintenanceProperties
    propertiesNeedingAttention
  }
}
'@
    $response = Invoke-RestMethod -Method Post -Uri $GraphQlUrl `
        -Headers @{ Authorization = "Bearer $token"; 'X-CSRF-Token' = 'property-authority-e2e' } `
        -ContentType 'application/json' `
        -Body (@{ query = $query; variables = @{ propertyId = $PropertyId } } | ConvertTo-Json -Depth 10)
    if ($response.errors) {
        throw "Booking/Property GraphQL failed: $($response.errors | ConvertTo-Json -Depth 8 -Compress)"
    }
    if ($response.data.propertyAvailability.propertyId -ne $PropertyId) {
        throw 'Booking returned authority evidence for the wrong property.'
    }

    [ordered]@{
        result = 'PASS'
        propertyId = $response.data.propertyAvailability.propertyId
        available = $response.data.propertyAvailability.available
        inventoryRevision = $response.data.propertyAvailability.inventoryRevision
        propertySummary = $response.data.propertyOperationalSummary
    } | ConvertTo-Json -Depth 6 -Compress
}
finally {
    if ($userUuid) {
        try {
            Invoke-UserSql @"
SET search_path TO app, extensions, public;
DELETE FROM admin_users WHERE auth_account_id = '$userUuid';
DELETE FROM subject_role_assignments
WHERE subject_id IN (SELECT id FROM authorization_subjects WHERE auth_account_id = '$userUuid');
DELETE FROM authorization_subjects WHERE auth_account_id = '$userUuid';
"@
        }
        catch { Write-Warning "User cleanup failed: $($_.Exception.Message)" }
    }
    if ($clientUuid -or $userUuid) {
        $cleanupScript = @'
set +e
kcadm=/opt/keycloak/bin/kcadm.sh
$kcadm config credentials --server http://localhost:8080 --realm master --user "$KC_BOOTSTRAP_ADMIN_USERNAME" --password "$KC_BOOTSTRAP_ADMIN_PASSWORD" >/dev/null 2>&1
test -z "$1" || $kcadm delete "users/$1" -r vistay-backoffice >/dev/null 2>&1
test -z "$2" || $kcadm delete "clients/$2" -r vistay-backoffice >/dev/null 2>&1
'@
        & docker exec vistay-keycloak-1 sh -ec $cleanupScript -- "$userUuid" "$clientUuid" | Out-Null
    }
}
