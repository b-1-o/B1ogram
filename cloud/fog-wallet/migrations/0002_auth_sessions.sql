-- Telegram-authenticated opaque sessions.
-- Store hashes only; raw session tokens are returned once to the client.
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

-- Prevent a captured Telegram ID token from being exchanged for multiple
-- application sessions. Tokens expire quickly; expired hashes are pruned on login.
CREATE TABLE IF NOT EXISTS used_auth_tokens (
  token_hash TEXT PRIMARY KEY,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  CHECK (expires_at > created_at)
);

CREATE INDEX IF NOT EXISTS idx_used_auth_tokens_expiry
  ON used_auth_tokens(expires_at);
