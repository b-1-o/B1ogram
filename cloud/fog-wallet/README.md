# Fog Wallet — Worker, cards and Studio

This directory is the source of truth for the Fog Wallet Cloudflare Worker, D1 schema and web-based administration page.

## Current services

- **Worker:** `fog-wallet-api`
- **D1:** `fog-wallet-db`
- **Public API:** `https://fog-wallet-api.collab-docs-b1o.workers.dev`
- **Admin Studio:** `https://fog-wallet-api.collab-docs-b1o.workers.dev/admin`

The card interface is rendered locally in Biogram. The Worker stores designs, compact artwork, card ownership, activation-code hashes, certificate signatures, transfer history and audit events.

## Required Worker settings

Keep all credentials out of Git:

- `TELEGRAM_CLIENT_ID` — plain-text Worker variable from BotFather OpenID.
- `TELEGRAM_CLIENT_SECRET` — Worker secret.
- `FOG_ADMIN_TOKEN` — random secret of at least 32 characters, used as a Bearer token for Admin Studio.
- `FOG_CARD_SIGNING_KEY` — random secret of at least 32 characters for HMAC-SHA-256 card certificates.

Generate two separate random values locally with `openssl rand -hex 32`, then add them as separate secrets in Cloudflare Worker settings. Do not put them in source files, issues, or screenshots. Rotating the signing key requires a key-versioning plan or old card proofs will fail verification.

## Telegram account linking

BotFather → selected bot → Login Widget → OpenID must list:

- Redirect: `https://fog-wallet-api.collab-docs-b1o.workers.dev/v1/auth/telegram/callback`
- Trusted origin: `https://fog-wallet-api.collab-docs-b1o.workers.dev`

The OIDC callback writes the signed Telegram numeric ID to `users.telegram_id`. Accounts created before migration 0003 must disconnect and reconnect once.

## API routes

### Account linking
- `GET /health`
- `POST /v1/connect/telegram/start`
- `GET /v1/auth/telegram/callback`
- `POST /v1/connect/telegram/status`
- `GET /v1/me`
- `POST /v1/connect/disconnect`

### Cards
- `GET /v1/cards/catalog` — enabled designs, palette, rarity, print-run count and artwork URL.
- `GET /v1/cards/collection` — authenticated user's cards.
- `GET /v1/cards/:id` — owner-only detail with signature verification and issuance events.
- `POST /v1/cards/claim` — claim an enabled standard design; one copy per design per account.
- `POST /v1/cards/activate` — redeem a single-use activation code.
- `POST /v1/cards/feature` — set a card as featured.
- `POST /v1/cards/transfers`, `POST /v1/cards/transfers/accept`, `POST /v1/cards/transfers/cancel` — ownership-transfer workflow.
- `GET /v1/cards/verify?serial=FG-YYYY-XXXXXXXX` — public certificate verification.
- `GET /v1/assets/:designId` — compact artwork.

Authenticated API requests use `Authorization: Bearer <access_token>`. The token is held in iOS Keychain; D1 stores only a token hash. Admin Studio compresses artwork in the browser and limits it to 320 KiB, stored in D1 to avoid requiring R2.

### Admin Studio
Open `/admin` and use the `FOG_ADMIN_TOKEN` as a Bearer token:
- `GET /v1/admin/overview`
- `GET/POST /v1/admin/designs`; `PATCH /v1/admin/designs/:id`
- `POST/PUT /v1/admin/designs/:id/art`
- `POST /v1/admin/designs/:id/codes` — generate up to 100 limited-edition codes per request.
- `GET /v1/admin/codes`; `POST /v1/admin/codes/:id/revoke`
- `GET /v1/admin/cards?q=...`
- `POST /v1/admin/cards/assign` and `POST /v1/admin/cards/transfer`
- `GET /v1/admin/users?telegram_id=...`
- `GET /v1/admin/activity`

Raw activation codes are displayed once and never saved in D1. Limited designs reserve one edition slot per activation-code row; a database trigger enforces the cap. The card back displays a masked proof, not the activation code. The full certificate is HMAC-SHA-256 signed by the Worker.

## Migration and deployment

Review and back up the live D1 database before applying migrations; some initial live tables were originally created manually.

```sh
npx wrangler d1 migrations apply fog-wallet-db --remote --config cloud/fog-wallet/wrangler.jsonc
npx wrangler deploy --config cloud/fog-wallet/wrangler.jsonc
```

First-card release order:
1. Set `FOG_ADMIN_TOKEN` and `FOG_CARD_SIGNING_KEY` as Worker secrets.
2. Apply migration `0003_cards_platform.sql` exactly once to the existing D1.
3. Deploy the updated Worker and the `src/cards.js` and `src/admin.js` files.
4. Open `/admin`, create a design and upload artwork.
5. Have the intended owner reconnect Fog Wallet once so their numeric Telegram ID is populated.
6. Issue the first real card from Studio to that linked numeric Telegram ID.
7. Install the latest Biogram build and test catalogue, claim, activation, serial/proof, disconnect and reconnect.

Do not manually insert a fake owned card as a seed. A card becomes real only after the service creates its ownership row and signed receipt. Run Worker/schema checks first, then dispatch one complete release-arm64 build after the code is grouped.

## Security
- Opt-in account link; no request for chats, contacts, or phone number.
- OIDC uses state, nonce, PKCE S256, server-side code exchange and RS256 ID-token verification.
- API sessions expire after 30 days. Disconnect revokes sessions but keeps card ownership and transfer history.
- Activation attempts are limited to 10 failures per account per 10-minute bucket.
- Admin routes require the admin Bearer token; the Studio stores it in sessionStorage for the current browser tab only.
- A masked proof is a display element, not a transfer credential. Certificate verification is performed server-side.
- Before wider release, test concurrency, replay, expiration, account mismatch, access control and backup/restore.
