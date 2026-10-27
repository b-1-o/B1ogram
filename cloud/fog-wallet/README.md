# Fog Wallet Cloudflare infrastructure

This directory is the source of truth for the Fog Wallet Worker and D1 schema.

## Cloud resources

- **Worker:** `fog-wallet-api`
- **D1 database:** `fog-wallet-db`
- **D1 ID:** `87080a92-8b59-4699-a62f-1719244c2590`
- **D1 location hint:** WNAM (Western North America)
- **Read replicas:** disabled to minimize resources for the first release
- **R2:** not yet enabled; public artwork storage will be added only when account-level R2 access is enabled

The database lives in Cloudflare, not inside GitHub. The repository contains configuration and migrations so the schema can be reviewed and reproduced. Never commit Cloudflare API tokens, Telegram Client Secrets, authentication tokens, or private signing keys.

## Opt-in Telegram connection

Fog Wallet connection is separate from the app's existing MTProto sign-in. The user stays signed in to Biogram as usual and explicitly chooses to connect Fog Wallet. The Web OIDC flow does not require Apple's Team ID or a native-app registration in BotFather.

Register these exact allowed URLs in BotFather → the selected bot → Login Widget → OpenID:

- **Redirect URL:** `https://fog-wallet-api.collab-docs-b1o.workers.dev/v1/auth/telegram/callback`
- **Trusted Origin:** `https://fog-wallet-api.collab-docs-b1o.workers.dev`

BotFather will show a Client ID and Client Secret. Configure them on the Worker:

- **Variable** `TELEGRAM_CLIENT_ID`: the Client ID from BotFather. It is public configuration, but is kept in Worker settings to avoid duplicating values in code.
- **Secret** `TELEGRAM_CLIENT_SECRET`: the Client Secret from BotFather. Store it only in Cloudflare Worker Secrets. Never place it in the iOS app or GitHub.

The authorization flow requests `openid profile` so the server can compare Telegram's signed numeric `id` claim to the Telegram account ID currently active in Biogram. The Worker uses only the signed identity subject for the Fog Wallet account and does not persist the returned profile fields. It does not request phone-number access or permission for the bot to send messages.

### API routes

- `GET /health` — minimal Worker/D1 health check.
- `POST /v1/connect/telegram/start` — starts a short-lived OIDC connection flow. JSON body: `{"expected_telegram_id":"<current Biogram Telegram user ID>"}`. Returns an authorization URL and a one-time flow ID.
- `GET /v1/auth/telegram/callback` — Telegram's registered redirect URI. Exchanges the authorization code server-side, validates the ID-token signature/issuer/audience/expiry/nonce/account ID, and marks the flow complete.
- `POST /v1/connect/telegram/status` — JSON body `{"flow_id":"<flow ID from start>"}`; returns pending/failed or returns a short-lived connection session exactly once after success.
- `GET /v1/me` — returns the current Fog Wallet user when sent `Authorization: Bearer <access_token>`.
- `POST /v1/connect/disconnect` — revokes all active Fog Wallet sessions for the connected user and disables their public profile-card setting. It does not delete issued-card ownership or the transfer ledger.
- All other routes return `404`.

The start and status endpoints are designed for native iOS API calls; no browser JavaScript widget is hosted on this origin. The app should poll status only while the user is actively completing the connection and must stop on completion, cancellation, app backgrounding, or timeout. Store the access token in iOS Keychain, never in logs or URLs.

### Security and user consent

- The flow uses random state, nonce, and PKCE S256. A transaction expires after ten minutes.
- The Worker exchanges the OAuth authorization code using the Client Secret stored only as a Cloudflare Secret.
- The Worker pins JWT verification to RS256 and validates the issuer, audience, expiry, issue time, nonce, and signed Telegram account ID.
- Session tokens are random opaque values; D1 stores only SHA-256 hashes. Sessions expire after 30 days.
- Flow IDs are random one-time polling credentials stored by hash. A completed flow can issue a session only once.
- Disconnect revokes active sessions and disables the public card setting; it does not erase card records, limited-edition proof, or transfer history.
- This is a first implementation, not yet fully integrated into the iOS UI. Before public launch, add platform-level rate limiting and run end-to-end testing for cancellation, expiry, replay, account mismatch, disconnect, and reconnect.

## Deploy

Use Node.js and Wrangler from the repository environment:

```sh
npx wrangler login
npx wrangler deploy --config cloud/fog-wallet/wrangler.jsonc
```

The Worker name and D1 binding in `wrangler.jsonc` point to the existing Fog Wallet resources.

## Database migrations

- `0001_initial.sql` defines the card schema.
- `0002_oauth_linking.sql` defines short-lived OIDC flows and revocable sessions.

The initial live schema was created through the Cloudflare API before the migration file was committed, and the transfer-acceptance trigger was tightened directly in D1. Wrangler has not yet recorded these live schema changes in its migration history. Review migration SQL before running it on an existing remote database.

```sh
npx wrangler d1 migrations apply fog-wallet-db --remote --config cloud/fog-wallet/wrangler.jsonc
```

Do not use this configuration with a different database ID unless you intend to initialize another Fog Wallet environment.

## Design principles

- No long-running server or background polling loops.
- D1 stores compact relational records; card rendering and animation run locally in iOS.
- Public immutable art assets may be hosted separately in R2 after it is enabled.
- Private API responses remain uncached.
- Every privileged operation is authorized inside the Worker; hiding a UI control is not access control.
