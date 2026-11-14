#!/bin/sh
set -eu

kcadm=/opt/keycloak/bin/kcadm.sh
profile=/opt/vistay/user-profile.json

"$kcadm" config credentials --server http://keycloak:8080 --realm master \
  --user "$KC_BOOTSTRAP_ADMIN_USERNAME" --password "$KC_BOOTSTRAP_ADMIN_PASSWORD" >/dev/null

ensure_facade() {
  realm="$1"
  "$kcadm" update "realms/$realm" -s registrationAllowed=true -s verifyEmail=true >/dev/null
  client_uuid=$("$kcadm" get clients -r "$realm" -q clientId=vistay-auth-facade \
    --fields id --format csv --noquotes | head -n 1)
  if [ -z "$client_uuid" ]; then
    client_uuid=$("$kcadm" create clients -r "$realm" -i \
      -s clientId=vistay-auth-facade -s name='ViStay Auth Facade' \
      -s enabled=true -s protocol=openid-connect -s publicClient=false \
      -s clientAuthenticatorType=client-secret -s secret="$KEYCLOAK_ADMIN_CLIENT_SECRET" \
      -s standardFlowEnabled=false -s implicitFlowEnabled=false \
      -s directAccessGrantsEnabled=false -s serviceAccountsEnabled=true \
      -s fullScopeAllowed=true)
  else
    "$kcadm" update "clients/$client_uuid" -r "$realm" \
      -s enabled=true -s publicClient=false -s clientAuthenticatorType=client-secret \
      -s secret="$KEYCLOAK_ADMIN_CLIENT_SECRET" -s serviceAccountsEnabled=true \
      -s standardFlowEnabled=false -s directAccessGrantsEnabled=false \
      -s fullScopeAllowed=true >/dev/null
  fi
  for role in manage-users query-users view-users; do
    "$kcadm" add-roles -r "$realm" --uusername service-account-vistay-auth-facade \
      --cclientid realm-management --rolename "$role" >/dev/null
  done
}

ensure_facade vistay-customer
ensure_facade vistay-host

# Backoffice identities are employee records. They are provisioned by an
# authorized administrator or through a one-time invitation, never by public signup.
"$kcadm" update "realms/vistay-backoffice" \
  -s registrationAllowed=false -s verifyEmail=true >/dev/null

# The backoffice roles scope has a dedicated vistay-backoffice-api role mapper.
# Keeping Keycloak's generic audience-resolve mapper would also add the
# unrelated `account` audience and make strict edge validation reject the JWT.
roles_scope=$($kcadm get client-scopes -r vistay-backoffice --fields id,name \
  --format csv --noquotes | grep ',roles$' | head -n 1 | cut -d, -f1)
if [ -n "$roles_scope" ]; then
  audience_mapper=$($kcadm get "client-scopes/$roles_scope/protocol-mappers/models" \
    -r vistay-backoffice --fields id,name --format csv --noquotes | \
    grep ',audience resolve$' | head -n 1 | cut -d, -f1)
  if [ -n "$audience_mapper" ]; then
    $kcadm delete "client-scopes/$roles_scope/protocol-mappers/models/$audience_mapper" \
      -r vistay-backoffice >/dev/null
  fi
fi

for realm in vistay-customer vistay-host vistay-backoffice; do
  "$kcadm" update users/profile -r "$realm" -f "$profile" >/dev/null
done

echo 'Keycloak profile-link configuration is reconciled.'
