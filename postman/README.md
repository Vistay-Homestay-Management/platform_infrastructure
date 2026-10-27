# ViStay Epic 01 Postman

Import both files into Postman:

- `ViStay-Epic01.postman_collection.json`
- `ViStay-Authorization.postman_collection.json`
- `ViStay-Local.postman_environment.json`

Select the **ViStay Local** environment before sending requests.

For an already initialized local Keycloak database, synchronize the checked-in
Postman PKCE client without recreating the realm:

```powershell
./scripts/Sync-KeycloakPostmanClient.ps1 `
  -AdminPassword '<local Keycloak bootstrap admin password>'
```

The same script can refresh the already initialized browser client after realm
configuration changes by adding `-ClientId vistay-backoffice-web`.
## Safe defaults

The `Safe smoke` folder is read-only and can run against the default Epic 01
Compose stack. All requests that create data, open a long-lived stream, mutate
payments, or emulate VietQR callbacks are skipped by default.

Enable an optional group only after supplying its required variables:

| Flag | Enables | Prerequisites |
| --- | --- | --- |
| `runBootstrap=true` | Backoffice account bootstrap | `bootstrapToken`, `bootstrapPassword` |
| `runNotificationStream=true` | GraphQL-over-SSE notification stream | `accessToken` with `notifications:read` |
| `runPaymentMutations=true` | Create/cancel payment intent | `accessToken`, payable `financePaymentRequestId`, Payment not `DISABLED` |
| `runVietQrCallbacks=true` | VietQR token and transaction callbacks | Callback credentials and `CALLBACK_ENABLED` mode |
| `runAuthorizationE2E=true` | Maker-checker and Booking scope flow | Full profile, three PKCE tokens, local booking fixtures |

Never commit populated secret values or an exported environment containing
tokens.

## Backoffice access token

The realm deliberately disables the resource-owner password grant. In Postman,
configure OAuth 2.0 **Authorization Code (With PKCE)** with:

- Auth URL: `http://identity.localhost/realms/vistay-backoffice/protocol/openid-connect/auth`
- Access Token URL: `http://identity.localhost/realms/vistay-backoffice/protocol/openid-connect/token`
- Client ID: `vistay-backoffice-postman`
- Callback URL: `https://oauth.pstmn.io/v1/browser-callback`
- Code challenge method: `SHA-256`; client secret: empty

Sign in in the browser, use the token, and copy it to `makerAccessToken`. Repeat
for the checker and scoped target accounts using `checkerAccessToken` and
`targetAccessToken`. The temporary password must be changed on first login.
The authenticated GraphQL requests send both `Authorization: Bearer ...` and
the required `X-CSRF-Token` header.

## Authorization E2E order

Start the full stack and run the Authorization collection folders in order.
Provisioning reaches User through Kafka, so retry each “Resolve subject” request
for a few seconds if it initially returns `AUTHORIZATION_SUBJECT_NOT_FOUND`.
After the CTV grant is approved, seed deterministic Booking rows:

```powershell
./scripts/Seed-AuthorizationE2E.ps1 `
  -MakerAccountId '<maker account id>' `
  -TargetAccountId '<target account id>' `
  -TargetProfileId '<target profile id>'
```

The fixture script refuses any PostgreSQL container other than the local
`vistay-postgres-1`. It creates OWN, ASSIGNED and unrelated bookings only for
scope verification. No token or password is stored in the repository.
## Payment activation

The checked-in local configuration defaults to `PAYMENT_ACTIVATION_MODE=DISABLED`.
Positive payment creation requires a valid Finance payment request and
`GENERATE_ONLY` or `CALLBACK_ENABLED`. VietQR callback requests additionally
require `CALLBACK_ENABLED`; returning `404` while disabled is intentional.
