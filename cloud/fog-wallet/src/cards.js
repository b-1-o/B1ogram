import { ADMIN_HTML } from "./admin.js";

const API_ORIGIN = "https://fog-wallet-api.collab-docs-b1o.workers.dev";
const MAX_ART_BYTES = 320 * 1024;
const CODE_BATCH_MAX = 100;

function normalizeCode(value) {
  return typeof value === "string" ? value.trim().toUpperCase().replace(/[^A-Z0-9]/g, "") : "";
}
function randomChars(length) {
  const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  const bytes = crypto.getRandomValues(new Uint8Array(length));
  let out = "";
  for (let i = 0; i < bytes.length; i++) out += alphabet[bytes[i] % alphabet.length];
  return out;
}
function newSerial() {
  return "FG-" + new Date().getUTCFullYear() + "-" + randomChars(8);
}
function newActivationCode() {
  const raw = randomChars(12);
  return "FOG-" + raw.slice(0, 4) + "-" + raw.slice(4, 8) + "-" + raw.slice(8, 12);
}
function parseObject(value, fallback = {}) {
  try {
    const parsed = JSON.parse(value || "{}");
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : fallback;
  } catch {
    return fallback;
  }
}
function publicDesign(row) {
  const design = parseObject(row.design_json);
  return {
    id: row.id,
    slug: row.slug,
    title: row.title,
    series: row.series,
    kind: row.kind,
    rarity: typeof design.rarity === "string" ? design.rarity : (row.kind === "limited" ? "Limited" : "Standard"),
    subtitle: typeof design.subtitle === "string" ? design.subtitle : "",
    palette: Array.isArray(design.palette) ? design.palette : ["#171719", "#414146", "#D8D2C7"],
    ornament: typeof design.ornament === "string" ? design.ornament : "orbit",
    edition_size: row.edition_size == null ? null : Number(row.edition_size),
    enabled: Number(row.enabled) === 1,
    issued_count: row.issued_count == null ? 0 : Number(row.issued_count),
    code_count: row.code_count == null ? 0 : Number(row.code_count),
    available_codes: row.available_codes == null ? 0 : Number(row.available_codes),
    remaining: row.kind === "limited" && row.edition_size != null
      ? Math.max(0, Number(row.edition_size) - Number(row.code_count || 0))
      : null,
    asset_url: Number(row.has_art || 0) === 1 ? API_ORIGIN + "/v1/assets/" + encodeURIComponent(row.id) : null,
    design
  };
}
async function getDesign(db, id, includeDisabled = false) {
  const where = includeDisabled ? "" : "AND d.enabled = 1";
  return db.prepare(
    "SELECT d.*,\n" +
    " (SELECT COUNT(*) FROM cards c WHERE c.design_id = d.id) AS issued_count,\n" +
    " (SELECT COUNT(*) FROM activation_codes ac WHERE ac.design_id = d.id) AS code_count,\n" +
    " (SELECT COUNT(*) FROM activation_codes ac WHERE ac.design_id = d.id AND ac.claimed_at IS NULL AND ac.revoked_at IS NULL AND (ac.expires_at IS NULL OR ac.expires_at > CAST(strftime('%s','now') AS INTEGER))) AS available_codes,\n" +
    " EXISTS(SELECT 1 FROM card_assets a WHERE a.design_id = d.id) AS has_art\n" +
    " FROM card_designs d WHERE d.id = ? " + where + " LIMIT 1"
  ).bind(id).first();
}
async function listDesigns(db, enabledOnly = false) {
  const where = enabledOnly ? "WHERE d.enabled = 1" : "";
  const result = await db.prepare(
    "SELECT d.*,\n" +
    " (SELECT COUNT(*) FROM cards c WHERE c.design_id = d.id) AS issued_count,\n" +
    " (SELECT COUNT(*) FROM activation_codes ac WHERE ac.design_id = d.id) AS code_count,\n" +
    " (SELECT COUNT(*) FROM activation_codes ac WHERE ac.design_id = d.id AND ac.claimed_at IS NULL AND ac.revoked_at IS NULL AND (ac.expires_at IS NULL OR ac.expires_at > CAST(strftime('%s','now') AS INTEGER))) AS available_codes,\n" +
    " EXISTS(SELECT 1 FROM card_assets a WHERE a.design_id = d.id) AS has_art\n" +
    " FROM card_designs d " + where + " ORDER BY d.created_at DESC"
  ).all();
  return (result.results || []).map(publicDesign);
}
async function createSignedCertificate(env, tools, card) {
  const keyText = env.FOG_CARD_SIGNING_KEY;
  if (typeof keyText !== "string" || keyText.length < 32) throw new Error("card_signing_key_not_configured");
  const payloadObject = {
    v: 1,
    card_id: card.id,
    serial: card.serial,
    design_id: card.designId,
    issued_at: card.issuedAt,
    receipt_id: card.receiptId,
    owner_digest: await tools.sha256Hex(card.telegramSub)
  };
  const payload = JSON.stringify(payloadObject);
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(keyText), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const signature = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(payload)));
  return { payload, signature: bytesToBase64Url(signature) };
}
function bytesToBase64Url(bytes) {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}
function base64UrlToBytes(value) {
  const base64 = value.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - value.length % 4) % 4);
  const binary = atob(base64);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}
async function verifyCertificate(env, payload, signature) {
  const keyText = env.FOG_CARD_SIGNING_KEY;
  if (typeof keyText !== "string" || keyText.length < 32) return false;
  try {
    const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(keyText), { name: "HMAC", hash: "SHA-256" }, false, ["verify"]);
    return await crypto.subtle.verify("HMAC", key, base64UrlToBytes(signature), new TextEncoder().encode(payload));
  } catch {
    return false;
  }
}
function maskedProof(signature) {
  return "FGP-" + signature.slice(0, 8) + "-••••••-" + signature.slice(-6);
}
async function writeAudit(db, action, metadata = {}) {
  try {
    await db.prepare(
      "INSERT INTO admin_audit_events (id, action, metadata_json, created_at) VALUES (?, ?, ?, ?)"
    ).bind(crypto.randomUUID(), action, JSON.stringify(metadata), Math.floor(Date.now() / 1000)).run();
  } catch {
    // Audit failures must not expose internal D1 details.
  }
}
async function requireUser(request, env, tools) {
  let user;
  try {
    user = await tools.authenticate(request, env);
  } catch {
    return { response: tools.json({ error: "database_unavailable" }, 503) };
  }
  if (!user) return { response: tools.json({ error: "unauthorized" }, 401) };
  if (!user.telegram_id) return { response: tools.json({ error: "telegram_identity_refresh_required" }, 409) };
  return { user };
}
async function isAdmin(request, env, tools) {
  const expected = env.FOG_ADMIN_TOKEN;
  const header = request.headers.get("authorization") || "";
  const supplied = header.startsWith("Bearer ") ? header.slice(7) : "";
  if (typeof expected !== "string" || expected.length < 32 || !supplied || supplied.length > 512) return false;
  const pair = await Promise.all([tools.sha256Hex(expected), tools.sha256Hex(supplied)]);
  let different = 0;
  for (let i = 0; i < pair[0].length; i++) different |= pair[0].charCodeAt(i) ^ pair[1].charCodeAt(i);
  return different === 0;
}
function activationCodeExpired(row, now) {
  return row.revoked_at != null || row.claimed_at != null || (row.expires_at != null && Number(row.expires_at) <= now);
}
async function createCardRecord(db, env, tools, args) {
  const now = Math.floor(Date.now() / 1000);
  const cardId = crypto.randomUUID();
  const serial = newSerial();
  const receiptId = crypto.randomUUID();
  const codeId = args.codeId || crypto.randomUUID();
  const privateCodeHash = args.codeHash || await tools.sha256Hex("internal:" + tools.randomToken());
  const cert = await createSignedCertificate(env, tools, {
    id: cardId, serial, designId: args.design.id, issuedAt: now, receiptId, telegramSub: args.user.telegram_sub
  });
  const statements = [];
  if (args.createCode) {
    statements.push(db.prepare(
      "INSERT INTO activation_codes (id, code_hash, design_id, intended_user_id, created_by_admin, created_at, expires_at, revoked_at, claimed_at, claimed_by_user_id)\n" +
      "VALUES (?, ?, ?, ?, ?, ?, NULL, NULL, NULL, NULL)"
    ).bind(codeId, privateCodeHash, args.design.id, args.user.id, args.source || "system", now));
  }
  statements.push(db.prepare(
    "UPDATE activation_codes SET claimed_at = ?, claimed_by_user_id = ?\n" +
    "WHERE id = ? AND claimed_at IS NULL AND revoked_at IS NULL\n" +
    "AND (expires_at IS NULL OR expires_at > ?) AND (intended_user_id IS NULL OR intended_user_id = ?)"
  ).bind(now, args.user.id, codeId, now, args.user.id));
  statements.push(db.prepare(
    "INSERT INTO cards (id, serial, owner_user_id, design_id, activation_code_id, receipt_id, certificate_payload, certificate_signature, issued_at, updated_at)\n" +
    "SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, ? WHERE EXISTS (\n" +
    " SELECT 1 FROM activation_codes WHERE id = ? AND design_id = ? AND claimed_at = ? AND claimed_by_user_id = ? AND revoked_at IS NULL\n" +
    ")"
  ).bind(cardId, serial, args.user.id, args.design.id, codeId, receiptId, cert.payload, cert.signature, now, now, codeId, args.design.id, now, args.user.id));
  statements.push(db.prepare(
    "INSERT INTO card_events (id, card_id, actor_user_id, event_type, metadata_json, created_at)\n" +
    "SELECT ?, ?, ?, 'issued', ?, ? WHERE EXISTS (SELECT 1 FROM cards WHERE id = ?)"
  ).bind(crypto.randomUUID(), cardId, args.actorUserId || args.user.id, JSON.stringify({ source: args.source || "activation" }), now, cardId));
  statements.push(db.prepare(
    "INSERT INTO user_card_settings (user_id, selected_design_id, customization_json, public_enabled, updated_at)\n" +
    "VALUES (?, ?, '{}', 0, ?) ON CONFLICT(user_id) DO UPDATE SET\n" +
    "selected_design_id = COALESCE(excluded.selected_design_id, user_card_settings.selected_design_id), updated_at = excluded.updated_at"
  ).bind(args.user.id, args.design.kind === "standard" ? args.design.id : null, now));
  const batch = await db.batch(statements);
  const cardInsertIndex = args.createCode ? 2 : 1;
  if (!batch[cardInsertIndex]?.meta || Number(batch[cardInsertIndex].meta.changes || 0) !== 1) throw new Error("activation_code_claim_conflict");
  return { id: cardId, serial, receipt_id: receiptId, issued_at: now, title: args.design.title, rarity: args.design.rarity, signature: cert.signature, proof: maskedProof(cert.signature) };
}
async function issueCardToUser(db, env, tools, design, user, source) {
  const codeHash = await tools.sha256Hex("internal-admin:" + tools.randomToken());
  return createCardRecord(db, env, tools, {
    design, user, createCode: true, codeId: crypto.randomUUID(), codeHash, source, actorUserId: null
  });
}
async function cardPayload(db, env, row, ownerVisible = true) {
  const designRow = await getDesign(db, row.design_id, true);
  if (!designRow) return null;
  const item = {
    id: row.id,
    serial: row.serial,
    issued_at: Number(row.issued_at),
    updated_at: Number(row.updated_at),
    receipt_id: row.receipt_id,
    proof: maskedProof(row.certificate_signature),
    certificate_verified: await verifyCertificate(env, row.certificate_payload, row.certificate_signature),
    design: publicDesign(designRow)
  };
  if (ownerVisible) item.certificate_payload = row.certificate_payload;
  return item;
}
async function catalog(request, env, tools) {
  try {
    return tools.json({ designs: await listDesigns(env.DB, true) });
  } catch {
    return tools.json({ error: "database_unavailable" }, 503);
  }
}
async function collection(request, env, tools, user) {
  try {
    const rows = await env.DB.prepare(
      "SELECT c.id, c.serial, c.design_id, c.receipt_id, c.certificate_payload, c.certificate_signature, c.issued_at, c.updated_at\n" +
      "FROM cards c WHERE c.owner_user_id = ? ORDER BY c.issued_at DESC LIMIT 200"
    ).bind(user.id).all();
    const cards = [];
    for (const row of rows.results || []) {
      const item = await cardPayload(env.DB, env, row, true);
      if (item) cards.push(item);
    }
    return tools.json({ cards });
  } catch {
    return tools.json({ error: "database_unavailable" }, 503);
  }
}
async function cardDetails(request, env, tools, user, cardId) {
  try {
    const row = await env.DB.prepare(
      "SELECT c.id, c.serial, c.design_id, c.receipt_id, c.certificate_payload, c.certificate_signature, c.issued_at, c.updated_at\n" +
      "FROM cards c WHERE c.id = ? AND c.owner_user_id = ? LIMIT 1"
    ).bind(cardId, user.id).first();
    if (!row) return tools.json({ error: "card_not_found" }, 404);
    const item = await cardPayload(env.DB, env, row, true);
    const events = await env.DB.prepare("SELECT event_type, metadata_json, created_at FROM card_events WHERE card_id = ? ORDER BY created_at DESC LIMIT 30").bind(cardId).all();
    item.events = (events.results || []).map((event) => ({ type: event.event_type, metadata: parseObject(event.metadata_json), created_at: Number(event.created_at) }));
    return tools.json({ card: item });
  } catch {
    return tools.json({ error: "database_unavailable" }, 503);
  }
}
async function claimStandard(request, env, tools, user) {
  const parsed = await tools.readJson(request);
  if (parsed.error) return parsed.error;
  const designId = String(parsed.value?.design_id || "");
  if (!/^[A-Za-z0-9_-]{1,80}$/.test(designId)) return tools.json({ error: "design_id_required" }, 400);
  let designRow;
  try { designRow = await getDesign(env.DB, designId); } catch { return tools.json({ error: "database_unavailable" }, 503); }
  if (!designRow) return tools.json({ error: "design_not_found" }, 404);
  const design = publicDesign(designRow);
  if (design.kind !== "standard") return tools.json({ error: "activation_code_required" }, 409);
  try {
    const existing = await env.DB.prepare(
      "SELECT c.id, c.serial, c.design_id, c.receipt_id, c.certificate_payload, c.certificate_signature, c.issued_at, c.updated_at\n" +
      "FROM cards c WHERE c.owner_user_id = ? AND c.design_id = ? ORDER BY c.issued_at ASC LIMIT 1"
    ).bind(user.id, designId).first();
    if (existing) return tools.json({ card: await cardPayload(env.DB, env, existing, true), already_owned: true });
    const card = await createCardRecord(env.DB, env, tools, {
      design, user, createCode: true, codeId: crypto.randomUUID(),
      codeHash: await tools.sha256Hex("catalog:" + tools.randomToken()),
      source: "catalog_claim", actorUserId: user.id
    });
    const row = await env.DB.prepare(
      "SELECT id, serial, design_id, receipt_id, certificate_payload, certificate_signature, issued_at, updated_at FROM cards WHERE id = ? LIMIT 1"
    ).bind(card.id).first();
    return tools.json({ card: await cardPayload(env.DB, env, row, true), already_owned: false }, 201);
  } catch (error) {
    const isKeyError = error?.message === "card_signing_key_not_configured";
    return tools.json({ error: isKeyError ? error.message : "card_issue_failed" }, isKeyError ? 503 : 409);
  }
}
async function activateCode(request, env, tools, user) {
  const parsed = await tools.readJson(request);
  if (parsed.error) return parsed.error;
  const normalized = normalizeCode(parsed.value?.code);
  if (normalized.length < 10 || normalized.length > 64) return tools.json({ error: "invalid_activation_code" }, 400);
  const now = Math.floor(Date.now() / 1000);
  const bucket = Math.floor(now / 600) * 600;
  try {
    const attempt = await env.DB.prepare("SELECT attempts FROM card_activation_attempts WHERE user_id = ? AND bucket_start = ? LIMIT 1").bind(user.id, bucket).first();
    if (Number(attempt?.attempts || 0) >= 10) return tools.json({ error: "too_many_attempts" }, 429);
    const codeHash = await tools.sha256Hex(normalized);
    const codeRow = await env.DB.prepare(
      "SELECT ac.id, ac.design_id, ac.intended_user_id, ac.revoked_at, ac.claimed_at, ac.expires_at,\n" +
      "d.slug, d.title, d.series, d.kind, d.design_json, d.asset_key, d.edition_size, d.enabled, d.created_at, d.updated_at,\n" +
      "(SELECT COUNT(*) FROM cards c WHERE c.design_id=d.id) AS issued_count,\n" +
      "(SELECT COUNT(*) FROM activation_codes x WHERE x.design_id=d.id) AS code_count,\n" +
      "(SELECT COUNT(*) FROM activation_codes x WHERE x.design_id=d.id AND x.claimed_at IS NULL AND x.revoked_at IS NULL) AS available_codes,\n" +
      "EXISTS(SELECT 1 FROM card_assets a WHERE a.design_id=d.id) AS has_art\n" +
      "FROM activation_codes ac JOIN card_designs d ON d.id = ac.design_id WHERE ac.code_hash = ? LIMIT 1"
    ).bind(codeHash).first();
    if (!codeRow || activationCodeExpired(codeRow, now) || Number(codeRow.enabled) !== 1 ||
        (codeRow.intended_user_id && codeRow.intended_user_id !== user.id)) {
      await env.DB.prepare(
        "INSERT INTO card_activation_attempts (user_id, bucket_start, attempts) VALUES (?, ?, 1)\n" +
        "ON CONFLICT(user_id, bucket_start) DO UPDATE SET attempts = attempts + 1"
      ).bind(user.id, bucket).run();
      return tools.json({ error: "activation_code_invalid_or_used" }, 400);
    }
    const card = await createCardRecord(env.DB, env, tools, {
      design: publicDesign(codeRow), user, codeId: codeRow.id, createCode: false, source: "activation_code", actorUserId: user.id
    });
    await env.DB.prepare("DELETE FROM card_activation_attempts WHERE user_id = ? AND bucket_start = ?").bind(user.id, bucket).run();
    const row = await env.DB.prepare(
      "SELECT id, serial, design_id, receipt_id, certificate_payload, certificate_signature, issued_at, updated_at FROM cards WHERE id = ? LIMIT 1"
    ).bind(card.id).first();
    return tools.json({ card: await cardPayload(env.DB, env, row, true) }, 201);
  } catch (error) {
    const isKeyError = error?.message === "card_signing_key_not_configured";
    return tools.json({ error: isKeyError ? error.message : "activation_code_claim_failed" }, isKeyError ? 503 : 409);
  }
}
async function setFeatured(request, env, tools, user) {
  const parsed = await tools.readJson(request);
  if (parsed.error) return parsed.error;
  const cardId = String(parsed.value?.card_id || "");
  const now = Math.floor(Date.now() / 1000);
  try {
    const card = await env.DB.prepare("SELECT id FROM cards WHERE id = ? AND owner_user_id = ? LIMIT 1").bind(cardId, user.id).first();
    if (!card) return tools.json({ error: "card_not_found" }, 404);
    await env.DB.prepare(
      "INSERT INTO user_card_settings (user_id, featured_card_id, customization_json, public_enabled, updated_at)\n" +
      "VALUES (?, ?, '{}', 0, ?) ON CONFLICT(user_id) DO UPDATE SET featured_card_id = excluded.featured_card_id, updated_at = excluded.updated_at"
    ).bind(user.id, cardId, now).run();
    await env.DB.prepare("INSERT INTO card_events (id, card_id, actor_user_id, event_type, metadata_json, created_at) VALUES (?, ?, ?, 'featured', '{}', ?)").bind(crypto.randomUUID(), cardId, user.id, now).run();
    return tools.json({ ok: true, featured_card_id: cardId });
  } catch {
    return tools.json({ error: "database_unavailable" }, 503);
  }
}
async function createUserTransfer(request, env, tools, user) {
  const parsed = await tools.readJson(request);
  if (parsed.error) return parsed.error;
  const cardId = String(parsed.value?.card_id || "");
  const recipientTelegramId = String(parsed.value?.recipient_telegram_id || "");
  if (!/^\d{1,24}$/.test(recipientTelegramId)) return tools.json({ error: "recipient_telegram_id_required" }, 400);
  const recipient = await env.DB.prepare("SELECT id FROM users WHERE telegram_id = ? LIMIT 1").bind(recipientTelegramId).first();
  if (!recipient) return tools.json({ error: "recipient_not_connected" }, 404);
  if (recipient.id === user.id) return tools.json({ error: "cannot_transfer_to_self" }, 400);
  const card = await env.DB.prepare("SELECT id, serial FROM cards WHERE id = ? AND owner_user_id = ? LIMIT 1").bind(cardId, user.id).first();
  if (!card) return tools.json({ error: "card_not_found" }, 404);
  const now = Math.floor(Date.now() / 1000), token = tools.randomToken(), transferId = crypto.randomUUID();
  try {
    await env.DB.batch([
      env.DB.prepare("INSERT INTO card_transfers (id, card_id, sender_user_id, recipient_user_id, token_hash, status, created_at, expires_at, accepted_at, cancelled_at) VALUES (?, ?, ?, ?, ?, 'pending', ?, ?, NULL, NULL)").bind(transferId, cardId, user.id, recipient.id, await tools.sha256Hex(token), now, now + 86400),
      env.DB.prepare("INSERT INTO card_events (id, card_id, actor_user_id, event_type, metadata_json, created_at) VALUES (?, ?, ?, 'transfer_created', ?, ?)").bind(crypto.randomUUID(), cardId, user.id, JSON.stringify({ recipient_telegram_id: recipientTelegramId }), now)
    ]);
    return tools.json({ transfer_id: transferId, token, expires_at: now + 86400 });
  } catch {
    return tools.json({ error: "transfer_create_failed_or_already_pending" }, 409);
  }
}
async function acceptUserTransfer(request, env, tools, user) {
  const parsed = await tools.readJson(request);
  if (parsed.error) return parsed.error;
  const token = String(parsed.value?.token || "");
  if (!/^[A-Za-z0-9_-]{40,128}$/.test(token)) return tools.json({ error: "transfer_token_required" }, 400);
  const now = Math.floor(Date.now() / 1000), tokenHash = await tools.sha256Hex(token);
  try {
    const transfer = await env.DB.prepare(
      "SELECT t.id, t.card_id, t.sender_user_id, t.recipient_user_id, t.expires_at, c.serial\n" +
      "FROM card_transfers t JOIN cards c ON c.id = t.card_id\n" +
      "WHERE t.token_hash = ? AND t.status = 'pending' LIMIT 1"
    ).bind(tokenHash).first();
    if (!transfer || transfer.recipient_user_id !== user.id || Number(transfer.expires_at) <= now) return tools.json({ error: "transfer_not_available" }, 404);
    await env.DB.batch([
      env.DB.prepare("UPDATE card_transfers SET status = 'accepted', accepted_at = ? WHERE id = ? AND status = 'pending' AND recipient_user_id = ? AND expires_at > ?").bind(now, transfer.id, user.id, now),
      env.DB.prepare("UPDATE cards SET owner_user_id = ?, updated_at = ? WHERE id = ? AND owner_user_id = ? AND EXISTS (SELECT 1 FROM card_transfers WHERE id = ? AND status = 'accepted')").bind(user.id, now, transfer.card_id, transfer.sender_user_id, transfer.id),
      env.DB.prepare("INSERT INTO card_events (id, card_id, actor_user_id, event_type, metadata_json, created_at) VALUES (?, ?, ?, 'transfer_accepted', '{}', ?)").bind(crypto.randomUUID(), transfer.card_id, user.id, now)
    ]);
    return tools.json({ ok: true, serial: transfer.serial });
  } catch {
    return tools.json({ error: "transfer_accept_failed" }, 409);
  }
}
async function cancelUserTransfer(request, env, tools, user) {
  const parsed = await tools.readJson(request);
  if (parsed.error) return parsed.error;
  const transferId = String(parsed.value?.transfer_id || ""), now = Math.floor(Date.now() / 1000);
  try {
    const transfer = await env.DB.prepare("SELECT id, card_id FROM card_transfers WHERE id = ? AND sender_user_id = ? AND status = 'pending' LIMIT 1").bind(transferId, user.id).first();
    if (!transfer) return tools.json({ error: "transfer_not_found" }, 404);
    await env.DB.batch([
      env.DB.prepare("UPDATE card_transfers SET status = 'cancelled', cancelled_at = ? WHERE id = ? AND status = 'pending'").bind(now, transferId),
      env.DB.prepare("INSERT INTO card_events (id, card_id, actor_user_id, event_type, metadata_json, created_at) VALUES (?, ?, ?, 'transfer_cancelled', '{}', ?)").bind(crypto.randomUUID(), transfer.card_id, user.id, now)
    ]);
    return tools.json({ ok: true });
  } catch {
    return tools.json({ error: "transfer_cancel_failed" }, 409);
  }
}
async function verifyPublicCard(request, env, tools, url) {
  const serial = (url.searchParams.get("serial") || "").trim().toUpperCase();
  if (!/^FG-\d{4}-[A-Z0-9]{6,12}$/.test(serial)) return tools.json({ error: "serial_required" }, 400);
  try {
    const row = await env.DB.prepare(
      "SELECT c.serial, c.certificate_payload, c.certificate_signature, c.issued_at, d.title FROM cards c\n" +
      "JOIN card_designs d ON d.id = c.design_id WHERE c.serial = ? LIMIT 1"
    ).bind(serial).first();
    if (!row) return tools.json({ valid: false, reason: "not_found" }, 404);
    const valid = await verifyCertificate(env, row.certificate_payload, row.certificate_signature);
    return tools.json({ valid, serial: row.serial, title: row.title, issued_at: Number(row.issued_at), reason: valid ? null : "signature_invalid" });
  } catch {
    return tools.json({ error: "verification_unavailable" }, 503);
  }
}
async function readAsset(request, env, tools, id) {
  if (request.method !== "GET") return tools.json({ error: "method_not_allowed" }, 405);
  let row;
  try { row = await env.DB.prepare("SELECT mime_type, data_base64 FROM card_assets WHERE design_id = ? LIMIT 1").bind(id).first(); }
  catch { return tools.json({ error: "asset_unavailable" }, 503); }
  if (!row) return tools.json({ error: "asset_not_found" }, 404);
  try {
    const binary = atob(row.data_base64), bytes = Uint8Array.from(binary, (c) => c.charCodeAt(0));
    return new Response(bytes, { status: 200, headers: {
      "Content-Type": row.mime_type, "Cache-Control": "public, max-age=86400, immutable",
      "X-Content-Type-Options": "nosniff", "Cross-Origin-Resource-Policy": "same-site",
      "Content-Security-Policy": "default-src 'none'; frame-ancestors 'none'"
    }});
  } catch { return tools.json({ error: "asset_corrupt" }, 500); }
}
function normalizeRecipientIdentifier(value) {
  const raw = String(value ?? "").trim();
  if (/^\d{1,24}$/.test(raw)) return { type: "id", value: raw };
  const username = raw.replace(/^@/, "").trim();
  if (/^[A-Za-z0-9_]{1,64}$/.test(username)) return { type: "username", value: username.toLowerCase() };
  return null;
}
async function findUserByRecipient(db, value, columns = "id, telegram_sub, telegram_id, username, display_name, created_at") {
  const identifier = normalizeRecipientIdentifier(value);
  if (!identifier) return null;
  if (identifier.type === "id") {
    return db.prepare("SELECT " + columns + " FROM users WHERE telegram_id = ? LIMIT 1").bind(identifier.value).first();
  }
  return db.prepare("SELECT " + columns + " FROM users WHERE LOWER(username) = ? LIMIT 1").bind(identifier.value).first();
}
async function adminApi(request, env, url, tools) {
  if (!await isAdmin(request, env, tools)) return tools.json({ error: "admin_unauthorized" }, 401);
  const path = url.pathname, method = request.method, now = Math.floor(Date.now() / 1000);
  if (path === "/v1/admin/overview" && method === "GET") {
    try {
      const result = await env.DB.batch([
        env.DB.prepare("SELECT COUNT(*) AS count FROM card_designs"),
        env.DB.prepare("SELECT COUNT(*) AS count FROM cards"),
        env.DB.prepare("SELECT COUNT(*) AS count FROM users"),
        env.DB.prepare("SELECT COUNT(*) AS count FROM activation_codes WHERE claimed_at IS NULL AND revoked_at IS NULL")
      ]);
      return tools.json({ designs: Number(result[0]?.results?.[0]?.count || 0), cards: Number(result[1]?.results?.[0]?.count || 0), users: Number(result[2]?.results?.[0]?.count || 0), unused_codes: Number(result[3]?.results?.[0]?.count || 0) });
    } catch { return tools.json({ error: "database_unavailable" }, 503); }
  }
  if (path === "/v1/admin/designs" && method === "GET") {
    try { return tools.json({ designs: await listDesigns(env.DB, false) }); }
    catch { return tools.json({ error: "database_unavailable" }, 503); }
  }
  if (path === "/v1/admin/designs" && method === "POST") {
    const parsed = await tools.readJson(request, 24 * 1024);
    if (parsed.error) return parsed.error;
    const body = parsed.value || {};
    const title = String(body.title || "").trim().slice(0, 80);
    const slug = String(body.slug || "").trim().toLowerCase();
    const series = String(body.series || "Fog Originals").trim().slice(0, 80);
    const kind = body.kind === "limited" ? "limited" : body.kind === "standard" ? "standard" : "";
    const rarity = String(body.rarity || (kind === "limited" ? "Rare" : "Standard")).trim().slice(0, 32);
    const subtitle = String(body.subtitle || "").trim().slice(0, 120);
    const palette = Array.isArray(body.palette) ? body.palette.slice(0, 4).filter((color) => typeof color === "string" && /^#[0-9A-Fa-f]{6}$/.test(color)) : [];
    const edition = kind === "limited" ? Number(body.edition_size) : null;
    if (!title || !kind || !/^[a-z0-9][a-z0-9-]{1,59}$/.test(slug) || !series ||
        (kind === "limited" && (!Number.isInteger(edition) || edition < 1 || edition > 10000))) return tools.json({ error: "invalid_design" }, 400);
    const id = crypto.randomUUID();
    const metadata = { rarity, subtitle, palette: palette.length >= 2 ? palette : ["#111113", "#34343A", "#E5D4B8"], ornament: ["orbit", "ribbon", "halo", "grid"].includes(body.ornament) ? body.ornament : "orbit" };
    try {
      await env.DB.prepare(
        "INSERT INTO card_designs (id, slug, title, series, kind, design_json, asset_key, edition_size, enabled, created_at, updated_at)\n" +
        "VALUES (?, ?, ?, ?, ?, ?, NULL, ?, 1, ?, ?)"
      ).bind(id, slug, title, series, kind, JSON.stringify(metadata), edition, now, now).run();
      await writeAudit(env.DB, "design_created", { id, slug, kind, rarity });
      return tools.json({ design: publicDesign(await getDesign(env.DB, id, true)) }, 201);
    } catch { return tools.json({ error: "design_slug_conflict_or_database_error" }, 409); }
  }
  const artMatch = path.match(/^\/v1\/admin\/designs\/([^/]+)\/art$/);
  if (artMatch && (method === "POST" || method === "PUT")) {
    const id = decodeURIComponent(artMatch[1]);
    const parsed = await tools.readJson(request, 500 * 1024);
    if (parsed.error) return parsed.error;
    const mime = String(parsed.value?.mime_type || ""), base64 = String(parsed.value?.data_base64 || "");
    if (!["image/jpeg", "image/png", "image/webp"].includes(mime) || !/^[A-Za-z0-9+/]*={0,2}$/.test(base64) || base64.length > 450 * 1024) return tools.json({ error: "invalid_artwork" }, 400);
    const bytes = Math.floor(base64.length * 3 / 4);
    if (bytes > MAX_ART_BYTES) return tools.json({ error: "artwork_too_large" }, 400);
    if (!await getDesign(env.DB, id, true)) return tools.json({ error: "design_not_found" }, 404);
    try {
      await env.DB.prepare(
        "INSERT INTO card_assets (design_id, mime_type, data_base64, size_bytes, updated_at)\n" +
        "VALUES (?, ?, ?, ?, ?) ON CONFLICT(design_id) DO UPDATE SET mime_type=excluded.mime_type,\n" +
        "data_base64=excluded.data_base64, size_bytes=excluded.size_bytes, updated_at=excluded.updated_at"
      ).bind(id, mime, base64, bytes, now).run();
      await writeAudit(env.DB, "artwork_uploaded", { design_id: id, mime_type: mime, size_bytes: bytes });
      return tools.json({ ok: true, asset_url: API_ORIGIN + "/v1/assets/" + encodeURIComponent(id), size_bytes: bytes });
    } catch { return tools.json({ error: "artwork_save_failed" }, 503); }
  }
  const designMatch = path.match(/^\/v1\/admin\/designs\/([^/]+)$/);
  if (designMatch && method === "PATCH") {
    const id = decodeURIComponent(designMatch[1]);
    const parsed = await tools.readJson(request, 12 * 1024);
    if (parsed.error) return parsed.error;
    const current = await getDesign(env.DB, id, true);
    if (!current) return tools.json({ error: "design_not_found" }, 404);
    const body = parsed.value || {};
    const enabled = body.enabled === false ? 0 : body.enabled === true ? 1 : Number(current.enabled);
    const title = typeof body.title === "string" ? body.title.trim().slice(0, 80) : current.title;
    const series = typeof body.series === "string" ? body.series.trim().slice(0, 80) : current.series;
    const metadata = parseObject(current.design_json);
    if (typeof body.rarity === "string") metadata.rarity = body.rarity.trim().slice(0, 32);
    if (typeof body.subtitle === "string") metadata.subtitle = body.subtitle.trim().slice(0, 120);
    if (Array.isArray(body.palette)) metadata.palette = body.palette.slice(0, 4).filter((color) => typeof color === "string" && /^#[0-9A-Fa-f]{6}$/.test(color));
    try {
      await env.DB.prepare("UPDATE card_designs SET title=?, series=?, design_json=?, enabled=?, updated_at=? WHERE id=?").bind(title || current.title, series || current.series, JSON.stringify(metadata), enabled, now, id).run();
      await writeAudit(env.DB, enabled ? "design_updated" : "design_disabled", { design_id: id, enabled: !!enabled });
      return tools.json({ design: publicDesign(await getDesign(env.DB, id, true)) });
    } catch { return tools.json({ error: "design_update_failed" }, 503); }
  }
  const codesMatch = path.match(/^\/v1\/admin\/designs\/([^/]+)\/codes$/);
  if (codesMatch && method === "POST") {
    const id = decodeURIComponent(codesMatch[1]), parsed = await tools.readJson(request, 8 * 1024);
    if (parsed.error) return parsed.error;
    const count = Number(parsed.value?.count || 1);
    if (!Number.isInteger(count) || count < 1 || count > CODE_BATCH_MAX) return tools.json({ error: "count_must_be_1_to_100" }, 400);
    let design;
    try { design = await getDesign(env.DB, id, true); } catch { return tools.json({ error: "database_unavailable" }, 503); }
    if (!design || Number(design.enabled) !== 1) return tools.json({ error: "design_not_enabled" }, 404);
    if (design.kind !== "limited") return tools.json({ error: "activation_codes_require_limited_design" }, 409);
    const issuedTo = String(parsed.value?.recipient ?? parsed.value?.telegram_id ?? "");
    let intendedUserId = null;
    if (issuedTo) {
      const recipient = await findUserByRecipient(env.DB, issuedTo, "id");
      if (!recipient) return tools.json({ error: "recipient_not_connected" }, 404);
      intendedUserId = recipient.id;
    }

    for (let i = 0; i < count; i++) {
      const code = newActivationCode();
      generated.push(code);
      statements.push(env.DB.prepare(
        "INSERT INTO activation_codes (id, code_hash, design_id, intended_user_id, created_by_admin, created_at, expires_at, revoked_at, claimed_at, claimed_by_user_id)\n" +
        "VALUES (?, ?, ?, ?, 'admin:code-generation', ?, NULL, NULL, NULL, NULL)"
      ).bind(crypto.randomUUID(), await tools.sha256Hex(normalizeCode(code)), id, intendedUserId, now));
    }
    try {
      await env.DB.batch(statements);
      await writeAudit(env.DB, "activation_codes_generated", { design_id: id, count, intended_user_id: intendedUserId });
      return tools.json({ codes: generated, count, shown_once: true }, 201);
    } catch { return tools.json({ error: "edition_limit_reached_or_code_generation_failed" }, 409); }
  }
  if (path === "/v1/admin/codes" && method === "GET") {
    const designId = url.searchParams.get("design_id") || "";
    try {
      const rows = await env.DB.prepare(
        "SELECT ac.id, ac.design_id, ac.created_by_admin, ac.created_at, ac.expires_at, ac.revoked_at, ac.claimed_at,\n" +
        "ac.claimed_by_user_id, d.title, u.telegram_id FROM activation_codes ac JOIN card_designs d ON d.id=ac.design_id\n" +
        "LEFT JOIN users u ON u.id=ac.claimed_by_user_id WHERE (? = '' OR ac.design_id = ?) ORDER BY ac.created_at DESC LIMIT 200"
      ).bind(designId, designId).all();
      return tools.json({ codes: rows.results || [] });
    } catch { return tools.json({ error: "database_unavailable" }, 503); }
  }
  const revokeMatch = path.match(/^\/v1\/admin\/codes\/([^/]+)\/revoke$/);
  if (revokeMatch && method === "POST") {
    const id = decodeURIComponent(revokeMatch[1]);
    try {
      const result = await env.DB.prepare("UPDATE activation_codes SET revoked_at=? WHERE id=? AND claimed_at IS NULL AND revoked_at IS NULL").bind(now, id).run();
      if (Number(result.meta?.changes || 0) !== 1) return tools.json({ error: "code_missing_or_already_used" }, 409);
      await writeAudit(env.DB, "activation_code_revoked", { code_id: id });
      return tools.json({ ok: true });
    } catch { return tools.json({ error: "code_revoke_failed" }, 503); }
  }
  if (path === "/v1/admin/cards" && method === "GET") {
    const query = (url.searchParams.get("q") || "").trim().slice(0, 80);
    try {
      const rows = await env.DB.prepare(
        "SELECT c.id, c.serial, c.issued_at, c.updated_at, c.owner_user_id, c.design_id, d.title AS design_title, d.kind, d.design_json,\n" +
        "u.telegram_id, u.username FROM cards c JOIN card_designs d ON d.id=c.design_id JOIN users u ON u.id=c.owner_user_id\n" +
        "WHERE (? = '' OR c.serial LIKE ? OR u.telegram_id = ? OR d.title LIKE ?) ORDER BY c.issued_at DESC LIMIT 150"
      ).bind(query, "%" + query + "%", query, "%" + query + "%").all();
      return tools.json({ cards: rows.results || [] });
    } catch { return tools.json({ error: "database_unavailable" }, 503); }
  }
  if (path === "/v1/admin/cards/assign" && method === "POST") {
    const parsed = await tools.readJson(request, 8 * 1024);
    if (parsed.error) return parsed.error;
    const designId = String(parsed.value?.design_id || ""), recipientInput = String(parsed.value?.recipient ?? parsed.value?.telegram_id ?? "");
    if (!normalizeRecipientIdentifier(recipientInput)) return tools.json({ error: "recipient_username_or_telegram_id_required" }, 400);
    try {
      const designRow = await getDesign(env.DB, designId);
      const user = await findUserByRecipient(env.DB, recipientInput, "id, telegram_sub, telegram_id, username");
      if (!designRow) return tools.json({ error: "design_not_found" }, 404);
      if (!user) return tools.json({ error: "recipient_not_connected" }, 404);
      const card = await issueCardToUser(env.DB, env, tools, publicDesign(designRow), user, "admin_assignment");
      await writeAudit(env.DB, "card_assigned", { serial: card.serial, design_id: designId, recipient: user.username ? "@" + user.username : user.telegram_id });
      return tools.json({ card }, 201);
    } catch (error) {
      const message = error?.message === "card_signing_key_not_configured" ? error.message : "card_issue_failed";
      return tools.json({ error: message }, message === "card_signing_key_not_configured" ? 503 : 409);
    }
  }
  if (path === "/v1/admin/cards/transfer" && method === "POST") {
    const parsed = await tools.readJson(request, 8 * 1024);
    if (parsed.error) return parsed.error;
    const serial = String(parsed.value?.serial || "").trim().toUpperCase(), recipientInput = String(parsed.value?.recipient ?? parsed.value?.telegram_id ?? "");
    if (!serial || !normalizeRecipientIdentifier(recipientInput)) return tools.json({ error: "serial_and_recipient_required" }, 400);
    try {
      const card = await env.DB.prepare("SELECT id, serial, owner_user_id FROM cards WHERE serial=? LIMIT 1").bind(serial).first();
      const recipient = await findUserByRecipient(env.DB, recipientInput, "id, telegram_id, username");
      if (!card) return tools.json({ error: "card_not_found" }, 404);
      if (!recipient) return tools.json({ error: "recipient_not_connected" }, 404);
      if (recipient.id === card.owner_user_id) return tools.json({ error: "already_owned_by_recipient" }, 409);
      const nowTs = now, transferId = crypto.randomUUID(), senderId = card.owner_user_id;
      await env.DB.batch([
        env.DB.prepare("INSERT INTO card_transfers (id, card_id, sender_user_id, recipient_user_id, token_hash, status, created_at, expires_at, accepted_at, cancelled_at) VALUES (?, ?, ?, ?, ?, 'pending', ?, ?, NULL, NULL)").bind(transferId, card.id, senderId, recipient.id, await tools.sha256Hex("admin:" + tools.randomToken()), nowTs, nowTs + 86400),
        env.DB.prepare("UPDATE card_transfers SET status='accepted', accepted_at=? WHERE id=? AND status='pending'").bind(nowTs, transferId),
        env.DB.prepare("UPDATE cards SET owner_user_id=?, updated_at=? WHERE id=? AND owner_user_id=? AND EXISTS(SELECT 1 FROM card_transfers WHERE id=? AND status='accepted')").bind(recipient.id, nowTs, card.id, senderId, transferId),
        env.DB.prepare("INSERT INTO card_events (id, card_id, actor_user_id, event_type, metadata_json, created_at) VALUES (?, ?, ?, 'transfer_created', ?, ?)").bind(crypto.randomUUID(), card.id, senderId, JSON.stringify({ admin: true, recipient_telegram_id: telegramId }), nowTs),
        env.DB.prepare("INSERT INTO card_events (id, card_id, actor_user_id, event_type, metadata_json, created_at) VALUES (?, ?, ?, 'transfer_accepted', ?, ?)").bind(crypto.randomUUID(), card.id, recipient.id, JSON.stringify({ admin: true }), nowTs)
      ]);
      await writeAudit(env.DB, "card_transferred", { serial, recipient: recipient.username ? "@" + recipient.username : recipient.telegram_id });
      return tools.json({ ok: true, serial, recipient: recipient.username ? "@" + recipient.username : recipient.telegram_id });
    } catch { return tools.json({ error: "card_transfer_failed_or_pending_transfer_exists" }, 409); }
  }
  if (path === "/v1/admin/users" && method === "GET") {
    const identifier = (url.searchParams.get("identifier") || url.searchParams.get("telegram_id") || "").trim();
    if (!normalizeRecipientIdentifier(identifier)) return tools.json({ users: [] });
    try {
      const user = await findUserByRecipient(env.DB, identifier, "id, telegram_id, username, display_name, created_at");
      return tools.json({ users: user ? [user] : [] });
    } catch { return tools.json({ error: "database_unavailable" }, 503); }
  }
  if (path === "/v1/admin/activity" && method === "GET") {
    try {
      const rows = await env.DB.prepare("SELECT id, action, metadata_json, created_at FROM admin_audit_events ORDER BY created_at DESC LIMIT 100").all();
      return tools.json({ events: (rows.results || []).map((row) => ({ id: row.id, action: row.action, metadata: parseObject(row.metadata_json), created_at: Number(row.created_at) })) });
    } catch { return tools.json({ error: "database_unavailable" }, 503); }
  }
  return tools.json({ error: "admin_route_not_found" }, 404);
}
export async function handleCardApi(request, env, url, tools) {
  const path = url.pathname;
  if ((path === "/admin" || path === "/admin/") && request.method === "GET") {
    return new Response(ADMIN_HTML, { status: 200, headers: {
      "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer", "X-Frame-Options": "DENY",
      "Content-Security-Policy": "default-src 'none'; img-src 'self' data: blob:; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'"
    }});
  }
  const assetMatch = path.match(/^\/v1\/assets\/([^/]+)$/);
  if (assetMatch) return readAsset(request, env, tools, decodeURIComponent(assetMatch[1]));
  if (path.startsWith("/v1/admin/")) {
    if (request.method === "OPTIONS") return tools.json({ error: "method_not_allowed" }, 405);
    return adminApi(request, env, url, tools);
  }
  if (path === "/v1/cards/catalog") {
    if (request.method !== "GET") return tools.json({ error: "method_not_allowed" }, 405);
    return catalog(request, env, tools);
  }
  if (path === "/v1/cards/verify") {
    if (request.method !== "GET") return tools.json({ error: "method_not_allowed" }, 405);
    return verifyPublicCard(request, env, tools, url);
  }
  if (path.startsWith("/v1/cards")) {
    if (path === "/v1/cards/transfers/accept") {
      if (request.method !== "POST") return tools.json({ error: "method_not_allowed" }, 405);
      const required = await requireUser(request, env, tools);
      if (required.response) return required.response;
      return acceptUserTransfer(request, env, tools, required.user);
    }
    const required = await requireUser(request, env, tools);
    if (required.response) return required.response;
    const user = required.user;
    if (path === "/v1/cards/collection" && request.method === "GET") return collection(request, env, tools, user);
    if (path === "/v1/cards/claim" && request.method === "POST") return claimStandard(request, env, tools, user);
    if (path === "/v1/cards/activate" && request.method === "POST") return activateCode(request, env, tools, user);
    if (path === "/v1/cards/feature" && request.method === "POST") return setFeatured(request, env, tools, user);
    if (path === "/v1/cards/transfers" && request.method === "POST") return createUserTransfer(request, env, tools, user);
    if (path === "/v1/cards/transfers/cancel" && request.method === "POST") return cancelUserTransfer(request, env, tools, user);
    const detailMatch = path.match(/^\/v1\/cards\/([^/]+)$/);
    if (detailMatch && request.method === "GET") return cardDetails(request, env, tools, user, decodeURIComponent(detailMatch[1]));
    return tools.json({ error: "cards_route_not_found" }, 404);
  }
  return null;
}
