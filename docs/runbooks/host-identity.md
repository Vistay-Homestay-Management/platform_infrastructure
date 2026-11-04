# Host identity realm runbook

This runbook covers the `vistay-host` realm contract from SCRUM-808 and the
edge handoff from SCRUM-816. It owns Keycloak realm behavior, local email
capture, and the enable/disable gate. It does not implement invitation
business logic or a local credential/session store.

## Ownership boundary

- Keycloak owns Host credentials, required actions, refresh tokens, and
  interactive sessions.
- Authentication owns invitation and lifecycle commands and reconciles the
  Keycloak subject. It must not persist passwords, action links, refresh tokens,
  or a parallel JWT.
- User owns the Host profile and authorization subject.
- Mailpit is a local-only development sink. It is never a public ingress and
  never receives production mail.

## Baseline and local profile

The checked-in `keycloak/realms/vistay-host-realm.json` deliberately keeps
`enabled: false`. Epic 01 edge smoke must continue to return `404` for Host and
Customer realm discovery. `.env.example` records the local activation signal as
`VISTAY_HOST_REALM_ENABLED=false`; changing that signal alone does not enable an
already-imported Keycloak realm.

The full local profile adds Mailpit at `mailpit:1025` and `mailpit:8025`. It has
no published host ports, so the SMTP sink and UI are reachable only from the
Compose network. The Host realm references SMTP values through environment
placeholders; no password or resolved secret belongs in this repository.

Render the profile without starting it:

```powershell
docker compose -f compose.yaml -f compose.full.yaml --env-file .env.example --profile full config --quiet
```

For a local disposable run, start the full profile and inspect captured mail
from a container on the `vistay` network. Do not expose Mailpit through Nginx.

## Contract gate

Run these from the repository root and keep the output secret-free:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/Test-HostRealmContract.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/Test-KeycloakContract.ps1
```

Before enabling the Host realm in an environment, the release operator must
also pass the full edge/JWT validation and the Host smoke flow owned by
SCRUM-816. The Host edge uses a separate `host-api.localhost` GraphQL host and
`host.localhost` Web host; its router trusts only the `vistay-host` issuer and
`vistay-host-api` audience and exposes only the profile fields approved by the
Host supergraph.

Run the edge contract gate from the repository root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/Test-HostEdgeTopology.ps1
```

The gate is static and secret-redacted. A release smoke must additionally call
`https://host-api.localhost/graphql` with a real Host token and verify that
Backoffice/customer/wrong-audience tokens, hostile origins, unlisted GraphQL
fields, and `/actuator` paths are rejected. The Host GraphQL router never falls
back to the Backoffice graph.

The gate verifies:

- exact redirect and origin allow-lists, S256 PKCE, and disabled implicit/direct
  grants;
- verified-email and ordered `VERIFY_EMAIL` then `UPDATE_PASSWORD` actions;
- 30-minute idle, 8-hour maximum, five-minute access-token, zero refresh-token
  reuse, and bounded recovery/action-token lifetimes;
- brute-force protection, logout/recovery settings, and deterministic realm
  convergence; and
- local SMTP capture without public ports or production secret values.

## Enablement and rollback

Enablement is an environment deployment decision, not a local JSON edit. The
deployment artifact may set the realm to enabled only after the contract, edge,
issuer/audience, and smoke gates pass and production SMTP values resolve from
the environment secret manager. Keep the default import disabled until then.

To roll back, stop or remove the Host ingress servers/router, then use the
reviewed Keycloak administration procedure to set `vistay-host.enabled=false`.
Retain all users and their audit history; do not delete the realm or recreate
users. Re-run the realm and Host edge contract tests plus the edge smoke check;
a disabled realm must converge to the documented `404` discovery behavior while
Backoffice routes and the Backoffice router remain healthy and unchanged.

Keycloak realm import is a bootstrap operation and does not mutate an existing
realm. Shared-environment changes therefore require an explicit reviewed
deployment or admin operation plus a recorded rollback point.
