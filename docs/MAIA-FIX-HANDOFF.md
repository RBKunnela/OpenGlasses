# Maia Offline — 3-Agent Fix Handoff (Jun 25, 2026)

> One source of truth for the three agents working this blocker:
> **Claude (Cowork, Mac)** = app code audit + this plan · **Grok (terminal, Mac)** = build/probe · **Claude Code (Hostinger terminal, KVM2)** = Caddy/OpenClaw.

## Verdict: the app is NOT the problem

Audited the full connection path. The iOS app is correct and needs **no rebuild** for this:

- `GatewayEndpoint.webSocketURL` builds `wss://srv753644.hstgr.cloud/ws?token=…` correctly.
- `OpenClawBridge.ensureWebSocket()` opens the socket with `Authorization: Bearer <token>` **and** `?token=`, then waits for OpenClaw's `connect.challenge` event before sending the `connect` handshake. This is the same protocol that already succeeds on Hermes/KVM4.
- Orange OpenClaw dot + red "Maia offline" = `webSocketReady == false` = the socket never upgraded. That is a server response, not an app bug.

**Do not reinstall the app expecting a fix.** It will behave identically until `/ws` upgrades.

## Root cause (confirmed)

Last probe: `https://srv753644.hstgr.cloud/ws` → **403, `Server: uvicorn`**.
Caddy on KVM2 forwards `/ws` to the **Maia Python API (uvicorn)** instead of **OpenClaw at `127.0.0.1:18789`**. uvicorn has no operator WebSocket, so it rejects the upgrade.

## THE FIX — Claude Code on KVM2 (srv753644)

```bash
hostname                                   # MUST be srv753644 (NOT srv659320 = Hermes/KVM4)
curl -s http://127.0.0.1:18789/health      # OpenClaw must answer locally; if not, OpenClaw is down
sudo cat /etc/caddy/Caddyfile              # inspect current routing
```

Add a `/ws` route that hits OpenClaw **before** the catch-all to uvicorn. Caddy's `reverse_proxy`
upgrades WebSockets transparently — no extra directives needed.

```caddy
srv753644.hstgr.cloud {
    # --- OpenClaw operator WebSocket: MUST come before the uvicorn catch-all ---
    handle /ws* {
        reverse_proxy 127.0.0.1:18789
    }

    # (everything else stays as-is — Maia Python API / uvicorn)
    handle {
        reverse_proxy 127.0.0.1:8000   # <-- keep whatever the existing upstream is
    }
}
```

Then:

```bash
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# Verify locally — expect: HTTP/1.1 101 Switching Protocols
TOKEN=$(python3 -c "import json;print(json.load(open('/root/.openclaw/openclaw.json'))['gateway']['auth']['token'])")
curl -sI -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
  "https://srv753644.hstgr.cloud/ws?token=$TOKEN" | head -5
```

Also print the gateway token so it can be matched against the iPhone:

```bash
echo "GATEWAY TOKEN: $TOKEN"
```

## VERIFY — Grok / user on Mac (after Caddy reload)

External probe (run from the Mac terminal — the Cowork sandbox is network-restricted and can't reach the VPS):

```bash
curl -sI -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
  'https://srv753644.hstgr.cloud/ws' | head -5
```

- `403 / Server: uvicorn` → Caddy fix not applied yet (or wrong host).
- `101 Switching Protocols` → server side fixed. Proceed to the iPhone.

## iPhone (user) — after 101

1. Gateway URL: `https://srv753644.hstgr.cloud` (no `:18789`, no `/ws`).
2. Token: **Maia KVM2 `gateway.auth.token`** — must equal the `GATEWAY TOKEN` printed above.
   Not the Telegram token, not the Hermes token, not the uvicorn/Maia-API token.
3. In Settings, tap the OpenClaw pill → "Testar conexão" (`probeConnection()`). It prints the iPhone Device ID.

## First pairing — Claude Code on KVM2

```bash
openclaw devices list                 # the iPhone Device ID from the probe should appear
openclaw devices approve --latest     # or approve by the specific device id
```

Then the iPhone pill goes green and "Oi Maia" routes voice through the glasses.

## Two distinct failure modes — don't confuse them

| Symptom | Meaning | Fix owner |
|---|---|---|
| `/ws` returns 403 / not 101 | Caddy still routing to uvicorn | Claude Code @ KVM2 |
| `/ws` returns 101 but app says handshake/`connect` failed (`ok:false`) | Wrong gateway token, or device not approved | User (token) + Claude Code (`devices approve`) |

## If Caddy genuinely can't be edited (fallback)

The app accepts any gateway URL. Alternatives, in order of preference:
1. Dedicated subdomain → OpenClaw: e.g. `maia.aicontexteng.com` (A record → 46.202.188.144) proxied straight to `127.0.0.1:18789`. Point the app there.
2. A distinct Caddy site block on KVM2 (separate hostname) reverse-proxying only OpenClaw.

Either way the app needs no code change — only the URL + Maia gateway token.
