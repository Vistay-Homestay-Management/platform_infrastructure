# ViStay Vault Transit

Local Compose runs Vault in explicit development mode and provisions four
non-exportable Transit keys:

- `vistay-profile-document`: AES-GCM encryption for CCCD;
- `vistay-profile-lookup`: deterministic HMAC-SHA256 lookup;
- `vistay-profile-link-otp`: HMAC-SHA256 challenge evidence;
- `vistay-profile-link-delivery`: encrypted email-delivery secret.

The development root token and fixed service tokens are local-only bootstrap
credentials. Production must use an initialized HA Vault/HCP Vault deployment,
TLS, audit devices and workload identity; it must not use `-dev`, a root token,
or tokens from `.env`.

User Service receives only encrypt/HMAC capabilities. Notification receives
only decrypt capability for the delivery ciphertext. Neither service can read
or export Transit key material.
