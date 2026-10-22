# Keycloak realm bootstrap

These imports create three deliberately isolated identity realms:

- `vistay-backoffice` for employees and operational administrators.
- `vistay-host` for owners and property hosts.
- `vistay-customer` for guests and customers.

The files contain public OIDC clients, API audiences, and baseline roles only.
They never contain users, client secrets, passwords, signing keys, or production
URLs. The browser and mobile clients use Authorization Code + PKCE (`S256`);
password and implicit grants are disabled.

Keycloak imports a realm only when that realm does not already exist. Editing a
JSON file does not mutate an existing realm. Treat these files as a development
bootstrap and apply reviewed realm changes through an explicit deployment
process in shared environments.

The three realms are separate credential stores. ViStay must not infer that
accounts in different realms belong to the same person merely because an email
address or phone number matches.
