# AI Agent Installation Guide (`nonlocal-bridge`)

**English** | [简体中文](zh-CN/agent-install.md)

> **Audience**: Autonomous coding agents (Antigravity, Claude Code, Codex, Cursor, etc.) installing and configuring `nonlocal-bridge` on a user's workstation.
> **Completion Criterion**: Exit code `0` (`"ok": true`) from `nonlocal-bridge doctor --json`.

---

## 1. Hard Safety Rules (NEVER Violate)

1. **NEVER read or print secrets**:
   - NEVER run `nonlocal-bridge token show --reveal`.
   - NEVER `cat`, read, or echo `~/.config/nonlocal/bearer.token`, `title-summary.key`, or any private key file into your context or response.
   - Instead, run `nonlocal-bridge token path` and tell the user to run `nonlocal-bridge token show --reveal` themselves when pasting into iOS.
2. **NEVER silently expose the bridge off loopback**:
   - Keep `server.host` at `127.0.0.1` unless the user **explicitly** chooses Direct LAN and acknowledges that `ws://` on LAN is plaintext (no E2EE).
   - Never pass `--allow-non-loopback` without explicit user confirmation.
3. **NEVER modify external or system-wide configs**:
   - NEVER edit `~/.gemini/antigravity-cli/settings.json`.
   - NEVER run `loginctl enable-linger` automatically — if `service install` or `doctor` warns that linger is off on Ubuntu, show the command to the user to run manually.
   - NEVER edit the user's Tailscale, Cloudflare, Nginx, or Caddy configs without explicit permission; only render read-only templates via `nonlocal-bridge template <name>`.
4. **NEVER overwrite existing config without asking**:
   - If `init` reports an existing config/token/database conflict, STOP and ask the user before using `--force`.

---

## 2. Step 0 — Read-Only Environment Probe

Run read-only checks first:

```bash
uname -s
node -v
which nonlocal-bridge || true
which agy || true
```

Evaluate:
- **Node.js**: Must be `>= 22.13.0` (Node 24 LTS recommended). If missing or older, stop and guide the user to install Node 22.13+ / 24 LTS before continuing.
- **OS**: `Darwin` (macOS `launchd`) or `Linux` (Ubuntu `systemd --user`). Note: Ubuntu support is implemented and offline-tested, pending real-host verification.

---

## 3. Step 1 — Ask the User Two Decisions (Do NOT Guess)

Before initializing, ask the user concisely:

1. **Which agent adapter?**
   - `antigravity` (default, Google Antigravity `agy acp`)
   - `generic-acp` (custom stdio ACP CLI — ask for the command and optional JSON args array)
2. **How will the iPhone connect?**
   - **Tailscale Serve (Recommended for remote access)** — bridge stays on `127.0.0.1`
   - **Cloudflare Tunnel** — bridge stays on `127.0.0.1`
   - **Self-hosted VPS (Caddy/Nginx + SSH tunnel)** — bridge stays on `127.0.0.1`
   - **Direct LAN (Trusted home Wi-Fi only, plaintext `ws://`, no E2EE)** — requires explicit LAN IPv4 literal and `--allow-non-loopback`

---

## 4. Step 2 — Install & Initialize

### 4.1 Install `nonlocal-bridge`

- Preferred (global npm install):
  ```bash
  npm install -g nonlocal-bridge
  ```
- If working inside a cloned repo without global install:
  ```bash
  cd packages/bridge && npm install && npm run build && npm link
  ```
- **Do NOT** use `npx nonlocal-bridge service install` and **do NOT** bypass the ephemeral-path check with `--allow-ephemeral-path`.

### 4.2 Non-Interactive Init

Run `init --yes` matching the user's choices (never add `--force` unless the user approved overwriting existing config):

- **Loopback (Tailscale / Cloudflare / VPS) + Antigravity**:
  ```bash
  nonlocal-bridge init --yes
  ```
- **Loopback + Generic ACP**:
  ```bash
  nonlocal-bridge init --yes \
    --adapter generic-acp \
    --adapter-command "<USER_CMD>" \
    --adapter-args '<JSON_STRING_ARRAY>'
  ```
- **Direct LAN (only after explicit user confirmation + LAN IPv4 literal, never `"localhost"` or hostname)**:
  ```bash
  nonlocal-bridge init --yes \
    --host "<USER_LAN_IPV4>" \
    --allow-non-loopback
  ```

---

## 5. Step 3 — Start or Install User Daemon (OS Branch)

Ask or follow user preference for background auto-start:

- **Background daemon (recommended)**:
  ```bash
  nonlocal-bridge service install
  ```
  - **macOS**: Installs `~/Library/LaunchAgents/com.nonlocal.bridge.plist`.
  - **Linux Ubuntu**: Installs `~/.config/systemd/user/nonlocal-bridge.service`. If output warns that lingering is disabled, instruct the user to run:
    ```bash
    loginctl enable-linger "$USER"
    ```
- **Standalone / temporary run**:
  ```bash
  nonlocal-bridge start --standalone
  ```

---

## 6. Step 4 — Render Network Access Template (Read-Only)

Run the read-only template command matching the user's Step 1 choice and share the rendered output + corresponding guide link:

| User Choice | Command | Guide |
|---|---|---|
| Tailscale | `nonlocal-bridge template tailscale` | `docs/networking/tailscale.md` |
| Cloudflare Tunnel | `nonlocal-bridge template cloudflare` | `docs/networking/cloudflare.md` |
| Self-hosted VPS | `nonlocal-bridge template vps-ssh-tunnel` and `vps-caddy` or `vps-nginx` | `docs/networking/vps.md` |
| Direct LAN | `nonlocal-bridge template lan` | `docs/networking/lan.md` |

---

## 7. Step 5 — Verify & Hand Off

Run the 8-point diagnostic:

```bash
nonlocal-bridge doctor --json
nonlocal-bridge token path
```

- **Success**: `doctor --json` exits `0` with `"ok": true`. Report to the user:
  1. Listen address(es) and service mode (`launchd` / `systemd` / `standalone`).
  2. Token file path (from `token path`) and the exact command for the user to copy their token manually:
     ```bash
     nonlocal-bridge token show --reveal
     ```
  3. Next steps for their chosen networking method and iOS Xcode build (`ios/`).

### `doctor --json` Failure Triage Map

| Failed `check.id` | Action |
|---|---|
| `node_runtime` | Ask user to upgrade Node.js to `>= 22.13.0` (24 LTS recommended) |
| `config_security` | Inspect `summary` / `fixHint` (e.g., `server.host` must be an IP literal, no unknown keys, no plaintext secrets in `config.json`) |
| `bearer_token` | Fix file permissions (`chmod 600`) or move outside `.git` repo (never read file contents) |
| `adapter_cli` | Verify `agy` (or custom CLI) is installed on `PATH` and logged in |
| `port_binding` | Port is `occupied_by_other`: ask user whether to stop the other process or pick another port (`--port`) |
| `bridge_live_handshake` | Run `nonlocal-bridge status --json` and `nonlocal-bridge logs -n 50` to diagnose startup failure |
