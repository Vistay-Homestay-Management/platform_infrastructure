# ViStay Epic 01 Postman

Import these files into Postman:

- `ViStay-Epic01.postman_collection.json`
- `ViStay-Authorization.postman_collection.json`
- `ViStay-Pricing.postman_collection.json`
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
| `runSessionRevoke=true` | Revoke the `sessionId` selected by the preceding list request | `accessToken`, `accountId`, `sessionRevocationReason` |
| `runProfileUpdate=true` | Update the signed-in admin's personal profile | Run Viewer first; set profile fields and use a token with `profile:update@SELF` |
| `runAccountLifecycle=true` | Lock, disable, or recover a Backoffice account | Target UUID/version and token with `account:suspend@ALL` or `account:unlock@ALL` |
| `runNotificationStream=true` | GraphQL-over-SSE notification stream | `accessToken` with `notifications:read` |
| `runPaymentMutations=true` | Create/cancel payment intent | `accessToken`, payable `financePaymentRequestId`, Payment not `DISABLED` |
| `runVietQrCallbacks=true` | VietQR token and transaction callbacks | Callback credentials and `CALLBACK_ENABLED` mode |
| `runAuthorizationE2E=true` | Maker-checker and Booking scope flow | Full profile, three PKCE tokens, local booking fixtures |
| `runAuthorizationUnavailable=true` | Fail-closed User authorization dependency test | Run Authorization E2E first, force a cache miss, then temporarily stop only `service-user` |
| `runPricingAuthoring=true` | Immutable property pricing authoring and validation flow | `makerAccessToken`, CTV `targetAccessToken`, and an existing exact-unit `pricingPropertyId` |
| `runPricingCalculation=true` | Deterministic SHORT/MEDIUM/LONG quote calculation and explanation | Run pricing authoring first; retain `pricingVersionId`, `pricingVersionNumber`, and `pricingPropertyId` |

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

## Session and recovery flow

Set `accountId` to the `accountId` returned by Viewer and copy the OAuth token
to `accessToken`. Run **List active Backoffice sessions** first; it stores the
first result as `sessionId`. Revocation is intentionally skipped until
`runSessionRevoke=true`. Reusing the same idempotency key returns the original
audit result without a second Keycloak mutation.

Credential recovery is exposed by the Keycloak login page through **Forgot
password**. Delivery of the reset link requires SMTP to be configured for the
Backoffice realm in each deployed environment; Postman never stores or submits
an administrator password.

## Personal profile flow

Copy an OAuth token to `accessToken`, then run **Viewer** first. It stores the
current `profileVersion` and profile fields in the environment. Review the
`profileDisplayName`, E.164 `profilePhone`, `profileAvatarMediaId`, and reason;
then enable `runProfileUpdate=true` and send **Update my profile**. The mutation
uses optimistic concurrency and an idempotency key. Clear
`profileIdempotencyKey` before submitting different values; keep it unchanged
only when verifying that the same request is replayed safely. Avatar data is an
external media UUID reference, not a binary upload.

## Account security lifecycle

Run **Inspect account security** with `securityTargetAccountId` to review the
projection version and Keycloak brute-force state, then review **List account
security events**. Mutations are skipped until `runAccountLifecycle=true`.
Choose `LOCK`, `DISABLE`, or `RECOVER`, copy the current version to
`securityTargetVersion`, and provide an eight-character reason. Clear the
idempotency key before changing inputs; a successful lock/disable also revokes
active Keycloak sessions, while recovery clears login failures before enabling
the account.

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
`vistay-postgres-1`. It creates creator-provenance, ASSIGNED and unrelated
bookings for scope verification. Creator provenance is deliberately denied:
`created_by` is audit metadata and never implies business ownership. The flow
also verifies that `totalAmount` is null unless `booking:read_sensitive` covers
the same record. The legacy environment variable remains `ownBookingId` for
collection compatibility. No token or password is stored in the repository.

The checked-in `authorization-security-matrix.json` is the coverage ledger for
`SCRUM-525`. CI verifies that every executable case maps to a real Postman
request with assertions. It also records cases that currently have only
service-level evidence or are blocked by a missing public resource API, so a
green collection cannot silently imply coverage that does not exist.

The Booking matrix now covers direct IDOR denial, list filtering, OWN+ASSIGNED
union behavior, ALL dominance, commercial-field masking, expired record
assignments, immediate scope reduction and authorization dependency failure.
The last failure-injection request is disabled separately because it requires
briefly stopping User Service; restart User Service immediately after running
it.

## Pricing authoring flow

Run the Authorization collection first to obtain `makerAccessToken` for the
SUPER_ADMIN author and `targetAccessToken` for the CTV denial case. Set
`pricingPropertyId` to an existing Property `properties.id`; in the current
model that ID is the exact physical unit, not a property-type or branch ID.
Then set `runPricingAuthoring=true` and run **ViStay Pricing Authoring** in its
checked-in order:

1. create one immutable version and retain its complete response snapshot;
2. replay the exact command and prove the same version is returned;
3. reject commission above the v1 20% ceiling and a custom rule spanning more
   than 29 days;
4. prove a CTV without `pricing:update` cannot author a version;
5. read the version by ID and find it in the property's version history.

The collection uses the approved v1 defaults: VND 1,000,000 base daily rate,
70% medium-stay factor, 55% long-stay factor, 14:00 check-in, 12:00 checkout,
120-minute turnover, 5% default commission, and a 20% commission ceiling.
Pricing authoring is append-only, so there is no delete/cleanup request. Clear
`pricingIdempotencyKey` before intentionally changing any happy-path input;
keeping the same key is only valid for the exact replay test. Leave
`runPricingAuthoring=false` during ordinary smoke runs.

After authoring, set `runPricingAuthoring=false` and
`runPricingCalculation=true`, then run **03 Calculate and explain deterministic
quotes**. The checked-in cases prove:

- a three-day SHORT stay applies the weekend surcharge per eligible charge day,
  explains matched/skipped rules and commission components, and totals VND
  3,360,000;
- the identical input and immutable profile return the same fingerprint, total,
  and full explanation;
- a 31-day MEDIUM stay uses the 70% daily factor and totals VND 22,785,000,
  including staff commission;
- a one-calendar-year LONG stay uses the 55% daily factor and totals VND
  210,787,500, including staff commission;
- zero-night input and a profile/property mismatch fail with stable error codes;
- Hive Router rejects an anonymous quote request.

The calculation query always supplies `rateProfileVersionId`; it does not pick
an active version. SCRUM-355 neither publishes pricing, accepts a manual
override, creates a durable quote ID/expiry, nor stores a booking snapshot.
Those lifecycle concerns remain in SCRUM-356 and SCRUM-357. The environment's
`pricingQuoteShortSnapshot`, fingerprint and total are temporary Postman
evidence only; their checked-in values remain empty.

## Payment activation

The checked-in local configuration defaults to `PAYMENT_ACTIVATION_MODE=DISABLED`.
Positive payment creation requires a valid Finance payment request and
`GENERATE_ONLY` or `CALLBACK_ENABLED`. VietQR callback requests additionally
require `CALLBACK_ENABLED`; returning `404` while disabled is intentional.
