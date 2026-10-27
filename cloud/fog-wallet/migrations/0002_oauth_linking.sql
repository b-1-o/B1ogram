-- Opt-in Telegram OIDC linking and revocable Fog Wallet API sessions.
-- Never store raw session tokens; only SHA-256 token hashes are stored.
CREATE TABLE IF NOT EXISTS user_sessions (
  token_hash TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id),
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  revoked_at INTEGER,
  CHECK (expires_at > created_at),
  CHECK (revoked_at IS NULL OR revoked_at >= created_at)
);

CREATE INDEX IF NOT EXISTS idx_user_sessions_user_expiry
  ON user_sessions(user_id, expires_at DESC);

CREATE INDEX IF NOT EXISTS idx_user_sessions_expiry
  ON user_sessions(expires_at);

-- State hashes prevent CSRF; flow ID hashes authorize one-time polling from the app.
-- PKCE verifier and nonce are short-lived and deleted when the flow expires.
CREATE TABLE IF NOT EXISTS telegram_oauth_flows (
  state_hash TEXT PRIMARY KEY,
  flow_id_hash TEXT NOT NULL UNIQUE,
  expected_telegram_id TEXT NOT NULL,
  nonce TEXT NOT NULL,
  code_verifier TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'completed', 'failed')),
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  user_id TEXT REFERENCES users(id),
  error_code TEXT,
  consumed_at INTEGER,
  CHECK (expires_at > created_at),
  CHECK (status <> 'completed' OR user_id IS NOT NULL),
  CHECK (consumed_at IS NULL OR status = 'completed')
);

CREATE INDEX IF NOT EXISTS idx_telegram_oauth_flows_expiry
  ON telegram_oauth_flows(expires_at);

CREATE INDEX IF NOT EXISTS idx_telegram_oauth_flows_expected_status
  ON telegram_oauth_flows(expected_telegram_id, status);
