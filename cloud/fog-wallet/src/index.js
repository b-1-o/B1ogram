const API_VERSION = "2.0.0";
const CALLBACK_URL = "https://fog-wallet-api.collab-docs-b1o.workers.dev/v1/auth/telegram/callback";
const APP_RETURN_URL = "biogram://oauth/callback";
const SESSION_SECONDS = 60 * 60 * 24 * 30;
const FLOW_SECONDS = 60 * 10;
const MAX_IMAGE_BYTES = 327680;
const ALLOWED_PALETTES = new Set(["Blue", "Dark Red", "Purple", "Green", "Orange", "Teal", "Pink", "Gray", "Black", "White"]);
const ALLOWED_MATERIALS = new Set(["matte", "glossy", "metallic"]);
const ALLOWED_PATTERNS = new Set(["none", "skulls", "pentagrams", "stars", "crosses", "snowflakes", "frost"]);

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET,POST,PUT,DELETE,OPTIONS",
  "Access-Control-Allow-Headers": "Authorization,Content-Type",
  "Access-Control-Max-Age": "86400"
};

function json(data, status = 200, extraHeaders = {}) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      ...CORS,
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
      "Referrer-Policy": "no-referrer",
      "Content-Security-Policy": "default-src 'none'; frame-ancestors 'none'",
      ...extraHeaders
    }
  });
}

function fail(error, status = 400, extra = {}) {
  return json({ error, ...extra }, status);
}

function nowSeconds() {
  return Math.floor(Date.now() / 1000);
}

function bytesToHex(bytes) {
  return Array.from(bytes, value => value.toString(16).padStart(2, "0")).join("");
}

function bytesToBase64Url(bytes) {
  let binary = "";
  for (const value of bytes) binary += String.fromCharCode(value);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

function base64UrlToBytes(value) {
  let base64 = String(value).replace(/-/g, "+").replace(/_/g, "/");
  while (base64.length % 4) base64 += "=";
  const binary = atob(base64);
  return Uint8Array.from(binary, character => character.charCodeAt(0));
}

function decodeJwtPart(value) {
  return JSON.parse(new TextDecoder().decode(base64UrlToBytes(value)));
}

async function sha256(value) {
  const data = new TextEncoder().encode(value);
  return bytesToHex(new Uint8Array(await crypto.subtle.digest("SHA-256", data)));
}

function randomToken(size = 32) {
  const bytes = new Uint8Array(size);
  crypto.getRandomValues(bytes);
  return bytesToBase64Url(bytes);
}

async function readJson(request, maxBytes = 512 * 1024) {
  const contentLength = Number(request.headers.get("Content-Length") || 0);
  if (contentLength > maxBytes) throw new Error("request_too_large");
  const raw = await request.text();
  if (new TextEncoder().encode(raw).byteLength > maxBytes) throw new Error("request_too_large");
  try {
    return raw ? JSON.parse(raw) : {};
  } catch {
    throw new Error("invalid_json");
  }
}

function redirectToApp(flowId, error) {
  const url = new URL(APP_RETURN_URL);
  if (flowId) url.searchParams.set("flow", flowId);
  if (error) url.searchParams.set("error", error);
  return Response.redirect(url.toString(), 302);
}

async function getFlow(db, stateHash) {
  return db.prepare(
    "SELECT state_hash, flow_id_hash, expected_telegram_id, nonce, code_verifier, status, created_at, expires_at, user_id, error_code, consumed_at, is_new_user FROM telegram_oauth_flows WHERE state_hash = ? LIMIT 1"
  ).bind(stateHash).first();
}

async function verifyTelegramIdToken(idToken, env, expectedNonce) {
  const parts = String(idToken || "").split(".");
  if (parts.length !== 3) throw new Error("invalid_id_token");

  const header = decodeJwtPart(parts[0]);
  const claims = decodeJwtPart(parts[1]);
  if (header.alg !== "RS256" || !header.kid) throw new Error("unsupported_id_token_algorithm");

  const jwksResponse = await fetch("https://oauth.telegram.org/.well-known/jwks.json", {
    headers: { "Accept": "application/json" },
    cf: { cacheTtl: 3600, cacheEverything: true }
  });
  if (!jwksResponse.ok) throw new Error("telegram_jwks_unavailable");
  const jwks = await jwksResponse.json();
  const jwk = Array.isArray(jwks.keys) ? jwks.keys.find(item => item.kid === header.kid && item.kty === "RSA") : null;
  if (!jwk) throw new Error("telegram_signing_key_not_found");

  const publicKey = await crypto.subtle.importKey(
    "jwk",
    jwk,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["verify"]
  );
  const signedContent = new TextEncoder().encode(parts[0] + "." + parts[1]);
  const signature = base64UrlToBytes(parts[2]);
  const signatureValid = await crypto.subtle.verify(
    { name: "RSASSA-PKCS1-v1_5" },
    publicKey,
    signature,
    signedContent
  );
  if (!signatureValid) throw new Error("invalid_id_token_signature");

  const clientId = String(env.TELEGRAM_CLIENT_ID || "9254075951");
  const audience = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
  const now = nowSeconds();

  if (claims.iss !== "https://oauth.telegram.org") throw new Error("invalid_id_token_issuer");
  if (!audience.includes(clientId)) throw new Error("invalid_id_token_audience");
  if (!Number.isFinite(Number(claims.exp)) || Number(claims.exp) <= now) throw new Error("id_token_expired");
  if (!Number.isFinite(Number(claims.iat)) || Number(claims.iat) > now + 60 || Number(claims.iat) < now - 3600) {
    throw new Error("invalid_id_token_time");
  }
  if (!claims.sub || String(claims.nonce || "") !== expectedNonce) throw new Error("invalid_id_token_nonce");

  const telegramId = String(claims.id || claims.sub);
  if (!/^\d{1,22}$/.test(telegramId)) throw new Error("invalid_telegram_user_id");
  return {
    telegramId,
    telegramSub: String(claims.sub),
    username: typeof claims.preferred_username === "string" ? claims.preferred_username.slice(0, 32) : null,
    displayName: typeof claims.name === "string" ? claims.name.slice(0, 96) : null
  };
}

async function exchangeTelegramCode(code, flow, env) {
  const clientId = String(env.TELEGRAM_CLIENT_ID || "9254075951");
  const clientSecret = env.TELEGRAM_CLIENT_SECRET;
  if (!clientSecret) throw new Error("telegram_login_not_configured");

  const body = new URLSearchParams({
    grant_type: "authorization_code",
    code,
    redirect_uri: CALLBACK_URL,
    client_id: clientId,
    code_verifier: flow.code_verifier
  });

  const tokenResponse = await fetch("https://oauth.telegram.org/token", {
    method: "POST",
    headers: {
      "Authorization": "Basic " + btoa(clientId + ":" + clientSecret),
      "Content-Type": "application/x-www-form-urlencoded",
      "Accept": "application/json"
    },
    body
  });
  const token = await tokenResponse.json().catch(() => ({}));
  if (!tokenResponse.ok || !token.id_token) {
    throw new Error(token.error || "telegram_token_exchange_failed");
  }
  return verifyTelegramIdToken(token.id_token, env, flow.nonce);
}

async function finishTelegramLogin(request, env) {
  const url = new URL(request.url);
  const state = url.searchParams.get("state");
  const code = url.searchParams.get("code");
  const oauthError = url.searchParams.get("error");
  if (!state) return redirectToApp(null, "missing_state");

  const stateHash = await sha256(state);
  const flow = await getFlow(env.DB, stateHash);
  if (!flow || flow.status !== "pending" || flow.expires_at <= nowSeconds()) {
    return redirectToApp(null, "flow_expired");
  }

  if (oauthError) {
    await env.DB.prepare(
      "UPDATE telegram_oauth_flows SET status = 'failed', error_code = ? WHERE state_hash = ? AND status = 'pending'"
    ).bind(String(oauthError).slice(0, 64), stateHash).run();
    return redirectToApp(null, "authorization_cancelled");
  }
  if (!code) {
    await env.DB.prepare(
      "UPDATE telegram_oauth_flows SET status = 'failed', error_code = 'missing_code' WHERE state_hash = ? AND status = 'pending'"
    ).bind(stateHash).run();
    return redirectToApp(null, "missing_authorization_code");
  }

  try {
    const identity = await exchangeTelegramCode(code, flow, env);
    if (identity.telegramId !== String(flow.expected_telegram_id) && identity.telegramSub !== String(flow.expected_telegram_id)) {
      throw new Error("telegram_account_mismatch");
    }

    const timestamp = nowSeconds();
    const existing = await env.DB.prepare(
      "SELECT id FROM users WHERE telegram_sub = ? OR telegram_id = ? LIMIT 1"
    ).bind(identity.telegramSub, identity.telegramId).first();

    let userId = existing?.id;
    const isNewUser = !userId;
    if (!userId) {
      userId = crypto.randomUUID();
      await env.DB.prepare(
        "INSERT INTO users (id, telegram_sub, username, display_name, created_at, updated_at, telegram_id) VALUES (?, ?, ?, ?, ?, ?, ?)"
      ).bind(userId, identity.telegramSub, identity.username, identity.displayName, timestamp, timestamp, identity.telegramId).run();
    } else {
      await env.DB.prepare(
        "UPDATE users SET telegram_sub = ?, telegram_id = ?, username = ?, display_name = ?, updated_at = ? WHERE id = ?"
      ).bind(identity.telegramSub, identity.telegramId, identity.username, identity.displayName, timestamp, userId).run();
    }

    const defaultProfile = JSON.stringify({
      profileColorEnabled: false,
      profileColor: null,
      cardStyle: { paletteName: "Dark Red", material: "glossy" },
      aliases: [],
      publicNumbers: []
    });
    await env.DB.prepare(
      "INSERT OR IGNORE INTO user_card_settings (user_id, selected_design_id, featured_card_id, customization_json, public_enabled, updated_at) VALUES (?, NULL, NULL, ?, 1, ?)"
    ).bind(userId, defaultProfile, timestamp).run();

    await env.DB.prepare(
      "INSERT INTO user_sessions (token_hash, user_id, created_at, expires_at, revoked_at) VALUES (?, ?, ?, ?, NULL) ON CONFLICT(token_hash) DO UPDATE SET user_id = excluded.user_id, created_at = excluded.created_at, expires_at = excluded.expires_at, revoked_at = NULL"
    ).bind(flow.flow_id_hash, userId, timestamp, timestamp + SESSION_SECONDS).run();

    await env.DB.prepare(
      "UPDATE telegram_oauth_flows SET status = 'completed', user_id = ?, is_new_user = ?, error_code = NULL WHERE state_hash = ? AND status = 'pending'"
    ).bind(userId, isNewUser ? 1 : 0, stateHash).run();

    return redirectToApp(state, null);
  } catch (error) {
    const codeValue = String(error?.message || "telegram_authorization_failed").slice(0, 96);
    await env.DB.prepare(
      "UPDATE telegram_oauth_flows SET status = 'failed', error_code = ? WHERE state_hash = ? AND status = 'pending'"
    ).bind(codeValue, stateHash).run().catch(() => {});
    return redirectToApp(null, codeValue);
  }
}

async function createTelegramFlow(request, env) {
  if (request.method !== "POST") return fail("method_not_allowed", 405);
  const input = await readJson(request, 4096);
  const expectedTelegramId = String(input.telegramId || "");
  if (!/^\d{1,22}$/.test(expectedTelegramId)) return fail("invalid_telegram_id", 400);
  if (!env.TELEGRAM_CLIENT_SECRET) return fail("telegram_login_not_configured", 503);

  const recent = await env.DB.prepare(
    "SELECT COUNT(*) AS count FROM telegram_oauth_flows WHERE expected_telegram_id = ? AND created_at > ?"
  ).bind(expectedTelegramId, nowSeconds() - 3600).first();
  if (Number(recent?.count || 0) >= 10) return fail("too_many_auth_attempts", 429);

  const state = randomToken(32);
  const flowId = randomToken(32);
  const nonce = randomToken(24);
  const verifier = randomToken(48);
  const challenge = bytesToBase64Url(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier))));
  const timestamp = nowSeconds();

  await env.DB.prepare(
    "INSERT INTO telegram_oauth_flows (state_hash, flow_id_hash, expected_telegram_id, nonce, code_verifier, status, created_at, expires_at, user_id, error_code, consumed_at, is_new_user) VALUES (?, ?, ?, ?, ?, 'pending', ?, ?, NULL, NULL, NULL, 0)"
  ).bind(await sha256(state), await sha256(flowId), expectedTelegramId, nonce, verifier, timestamp, timestamp + FLOW_SECONDS).run();

  const authUrl = new URL("https://oauth.telegram.org/auth");
  authUrl.searchParams.set("client_id", String(env.TELEGRAM_CLIENT_ID || "9254075951"));
  authUrl.searchParams.set("redirect_uri", CALLBACK_URL);
  authUrl.searchParams.set("response_type", "code");
  authUrl.searchParams.set("scope", "openid profile");
  authUrl.searchParams.set("state", state);
  authUrl.searchParams.set("nonce", nonce);
  authUrl.searchParams.set("code_challenge", challenge);
  authUrl.searchParams.set("code_challenge_method", "S256");

  return json({ flowId, state, authorizationUrl: authUrl.toString(), expiresIn: FLOW_SECONDS }, 201);
}

async function pollTelegramFlow(request, env) {
  const url = new URL(request.url);
  const state = url.searchParams.get("state") || "";
  if (!/^[A-Za-z0-9_-]{32,96}$/.test(state)) return fail("invalid_flow_state", 400);
  const stateHash = await sha256(state);
  const row = await env.DB.prepare(
    "SELECT status, expires_at, error_code, is_new_user FROM telegram_oauth_flows WHERE state_hash = ? LIMIT 1"
  ).bind(stateHash).first();

  if (!row) return fail("flow_not_found", 404);
  if (row.status === "pending" && row.expires_at <= nowSeconds()) {
    await env.DB.prepare(
      "UPDATE telegram_oauth_flows SET status = 'failed', error_code = 'flow_expired' WHERE state_hash = ? AND status = 'pending'"
    ).bind(stateHash).run();
    return json({ status: "failed", error: "flow_expired" });
  }
  if (row.status === "failed") return json({ status: "failed", error: row.error_code || "authorization_failed" });
  if (row.status === "completed") return json({ status: "completed", isNewUser: row.is_new_user === 1 });
  return json({ status: "pending" }, 202);
}
function bearerToken(request) {
  const header = request.headers.get("Authorization") || "";
  const match = header.match(/^Bearer\s+([A-Za-z0-9_-]{32,96})$/i);
  return match ? match[1] : null;
}

async function authenticatedUser(request, env) {
  const token = bearerToken(request);
  if (!token) return null;
  const tokenHash = await sha256(token);
  return env.DB.prepare(
    "SELECT u.id, u.telegram_id, u.telegram_sub, u.username, u.display_name FROM user_sessions s JOIN users u ON u.id = s.user_id WHERE s.token_hash = ? AND s.revoked_at IS NULL AND s.expires_at > ? LIMIT 1"
  ).bind(tokenHash, nowSeconds()).first();
}

function normalizeProfile(input) {
  const cardStyleInput = input && typeof input.cardStyle === "object" ? input.cardStyle : {};
  const paletteName = ALLOWED_PALETTES.has(cardStyleInput.paletteName) ? cardStyleInput.paletteName : "Dark Red";
  const material = ALLOWED_MATERIALS.has(cardStyleInput.material) ? cardStyleInput.material : "glossy";

  let profileColor = null;
  if (input && input.profileColor && typeof input.profileColor === "object") {
    const color = input.profileColor;
    const values = [color.r, color.g, color.b, color.brightness, color.patternOpacity];
    const validNumbers = values.every(value => value === undefined || (Number.isFinite(Number(value)) && Number(value) >= 0 && Number(value) <= 1.5));
    if (validNumbers) {
      profileColor = {
        r: Math.max(0, Math.min(1, Number(color.r))),
        g: Math.max(0, Math.min(1, Number(color.g))),
        b: Math.max(0, Math.min(1, Number(color.b))),
        brightness: Math.max(0.3, Math.min(1.2, Number(color.brightness ?? 1))),
        pattern: ALLOWED_PATTERNS.has(color.pattern) ? color.pattern : "none",
        patternOpacity: Math.max(0, Math.min(1, Number(color.patternOpacity ?? 0.25)))
      };
    }
  }

  const aliases = Array.isArray(input?.aliases)
    ? Array.from(new Set(input.aliases
        .filter(value => typeof value === "string")
        .map(value => value.replace(/^@/, "").trim())
        .filter(value => /^[A-Za-z0-9_]{1,32}$/.test(value))
      )).slice(0, 12)
    : [];

  const publicNumbers = Array.isArray(input?.publicNumbers)
    ? input.publicNumbers.filter(item => item && item.isPublic === true && typeof item.number === "string")
      .slice(0, 6)
      .map(item => ({
        id: String(item.id || crypto.randomUUID()).slice(0, 64),
        label: typeof item.label === "string" ? item.label.slice(0, 32) : null,
        number: item.number.trim().slice(0, 48),
        isPublic: true
      }))
    : [];

  return {
    profileColorEnabled: input?.profileColorEnabled === true && profileColor !== null,
    profileColor,
    cardStyle: { paletteName, material },
    aliases,
    publicNumbers
  };
}

async function saveMyProfile(request, env, user) {
  if (request.method !== "PUT" && request.method !== "POST") return fail("method_not_allowed", 405);
  const input = await readJson(request, 64 * 1024);
  const profile = normalizeProfile(input);
  const publicEnabled = input.publicEnabled !== false;
  const timestamp = nowSeconds();
  await env.DB.prepare(
    "INSERT INTO user_card_settings (user_id, selected_design_id, featured_card_id, customization_json, public_enabled, updated_at) VALUES (?, NULL, NULL, ?, ?, ?) ON CONFLICT(user_id) DO UPDATE SET customization_json = excluded.customization_json, public_enabled = excluded.public_enabled, updated_at = excluded.updated_at"
  ).bind(user.id, JSON.stringify(profile), publicEnabled ? 1 : 0, timestamp).run();
  return json({ ok: true, updatedAt: timestamp });
}

async function saveCardImage(request, env, user) {
  if (request.method === "DELETE") {
    await env.DB.prepare("DELETE FROM biogram_profile_assets WHERE user_id = ?").bind(user.id).run();
    return json({ ok: true });
  }
  if (request.method !== "PUT") return fail("method_not_allowed", 405);
  const input = await readJson(request, 512 * 1024);
  const imageBase64 = String(input.imageBase64 || "");
  if (!imageBase64 || imageBase64.length > Math.ceil(MAX_IMAGE_BYTES * 4 / 3) + 16) return fail("invalid_image", 413);
  let bytes;
  try {
    bytes = Uint8Array.from(atob(imageBase64.replace(/^data:image\/jpeg;base64,/, "")), value => value.charCodeAt(0));
  } catch {
    return fail("invalid_image_encoding", 400);
  }
  if (bytes.byteLength === 0 || bytes.byteLength > MAX_IMAGE_BYTES || bytes[0] !== 0xff || bytes[1] !== 0xd8) {
    return fail("invalid_image_format_or_size", 413);
  }
  const normalized = btoa(Array.from(bytes, value => String.fromCharCode(value)).join(""));
  const timestamp = nowSeconds();
  await env.DB.prepare(
    "INSERT INTO biogram_profile_assets (user_id, mime_type, data_base64, size_bytes, updated_at) VALUES (?, 'image/jpeg', ?, ?, ?) ON CONFLICT(user_id) DO UPDATE SET mime_type = excluded.mime_type, data_base64 = excluded.data_base64, size_bytes = excluded.size_bytes, updated_at = excluded.updated_at"
  ).bind(user.id, normalized, bytes.byteLength, timestamp).run();
  return json({ ok: true, sizeBytes: bytes.byteLength, updatedAt: timestamp });
}

async function getProfile(request, env, user, isOwnProfile) {
  const userId = isOwnProfile ? user.id : null;
  const telegramId = isOwnProfile ? user.telegram_id : decodeURIComponent(new URL(request.url).pathname.split("/").pop() || "");
  if (!isOwnProfile && !/^\d{1,22}$/.test(telegramId)) return fail("profile_not_found", 404);

  const target = isOwnProfile
    ? await env.DB.prepare(
        "SELECT u.id, u.telegram_id, u.username, u.display_name, s.customization_json, s.public_enabled, s.updated_at FROM users u LEFT JOIN user_card_settings s ON s.user_id = u.id WHERE u.id = ? LIMIT 1"
      ).bind(userId).first()
    : await env.DB.prepare(
        "SELECT u.id, u.telegram_id, u.username, u.display_name, s.customization_json, s.public_enabled, s.updated_at FROM users u JOIN user_card_settings s ON s.user_id = u.id WHERE u.telegram_id = ? AND s.public_enabled = 1 LIMIT 1"
      ).bind(telegramId).first();

  if (!target || (!isOwnProfile && target.public_enabled !== 1)) return fail("profile_not_found", 404);
  const asset = await env.DB.prepare(
    "SELECT data_base64 FROM biogram_profile_assets WHERE user_id = ? LIMIT 1"
  ).bind(target.id).first();

  let customization = {};
  try {
    customization = target.customization_json ? JSON.parse(target.customization_json) : {};
  } catch {
    customization = {};
  }

  return json({
    profile: {
      telegramId: String(target.telegram_id || ""),
      username: target.username || null,
      displayName: target.display_name || "Biogram member",
      profileColorEnabled: customization.profileColorEnabled === true,
      profileColor: customization.profileColor || null,
      cardStyle: customization.cardStyle || { paletteName: "Dark Red", material: "glossy" },
      aliases: Array.isArray(customization.aliases) ? customization.aliases : [],
      publicNumbers: Array.isArray(customization.publicNumbers) ? customization.publicNumbers : [],
      cardImageBase64: asset?.data_base64 || null,
      publicEnabled: target.public_enabled === 1,
      updatedAt: Number(target.updated_at || 0)
    }
  });
}

async function revokeSession(request, env, user) {
  if (request.method !== "POST") return fail("method_not_allowed", 405);
  const token = bearerToken(request);
  if (token) {
    await env.DB.prepare(
      "UPDATE user_sessions SET revoked_at = ? WHERE token_hash = ? AND user_id = ? AND revoked_at IS NULL"
    ).bind(nowSeconds(), await sha256(token), user.id).run();
  }
  return json({ ok: true });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });

    if (url.pathname === "/health") {
      if (request.method !== "GET") return fail("method_not_allowed", 405);
      try {
        await env.DB.prepare("SELECT 1 AS ok").first();
        return json({ ok: true, service: "biogram-cloud-profiles", version: API_VERSION, database: "connected", auth: "telegram-oidc" });
      } catch {
        return json({ ok: false, service: "biogram-cloud-profiles", version: API_VERSION, database: "unavailable" }, 503);
      }
    }

    if (url.pathname === "/v1/auth/telegram/start") {
      try {
        return await createTelegramFlow(request, env);
      } catch (error) {
        return fail(error?.message || "auth_flow_creation_failed", 500);
      }
    }

    if (url.pathname === "/v1/auth/telegram/callback") {
      if (request.method !== "GET") return fail("method_not_allowed", 405);
      return finishTelegramLogin(request, env);
    }

    if (url.pathname === "/v1/auth/telegram/status") {
      if (request.method !== "GET") return fail("method_not_allowed", 405);
      try {
        return await pollTelegramFlow(request, env);
      } catch (error) {
        return fail(error?.message || "flow_status_failed", 500);
      }
    }

    const user = await authenticatedUser(request, env);
    if (url.pathname === "/v1/profile/me") {
      if (!user) return fail("unauthorized", 401);
      if (request.method === "GET") return getProfile(request, env, user, true);
      try {
        return await saveMyProfile(request, env, user);
      } catch (error) {
        return fail(error?.message || "profile_update_failed", 400);
      }
    }

    if (url.pathname === "/v1/profile/me/card-image") {
      if (!user) return fail("unauthorized", 401);
      try {
        return await saveCardImage(request, env, user);
      } catch (error) {
        return fail(error?.message || "card_image_update_failed", 400);
      }
    }

    if (url.pathname.startsWith("/v1/profiles/")) {
      if (request.method !== "GET") return fail("method_not_allowed", 405);
      try {
        return await getProfile(request, env, user, false);
      } catch (error) {
        return fail(error?.message || "profile_lookup_failed", 400);
      }
    }

    if (url.pathname === "/v1/auth/logout") {
      if (!user) return fail("unauthorized", 401);
      return revokeSession(request, env, user);
    }

    return fail("not_found", 404);
  }
};
