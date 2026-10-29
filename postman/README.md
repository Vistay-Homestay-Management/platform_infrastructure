# ViStay Epic 01 Postman

Import these files into Postman:

- `ViStay-Epic01.postman_collection.json`
- `ViStay-Authorization.postman_collection.json`
- `ViStay-Pricing.postman_collection.json`
- `ViStay-Inventory.postman_collection.json`
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
| `runPricingOverride=true` | Audited manual override, exact replay, and changed-payload idempotency rejection | SUPER_ADMIN `makerAccessToken`; run pricing authoring first |
| `runPricingLargeOverride=true` | Optional reduction above 20% with large-override approval evidence | Also set `runPricingOverride=true`; User Service V8 catalog and refreshed SUPER_ADMIN authorization snapshot |
| `runPricingPublication=true` | Publish one fresh immutable profile and create/replay/read an immutable quote snapshot | SUPER_ADMIN `makerAccessToken`; run pricing authoring first with a new unpublished `pricingVersionId` |
| `runPricingOverrideConsumption=true` | Optionally consume the exact SCRUM-356 override into a quote snapshot and replay it | Also set `runPricingPublication=true`; run folder 04 first and retain an unexpired matching `pricingOverrideId` |
| `runInventorySeededScenarios=true` | Read available, blocking, history-only, and adjacent exact-unit fixtures | Read-only fixture properties plus `inventoryAccessToken` with `inventory:read` and the required exact scope |
| `runInventoryValidationScenarios=true` | Verify invalid ranges and missing/unmapped property failures | `inventoryAccessToken`, an available fixture, and an intentionally unmapped Property fixture |
| `runInventoryAuthorizationScenarios=true` | Verify unauthenticated, foreign-branch, revoked, and scope-without-partition denial | Dedicated empty/revoked/foreign-branch tokens and fixture assignments described below |
| `runInventoryDependencyScenarios=true` | Verify Property and User/Authorization fail-closed errors | Run one request while only its named local dependency is stopped; restore it immediately |

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
Manual override is covered by the separate SCRUM-356 flow below, while
publication, active-version selection, and persisted historical evidence are
covered by the SCRUM-357 flow. The environment's
`pricingQuoteShortSnapshot`, fingerprint and total are temporary Postman
evidence only; their checked-in values remain empty.

## Manual pricing override flow

The realm does not enable password grant. First run the Authorization collection
and complete PKCE login for the SUPER_ADMIN maker so `makerAccessToken` is
populated. The override folder reuses the immutable profile created by **01
Author immutable pricing version**; it reads that profile again and recalculates
the base quote on the server before sending any mutation.

Set `runPricingAuthoring=false`, `runPricingCalculation=false`, and
`runPricingOverride=true`, then run **04 Apply audited manual pricing override**
in order. The checked-in flow:

1. proves the admin token can read `pricingVersionId`;
2. calculates a staff-created `ADMIN_PORTAL` base quote and retains only its
   temporary fingerprint/amount evidence;
3. applies a reduction at the 20% approval boundary, verifies immutable actor,
   scope, reason, correlation, before/after, expiry, precedence, component and
   recalculated-commission evidence;
4. replays the byte-identical command and proves the same artifact and complete
   response are returned;
5. reuses the same idempotency key with a changed target and requires
   `IDEMPOTENCY_KEY_REUSED`.

To additionally prove `pricing:approve-large-override`, set
`runPricingLargeOverride=true`. This last request reduces lodging by 25% and
requires the SUPER_ADMIN snapshot to contain both `pricing:override` and
`pricing:approve-large-override`. Leave the flag false when User Service has not
yet run migration V8 or its authorization cache/version has not refreshed.

Override records and command evidence are append-only. There is deliberately no
cleanup request. Clear `pricingOverrideIdempotencyKey`,
`pricingOverrideCorrelationId`, `pricingLargeOverrideIdempotencyKey`, and
`pricingLargeOverrideCorrelationId` before intentionally starting a new command;
retain them only for the exact replay cases. Keep both override flags `false`
during ordinary smoke runs and never commit populated tokens or evidence.

## Pricing publication and snapshot flow

Publication is append-only. Run **01 Author immutable pricing version** first
with a new profile; a profile that was already published cannot be republished
under another command. Both publication preview and publish pass that immutable
identity as the contract field `rateProfileVersionId`. Keep the authoring,
calculation, and override flags disabled after their prerequisite data has been
created, then set
`runPricingPublication=true` and run **05 Publish pricing and preserve immutable
snapshots** in order:

1. preview the authored profile and retain its canonical fingerprint plus the
   current property publication head;
2. publish with `pricing:approve` using both expected values, then replay the
   exact command to prove idempotency;
3. preview a quote without supplying a profile ID, proving the server selects
   the effective published profile for the complete stay;
4. create an immutable `booking_quotes` pricing snapshot, replay the exact
   command, and read the stored evidence without recalculation;
5. submit a different valid fingerprint and require `STALE_BASE_QUOTE`.

The folder uses the same SHORT staff-created input as the override flow so the
optional consumption case can match exactly. To exercise it, run folder 04
immediately beforehand, retain the unexpired `pricingOverrideId`, and also set
`runPricingOverrideConsumption=true`. The last two requests consume that exact
override once and prove that an exact idempotent replay still returns the
original snapshot despite the one-consumer guard.

Clear all `pricingPublication*`, `pricingPublishedQuote*`, `pricingSnapshot*`,
and `pricingOverrideConsumption*` evidence before intentionally starting a new
publication command. Leave both SCRUM-357 flags `false` for ordinary smoke
runs. No cleanup request exists because publications, outbox facts, overrides,
and pricing snapshots are audit evidence.

## Exact-unit inventory observation flow

`ViStay-Inventory.postman_collection.json` is a dedicated read-only collection
for SCRUM-358. It contains no mutation, block-write request, idempotency key, or
cleanup request. All four inventory flags are checked in as `false`, so importing
or running the collection with repository defaults skips every live request. CI
validates the request shape and JavaScript assertions; it does not claim that an
optional seeded scenario ran against a live stack.

There is intentionally no generic SQL block fixture in this repository. Direct
ad-hoc inserts could bypass Booking's revision updates, repeatable-read behavior,
and blocking-range exclusion invariant. No public block-write API or shared seed
script exists yet: keep the flags `false` until a disposable fixture has been
prepared through a Booking-owned integration-test/controlled seed path after all
service migrations have run. Never seed shared or production data. Use the same
half-open request range in the environment (`2027-06-10` through `2027-06-13`)
and populate these IDs:

| Variable | Required disposable fixture state |
| --- | --- |
| `inventoryAvailablePropertyId` | Active Property-to-Branch membership and no overlap |
| `inventoryBookingBlockedPropertyId` | Overlapping `BOOKING/TENTATIVE` block |
| `inventoryMaintenanceBlockedPropertyId` | Overlapping `MAINTENANCE/ACTIVE` block |
| `inventoryChannelBlockedPropertyId` | Overlapping `CHANNEL/ACTIVE` block with a nonblank normalized provider and opaque external reference |
| `inventoryHistoryOnlyPropertyId` | Overlapping `RELEASED` and `CANCELLED` rows only |
| `inventoryAdjacentPropertyId` | One block ending exactly at check-in and one starting exactly at checkout; neither overlaps |
| `inventoryUnmappedPropertyId` | Existing exact unit with no active Property-to-Branch membership |
| `inventoryForeignPropertyId` | Active unit in a branch different from the branch-bound caller |
| `inventoryMissingPropertyId` | Valid UUID that does not exist; the checked-in value is reserved for this local test |

For the available fixture, also copy its authoritative branch, Property
membership version, and current Booking inventory revision into
`inventoryExpectedBranchId`, `inventoryExpectedMembershipVersion`, and
`inventoryExpectedRevision`. The positive assertion compares these exact values;
it does not accept merely nonempty metadata.

Obtain tokens through Backoffice PKCE. `inventoryAccessToken` must represent an
active account with `inventory:read` and either explicit `ALL` for an allowed
global role or the exact current `BRANCH` partition. The other token variables
must represent, respectively, a foreign branch, a revoked/inactive assignment,
and an `OWN`, `SELF`, or `ASSIGNED` grant without the exact branch partition.
Never copy one powerful token into the denial variables.

Run folders in order, enabling only the corresponding flag. A successful seeded
run proves available and blocked outcomes, sanitized channel evidence,
nonblocking history, adjacency, stable validation/property codes, and fail-closed
authorization. For dependency injection, first force an authorization cache miss.
Then stop only Property for **Property partition dependency unavailable**, or only
User for **Authorization dependency unavailable**, run that single request, and
restart the dependency before continuing. Both requests require the exact stable
error and reject any object that could be mistaken for `available: true`.

The response contract deliberately exposes only property/range, availability,
revision, branch-membership evidence, observation time, and sanitized overlap
type/status/range/provider. It must never expose an inventory/block ID,
booking/hold ID, external channel reference, reason/notes, identity/PII,
commercial amount, credential, raw authorization evidence, dependency address,
or SQL text.

## Payment activation

The checked-in local configuration defaults to `PAYMENT_ACTIVATION_MODE=DISABLED`.
Positive payment creation requires a valid Finance payment request and
`GENERATE_ONLY` or `CALLBACK_ENABLED`. VietQR callback requests additionally
require `CALLBACK_ENABLED`; returning `404` while disabled is intentional.
