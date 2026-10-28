-- Prevent concurrent or administrative issuance from creating duplicate standard cards
-- for a single account/design. Limited editions remain individually ownable.
CREATE TABLE IF NOT EXISTS standard_card_claims (
  user_id TEXT NOT NULL REFERENCES users(id),
  design_id TEXT NOT NULL REFERENCES card_designs(id),
  card_id TEXT NOT NULL UNIQUE,
  claimed_at INTEGER NOT NULL,
  PRIMARY KEY (user_id, design_id)
);

-- Seed legacy inventory before enforcing new writes. INSERT OR IGNORE keeps the oldest
-- card in the claim ledger if pre-existing data already contains duplicates.
INSERT OR IGNORE INTO standard_card_claims (user_id, design_id, card_id, claimed_at)
SELECT c.owner_user_id, c.design_id, c.id, c.issued_at
FROM cards c
JOIN card_designs d ON d.id = c.design_id
WHERE d.kind = 'standard'
ORDER BY c.issued_at ASC;

DROP TRIGGER IF EXISTS trg_standard_card_claim_insert;
CREATE TRIGGER trg_standard_card_claim_insert
BEFORE INSERT ON cards
WHEN COALESCE((SELECT kind FROM card_designs WHERE id = NEW.design_id), '') = 'standard'
BEGIN
  INSERT INTO standard_card_claims (user_id, design_id, card_id, claimed_at)
  VALUES (NEW.owner_user_id, NEW.design_id, NEW.id, NEW.issued_at);
END;

DROP TRIGGER IF EXISTS trg_standard_card_claim_transfer;
CREATE TRIGGER trg_standard_card_claim_transfer
AFTER UPDATE OF owner_user_id ON cards
WHEN NEW.owner_user_id <> OLD.owner_user_id
  AND COALESCE((SELECT kind FROM card_designs WHERE id = NEW.design_id), '') = 'standard'
BEGIN
  DELETE FROM standard_card_claims WHERE card_id = OLD.id;
  INSERT INTO standard_card_claims (user_id, design_id, card_id, claimed_at)
  VALUES (NEW.owner_user_id, NEW.design_id, NEW.id, NEW.updated_at);
END;
