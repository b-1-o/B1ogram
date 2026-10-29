const API_VERSION = "1.0.0";

function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
      "Referrer-Policy": "no-referrer"
    }
  });
}

export default {
  async fetch(request) {
    const url = new URL(request.url);

    if (url.pathname === "/health") {
      if (request.method !== "GET") return json({ error: "method_not_allowed" }, 405);
      return json({
        ok: true,
        service: "biogram-profile-colors",
        version: API_VERSION,
        mode: "telegram-native-profile-colors",
        customCardArtwork: "stored_on_device"
      });
    }

    if (
      url.pathname === "/admin" ||
      url.pathname.startsWith("/v1/admin/") ||
      url.pathname.startsWith("/v1/cards/") ||
      url.pathname.startsWith("/v1/connect/") ||
      url.pathname === "/v1/auth/telegram/callback"
    ) {
      return json({
        error: "feature_removed",
        message: "Fog Wallet activation codes, card issuing and OAuth linking have been retired. Biogram profile colors use Telegram's native profile system."
      }, 410);
    }

    return json({ error: "not_found" }, 404);
  }
};
