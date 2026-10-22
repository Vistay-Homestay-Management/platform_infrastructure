# ViStay Platform Infrastructure

ViStay's local platform stack uses Caddy as the only public ingress and the
Docker image of GraphQL Hive Router for the Backoffice federated GraphQL API.
The deprecated Spring gateway is not part of the topology.

This public repository must never contain real passwords, private keys,
generated certificates, database dumps, or production endpoints.

## Epic 01 local stack

Generate role-scoped development certificates, then start only the services
required by Epic 01:

```powershell
./scripts/Generate-DevCertificates.ps1
docker compose -f compose.yaml -f compose.full.yaml --env-file .env --profile epic01 up --build
```

The profile contains PostgreSQL, Redis, Kafka, Keycloak, Authentication, User,
Notification, the Admin frontend, Hive Router, and Caddy. `full` additionally
starts the bounded contexts scheduled for later epics. The checked-in
`.env.example` is for isolated local/CI smoke tests only.

Important trust boundaries:

- Caddy alone publishes public ports. Keycloak admin endpoints stay internal.
- Only the Backoffice realm is exposed during Epic 01; Host and Customer are deferred.
- Kafka uses TLS, distinct SCRAM principals, deny-by-default ACLs, and exactly
  the three Epic 01 contract topics.
- Internal User authorization RPCs require a CA-issued client certificate,
  the Authentication SPIFFE URI, and a deadline no longer than two seconds.
- Authentication, User, and Notification use separate runtime and migrator
  database roles. Runtime roles have no schema or database creation rights.

Run the static gates with:

```powershell
./scripts/Test-EdgeTopology.ps1 -IncludeEpic01
./scripts/Test-KeycloakContract.ps1
./scripts/Compose-Supergraph.ps1
```

## Federation contracts

`router/backoffice/subgraphs` vendors the reviewed User and Notification SDLs
from `platform_contracts`. `Compose-Supergraph.ps1` composes them into the
checked-in Hive Router supergraph. Update the source commit comment whenever a
contract is refreshed.

## Remote PostgreSQL operations

Provisioning creates one database per bounded context, separates NOLOGIN
ownership from migrator and runtime roles, applies Flyway migrations, and
grants runtime DML without DDL:

```powershell
$password = Read-Host 'PostgreSQL bootstrap password' -AsSecureString
./scripts/Initialize-RemoteDatabases.ps1 -BootstrapPassword $password
./scripts/Test-RemoteDatabases.ps1
./scripts/Audit-RemoteDatabases.ps1
./scripts/Backup-RemoteDatabases.ps1
```

PostgreSQL TLS is required by default. The current Tailscale database endpoint
does not offer PostgreSQL TLS, so an exceptional run must state both
`-SslMode disable` and `-AllowInsecureTailscaleTransport`. Tailscale encrypts
the network path, but this is still not a substitute for PostgreSQL TLS and
must remain a tracked infrastructure gap.

Generated credentials are encrypted for the current Windows user with DPAPI
under `.secrets`. Backups are authenticated encrypted archives under
`.backups`, include SHA-256 hashes, and must pass an actual restore smoke test.
Both directories are outside source control.

After provisioning, publish only runtime credentials to protected GitHub
environments:

```powershell
./scripts/Publish-GitHubEnvironmentSecrets.ps1
./scripts/Publish-GitHubSecuritySecrets.ps1
```
