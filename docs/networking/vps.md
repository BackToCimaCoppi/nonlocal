# Remote Access via Self-Hosted VPS (Caddy / Nginx + SSH Tunnel)

**English** | [简体中文](../zh-CN/networking/vps.md)

Use this setup if you already run a public VPS with a domain and want full self-hosted control behind carrier-grade NAT.

```text
iPhone ──(wss://:443)──▶ VPS (Caddy or Nginx TLS) ──▶ VPS 127.0.0.1:18765
                                                            ▲
                                                  Reverse SSH (-R)
                                                            │
                                          Workstation 127.0.0.1:8765 (nonlocal-bridge)
```

---

## 1. Render the Built-In Templates

```bash
nonlocal-bridge template vps-ssh-tunnel
nonlocal-bridge template vps-caddy    # Option A: Caddy (auto Let's Encrypt)
nonlocal-bridge template vps-nginx    # Option B: Nginx + Certbot
```

---

## 2. Configure the Reverse Proxy on Your VPS

Both built-in proxy templates enforce three security rules:

1. **Block `/health`** externally (`404`).
2. **Apply outer per-IP rate limiting** on WebSocket upgrade requests.
3. **Overwrite `X-Forwarded-For` with a single-hop verified client IP** (`{remote_host}` in Caddy / `$remote_addr` in Nginx) so clients cannot spoof forwarded headers.

### Option A: Caddy (`vps-caddy`)

- Paste the output of `nonlocal-bridge template vps-caddy` into your `Caddyfile`.
- Replace `<YOUR_BRIDGE_DOMAIN>.example.com` with your domain and point `reverse_proxy` to the VPS tunnel port (e.g. `127.0.0.1:18765`).
- Reload Caddy.

### Option B: Nginx (`vps-nginx`)

- Paste the output of `nonlocal-bridge template vps-nginx` into your Nginx site config.
- Replace `<YOUR_BRIDGE_DOMAIN>.example.com`, configure TLS certificates (e.g. Let's Encrypt), and point `proxy_pass` to the VPS tunnel port (e.g. `127.0.0.1:18765`).
- Keep `proxy_read_timeout 3600s` and `proxy_send_timeout 3600s` for long-lived WebSocket sessions.
- Test and reload: `sudo nginx -t && sudo systemctl reload nginx`.

---

## 3. Start the Cross-Platform SSH Reverse Tunnel on Your Workstation

Save the output of `nonlocal-bridge template vps-ssh-tunnel` to a script (for example `~/bin/nonlocal-tunnel.sh` and `chmod +x`), then run it with environment variables:

```bash
NONLOCAL_RELAY_HOST=203.0.113.10 \
NONLOCAL_RELAY_USER=tunnel \
NONLOCAL_REMOTE_PORT=18765 \
NONLOCAL_LOCAL_PORT=8765 \
NONLOCAL_SSH_KEY=~/.ssh/id_ed25519 \
~/bin/nonlocal-tunnel.sh
```

> Tip: Use a dedicated, restricted SSH user on your VPS (`AllowTcpForwarding remote`, `PermitTTY no`, `ForceCommand /usr/sbin/nologin`) so the tunnel key cannot open an interactive shell.

---

## 4. Enable Trusted Proxy Rate Limiting on the Bridge

On your workstation, set `security.trustedProxies` in `~/.config/nonlocal/config.json` to `["127.0.0.1"]` (matching the SSH tunnel's local source address) and restart the bridge:

```bash
nonlocal-bridge restart
```

Now `nonlocal-bridge` rate-limits abusive remote IPs individually using the single-hop `X-Forwarded-For` set by your VPS proxy, without ever locking out your own valid connections.

---

## 5. Connect from Your iPhone

- **URL**: `wss://<YOUR_BRIDGE_DOMAIN>.example.com/acp`
- **Bearer Token**: Run `nonlocal-bridge token show --reveal` on your workstation.
