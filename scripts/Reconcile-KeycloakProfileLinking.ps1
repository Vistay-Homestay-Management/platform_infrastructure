[CmdletBinding()]
param(
    [string]$KeycloakContainer = 'vistay-keycloak-1'
)

$ErrorActionPreference = 'Stop'

$reconcileScript = @'
set -euo pipefail
kcadm=/opt/keycloak/bin/kcadm.sh
$kcadm config credentials --server http://localhost:8080 --realm master \
  --user "$KC_BOOTSTRAP_ADMIN_USERNAME" --password "$KC_BOOTSTRAP_ADMIN_PASSWORD" >/dev/null

ensure_facade() {
  realm="$1"
  $kcadm update "realms/$realm" -s registrationAllowed=true -s verifyEmail=true >/dev/null
  client_uuid=$($kcadm get clients -r "$realm" -q clientId=vistay-auth-facade \
    --fields id --format csv --noquotes | head -n 1)
  if test -z "$client_uuid"; then
    client_uuid=$($kcadm create clients -r "$realm" -i \
      -s clientId=vistay-auth-facade -s name='ViStay Auth Facade' \
      -s enabled=true -s protocol=openid-connect -s publicClient=false \
      -s clientAuthenticatorType=client-secret -s secret="$KEYCLOAK_ADMIN_CLIENT_SECRET" \
      -s standardFlowEnabled=false -s implicitFlowEnabled=false \
      -s directAccessGrantsEnabled=false -s serviceAccountsEnabled=true \
      -s fullScopeAllowed=true)
  else
    $kcadm update "clients/$client_uuid" -r "$realm" \
      -s enabled=true -s publicClient=false -s clientAuthenticatorType=client-secret \
      -s secret="$KEYCLOAK_ADMIN_CLIENT_SECRET" -s serviceAccountsEnabled=true \
      -s standardFlowEnabled=false -s directAccessGrantsEnabled=false \
      -s fullScopeAllowed=true >/dev/null
  fi
  for role in manage-users query-users view-users; do
    $kcadm add-roles -r "$realm" --uusername service-account-vistay-auth-facade \
      --cclientid realm-management --rolename "$role" >/dev/null
  done
}

ensure_facade vistay-customer
ensure_facade vistay-host
printf '%s\n' 'Keycloak Customer/Host profile-link administration reconciled.'
'@

& docker exec $KeycloakContainer sh -ec $reconcileScript
if ($LASTEXITCODE -ne 0) { throw 'Keycloak profile-link reconciliation failed.' }

$profileAttributes = @(
    [ordered]@{
        name = 'vistay_profile_id'
        displayName = 'ViStay profile ID'
        permissions = [ordered]@{ view = @('admin', 'user'); edit = @('admin') }
        multivalued = $false
    },
    [ordered]@{
        name = 'vistay_account_type'
        displayName = 'ViStay account type'
        permissions = [ordered]@{ view = @('admin', 'user'); edit = @('admin') }
        multivalued = $false
    },
    [ordered]@{
        name = 'vistay_invitation_id'
        displayName = 'ViStay invitation ID'
        permissions = [ordered]@{ view = @('admin'); edit = @('admin') }
        multivalued = $false
    },
    [ordered]@{
        name = 'vistay_provisioning_reference'
        displayName = 'ViStay provisioning reference'
        permissions = [ordered]@{ view = @('admin'); edit = @('admin') }
        multivalued = $false
    },
    [ordered]@{
        name = 'phone'
        displayName = 'Phone'
        permissions = [ordered]@{ view = @('admin', 'user'); edit = @('admin', 'user') }
        multivalued = $false
    }
)

foreach ($realm in @('vistay-customer', 'vistay-host', 'vistay-backoffice')) {
    $profileJson = (& docker exec $KeycloakContainer sh -ec `
        'kcadm=/opt/keycloak/bin/kcadm.sh; $kcadm get users/profile -r "$1"' -- $realm) | Out-String
    if ($LASTEXITCODE -ne 0) { throw "Cannot read Keycloak user profile for $realm." }
    $profile = $profileJson | ConvertFrom-Json
    $existingNames = @($profile.attributes | ForEach-Object { $_.name })
    foreach ($definition in $profileAttributes) {
        if ($existingNames -notcontains $definition.name) {
            $profile.attributes += [pscustomobject]$definition
        }
    }
    $encodedProfile = [Convert]::ToBase64String(
        [Text.Encoding]::UTF8.GetBytes(($profile | ConvertTo-Json -Depth 20 -Compress)))
    & docker exec $KeycloakContainer sh -ec `
        'set -e; file="/tmp/vistay-user-profile-$2.json"; printf "%s" "$1" | base64 -d > "$file"; kcadm=/opt/keycloak/bin/kcadm.sh; $kcadm update users/profile -r "$2" -f "$file" >/dev/null; rm -f "$file"' `
        -- $encodedProfile $realm
    if ($LASTEXITCODE -ne 0) { throw "Cannot update Keycloak user profile for $realm." }
}

Write-Output 'Keycloak managed ViStay profile attributes reconciled.'
