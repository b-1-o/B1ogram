import { handleCardApi } from "./cards.js";

const API_VERSION = "0.4.0";
const TELEGRAM_ISSUER = "https://oauth.telegram.org";
const TELEGRAM_AUTH_URL = "https://oauth.telegram.org/auth";
const TELEGRAM_TOKEN_URL = "https://oauth.telegram.org/token";
const TELEGRAM_JWKS_URL = "https://oauth.telegram.org/.well-known/jwks.json";
const TELEGRAM_REDIRECT_URI = "https://fog-wallet-api.collab-docs-b1o.workers.dev/v1/auth/telegram/callback";
const FLOW_TTL_SECONDS = 10 * 60;
const SESSION_TTL_SECONDS = 30 * 24 * 60 * 60;
const MAX_TOKEN_LENGTH = 16 * 1024;
const MAX_BODY_BYTES = 2048;

let jwksMemoryCache = null;
let jwksMemoryExpiresAt = 0;

function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
      "X-Frame-Options": "DENY",
      "Referrer-Policy": "no-referrer",
      "Content-Security-Policy": "default-src 'none'; frame-ancestors 'none'"
    }
  });
}

function htmlPage(title, message, status = 200) {
  const safeTitle = escapeHtml(title);
  const safeMessage = escapeHtml(message);
  return new Response(
    "<!doctype html><html lang=\"en\"><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>" +
      safeTitle +
      "</title><body style=\"font:16px system-ui;background:#111;color:#f5f5f5;margin:0;min-height:100vh;display:grid;place-items:center\"><main style=\"max-width:440px;padding:32px\"><h1>" +
      safeTitle +
      "</h1><p style=\"line-height:1.6;color:#ccc\">" +
      safeMessage +
      "</p><p style=\"color:#888;font-size:13px\">You can close this page and return to Biogram.</p></main></body></html>",
    {
      status,
      headers: {
        "Content-Type": "text/html; charset=utf-8",
        "Cache-Control": "no-store",
        "X-Content-Type-Options": "nosniff",
        "X-Frame-Options": "DENY",
        "Referrer-Policy": "no-referrer",
        "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'; base-uri 'none'"
      }
    }
  );
}

function escapeHtml(value) {
  return String(value).replace(/[&<>"']/g, (character) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    '"': "&quot;",
    "'": "&#39;"
  })[character]);
}

class AuthFlowError extends Error {
  constructor(code = "telegram_auth_failed", status = 401) {
    super(code);
    this.code = code;
    this.status = status;
  }
}

function decodeBase64Url(value) {
  if (typeof value !== "string" || !/^[A-Za-z0-9_-]+$/.test(value)) {
    throw new AuthFlowError();
  }

  const base64 = value.replace(/-/g, "+").replace(/_/g, "/");
  const padded = base64 + "=".repeat((4 - (base64.length % 4)) % 4);
  try {
    const binary = atob(padded);
    return Uint8Array.from(binary, (character) => character.charCodeAt(0));
  } catch {
    throw new AuthFlowError();
  }
}

function encodeBase64Url(bytes) {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

function decodeJsonSegment(segment) {
  try {
    return JSON.parse(new TextDecoder().decode(decodeBase64Url(segment)));
  } catch {
    throw new AuthFlowError();
  }
}

function randomToken() {
  return encodeBase64Url(crypto.getRandomValues(new Uint8Array(32)));
}

async function sha256Bytes(value) {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)));
}

async function sha256Hex(value) {
  return Array.from(await sha256Bytes(value), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function sha256Base64Url(value) {
  return encodeBase64Url(await sha256Bytes(value));
}

async function readJson(request, maxBytes = MAX_BODY_BYTES) {
  const contentType = request.headers.get("content-type") || "";
  if (!contentType.toLowerCase().startsWith("application/json")) {
    return { error: json({ error: "content_type_must_be_json" }, 415) };
  }

  const contentLength = Number(request.headers.get("content-length") || 0);
  if (contentLength > maxBytes) {
    return { error: json({ error: "request_too_large" }, 413) };
  }

  if (!request.body) return { error: json({ error: "invalid_json" }, 400) };

  const reader = request.body.getReader();
  const chunks = [];
  let byteLength = 0;

  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      byteLength += value.byteLength;
      if (byteLength > maxBytes) {
        await reader.cancel();
        return { error: json({ error: "request_too_large" }, 413) };
      }
      chunks.push(value);
    }
  } catch {
    return { error: json({ error: "invalid_json" }, 400) };
  }

  const bytes = new Uint8Array(byteLength);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }

  try {
    return { value: JSON.parse(new TextDecoder().decode(bytes)) };
  } catch {
    return { error: json({ error: "invalid_json" }, 400) };
  }
}

async function getTelegramJwks(forceRefresh = false) {
  const now = Date.now();
  if (!forceRefresh && jwksMemoryCache && jwksMemoryExpiresAt > now) {
    return jwksMemoryCache;
  }

  let response;
  try {
    response = await fetch(TELEGRAM_JWKS_URL, {
      headers: { Accept: "application/json", ...(forceRefresh ? { "Cache-Control": "no-cache" } : {}) }
    });
  } catch {
    throw new AuthFlowError("telegram_auth_unavailable", 503);
  }
  if (!response.ok) throw new AuthFlowError("telegram_auth_unavailable", 503);

  let keys;
  try {
    keys = await response.json();
  } catch {
    throw new AuthFlowError("telegram_auth_unavailable", 503);
  }
  if (!Array.isArray(keys?.keys) || keys.keys.length === 0) {
    throw new AuthFlowError("telegram_auth_unavailable", 503);
  }

  jwksMemoryCache = keys;
  jwksMemoryExpiresAt = now + 5 * 60 * 1000;
  return keys;
}

async function verifyIdToken(idToken, clientId, expectedNonce, expectedTelegramId) {
  if (typeof idToken !== "string" || idToken.length < 20 || idToken.length > MAX_TOKEN_LENGTH) {
    throw new AuthFlowError();
  }

  const segments = idToken.split(".");
  if (segments.length !== 3) throw new AuthFlowError();
  const header = decodeJsonSegment(segments[0]);
  const claims = decodeJsonSegment(segments[1]);

  // Pin the signing algorithm; do not accept the algorithm selected by an incoming JWT.
  if (header?.alg !== "RS256" || typeof header?.kid !== "string") throw new AuthFlowError();

  let jwks = await getTelegramJwks();
  let jwk = jwks.keys.find((key) =>
    key?.kid === header.kid &&
    key?.kty === "RSA" &&
    (!key.use || key.use === "sig") &&
    (!key.alg || key.alg === "RS256")
  );
  if (!jwk) {
    jwks = await getTelegramJwks(true);
    jwk = jwks.keys.find((key) =>
      key?.kid === header.kid &&
      key?.kty === "RSA" &&
      (!key.use || key.use === "sig") &&
      (!key.alg || key.alg === "RS256")
    );
  }
  if (!jwk) throw new AuthFlowError();

  let validSignature = false;
  try {
    const publicKey = await crypto.subtle.importKey(
      "jwk",
      jwk,
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
      false,
      ["verify"]
    );
    validSignature = await crypto.subtle.verify(
      "RSASSA-PKCS1-v1_5",
      publicKey,
      decodeBase64Url(segments[2]),
      new TextEncoder().encode(segments[0] + "." + segments[1])
    );
  } catch {
    throw new AuthFlowError();
  }
  if (!validSignature) throw new AuthFlowError();

  const now = Math.floor(Date.now() / 1000);
  const audienceMatches = claims?.aud === clientId ||
    (Array.isArray(claims?.aud) && claims.aud.includes(clientId));
  const telegramId = claims?.id === undefined ? "" : String(claims.id);

  if (
    claims?.iss !== TELEGRAM_ISSUER ||
    !audienceMatches ||
    (Array.isArray(claims?.aud) && claims?.azp && claims.azp !== clientId) ||
    typeof claims?.sub !== "string" ||
    claims.sub.length < 1 ||
    claims.sub.length > 128 ||
    !Number.isInteger(claims?.exp) ||
    !Number.isInteger(claims?.iat) ||
    claims.exp <= now ||
    claims.iat > now + 60 ||
    claims.exp <= claims.iat ||
    claims.exp - claims.iat > 2 * 60 * 60 ||
    claims.nonce !== expectedNonce
  ) {
    throw new AuthFlowError();
  }

  if (!/^\d{1,24}$/.test(telegramId) || telegramId !== expectedTelegramId) {
    throw new AuthFlowError("telegram_account_mismatch");
  }

  return { sub: claims.sub, telegramId };
}

async function startTelegramConnect(request, env) {
  if (!env.TELEGRAM_CLIENT_ID || !/^\d{5,20}$/.test(env.TELEGRAM_CLIENT_ID)) {
    return json({ error: "telegram_login_not_configured" }, 503);
  }

  const parsed = await readJson(request);
  if (parsed.error) return parsed.error;
  const expectedTelegramId = String(parsed.value?.expected_telegram_id ?? "");
  if (!/^\d{1,24}$/.test(expectedTelegramId)) {
    return json({ error: "expected_telegram_id_required" }, 400);
  }

  const flowId = randomToken();
  const state = randomToken();
  const nonce = randomToken();
  const codeVerifier = randomToken();
  const now = Math.floor(Date.now() / 1000);
  const expiresAt = now + FLOW_TTL_SECONDS;

  try {
    await env.DB.batch([
      env.DB.prepare("DELETE FROM telegram_oauth_flows WHERE expires_at <= ?").bind(now),
      env.DB.prepare(
        `INSERT INTO telegram_oauth_flows
         (state_hash, flow_id_hash, expected_telegram_id, nonce, code_verifier, status, created_at, expires_at, user_id, error_code, consumed_at)
         VALUES (?, ?, ?, ?, ?, 'pending', ?, ?, NULL, NULL, NULL)`
      ).bind(
        await sha256Hex(state),
        await sha256Hex(flowId),
        expectedTelegramId,
        nonce,
        codeVerifier,
        now,
        expiresAt
      )
    ]);
  } catch {
    return json({ error: "database_unavailable" }, 503);
  }

  const authorizationUrl = new URL(TELEGRAM_AUTH_URL);
  authorizationUrl.searchParams.set("client_id", env.TELEGRAM_CLIENT_ID);
  authorizationUrl.searchParams.set("redirect_uri", TELEGRAM_REDIRECT_URI);
  authorizationUrl.searchParams.set("response_type", "code");
  authorizationUrl.searchParams.set("scope", "openid profile");
  authorizationUrl.searchParams.set("state", state);
  authorizationUrl.searchParams.set("nonce", nonce);
  authorizationUrl.searchParams.set("code_challenge", await sha256Base64Url(codeVerifier));
  authorizationUrl.searchParams.set("code_challenge_method", "S256");

  return json({
    flow_id: flowId,
    authorization_url: authorizationUrl.toString(),
    expires_in: FLOW_TTL_SECONDS
  });
}

async function markFlowFailed(env, stateHash, code) {
  const now = Math.floor(Date.now() / 1000);
  try {
    await env.DB.prepare(
      "UPDATE telegram_oauth_flows SET status = 'failed', error_code = ? WHERE state_hash = ? AND status = 'pending' AND expires_at > ?"
    ).bind(code, stateHash, now).run();
  } catch {
    // Do not expose internal details in the browser callback response.
  }
}

async function telegramCallback(request, env) {
  const url = new URL(request.url);
  const state = url.searchParams.get("state") || "";
  const code = url.searchParams.get("code") || "";
  const providerError = url.searchParams.get("error");
  if (!/^[A-Za-z0-9_-]{40,128}$/.test(state)) {
    return htmlPage("Connection failed", "The sign-in request was invalid or expired.", 400);
  }

  const stateHash = await sha256Hex(state);
  const now = Math.floor(Date.now() / 1000);
  let flow;
  try {
    flow = await env.DB.prepare(
      "SELECT state_hash, flow_id_hash, expected_telegram_id, nonce, code_verifier, status, expires_at FROM telegram_oauth_flows WHERE state_hash = ? LIMIT 1"
    ).bind(stateHash).first();
  } catch {
    return htmlPage("Connection unavailable", "Fog Wallet could not access its database. Return to Biogram and try again.", 503);
  }

  if (!flow || flow.status !== "pending" || flow.expires_at <= now) {
    return htmlPage("Connection expired", "This sign-in request is no longer active. Return to Biogram and start again.", 400);
  }

  if (providerError || code.length < 1 || code.length > 4096 || /[\\r\\n]/.test(code)) {
    await markFlowFailed(env, stateHash, providerError ? "telegram_login_cancelled" : "invalid_authorization_code");
    return htmlPage("Connection cancelled", "No Fog Wallet connection was created. You can return to Biogram.");
  }

  if (!env.TELEGRAM_CLIENT_ID || !env.TELEGRAM_CLIENT_SECRET) {
    await markFlowFailed(env, stateHash, "telegram_login_not_configured");
    return htmlPage("Connection unavailable", "Fog Wallet sign-in has not been configured yet. Return to Biogram later.", 503);
  }

  let tokenResponse;
  try {
    const body = new URLSearchParams({
      grant_type: "authorization_code",
      code,
      redirect_uri: TELEGRAM_REDIRECT_URI,
      client_id: env.TELEGRAM_CLIENT_ID,
      code_verifier: flow.code_verifier
    });
    tokenResponse = await fetch(TELEGRAM_TOKEN_URL, {
      method: "POST",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
        Authorization: "Basic " + btoa(env.TELEGRAM_CLIENT_ID + ":" + env.TELEGRAM_CLIENT_SECRET),
        Accept: "application/json"
      },
      body
    });
  } catch {
    await markFlowFailed(env, stateHash, "telegram_auth_unavailable");
    return htmlPage("Connection unavailable", "Telegram sign-in could not be reached. Return to Biogram and try again.", 503);
  }

  let tokenPayload;
  try {
    tokenPayload = await tokenResponse.json();
  } catch {
    tokenPayload = null;
  }
  if (!tokenResponse.ok || typeof tokenPayload?.id_token !== "string") {
    await markFlowFailed(env, stateHash, "telegram_token_exchange_failed");
    return htmlPage("Connection failed", "Telegram did not complete the sign-in. Return to Biogram and try again.", 401);
  }

  let identity;
  try {
    identity = await verifyIdToken(
      tokenPayload.id_token,
      env.TELEGRAM_CLIENT_ID,
      flow.nonce,
      flow.expected_telegram_id
    );
  } catch (error) {
    const errorCode = error instanceof AuthFlowError ? error.code : "telegram_auth_failed";
    await markFlowFailed(env, stateHash, errorCode);
    if (errorCode === "telegram_account_mismatch") {
      return htmlPage("Wrong Telegram account", "You approved a different Telegram account than the one currently open in Biogram. No connection was created. Return to Biogram, switch to the intended account, and try again.", 403);
    }
    return htmlPage("Connection failed", "Telegram identity verification did not succeed. No account was linked. Return to Biogram and try again.", 401);
  }

  const completedAt = Math.floor(Date.now() / 1000);
  let user;
  try {
    user = await env.DB.prepare(
      `INSERT INTO users (id, telegram_sub, telegram_id, username, display_name, created_at, updated_at)
       VALUES (?, ?, ?, NULL, NULL, ?, ?)
       ON CONFLICT(telegram_sub) DO UPDATE SET telegram_id = excluded.telegram_id, updated_at = excluded.updated_at
       RETURNING id, telegram_sub`
    ).bind(crypto.randomUUID(), identity.sub, identity.telegramId, completedAt, completedAt).first();
  } catch {
    await markFlowFailed(env, stateHash, "database_unavailable");
    return htmlPage("Connection unavailable", "Fog Wallet could not save the connection. Return to Biogram and try again.", 503);
  }

  if (!user?.id) {
    await markFlowFailed(env, stateHash, "database_unavailable");
    return htmlPage("Connection unavailable", "Fog Wallet could not save the connection. Return to Biogram and try again.", 503);
  }

  try {
    const result = await env.DB.prepare(
      "UPDATE telegram_oauth_flows SET status = 'completed', user_id = ?, error_code = NULL WHERE state_hash = ? AND status = 'pending' AND expires_at > ?"
    ).bind(user.id, stateHash, completedAt).run();
    if ((result.meta?.changes ?? 0) !== 1) {
      return htmlPage("Connection expired", "This sign-in request was already used or expired. Return to Biogram and start again.", 400);
    }
  } catch {
    return htmlPage("Connection unavailable", "Fog Wallet could not finish saving the connection. Return to Biogram and try again.", 503);
  }

  return htmlPage("Fog Wallet connected", "Telegram confirmed your account. Return to Biogram to finish enabling Fog Wallet. You can disconnect it later in Biogram settings.");
}

async function connectStatus(request, env) {
  const parsed = await readJson(request);
  if (parsed.error) return parsed.error;
  const flowId = parsed.value?.flow_id;
  if (typeof flowId !== "string" || !/^[A-Za-z0-9_-]{40,128}$/.test(flowId)) {
    return json({ error: "flow_id_required" }, 400);
  }

  const flowIdHash = await sha256Hex(flowId);
  const now = Math.floor(Date.now() / 1000);
  let flow;
  try {
    flow = await env.DB.prepare(
      "SELECT flow_id_hash, status, user_id, error_code, expires_at, consumed_at FROM telegram_oauth_flows WHERE flow_id_hash = ? LIMIT 1"
    ).bind(flowIdHash).first();
  } catch {
    return json({ error: "database_unavailable" }, 503);
  }

  if (!flow || flow.expires_at <= now) return json({ status: "expired" }, 410);
  if (flow.status === "pending") return json({ status: "pending" });
  if (flow.status === "failed") {
    return json({ status: "failed", error: flow.error_code || "telegram_auth_failed" }, 400);
  }
  if (flow.status !== "completed" || flow.consumed_at !== null) {
    return json({ status: "consumed" }, 410);
  }

  const accessToken = randomToken();
  const accessTokenHash = await sha256Hex(accessToken);
  const expiresAt = now + SESSION_TTL_SECONDS;
  let batch;
  try {
    batch = await env.DB.batch([
      env.DB.prepare(
        `INSERT INTO user_sessions (token_hash, user_id, created_at, expires_at, revoked_at)
         SELECT ?, user_id, ?, ?, NULL
         FROM telegram_oauth_flows
         WHERE flow_id_hash = ? AND status = 'completed' AND consumed_at IS NULL AND expires_at > ?
         RETURNING user_id`
      ).bind(accessTokenHash, now, expiresAt, flowIdHash, now),
      env.DB.prepare(
        "UPDATE telegram_oauth_flows SET consumed_at = ? WHERE flow_id_hash = ? AND status = 'completed' AND consumed_at IS NULL AND expires_at > ?"
      ).bind(now, flowIdHash, now),
      env.DB.prepare("DELETE FROM user_sessions WHERE expires_at <= ? OR revoked_at IS NOT NULL").bind(now),
      env.DB.prepare("DELETE FROM telegram_oauth_flows WHERE expires_at <= ?").bind(now)
    ]);
  } catch {
    return json({ error: "database_unavailable" }, 503);
  }

  const insertedRows = batch?.[0]?.results || [];
  if (insertedRows.length !== 1 || !insertedRows[0].user_id) {
    return json({ status: "consumed" }, 410);
  }

  let user;
  try {
    user = await env.DB.prepare(
      "SELECT id, telegram_sub, username, display_name FROM users WHERE id = ? LIMIT 1"
    ).bind(insertedRows[0].user_id).first();
  } catch {
    return json({ error: "database_unavailable" }, 503);
  }
  if (!user) return json({ error: "database_unavailable" }, 503);

  return json({
    status: "connected",
    access_token: accessToken,
    token_type: "Bearer",
    expires_in: SESSION_TTL_SECONDS,
    user: {
      id: user.id,
      telegram_sub: user.telegram_sub,
      telegram_id: user.telegram_id,
      username: user.username,
      display_name: user.display_name
    }
  });
}

async function authenticate(request, env) {
  const authorization = request.headers.get("authorization") || "";
  const match = authorization.match(/^Bearer ([A-Za-z0-9_-]{40,128})$/);
  if (!match) return null;

  const now = Math.floor(Date.now() / 1000);
  return env.DB.prepare(
    `SELECT u.id, u.telegram_sub, u.telegram_id, u.username, u.display_name, s.expires_at
     FROM user_sessions s
     JOIN users u ON u.id = s.user_id
     WHERE s.token_hash = ? AND s.revoked_at IS NULL AND s.expires_at > ?
     LIMIT 1`
  ).bind(await sha256Hex(match[1]), now).first();
}

async function currentUser(request, env) {
  let user;
  try {
    user = await authenticate(request, env);
  } catch {
    return json({ error: "database_unavailable" }, 503);
  }
  if (!user) return json({ error: "unauthorized" }, 401);
  return json({
    user: {
      id: user.id,
      telegram_sub: user.telegram_sub,
      username: user.username,
      display_name: user.display_name
    },
    expires_at: user.expires_at
  });
}

async function disconnect(request, env) {
  let user;
  try {
    user = await authenticate(request, env);
  } catch {
    return json({ error: "database_unavailable" }, 503);
  }
  if (!user) return json({ error: "unauthorized" }, 401);

  const now = Math.floor(Date.now() / 1000);
  try {
    await env.DB.batch([
      env.DB.prepare(
        "UPDATE user_sessions SET revoked_at = ? WHERE user_id = ? AND revoked_at IS NULL"
      ).bind(now, user.id),
      env.DB.prepare(
        "UPDATE user_card_settings SET public_enabled = 0, updated_at = ? WHERE user_id = ?"
      ).bind(now, user.id)
    ]);
  } catch {
    return json({ error: "database_unavailable" }, 503);
  }
  return json({ ok: true, disconnected: true });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname;

    if (path === "/health") {
      if (request.method !== "GET") return json({ error: "method_not_allowed" }, 405);
      try {
        const row = await env.DB.prepare("SELECT 1 AS ok").first();
        if (row?.ok !== 1) {
          return json({ ok: false, service: "fog-wallet-api", version: API_VERSION, error: "database_unavailable" }, 503);
        }
        return json({ ok: true, service: "fog-wallet-api", version: API_VERSION, database: "connected" });
      } catch {
        return json({ ok: false, service: "fog-wallet-api", version: API_VERSION, error: "database_unavailable" }, 503);
      }
    }

    if (path === "/v1/connect/telegram/start") {
      if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);
      return startTelegramConnect(request, env);
    }

    if (path === "/v1/auth/telegram/callback") {
      if (request.method !== "GET") return htmlPage("Method not allowed", "Use the Telegram sign-in redirect.", 405);
      return telegramCallback(request, env);
    }

    if (path === "/v1/connect/telegram/status") {
      if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);
      return connectStatus(request, env);
    }

    if (path === "/v1/me") {
      if (request.method !== "GET") return json({ error: "method_not_allowed" }, 405);
      return currentUser(request, env);
    }

    if (path === "/v1/connect/disconnect") {
      if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);
      return disconnect(request, env);
    }

    const cardResponse = await handleCardApi(request, env, url, {
      json,
      readJson,
      sha256Hex,
      randomToken,
      authenticate
    });
    if (cardResponse) return cardResponse;

    return json({ error: "not_found" }, 404);
  }
};
