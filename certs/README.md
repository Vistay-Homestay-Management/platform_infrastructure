# Development certificates

Generated files are ignored by Git. Create them before starting Kafka:

```powershell
./scripts/Generate-DevCertificates.ps1 -StorePassword $env:KAFKA_STORE_PASSWORD
```

These certificates are development-only. Never copy the development CA or private keys to a deployed environment.
