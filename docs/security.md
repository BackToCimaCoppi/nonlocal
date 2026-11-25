# Security Model & Encryption Boundaries

**English** | [简体中文](zh-CN/security.md)

`nonlocal-bridge` can read files from your workstation and drive local coding agents. Its security model is fail-closed by default and intentionally transparent about what is and is not encrypted.

---

## 1. Loopback-First Binding & Non-Loopback Guardrails

- **Default bind**: `127.0.0.1:8765` (`server.allowNonLoopback = false`).
- **IP literals only**: `server.host` accepts only valid IPv4/IPv6 literals. Hostnames (including `"localhost"`) fail closed at config validation, startup, and `doctor`.
- **Two-key guard for non-loopback**: Binding any non-loopback IP (LAN unicast, `0.0.0.0`, `::`, or public IP) requires **both** setting `server.host` and explicitly setting `server.allowNonLoopback = true` (`--allow-non-loopback` / `NONLOCAL_ALLOW_NON_LOOPBACK=1`). Otherwise the bridge refuses to start (exit code `1`, zero sockets opened).
- **Tiered plaintext warnings**:
  - Private unicast IP (`lan_plaintext`): warns that `ws://` traffic is unencrypted and should only be used on trusted private networks.
  - Wildcard (`0.0.0.0`, `::`) or public IP (`public_or_wildcard_plaintext`): escalated warning recommending loopback + Tailscale / Cloudflare / TLS reverse proxy.
  - Warnings appear consistently in `init`, startup logs (`non_loopback_listening`), `status --json`, and `doctor --json`.
- **Companion loopback listener**: When bound to a specific non-loopback unicast IP, the bridge also opens a companion loopback listener on the same port (`127.0.0.1` for IPv4, `::1` for IPv6) so local CLI diagnostics keep working safely.

---

## 2. Authentication & Secret Isolation

- **Header-only Bearer auth**: WebSocket upgrades accept only `Authorization: Bearer <token>`. Query-string tokens (`?token=`, `?access_token=`) are always rejected with `401 Unauthorized`.
- **Constant-time verification**: Tokens are compared using per-process random-key HMAC-SHA256 + `crypto.timingSafeEqual`.
- **Isolated `0600` secret files**:
  - Bearer token (`>= 32` bytes after trim) lives in `~/.config/nonlocal/bearer.token` (`0600`), never inside `config.json`.
  - Optional `titleSummary` API key lives in a separate `0600` file or `NONLOCAL_TITLE_SUMMARY_API_KEY` (memory only).
  - Putting plaintext secret keys (`token`, `bearerToken`, `apiKey`, `key`, `secret`, `password`) inside `config.json`, setting permissions wider than `0600`, or placing secret files inside any `.git` repository fails closed.
- **Sanitized logging**: `bridge.log` (`0600`, JSONL) uses a strict field allowlist, strips message/file contents, and redacts registered secrets before writing.

---

## 3. Brute-Force Rate Limiting (Without Self-Lockout)

- **Non-loopback clients**: Sliding window (defaults: `10` failed handshakes within `10` minutes → `429 Too Many Requests` + `Retry-After` for `5` minutes). Any valid handshake clears the client's failure history immediately.
- **Loopback clients (`127.0.0.1` / `::1`)**: Never permanently banned (never returns `429`); applies a short `200ms` backoff on auth failure so external scans behind a local forwarder cannot lock you out of your own machine.
- **Reverse-proxy real IP handling**: Configure `security.trustedProxies` with explicit proxy IP/CIDR entries (wildcards `0.0.0.0/0` and `::/0` are rejected). Only connections arriving from a trusted proxy parse `X-Forwarded-For` from right to left; untrusted peers cannot spoof `X-Forwarded-For`.

---

## 4. Loopback-Only `/health`

`GET /health` returns `200 OK` (`{"ok":true,"childAlive":...,"activeClient":...}`) **only** when both conditions hold:

1. The TCP socket peer address is pure loopback (`127.0.0.1`, `127.0.0.0/8`, or `::1`).
2. The request carries **none** of `x-forwarded-for`, `forwarded`, `x-real-ip`, or `cf-connecting-ip`.

Any non-loopback or proxied request to `/health` receives `404 Not Found`.

---

## 5. Honest Encryption Boundaries (Why No Built-In TLS or E2EE)

- **No built-in TLS**: Apple's `NWConnection` rejects self-signed certificates by default. Instead of forcing users to manage local certificate renewals, `nonlocal-bridge` stays pure HTTP/WS on loopback and delegates `wss://` TLS termination to battle-tested tools that issue trusted certificates automatically (Tailscale Serve, Cloudflare Tunnel, Caddy, or Nginx + Let's Encrypt).
- **No application-layer E2EE**:
  - Over **Tailscale**, **Cloudflare Tunnel**, or **VPS TLS**, traffic is protected by transport-layer encryption (`wss://` / WireGuard).
  - Over **Direct LAN**, traffic is **plaintext `ws://`** — never use Direct LAN on public Wi-Fi, cafes, hotels, or untrusted networks.

---

## 6. Session & Filesystem Boundaries

- **Closed owned-session allowlist**: The bridge only lists and manages sessions created through Nonlocal. Desktop-only sessions are not exposed or deletable through the bridge.
- **Remote filesystem safety**: `nonlocal/fs_read_file` caps text previews at `512 KiB` (UTF-8 safe truncation) and images at `10 MiB`, fast-rejects binaries/FIFOs, and logs zero file contents.
- **Symlink escape protection**: Antigravity cascade deletion rejects intermediate symlink escapes (`-32023`) and never touches unrelated sessions.
