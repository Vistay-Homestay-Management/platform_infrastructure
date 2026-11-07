# ViStay Platform Infrastructure

ViStay's local platform stack uses Nginx as the only public ingress and the
Docker image of GraphQL Hive Router for the Backoffice federated GraphQL API.
The retired Spring gateway repository is archived and is not part of the topology.

This public repository must never contain real passwords, private keys,
generated certificates, database dumps, or production endpoints.

## Epic 01 local stack

Create the local environment file once, generate role-scoped development
certificates, then start the complete stack:

```powershell
Copy-Item .env.example .env
./scripts/Generate-DevCertificates.ps1
docker compose -f compose.yaml -f compose.full.yaml --env-file .env --profile full up -d --build
```

PostgreSQL is published on `127.0.0.1:55432` by default to avoid colliding
with a workstation installation. Use `--profile epic01` instead of `full` when
only the Epic 01 services are needed. Running plain `docker compose up` is not
equivalent because application services live in `compose.full.yaml` profiles.

The profile contains PostgreSQL, Redis, Kafka, Keycloak, Authentication, User,
Notification, Finance, Payment, the Admin and Host frontends, separate Backoffice/Host
Hive Routers, and Nginx. `full` additionally
starts the bounded contexts scheduled for later epics. The checked-in
`.env.example` is for isolated local/CI smoke tests only.

Local verification and recovery messages are captured by the internal Mailpit
service. SMTP settings are configured independently for the Backoffice, Customer,
and Host realms through their `VISTAY_*_SMTP_*` environment variables. After
changing SMTP values for an existing Keycloak database, reconcile the realms with:

```powershell
./scripts/Sync-KeycloakSmtp.ps1
```

The script reads credentials and SMTP values from the running local Keycloak
container; it does not require deleting or re-importing a realm.

Important trust boundaries:

- Nginx alone publishes the public HTTP port. Keycloak admin endpoints stay internal.
- VietQR callbacks remain disabled until the production HTTPS and merchant UAT gates pass.
- The Host edge boundary is allow-listed but the checked-in Host realm remains disabled
  until its issuer/audience and smoke gates pass; Customer remains deferred.
- Kafka uses TLS, distinct SCRAM principals, deny-by-default ACLs, and exactly
  the reviewed versioned contract topics, including Booking pricing publication
  and inventory block changes.
- Internal User authorization RPCs require a CA-issued client certificate,
  the Authentication SPIFFE URI, and a deadline no longer than two seconds.
- Authentication, User, Notification, Finance, and Payment use separate runtime and migrator
  database roles. Runtime roles have no schema or database creation rights.

Run the static gates with:

```powershell
./scripts/Test-EdgeTopology.ps1 -IncludeEpic01
./scripts/Test-HostEdgeTopology.ps1
./scripts/Test-KeycloakContract.ps1
./scripts/Compose-Supergraph.ps1
./scripts/Compose-HostSupergraph.ps1
./scripts/Test-Observability.ps1
```

The Epic 01 walking slice exports W3C-correlated traces from Authentication,
User, and Notification to the local OpenTelemetry Collector. Prometheus-format
metrics remain internal at each service's `/actuator/prometheus` endpoint. See
[`observability/README.md`](observability/README.md) for verification, incident,
and rollback procedures.

## Postman verification

Import the collection and local environment from [`postman/`](postman/README.md).
The default run executes only read-only health, readiness, OIDC discovery, and
unauthenticated security checks. Account bootstrap, notification streaming,
payment mutations, pricing authoring/publication, inventory block commands, and
VietQR callbacks require explicit opt-in flags.

For the current backend capability and frontend handoff snapshot, see
[`summary/`](summary/README.md).

## Federation contracts

`router/backoffice/subgraphs` vendors the reviewed User, Notification, and Payment SDLs
from `platform_contracts`. `router/host` contains a separate profile-only User graph and
Host JWT router; it must never reuse the Backoffice router configuration. The Backoffice
and Host supergraphs are composed independently into checked-in Hive Router artifacts.
Update the source commit comment whenever a contract is refreshed.

## Jira catalog synchronization

The canonical Jira delivery specification lives in `platform_contracts/docs/jira`.
Use [`scripts/jira/Sync-JiraCatalog.ps1`](scripts/jira/README.md) in `Validate`,
`DryRun`, then `Apply` mode. Every non-validation run writes a local backup;
the post-apply dry run must report zero changes. The tool never deletes issues
or comments and never transitions workflow status.

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
