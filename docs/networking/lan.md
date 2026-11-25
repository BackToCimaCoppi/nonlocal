# Direct LAN Access (Trusted Home Wi-Fi Only)

**English** | [简体中文](../zh-CN/networking/lan.md)

> **Security Warning**: Direct LAN connections use **plaintext `ws://`** with **no application-layer end-to-end encryption (E2EE)**. Only use this mode on a trusted private/home Wi-Fi network. Never use Direct LAN on public Wi-Fi, hotels, cafes, or public IP addresses — use [Tailscale Serve](tailscale.md) instead.

---

## 1. Built-In Guardrails When Leaving Loopback

- **Two-key confirmation**: Binding a non-loopback IP requires **both** `--host <LAN_IPV4>` and `--allow-non-loopback` (or `server.allowNonLoopback: true` in `config.json`).
- **IP literals only**: `server.host` must be an explicit IPv4/IPv6 literal (e.g. `192.168.1.50`), never a hostname.
- **Companion loopback listener**: When bound to a specific LAN unicast IP, `nonlocal-bridge` automatically listens on `127.0.0.1` (or `::1`) on the same port as well so local `status` and `doctor` checks continue working.
- **`/health` stays private**: Requests to `/health` from any non-loopback IP always return `404 Not Found`.
- **Brute-force rate limiting**: Non-loopback IPs are banned for `5` minutes (`429 Too Many Requests`) after `10` failed auth attempts within `10` minutes.

---

## 2. Render the LAN Template

```bash
nonlocal-bridge template lan
```

---

## 3. Configure & Restart the Bridge

Find your workstation's private LAN IPv4 address (for example `192.168.1.50`), then either update `~/.config/nonlocal/config.json`:

```json
{
  "server": {
    "host": "192.168.1.50",
    "port": 8765,
    "allowNonLoopback": true
  }
}
```

Or reconfigure via CLI (note: `--force` overwrites existing config and generates a new token):

```bash
nonlocal-bridge init --yes \
  --host 192.168.1.50 \
  --port 8765 \
  --allow-non-loopback \
  --force
```

Restart and verify:

```bash
nonlocal-bridge restart
nonlocal-bridge doctor --json
```

`doctor --json` will report `config_security: "warn"` (expected reminder that plaintext LAN listening is enabled) and exit `0` when healthy.

---

## 4. Connect from Your iPhone

Ensure your iPhone is on the same Wi-Fi network, then configure:

- **URL**: `ws://<YOUR_LAN_IPV4>:8765/acp`
- **Bearer Token**: Run `nonlocal-bridge token show --reveal` on your workstation.
