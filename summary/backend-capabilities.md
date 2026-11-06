# Backend capabilities and current state

## 1. Platform and trust boundaries

- Nginx is the only public ingress. Backoffice and Host GraphQL are separate
  Hive Router instances and are composed from separate supergraphs.
- Backoffice uses the `vistay-backoffice` Keycloak realm. Host uses the separate
  `vistay-host` issuer and `vistay-host-api` audience; tokens must never cross
  realms or audiences.
- Authentication owns credentials, invitations, lifecycle and sessions.
  User owns profiles and authorization subjects. Keycloak owns passwords,
  required actions, refresh-token rotation and interactive sessions.
- User authorization is action + partition + field-group based. Supported data
  scopes are `SELF`, `OWN`, `ASSIGNED`, `PARTITION` and `ALL`.
- PostgreSQL databases and runtime roles are separated by bounded context;
  runtime roles do not own schemas or perform DDL.
- Kafka, gRPC mTLS, OpenTelemetry traces and Prometheus actuator metrics are
  wired into the local platform profile.

## 2. Authentication REST

Implemented endpoints available behind `http://auth.localhost` include:

### Backoffice accounts

- `POST /api/v1/backoffice/accounts`: provision a Backoffice account with an
  idempotency key.
- `POST /api/v1/backoffice/accounts/bootstrap`: controlled initial bootstrap.
- `GET /api/v1/backoffice/accounts/{accountId}`: read account security state.
- `GET /api/v1/backoffice/accounts/{accountId}/security-events`: read security
  audit events.
- `POST /api/v1/backoffice/accounts/{accountId}/lifecycle`: lock/unlock or
  suspend/reactivate an account according to the account lifecycle contract.
- `GET /api/v1/backoffice/accounts/{accountId}/sessions`: list active sessions
  as a summary projection; credentials are never returned.
- `DELETE /api/v1/backoffice/accounts/{accountId}/sessions/{sessionId}`:
  revoke one session with idempotency and correlation headers.

### Host invitation and activation

- `POST /v1/host/invitations` (also `/api/v1/host-accounts`): issue one Host
  invitation with `propertyId`, `branchId`, `accountType=HOST`, idempotency key
  and an Admin partition.
- `POST /v1/host/invitations/{invitationId}/resend`: resend a captured action
  email with a new command key.
- `POST /v1/host/invitations/{invitationId}/activate`: activate the Host
  subject after the Keycloak action reference is obtained; expected version is
  required for optimistic concurrency.

The local Mailpit sink is internal-only at `mailpit:8025`; it is not a browser
endpoint and has no public host port in the checked-in profile.

## 3. Backoffice GraphQL

Endpoint: `POST http://graphql.localhost/graphql`.

### Viewer and profile

- `viewer`: account/profile identity, roles, permissions, effective grants and
  authorization version.
- `myProfile`: the authenticated personal profile.
- `updateMyProfile(input)`: optimistic-concurrency profile update using
  `expectedVersion`, `reason` and `idempotencyKey`.

### Authorization catalogue and management

- Queries: `authorizationCatalog`, `authorizationSubject`,
  `authorizationSubjectByAccount`, `authorizationChangeRequests` and
  `authorizationAudit`.
- Mutations: `requestAuthorizationChange`, `approveAuthorizationChange`,
  `rejectAuthorizationChange`, `revokeRoleAssignment`,
  `reduceAuthorizationScopes` and `establishSecondApprover`.
- Approval is versioned and maker/checker aware; stale approval returns a
  stable `VERSION_CONFLICT` marker.

### Other federated areas already composed

The Backoffice supergraph contains the reviewed User, Booking, Notification and
Payment SDLs. Current contract families include:

- property price profile authoring, deterministic quote calculation, audited
  override and immutable quote snapshots;
- inventory availability observation, idempotent block create/release and
  management pagination;
- notification stream with opaque cursor/reconnect/deduplication behavior;
- finance/payment intent and VietQR callback boundaries, with payment callback
  activation deliberately disabled by default.

The exact fields and input types must be taken from
`router/backoffice/supergraph.graphql` or the matching Postman collection; do
not recreate a second frontend-specific API shape.

## 4. Host GraphQL

Endpoint: `POST http://host-api.localhost/graphql`.

The checked-in Host supergraph is deliberately profile-only:

- Query `myProfile` returns `accountId`, `profileId`, `displayName`, `email`,
  `contactPhone`, `avatarMediaId`, `version`, `updatedAt` and `replayed`.
- Mutation `updateMyProfile(input)` accepts `displayName`, `contactPhone`,
  `avatarMediaId`, `expectedVersion`, `reason` and `idempotencyKey`.
- Backoffice fields such as `viewer`, `authorizationCatalog` and
  `authorizationSubject` are not exposed through the Host router.

The broader Host identity contract also defines `hostViewer`, lifecycle and
session operations, but the current edge artifact only exposes the approved
profile graph. Keep Host UI code behind feature flags until the Host realm,
issuer/audience and live smoke gates are explicitly enabled.

## 5. Security and error behavior

Frontend must assume:

- missing/expired/wrong-realm credentials return `UNAUTHENTICATED`,
  `INVALID_TOKEN` or an HTTP 401/403 boundary response;
- an inactive or not-yet-provisioned account returns
  `PROFILE_NOT_PROVISIONED` rather than a partial viewer;
- stale profile/authorization/lifecycle versions return a conflict such as
  `VERSION_CONFLICT` or `STALE_VERSION`;
- reusing an idempotency key with a different canonical payload returns
  `IDEMPOTENCY_KEY_REUSED` or the corresponding stable Host conflict;
- partition or field-group violations fail closed and must not leak whether a
  foreign account/property exists.

Never store access tokens in application business state, display raw token or
action-link values in logs, or use a powerful Admin token for a negative test.

## 6. What is ready vs limited

### Ready for frontend integration

- Backoffice PKCE login against Keycloak and the Backoffice `viewer` query.
- Backoffice profile display/update with optimistic version handling.
- Role/permission/grant display and authorization request/review screens.
- Session list/revoke and account security/lifecycle screens.
- GraphQL error, idempotency, correlation and notification cursor contracts.
- Local Docker Compose routing and immutable CI image publication for the
  Authentication and User services.

### Limited or intentionally disabled

- Host realm is disabled in the checked-in baseline. The Host UI can be shaped
  now, but live PKCE/invitation/activation requires explicit environment
  enablement and secure credentials.
- `frontend_host` is currently a visual prototype with fixture data. Its Apollo
  default points to `http://localhost:8080/graphql`; integrated local usage
  should point to `http://host-api.localhost/graphql` through `VITE_GRAPHQL_URL`.
- Customer realm and customer edge are deferred in the current infrastructure
  baseline.
- Payment callbacks and production SMTP are disabled until their external
  security/UAT gates pass.
