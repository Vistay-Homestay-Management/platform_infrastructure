#!/bin/sh
set -eu

export VAULT_ADDR="${VAULT_ADDR:-http://vault:8200}"
export VAULT_TOKEN="${VAULT_DEV_ROOT_TOKEN_ID:?VAULT_DEV_ROOT_TOKEN_ID is required}"

until vault status >/dev/null 2>&1; do
  sleep 1
done

if ! vault secrets list -format=json | grep -q '"transit/"'; then
  vault secrets enable -path=transit transit
fi

ensure_key() {
  name="$1"
  type="$2"
  if ! vault read "transit/keys/${name}" >/dev/null 2>&1; then
    if [ "$type" = "hmac" ]; then
      vault write "transit/keys/${name}" type="${type}" key_size=32 exportable=false allow_plaintext_backup=false
    else
      vault write "transit/keys/${name}" type="${type}" exportable=false allow_plaintext_backup=false
    fi
  fi
}

ensure_key vistay-profile-document aes256-gcm96
ensure_key vistay-profile-lookup hmac
ensure_key vistay-profile-link-otp hmac
ensure_key vistay-profile-link-delivery aes256-gcm96

vault policy write vistay-user-identity - <<'EOF'
path "transit/encrypt/vistay-profile-document" {
  capabilities = ["update"]
}
path "transit/decrypt/vistay-profile-document" {
  capabilities = ["update"]
}
path "transit/hmac/vistay-profile-lookup/*" {
  capabilities = ["update"]
}
path "transit/hmac/vistay-profile-link-otp/*" {
  capabilities = ["update"]
}
path "transit/encrypt/vistay-profile-link-delivery" {
  capabilities = ["update"]
}
EOF

vault policy write vistay-notification-profile-link - <<'EOF'
path "transit/decrypt/vistay-profile-link-delivery" {
  capabilities = ["update"]
}
EOF

ensure_token() {
  token="$1"
  policy="$2"
  if ! VAULT_TOKEN="$token" vault token lookup >/dev/null 2>&1; then
    vault token create -id="$token" -policy="$policy" -orphan -ttl=0 -display-name="$policy" >/dev/null
  fi
}

ensure_token "${VAULT_USER_SERVICE_TOKEN:?VAULT_USER_SERVICE_TOKEN is required}" vistay-user-identity
ensure_token "${VAULT_NOTIFICATION_SERVICE_TOKEN:?VAULT_NOTIFICATION_SERVICE_TOKEN is required}" vistay-notification-profile-link

echo "Vault Transit keys and least-privilege local service policies are ready."
