const API_VERSION = "0.2.0";
const TELEGRAM_ISSUER = "https://oauth.telegram.org";
const TELEGRAM_JWKS_URL = "https://oauth.telegram.org/.well-known/jwks.json";
const SESSION_TTL_SECONDS = 30 * 24 * 60 * 60;
const MAX_ID_TOKEN_LENGTH = 16 * 1024;
const MAX_TOKEN_LIFETIME_SECONDS = 4 * 60 * 60;

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

class TokenError extends Error {
  constructor(code = "invalid_telegram_token", status = 401) {
    super(code);
    this.code = code;
    this.status = status;
  }
}

function decodeBase64Url(value) {
  if (typeof value !== "string" || !/^[A-Za-z0-9_-]+$/.test(value)) {
    throw new TokenError();
  }

  const base64 = value.replace(/-/g, "+").replace(/_/g, "/");
  const padded = base64 + "=".repeat((4 - (base64.length % 4)) % 4);

  try {
    const binary = atob(padded);
    return Uint8Array.from(binary, (character) => character.charCodeAt(0));
  } catch {
    throw new TokenError();
  }
}

function decodeJsonSegment(segment) {
  try {
    return JSON.parse(new TextDecoder().decode(decodeBase64Url(segment)));
  } catch {
    throw new TokenError();
  }
}

function encodeBase64Url(bytes) {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);

  return btoa(binary)
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "");
}

async function sha256Hex(value) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function getTelegramJwks(forceRefresh = false) {
  const now = Date.now();

  if (!forceRefresh && jwksMemoryCache && jwksMemoryExpiresAt > now) {
    return jwksMemoryCache;
  }

  let response;
  try {
    response = await fetch(TELEGRAM_JWKS_URL, {
      headers: {
        Accept: "application/json",
        ...(forceRefresh ? { "Cache-Control": "no-cache" } : {})
      }
    });
  } catch {
    throw new TokenError("telegram_auth_unavailable", 503);
  }

  if (!response.ok) {
    throw new TokenError("telegram_auth_unavailable", 503);
  }

  let value;
  try {
    value = await response.json();
  } catch {
    throw new TokenError("telegram_auth_unavailable", 503);
  }

  if (!Array.isArray(value?.keys) || value.keys.length === 0) {
    throw new TokenError("telegram_auth_unavailable", 503);
  }

  // Cache only in this isolate; logins are infrequent and no cache binding is required.
  jwksMemoryCache = value;
  jwksMemoryExpiresAt = now + 5 * 60 * 1000;
  return value;
}
async function verifyTelegramIdToken(idToken, clientId) {
  if (typeof idToken !== "string" || idToken.length < 20 || idToken.length > MAX_ID_TOKEN_LENGTH) {
    throw new TokenError();
  }

  const segments = idToken.split(".");
  if (segments.length !== 3) throw new TokenError();

  const header = decodeJsonSegment(segments[0]);
  const claims = decodeJsonSegment(segments[1]);

  // Pin the algorithm. Never trust an algorithm selected by the incoming JWT.
  if (header?.alg !== "RS256" || typeof header?.kid !== "string") {
    throw new TokenError();
  }

  let jwks = await getTelegramJwks();
  let jwk = jwks.keys.find((key) =>
    key?.kid === header.kid &&
    key?.kty === "RSA" &&
    (!key.use || key.use === "sig") &&
    (!key.alg || key.alg === "RS256")
  );

  // Refresh once when Telegram rotates signing keys.
  if (!jwk) {
    jwks = await getTelegramJwks(true);
    jwk = jwks.keys.find((key) =>
      key?.kid === header.kid &&
      key?.kty === "RSA" &&
      (!key.use || key.use === "sig") &&
      (!key.alg || key.alg === "RS256")
    );
  }

  if (!jwk) throw new TokenError();

  let publicKey;
  let validSignature = false;
  try {
    publicKey = await crypto.subtle.importKey(
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
    throw new TokenError();
  }

  if (!validSignature) throw new TokenError();

  const now = Math.floor(Date.now() / 1000);
  const audienceMatches = claims?.aud === clientId ||
    (Array.isArray(claims?.aud) && claims.aud.includes(clientId));

  if (
    claims?.iss !== TELEGRAM_ISSUER ||
    !audienceMatches ||
    (Array.isArray(claims?.aud) && claims?.azp && claims.azp !== clientId) ||
    typeof claims?.sub !== "string" ||
    claims.sub.length < 1 ||
    claims.sub.length > 128 ||
    !/^\d+$/.test(claims.sub) ||
    !Number.isInteger(claims?.exp) ||
    !Number.isInteger(claims?.iat) ||
    claims.exp <= now ||
    claims.iat > now + 60 ||
    claims.exp <= claims.iat ||
    claims.exp - claims.iat > MAX_TOKEN_LIFETIME_SECONDS ||
    (claims.nbf !== undefined && (!Number.isInteger(claims.nbf) || claims.nbf > now + 60))
  ) {
    throw new TokenError();
  }

  return {
    sub: claims.sub,
    username: typeof claims.preferred_username === "string"
      ? claims.preferred_username.slice(0, 64)
      : null,
    displayName: typeof claims.name === "string" ? claims.name.slice(0, 120) : null,
    tokenExpiresAt: claims.exp
  };
}

function randomOpaqueToken() {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return encodeBase64Url(bytes);
}

function safeUser(user) {
  return {
    id: user.id,
    telegram_sub: user.telegram_sub,
    username: user.username,
    display_name: user.display_name
  };
}

async function readJson(request, maxBytes = 20 * 1024) {
  const contentType = request.headers.get("content-type") || "";
  if (!contentType.toLowerCase().startsWith("application/json")) {
    return { error: json({ error: "content_type_must_be_json" }, 415) };
  }

  const declaredLength = Number(request.headers.get("content-length") || 0);
  if (declaredLength > maxBytes) {
    return { error: json({ error: "request_too_large" }, 413) };
  }

  if (!request.body) return { error: json({ error: "invalid_json" }, 400) };

  const reader = request.body.getReader();
  const chunks = [];
  let totalBytes = 0;

  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      totalBytes += value.byteLength;
      if (totalBytes > maxBytes) {
        await reader.cancel();
        return { error: json({ error: "request_too_large" }, 413) };
      }
      chunks.push(value);
    }
  } catch {
    return { error: json({ error: "invalid_json" }, 400) };
  }

  const bytes = new Uint8Array(totalBytes);
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
async function authenticate(request, env) {
  const authorization = request.headers.get("authorization") || "";
  const match = authorization.match(/^Bearer ([A-Za-z0-9_-]{40,128})$/);
  if (!match) return null;

  const tokenHash = await sha256Hex(match[1]);
  const now = Math.floor(Date.now() / 1000);

  return env.DB.prepare(
    `SELECT u.id, u.telegram_sub, u.username, u.display_name, s.expires_at
     FROM user_sessions s
     JOIN users u ON u.id = s.user_id
     WHERE s.token_hash = ? AND s.revoked_at IS NULL AND s.expires_at > ?
     LIMIT 1`
  ).bind(tokenHash, now).first();
}

async function telegramLogin(request, env) {
  if (!env.TELEGRAM_CLIENT_ID || !/^\d+$/.test(env.TELEGRAM_CLIENT_ID)) {
    return json({ error: "telegram_login_not_configured" }, 503);
  }

  const parsed = await readJson(request);
  if (parsed.error) return parsed.error;

  const idToken = parsed.value?.id_token;
  if (typeof idToken !== "string") {
    return json({ error: "id_token_required" }, 400);
  }

  let identity;
  try {
    identity = await verifyTelegramIdToken(idToken, env.TELEGRAM_CLIENT_ID);
  } catch (error) {
    if (error instanceof TokenError) {
      return json({ error: error.code }, error.status);
    }
    return json({ error: "telegram_auth_unavailable" }, 503);
  }

  const now = Math.floor(Date.now() / 1000);
  const idTokenHash = await sha256Hex(idToken);
  const sessionToken = randomOpaqueToken();
  const sessionHash = await sha256Hex(sessionToken);
  const sessionExpiresAt = now + SESSION_TTL_SECONDS;

  let user;
  try {
    user = await env.DB.prepare(
      `INSERT INTO users (id, telegram_sub, username, display_name, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?)
       ON CONFLICT(telegram_sub) DO UPDATE SET
         username = excluded.username,
         display_name = excluded.display_name,
         updated_at = excluded.updated_at
       RETURNING id, telegram_sub, username, display_name`
    ).bind(
      crypto.randomUUID(),
      identity.sub,
      identity.username,
      identity.displayName,
      now,
      now
    ).first();
  } catch {
    return json({ error: "database_unavailable" }, 503);
  }

  if (!user?.id) return json({ error: "database_unavailable" }, 503);

  try {
    // D1 batch is transactional: a replayed ID token cannot create another session.
    await env.DB.batch([
      env.DB.prepare(
        "INSERT INTO used_auth_tokens (token_hash, created_at, expires_at) VALUES (?, ?, ?)"
      ).bind(idTokenHash, now, identity.tokenExpiresAt + 120),
      env.DB.prepare(
        "INSERT INTO user_sessions (token_hash, user_id, created_at, expires_at, revoked_at) VALUES (?, ?, ?, ?, NULL)"
      ).bind(sessionHash, user.id, now, sessionExpiresAt),
      env.DB.prepare("DELETE FROM used_auth_tokens WHERE expires_at <= ?").bind(now),
      env.DB.prepare(
        "DELETE FROM user_sessions WHERE expires_at <= ? OR revoked_at IS NOT NULL"
      ).bind(now)
    ]);
  } catch (error) {
    const message = String(error?.message || "");
    if (message.includes("used_auth_tokens.token_hash") || message.includes("UNIQUE constraint failed")) {
      return json({ error: "id_token_already_used" }, 409);
    }
    return json({ error: "database_unavailable" }, 503);
  }

  return json({
    access_token: sessionToken,
    token_type: "Bearer",
    expires_in: SESSION_TTL_SECONDS,
    user: safeUser(user)
  });
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
    user: safeUser(user),
    expires_at: user.expires_at
  });
}

async function logout(request, env) {
  const authorization = request.headers.get("authorization") || "";
  const match = authorization.match(/^Bearer ([A-Za-z0-9_-]{40,128})$/);
  if (!match) return json({ error: "unauthorized" }, 401);

  try {
    await env.DB.prepare(
      "UPDATE user_sessions SET revoked_at = ? WHERE token_hash = ? AND revoked_at IS NULL"
    ).bind(Math.floor(Date.now() / 1000), await sha256Hex(match[1])).run();
  } catch {
    return json({ error: "database_unavailable" }, 503);
  }

  return json({ ok: true });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname;

    if (path === "/health") {
      if (request.method !== "GET") {
        return json({ error: "method_not_allowed" }, 405);
      }

      try {
        const row = await env.DB.prepare("SELECT 1 AS ok").first();
        if (row?.ok !== 1) {
          return json({
            ok: false,
            service: "fog-wallet-api",
            version: API_VERSION,
            error: "database_unavailable"
          }, 503);
        }

        return json({
          ok: true,
          service: "fog-wallet-api",
          version: API_VERSION,
          database: "connected"
        });
      } catch {
        return json({
          ok: false,
          service: "fog-wallet-api",
          version: API_VERSION,
          error: "database_unavailable"
        }, 503);
      }
    }

    if (path === "/v1/auth/telegram") {
      if (request.method !== "POST") {
        return json({ error: "method_not_allowed" }, 405);
      }
      return telegramLogin(request, env);
    }

    if (path === "/v1/me") {
      if (request.method !== "GET") {
        return json({ error: "method_not_allowed" }, 405);
      }
      return currentUser(request, env);
    }

    if (path === "/v1/auth/logout") {
      if (request.method !== "POST") {
        return json({ error: "method_not_allowed" }, 405);
      }
      return logout(request, env);
    }

    return json({ error: "not_found" }, 404);
  }
};
