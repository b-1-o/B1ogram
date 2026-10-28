-- Fog Wallet card catalog, artwork, activation throttling, admin audit, and Telegram numeric IDs.
-- Existing account links are backfilled when the user reconnects through Telegram OIDC.
ALTER TABLE users ADD COLUMN telegram_id TEXT;

CREATE UNIQUE INDEX IF NOT EXISTS idx_users_telegram_id
  ON users(telegram_id);

CREATE TABLE IF NOT EXISTS card_assets (
  design_id TEXT PRIMARY KEY REFERENCES card_designs(id),
  mime_type TEXT NOT NULL CHECK (mime_type IN ('image/jpeg', 'image/png', 'image/webp')),
  data_base64 TEXT NOT NULL,
  size_bytes INTEGER NOT NULL CHECK (size_bytes > 0 AND size_bytes <= 327680),
  updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS card_activation_attempts (
  user_id TEXT NOT NULL REFERENCES users(id),
  bucket_start INTEGER NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  PRIMARY KEY (user_id, bucket_start)
);

CREATE INDEX IF NOT EXISTS idx_card_activation_attempts_bucket
  ON card_activation_attempts(bucket_start);

CREATE TABLE IF NOT EXISTS admin_audit_events (
  id TEXT PRIMARY KEY,
  action TEXT NOT NULL,
  metadata_json TEXT NOT NULL CHECK (json_valid(metadata_json)),
  created_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_admin_audit_events_created
  ON admin_audit_events(created_at DESC);

-- Standard cards can be claimed without a user-entered activation code.
-- A server-generated internal code row keeps cards.activation_code_id non-null.
-- Limited cards reserve one print-run slot per issued/redeemable code.
DROP TRIGGER IF EXISTS trg_activation_code_design_limit;

CREATE TRIGGER trg_activation_code_design_limit
BEFORE INSERT ON activation_codes
WHEN COALESCE((SELECT kind FROM card_designs WHERE id = NEW.design_id), '') NOT IN ('standard', 'limited')
  OR (
    (SELECT kind FROM card_designs WHERE id = NEW.design_id) = 'limited'
    AND (SELECT COUNT(*) FROM activation_codes WHERE design_id = NEW.design_id) >=
        (SELECT edition_size FROM card_designs WHERE id = NEW.design_id)
  )
BEGIN
  SELECT RAISE(ABORT, 'activation_code_design_limit');
END;
