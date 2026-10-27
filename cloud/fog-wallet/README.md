# Fog Wallet Cloudflare infrastructure

This directory is the source of truth for the initial Fog Wallet Cloudflare Worker and D1 schema.

## Cloud resources

- **Worker:** `fog-wallet-api`
- **D1 database:** `fog-wallet-db`
- **D1 ID:** `87080a92-8b59-4699-a62f-1719244c2590`
- **D1 location hint:** WNAM (Western North America)
- **Read replicas:** disabled to minimize resources for the first release
- **R2:** not yet enabled; image hosting will be added only when account-level R2 access is enabled

The database was created in the Cloudflare account, not inside GitHub. The repository contains configuration and migration files so the schema can be reviewed and reproduced. Never commit API tokens, HMAC secrets, signing private keys, Telegram client secrets, or admin credentials.

## Current API status

The deployed Worker currently exposes only `GET /health`, which performs a minimal `SELECT 1` query against D1. Other paths return `404`. Activation, authentication, card issuance, admin endpoints, public profiles, and transfers are **not implemented yet**. Do not treat the service as production-ready for real users until these endpoints, authentication, and abuse controls are implemented and tested.

## Deploy

Install Node.js and Wrangler in the repository environment, then authenticate with Cloudflare:

```sh
npx wrangler login
npx wrangler deploy --config cloud/fog-wallet/wrangler.jsonc
```

The Worker name and D1 binding in `wrangler.jsonc` point to the existing Fog Wallet resources.

## Database migrations

The live schema was created through the Cloudflare API before this migration file was committed, and the deployed database's transfer-acceptance trigger has also been tightened directly. Wrangler has not yet recorded this migration in its migration history. The migration uses `IF NOT EXISTS` for schema objects and replaces the transfer-acceptance trigger with the stricter rule that only a pending transfer may be accepted.

To sync Wrangler's migration history and apply this migration to the existing remote database:

```sh
npx wrangler d1 migrations apply fog-wallet-db --remote --config cloud/fog-wallet/wrangler.jsonc
```

Review the proposed migration before running it. Do not use this configuration with a different database ID unless you intend to initialize another Fog Wallet environment.

## Design principles

- No long-running server or polling loops.
- D1 stores small relational records; the client performs card rendering and animation locally.
- Public immutable art assets will be hosted separately in R2 after it is enabled and cached at the edge.
- Private API responses must remain uncached.
- Every privileged operation must be authorized inside the Worker; hiding an admin button in the UI is not an access-control mechanism.
