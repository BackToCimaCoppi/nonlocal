# Remote Access via Tailscale Serve (Recommended)

**English** | [简体中文](../zh-CN/networking/tailscale.md)

**Tailscale Serve** is the recommended way to reach `nonlocal-bridge` from outside your home network:

- Traffic stays inside your private WireGuard tailnet (never exposed to the public internet).
- Tailscale issues valid HTTPS/WSS certificates trusted natively by iOS.
- `nonlocal-bridge` remains safely bound to `127.0.0.1:8765`.

---

## 1. Prerequisites

1. `nonlocal-bridge` running on loopback (`127.0.0.1:8765`) and passing `nonlocal-bridge doctor --json`.
2. [Tailscale](https://tailscale.com/) installed and signed into the same tailnet on both your workstation and your iPhone.
3. **MagicDNS** and **HTTPS Certificates** enabled in the Tailscale admin console (DNS settings).

---

## 2. Render the Bridge Template

```bash
nonlocal-bridge template tailscale
```

This prints the exact `tailscale serve` command for your configured port:

```bash
tailscale serve --bg --https=443 --set-path=/acp http://127.0.0.1:8765/acp
```

Run that command on your workstation. Notice it only exposes `/acp` — `/health` stays loopback-only.

---

## 3. Connect from Your iPhone

1. Verify your Tailscale Serve rule is active:
   ```bash
   tailscale serve status
   ```
2. On your workstation, reveal your Bearer token manually:
   ```bash
   nonlocal-bridge token show --reveal
   ```
3. In the Nonlocal iOS app, configure:
   - **URL**: `wss://<YOUR_MACHINE_NAME>.<YOUR_TAILNET_SUFFIX>.ts.net/acp`
   - **Authorization**: Bearer token from step 2

---

## 4. Turn Off Later

```bash
tailscale serve --https=443 --set-path=/acp off
```

## Troubleshooting

- **iOS TLS error**: Confirm HTTPS Certificates and MagicDNS are enabled in your Tailscale admin console and wait 1–2 minutes for initial certificate issuance.
- **Connection refused**: Check `nonlocal-bridge status --json` to confirm the bridge is running on the same port used in `tailscale serve`.
