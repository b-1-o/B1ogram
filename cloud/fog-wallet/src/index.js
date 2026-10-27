const API_VERSION = "0.1.0";

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

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === "/health") {
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

    return json({ error: "not_found" }, 404);
  }
};
