# ViStay Platform Infrastructure

Local development infrastructure, database bootstrap tooling, Apollo Federation routing, and reusable CI workflows for ViStay.

The repository is public and must never contain real endpoints, passwords, private keys, generated certificates, or database dumps.

Run the complete local platform with both Compose files:

```powershell
docker compose -f compose.yaml -f compose.full.yaml --env-file .env --profile full up --build
```

## Planned profiles

- `dependencies`: PostgreSQL, Kafka, Redis, MinIO, and Apollo Router.
- `full`: dependencies plus all ViStay services and web applications.

Production application deployment is intentionally excluded until remote SSH or Tailscale SSH access is available.

## Remote PostgreSQL provisioning

The provisioning command creates one database per bounded context, separates
NOLOGIN ownership from migrator and runtime roles, applies the checked-in
Flyway migrations, and grants runtime DML without DDL.

```powershell
$password = Read-Host 'PostgreSQL bootstrap password' -AsSecureString
./scripts/Initialize-RemoteDatabases.ps1 -BootstrapPassword $password
./scripts/Test-RemoteDatabases.ps1
```

Generated credentials are encrypted for the current Windows user with DPAPI
and written outside this repository to `.secrets/database-credentials.xml`.
Never copy that file into source control.

After provisioning, publish only the runtime credentials to protected GitHub
environments:

```powershell
./scripts/Publish-GitHubEnvironmentSecrets.ps1
./scripts/Publish-GitHubSecuritySecrets.ps1
```

## Federation composition

`scripts/Compose-Supergraph.ps1` composes the nine business subgraphs into
the checked-in `supergraph.graphql` consumed by Apollo Router. Composition
must pass whenever a subgraph schema changes.
