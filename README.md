# ViStay Platform Infrastructure

Local development infrastructure, database bootstrap tooling, Apollo Federation routing, and reusable CI workflows for ViStay.

The repository is public and must never contain real endpoints, passwords, private keys, generated certificates, or database dumps.

## Planned profiles

- `dependencies`: PostgreSQL, Kafka, Redis, MinIO, and Apollo Router.
- `full`: dependencies plus all ViStay services and web applications.

Production application deployment is intentionally excluded until remote SSH or Tailscale SSH access is available.
