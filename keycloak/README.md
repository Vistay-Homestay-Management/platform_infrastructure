# Keycloak realm bootstrap

These imports create three deliberately isolated identity realms:

- `vistay-backoffice` for employees and operational administrators.
- `vistay-host` for owners and property hosts.
- `vistay-customer` for guests and customers.

The files contain public OIDC clients, API audiences, baseline roles, and the
non-human `vistay-auth-facade` service account definition. They never contain
human users, literal client secrets, passwords, signing keys, or production URLs. The
browser and mobile clients use Authorization Code + PKCE (`S256`); password and
implicit grants are disabled.

Backoffice browser and mobile access tokens include audience
`vistay-backoffice-api`, the string claim `account_type=ADMIN`, and the default
scope `notifications:read`. The Auth facade service account is limited to the
Backoffice realm's `manage-users` and `query-users` roles. Its import uses the
`${KEYCLOAK_ADMIN_CLIENT_SECRET}` environment placeholder; provision that value
from a secret manager and never add the resolved secret to this repository.

Keycloak imports a realm only when that realm does not already exist. Editing a
JSON file does not mutate an existing realm. Treat these files as a development
bootstrap and apply reviewed realm changes through an explicit deployment
process in shared environments.

The three realms are separate credential stores. ViStay must not infer that
accounts in different realms belong to the same person merely because an email
address or phone number matches.
