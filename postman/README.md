# ViStay Epic 01 Postman

Import both files into Postman:

- `ViStay-Epic01.postman_collection.json`
- `ViStay-Local.postman_environment.json`

Select the **ViStay Local** environment before sending requests.

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

Never commit populated secret values or an exported environment containing
tokens.

## Backoffice access token

The realm deliberately disables the resource-owner password grant. Sign in at
`http://admin.localhost` through Authorization Code + PKCE, then copy the
session's `access_token` into the Postman `accessToken` environment variable.
The authenticated GraphQL requests send both `Authorization: Bearer ...` and
the required `X-CSRF-Token` header.

## Payment activation

The checked-in local configuration defaults to `PAYMENT_ACTIVATION_MODE=DISABLED`.
Positive payment creation requires a valid Finance payment request and
`GENERATE_ONLY` or `CALLBACK_ENABLED`. VietQR callback requests additionally
require `CALLBACK_ENABLED`; returning `404` while disabled is intentional.

