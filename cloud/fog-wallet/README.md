# Biogram Cloud Profiles

Biogram provisions a cloud profile after the user's normal Telegram account login. The app starts this one-time verification automatically; there is no separate Fog Wallet connection screen.

## Identity and sessions

- The app sends its current Telegram numeric user ID as an expected identity, not as proof of identity.
- The Worker creates a short-lived OAuth flow using state, nonce and PKCE.
- Telegram signs the ID token. The Worker verifies the signature against Telegram's JWKS, issuer, audience, expiry, nonce and expected Telegram ID.
- A random flow token becomes the bearer session token. Only its SHA-256 hash is stored in D1.
- Sessions expire after 30 days. A new Telegram verification is required after expiration or revocation.

Register these values in @BotFather → Login Widget → Allowed URLs:

- \`https://fog-wallet-api.collab-docs-b1o.workers.dev\`
- \`https://fog-wallet-api.collab-docs-b1o.workers.dev/v1/auth/telegram/callback\`

Configure the Worker secret \`TELEGRAM_CLIENT_SECRET\`. The client ID is \`9254075951\`.

## Public profile data

The public profile contains verified display name and username, Biogram aliases, selected card palette and material, profile color and pattern, explicitly-public virtual numbers, and optional JPEG card artwork (maximum 320 KiB). Local-only banner and premium simulation settings are never uploaded.

## API

- \`POST /v1/auth/telegram/start\`
- \`GET /v1/auth/telegram/callback\`
- \`GET /v1/auth/telegram/status?flow=<flowId>\`
- \`GET /v1/profile/me\`
- \`PUT /v1/profile/me\`
- \`PUT /v1/profile/me/card-image\`
- \`DELETE /v1/profile/me/card-image\`
- \`GET /v1/profiles/<telegramId>\`
- \`POST /v1/auth/logout\`

## Deploy

\`\`\`sh
npx wrangler d1 migrations apply fog-wallet-db --remote --config cloud/fog-wallet/wrangler.jsonc
npx wrangler deploy --config cloud/fog-wallet/wrangler.jsonc
\`\`\`
