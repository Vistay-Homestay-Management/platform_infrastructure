# Development certificates

Generated files are ignored by Git. Create both Kafka and gRPC development
bundles before starting the dependency, Epic 01, or full profiles:

```powershell
./scripts/Generate-DevCertificates.ps1 -StorePassword $env:KAFKA_STORE_PASSWORD
```

The generator removes both CA private keys after signing and creates
role-scoped directories:

- `kafka/broker`: broker keypair, truststore, and health-check client config.
- `kafka/admin`: initializer/admin keypair, truststore, and client config.
- `kafka/client`: truststore only; this is the only Kafka bundle mounted by
  application services.
- `grpc/user-server`: User server keypair and CA certificate.
- `grpc/authentication-client`: Authentication client keypair and CA
  certificate.
- `grpc/booking-client`: Booking client keypair and CA certificate.
- `grpc/finance-client`: Finance client keypair and CA certificate.
- `grpc/payment-client`: Payment client keypair and CA certificate.

Compose never mounts the generated root into a workload. A compromised service
therefore cannot obtain the Kafka broker/admin identity or a CA signing key.
These certificates remain development-only; production certificates must come
from the deployment secret manager.

The gRPC bundle contains a `service-user` server certificate and an
`authentication` client certificate whose URI SAN is
`spiffe://vistay/service/authentication`. The Booking client uses
`spiffe://vistay/service/booking`, the Finance client uses
`spiffe://vistay/service/finance`, and the Payment client uses
`spiffe://vistay/service/payment`. The User service requires mutual TLS and
rejects callers outside that explicit URI allowlist. Production certificates must
come from the deployment secret manager and workload identity process.
