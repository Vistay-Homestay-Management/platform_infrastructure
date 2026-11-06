# Frontend integration guide

## Recommended implementation order

1. Implement OIDC Authorization Code + PKCE (S256) for the Backoffice realm
   using the public client `vistay-backoffice-web`.
2. Store the access token in the frontend's existing session mechanism and send
   `Authorization: Bearer <token>` to the GraphQL endpoint. Do not put tokens
   in URLs, Redux/business state, or logs.
3. Load `viewer` first. Treat `PROFILE_NOT_PROVISIONED`, inactive grants and
   `UNAUTHENTICATED` as explicit UI states, not empty data.
4. Build profile and authorization screens using the returned `version` and
   `authorizationVersion`; send the last observed value back on mutations.
5. Add session/security screens and notification cursor persistence after the
   identity shell is stable.
6. Keep Host routes behind a feature flag until the Host realm is enabled in the
   target environment.

## Browser configuration

For the current local stack:

```dotenv
# Backoffice web
VITE_GRAPHQL_URL=http://graphql.localhost/graphql
VITE_AUTH_URL=http://identity.localhost/realms/vistay-backoffice

# Host web, only after the Host realm gate is enabled
VITE_HOST_GRAPHQL_URL=http://host-api.localhost/graphql
VITE_HOST_AUTH_URL=http://identity.localhost/realms/vistay-host
```

The browser should call Nginx hostnames. Internal Compose names are only for
service-to-service traffic.

## Minimum Backoffice viewer query

```graphql
query Viewer {
  viewer {
    accountId
    profileId
    displayName
    email
    contactPhone
    avatarMediaId
    profileVersion
    roles
    permissions
    grants { permissionCode scopes }
    authorizationVersion
  }
}
```

## Profile update pattern

```graphql
mutation UpdateProfile($input: UpdateMyProfileInput!) {
  updateMyProfile(input: $input) {
    accountId
    profileId
    displayName
    contactPhone
    avatarMediaId
    version
    updatedAt
    replayed
  }
}
```

Example variables should use the version returned by `myProfile` or `viewer`:

```json
{
  "input": {
    "displayName": "Updated display name",
    "contactPhone": "+84900000000",
    "avatarMediaId": null,
    "expectedVersion": 1,
    "reason": "User requested profile correction",
    "idempotencyKey": "runtime-generated-uuid"
  }
}
```

On a version conflict, refetch the profile and show a non-destructive retry
state. Never silently overwrite another update.

## Authorization screens

Use `authorizationSubject` or `authorizationSubjectByAccount` to render the
current role assignments and effective grants. Use:

- `requestAuthorizationChange` for a pending role request;
- `approveAuthorizationChange` or `rejectAuthorizationChange` for the checker;
- `reduceAuthorizationScopes` for least-privilege reduction;
- `revokeRoleAssignment` for removal;
- `authorizationAudit` for the timeline.

The UI should show role code, permission code, scopes, expiry, request status,
reason and audit correlation ID. Do not infer permissions from route names or
hard-code a role as equivalent to `ALL`.

## Session and error UX

- 401/`UNAUTHENTICATED`: clear the session and restart PKCE login.
- 403/partition denial: show an authorization message without revealing the
  target resource's existence.
- `VERSION_CONFLICT`/`STALE_VERSION`: refetch and offer an explicit retry.
- `IDEMPOTENCY_KEY_REUSED`: preserve the original command result and do not
  generate a second mutation automatically.
- Network/5xx: show a retryable state with the correlation/request ID when the
  edge returns one; never print Authorization headers.

## Host UI status

The current `frontend_host` shell is visual-only and contains fixture cards for
homes, revenue, occupancy and activity. Replace those fixtures in this order:

1. OIDC Host login and realm-disabled/error state;
2. `myProfile` for the account header and editable profile;
3. property/booking/finance screens only when their approved Host contract is
   exposed by the Host supergraph;
4. lifecycle/session/recovery controls after the Host identity runtime gate.

The Postman evidence collection in `postman/` documents the intended invitation,
activation, replay, PKCE, lifecycle and negative behavior without committing
credentials.
