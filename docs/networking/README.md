# Networking Overview

**English** | [简体中文](../zh-CN/networking/README.md)

`nonlocal-bridge` binds to `127.0.0.1:8765` by default and intentionally does not bundle TLS certificates. Choose one of the four supported access methods below to connect your iPhone.

---

## Compare the 4 Access Methods

| Method | Encrypted (`wss://`) | Needs VPS / Domain | Bridge Listen Host | Best For | Guide |
|---|---|---|---|---|---|
| **Tailscale Serve (Recommended)** | Yes (WireGuard + auto HTTPS) | No | `127.0.0.1` | Private remote access from anywhere with zero port forwarding | [Tailscale Guide](tailscale.md) |
| **Cloudflare Tunnel** | Yes (Cloudflare TLS) | Own domain only | `127.0.0.1` | Remote access without installing a VPN app on your iPhone | [Cloudflare Guide](cloudflare.md) |
| **Self-Hosted VPS (Caddy / Nginx + SSH)** | Yes (Let's Encrypt TLS) | VPS + domain | `127.0.0.1` | Full self-hosted control behind carrier-grade NAT | [Self-Hosted VPS Guide](vps.md) |
| **Direct LAN** | **No (plaintext `ws://`)** | No | LAN IPv4 + `--allow-non-loopback` | Trusted home Wi-Fi only (lowest setup) | [Direct LAN Guide](lan.md) |

---

## Built-In Read-Only Templates

`nonlocal-bridge` ships with 6 sanitized configuration templates that automatically substitute your configured port without modifying any external software on your machine:

```bash
nonlocal-bridge template list
nonlocal-bridge template tailscale
nonlocal-bridge template cloudflare
nonlocal-bridge template vps-caddy
nonlocal-bridge template vps-nginx
nonlocal-bridge template vps-ssh-tunnel
nonlocal-bridge template lan
```

---

## Security Reminder

- Keep `/health` private: all reverse-proxy and tunnel templates only forward WebSocket paths (`/acp` and `/ws`), and the bridge itself returns `404` for any non-loopback or forwarded `/health` request.
- Never expose plaintext `ws://` directly to the public internet. See [Security Model & Encryption Boundaries](../security.md).
