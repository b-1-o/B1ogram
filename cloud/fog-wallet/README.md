# Biogram profile appearance

Biogram now keeps profile-card artwork and material choices on the device and uses Telegram's native profile-color API for the public profile accent.

## Native iOS profile card

The iOS settings screen includes a 3D profile-card studio:
- The card has separate front and back faces, perspective rotation, drag-to-tilt interaction and a spring return.
- The front supports a photo selected from the user's library or one of Biogram's existing palette colors.
- Surface choices are matte, glossy and metallic.
- The back shows the Telegram username, numeric Telegram ID and a decorative profile signature. The signature is not an authorization token, activation code, or payment credential.
- Artwork and material preferences are stored in the app's local account-specific settings. They are not uploaded to this Worker.

## Public profile colors

The profile-color control retains Biogram's existing palette. When a color is selected, Biogram maps it to the nearest Telegram-supported profile color and asks Telegram to save it, so other Telegram/Biogram clients can display the native profile-color accent. Telegram supports a fixed set of profile colors; it cannot publish Biogram's arbitrary RGB shade or custom card artwork through this API.

## Retired service

The previous Fog Wallet collection, card issuance, activation codes, admin Studio and Telegram OAuth-linking endpoints have been retired. Legacy endpoints return HTTP 410. The Worker only exposes `GET /health` for operational checks.

The old D1 database and migration files are intentionally retained as dormant historical data; this repository does not drop the database or erase its records. It is no longer bound to the Worker.

## Deploy

From the repository root:

```sh
npx wrangler deploy --config cloud/fog-wallet/wrangler.jsonc
```

Do not add back the retired D1 binding, OAuth client secret or card-signing/admin secrets unless a new, reviewed feature explicitly needs them.
