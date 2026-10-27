# Fog Wallet Cloudflare infrastructure

This directory is the source of truth for the Fog Wallet Worker and D1 schema.

## Cloud resources

- **Worker:** `fog-wallet-api`
- **D1 database:** `fog-wallet-db`
- **D1 ID:** `87080a92-8b59-4699-a62f-1719244c2590`
- **D1 location hint:** WNAM (Western North America)
- **Read replicas:** disabled to minimize resources for the first release
- **R2:** not yet enabled; image hosting will be added only when account-level R2 access is enabled

The database lives in the Cloudflare account, not inside GitHub. The repository contains configuration and migrations so the schema can be reviewed and reproduced. Never commit API tokens, private signing keys, activation-code secrets, authentication credentials, or admin credentials.

## Current API

- `GET /health` — minimal Worker/D1 health check.
- `POST /v1/auth/telegram` — verify a Telegram Login OIDC ID token and create an application session.
- `GET /v1/me` — return the current authenticated user.
- `POST /v1/auth/logout` — revoke the current session.
- Other routes return `404`.

### Telegram Login setup

1. Register Biogram's exact iOS app identifiers with Telegram using the official [Telegram Login for iOS SDK](https://github.com/TelegramMessenger/telegram-login-ios) instructions in [Telegram's Login documentation](https://core.telegram.org/bots/telegram-login).
2. Use the default **RS256** ID-token signing algorithm while this Worker is configured for RS256.
3. In **Cloudflare Dashboard → Workers & Pages → fog-wallet-api → Settings → Variables and Secrets**, add a plain-text **Variable** named `TELEGRAM_CLIENT_ID` with the Client ID from @BotFather. The Client ID is public configuration, not a secret.
4. The iOS app must use the official SDK's OAuth Authorization Code + PKCE flow, then send the returned `idToken` to `POST /v1/auth/telegram` as JSON: `{"id_token":"<id-token>"}`. Never send a user ID alone as proof of identity.
5. Do not add the Telegram Client Secret to this Worker for this native SDK flow. The SDK obtains the ID token, and the Worker validates Telegram's signature against Telegram's public JWKS. Do not place a Client Secret inside the iOS app either.
6. If `TELEGRAM_CLIENT_ID` is missing or invalid, login fails closed with `503 telegram_login_not_configured`. This is intentional.

### Authentication security

- The Worker pins JWT verification to RS256, validates Telegram's issuer, audience, subject, issue time and expiry, and refreshes public keys when an unknown key ID appears.
- Each verified ID token may be exchanged once. Only its SHA-256 hash is stored in D1 to help prevent replay.
- The Worker creates a cryptographically random opaque session token. The raw token is returned once; D1 stores only its SHA-256 hash.
- App sessions expire after 30 days. `POST /v1/auth/logout` revokes a session.
- Session tokens must be sent as `Authorization: Bearer <access_token>`. Do not log tokens or include them in URLs.
- The Worker does not yet implement card catalog, activation-code issuance, limited-card issuance, transfer, or admin routes. Do not treat the service as production-ready for real users until those endpoints, authorization rules, abuse controls, and integration tests are complete.

## Deploy

Install Node.js and Wrangler in the repository environment, then authenticate with Cloudflare:

```sh
npx wrangler login
npx wrangler deploy --config cloud/fog-wallet/wrangler.jsonc
```

The Worker name and D1 binding in `wrangler.jsonc` point to the existing Fog Wallet resources.

## Database migrations

- `0001_initial.sql` defines the initial card schema.
- `0002_auth_sessions.sql` defines opaque sessions and one-time authentication-token hashes.

The live initial schema was created through the Cloudflare API before the migration file was committed, and the transfer-acceptance trigger was tightened directly in D1. Wrangler has not yet recorded the initial migration in its migration history. The first migration uses `IF NOT EXISTS` for its schema objects and replaces the transfer-acceptance trigger with the stricter rule that only a pending transfer may be accepted.

Apply migrations to the existing remote database only after reviewing the SQL:

```sh
npx wrangler d1 migrations apply fog-wallet-db --remote --config cloud/fog-wallet/wrangler.jsonc
```

Do not use this configuration with a different database ID unless you intend to initialize another Fog Wallet environment.

## Design principles

- No long-running server or polling loops.
- D1 stores compact relational records; card rendering and animation run locally in iOS.
- Public immutable art assets may be hosted separately in R2 after it is enabled.
- Private API responses remain uncached.
- Every privileged operation must be authorized inside the Worker; hiding an admin button in the UI is not access control.
- Configure platform-level rate limiting before public launch. Do not build expensive per-request polling into the mobile app.
