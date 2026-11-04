# Epic 01 observability runbook

The local walking slice exports sampled OTLP traces from Authentication, User,
and Notification to a pinned OpenTelemetry Collector. Each service exposes
Prometheus metrics and readiness only inside the `vistay` Docker network. Nginx
remains the sole public ingress.

## Start and verify

```powershell
docker compose -f compose.yaml -f compose.full.yaml --env-file .env --profile epic01 up -d --build --wait
./scripts/Test-Observability.ps1
```

The verification gate checks collector health, service readiness, Prometheus
metrics, and exported spans. To follow a request, capture `X-Request-ID` from
the Nginx response, then search the JSON logs for that value and the associated
`traceId`/`spanId`:

```powershell
docker compose -f compose.yaml -f compose.full.yaml logs --since 10m nginx router-backoffice authentication user notification
docker compose -f compose.yaml -f compose.full.yaml logs --since 10m otel-collector
```

Application logs use structured output. Do not log authorization headers,
cookies, access tokens, passwords, request bodies, or raw Kafka payloads. The
default access and application log configuration records metadata only.

## Incident triage

1. Check `/healthz` at Nginx and collector health at `127.0.0.1:13133`.
2. Check `/actuator/health/readiness` for the three walking-slice services.
3. Correlate Nginx `request_id`, application `traceId`, and collector spans.
4. Check Kafka consumer lag and outbox/inbox retry rows before replaying data.
5. Preserve logs and the failing request ID before restarting a component.

## Rollback

Tracing is fail-open: an unavailable collector must not reject business
requests. Set `OTEL_SAMPLING_PROBABILITY=0.0` and recreate application services
to stop span export while preserving health and metrics. To roll back the
collector itself, restore the previously reviewed immutable image digest and
configuration, then run `Test-Observability.ps1` again. Never replace the
pinned collector image with `latest`.
