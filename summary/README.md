# ViStay system summary for Frontend

Snapshot này dành cho frontend engineer bắt đầu xây UI trên backend hiện tại.
Nó ghi lại những gì đã có trong `dev`, URL local, image vừa build và các phần
còn phải bật hoặc hoàn thiện. Contract chi tiết vẫn nằm trong
`platform_contracts` và SDL đã compose trong `router/`.

Snapshot: 2026-11-04  
Infrastructure commit: `012dc76b`  
Local profile: Docker Compose `full`

## Build snapshot

Hai service có code mới đã được build local thành công từ source đang ở `dev`:

| Service | Source commit | Local image | Image ID | CI image/publish |
| --- | --- | --- | --- | --- |
| Authentication | `8888eb3` | `vistay-authentication:latest` | `sha256:cfbf58b0f7fb...c9452d6` | [CI 41803404771](https://github.com/Vistay-Homestay-Management/service_authentication/actions/runs/41803404771) |
| User | `39d7ff7` | `vistay-user:latest` | `sha256:ee9ee3b14b75...d1dc47eb` | [CI 41810699907](https://github.com/Vistay-Homestay-Management/service_user/actions/runs/41810699907) |

CI đã publish tag `:dev` lên GHCR. Image local `:latest` ở trên không tự push
lên registry. Container đang chạy trước khi build chưa bị recreate; dùng lệnh
sau nếu muốn áp dụng image mới vào stack đang chạy:

```powershell
docker compose -f compose.yaml -f compose.full.yaml --env-file .env --profile full up -d --no-deps --force-recreate authentication user
```

## Local URLs

| Capability | URL | State |
| --- | --- | --- |
| Backoffice web | `http://admin.localhost` | Available in full profile |
| Backoffice GraphQL | `http://graphql.localhost/graphql` | Available; requires Backoffice JWT |
| Authentication REST | `http://auth.localhost` | Available through Nginx |
| Backoffice Keycloak | `http://identity.localhost/realms/vistay-backoffice` | Available |
| Host web | `http://host.localhost` | Edge route exists; realm disabled in checked-in baseline |
| Host GraphQL | `http://host-api.localhost/graphql` | Profile-only graph; realm/JWT smoke gate still required |
| PostgreSQL | `127.0.0.1:55432` | Local development only |

Only Nginx is intended to be public. Do not point frontend code at internal
Docker names such as `service-user`, `keycloak`, or `router-host` from a browser.

## Start the full local stack

```powershell
Copy-Item .env.example .env
./scripts/Generate-DevCertificates.ps1
docker compose -f compose.yaml -f compose.full.yaml --env-file .env --profile full up -d --build
```

The compose profile includes PostgreSQL, Redis, Kafka, Keycloak, Authentication,
User, Notification, Finance, Payment, Property, Booking, Media, OTA, Operations,
Warehouse, both GraphQL routers, Nginx and the three frontend containers.

## Read next

- [`backend-capabilities.md`](backend-capabilities.md): implemented backend
  capabilities, state machines, permissions and known limitations.
- [`frontend-integration.md`](frontend-integration.md): frontend URLs, GraphQL
  operations, authentication headers, error handling and implementation order.
- [`../postman/README.md`](../postman/README.md): executable local API evidence.

## Important baseline limitation

The checked-in Host realm intentionally has `VISTAY_HOST_REALM_ENABLED=false`.
Host frontend screens can be developed against the documented schema and mocked
fixtures, but a real Host login/invitation/activation requires an explicitly
enabled isolated realm, valid runtime credentials and the Host smoke gate.
