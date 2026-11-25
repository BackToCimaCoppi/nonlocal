# Remote Access via Cloudflare Tunnel

**English** | [简体中文](../zh-CN/networking/cloudflare.md)

Use **Cloudflare Tunnel (`cloudflared`)** if you own a domain on Cloudflare and want encrypted `wss://` access from your iPhone without running a VPN client.

- `nonlocal-bridge` stays bound to `127.0.0.1:8765` (no router port forwarding required).
- Cloudflare terminates TLS with certificates trusted by iOS.

---

## 1. Prerequisites

1. `nonlocal-bridge` running on `127.0.0.1:8765` and passing `nonlocal-bridge doctor --json`.
2. A domain managed by Cloudflare and `cloudflared` installed on your workstation.

---

## 2. Render the Tunnel Template

```bash
nonlocal-bridge template cloudflare
```

Example output (using your configured port):

```yaml
tunnel: <YOUR_CLOUDFLARE_TUNNEL_ID>
credentials-file: /path/to/<YOUR_TUNNEL_CREDENTIALS_FILE>.json

ingress:
  - hostname: <YOUR_BRIDGE_HOSTNAME>.example.com
    path: ^/(acp|ws)$
    service: http://127.0.0.1:8765
    originRequest:
      noTLSVerify: false
  - service: http_status:404
```

Key points:
- `path: ^/(acp|ws)$` exposes only the WebSocket endpoints; everything else (including `/health`) returns `404`.
- Even if `/health` were proxied, `nonlocal-bridge` rejects any request carrying `cf-connecting-ip` or `x-forwarded-for` with `404`.

---

## 3. Create & Start the Tunnel

1. Authenticate and create a named tunnel with `cloudflared`:
   ```bash
   cloudflared tunnel login
   cloudflared tunnel create nonlocal-bridge
   cloudflared tunnel route dns nonlocal-bridge <YOUR_BRIDGE_HOSTNAME>.example.com
   ```
2. Save the rendered YAML to `~/.cloudflared/config.yml` with your real tunnel ID, credentials path, and hostname.
3. Run the tunnel:
   ```bash
   cloudflared tunnel run nonlocal-bridge
   ```

---

## 4. Optional Hardening & Rate Limiting

- Add `"127.0.0.1"` to `security.trustedProxies` in `~/.config/nonlocal/config.json` if you want per-client IP rate limiting behind local `cloudflared` (otherwise loopback requests use short backoff without self-lockout).
- Configure Cloudflare WAF rate-limiting rules on `<YOUR_BRIDGE_HOSTNAME>.example.com` for an outer defense layer.

---

## 5. Connect from Your iPhone

- **URL**: `wss://<YOUR_BRIDGE_HOSTNAME>.example.com/acp`
- **Bearer Token**: Run `nonlocal-bridge token show --reveal` on your workstation.
