# Quickstart (macOS & Linux Ubuntu)

**English** | [简体中文](zh-CN/quickstart.md)

Get `nonlocal-bridge` installed, running as a user-level background daemon, and verified end-to-end.

---

## 1. Prerequisites

- **Node.js `>= 22.13.0`** (Node 24 LTS recommended). `nonlocal-bridge` uses Node's built-in `node:sqlite` with zero native C++ compilation.
- **Coding Agent CLI**:
  - Default (`antigravity`): Google Antigravity CLI (`agy`) installed on `PATH` and logged in.
  - Generic (`generic-acp`): Any standard stdio ACP CLI command.
- **OS**:
  - **macOS**: Verified end-to-end on physical iPhone (`launchd` user agent).
  - **Linux Ubuntu**: Fully implemented and unit-tested offline (`systemd --user`), pending real-host verification.

---

## 2. Install `nonlocal-bridge`

### Global Install via npm (Recommended)

```bash
npm install -g nonlocal-bridge
nonlocal-bridge --version
```

> Do not run `nonlocal-bridge service install` via `npx` (`/_npx/` cache paths). The installer intentionally blocks ephemeral paths so your background daemon stays working after cache cleanup.

### Install from Source

If you cloned this repository or want to hack on the bridge:

```bash
git clone https://github.com/BackToCimaCoppi/nonlocal.git
cd nonlocal/packages/bridge
npm install
npm run build
# Optional: put `nonlocal-bridge` on your global PATH
npm link
```

---

## 3. Initialize Configuration & Bearer Token

Run the interactive wizard:

```bash
nonlocal-bridge init
```

Or initialize non-interactively:

```bash
# Default: Antigravity (agy acp) on 127.0.0.1:8765
nonlocal-bridge init --yes

# Generic stdio ACP agent example
nonlocal-bridge init --yes \
  --adapter generic-acp \
  --adapter-command my-acp-cli \
  --adapter-args '["serve"]'
```

`init` creates XDG-compliant directories (`0700`) and secret files (`0600`):

- `~/.config/nonlocal/config.json` — main configuration (never stores plaintext secrets).
- `~/.config/nonlocal/bearer.token` — 64-character hex Bearer token (`0600`).
- `~/.local/state/nonlocal/` — `bridge-state.db`, `bridge.runtime.json`, `bridge.log`, `service.log`.

To inspect or rotate your token later:

```bash
nonlocal-bridge token path
nonlocal-bridge token show --reveal   # Explicitly prints plaintext token for your iPhone
nonlocal-bridge token rotate          # Generates a new token (restart bridge afterward)
```

---

## 4. Start & Enable Background Daemon

### Install User-Level Daemon (Recommended)

```bash
nonlocal-bridge service install
nonlocal-bridge service status
```

- **macOS (`launchd`)**: Writes and validates (`plutil -lint`) `~/Library/LaunchAgents/com.nonlocal.bridge.plist` (`KeepAlive`, `Umask=0077`, separate `bridge.log` / `service.log`).
- **Linux Ubuntu (`systemd --user`)**: Writes `~/.config/systemd/user/nonlocal-bridge.service` (`UMask=0077`, `Restart=always`, `KillMode=control-group`).
  - **Important on Ubuntu**: User systemd services stop when you log out of SSH unless lingering is enabled. `service install` and `doctor` check linger read-only and print the exact command if needed:
    ```bash
    loginctl enable-linger "$USER"
    ```

To remove the daemon later:

```bash
nonlocal-bridge service uninstall
```

### Manual / Standalone Lifecycle

If you prefer not to install a background daemon:

```bash
nonlocal-bridge start                # Detached background process
nonlocal-bridge start --foreground   # Foreground mode (prints LISTENING host=... port=... pid=...)
nonlocal-bridge status --json        # Check runtime, /health, and service status
nonlocal-bridge logs -n 50           # Bridge JSONL logs (add --service for daemon logs)
nonlocal-bridge restart
nonlocal-bridge stop
```

---

## 5. Verify with `doctor --json`

Always finish setup by running:

```bash
nonlocal-bridge doctor --json
```

Exit code `0` (`"ok": true`) confirms all 8 checks passed — including a live WebSocket `initialize` handshake against your running bridge.

### Common Troubleshooting

| Check / Symptom | Likely Cause | Fix |
|---|---|---|
| `port_binding: fail` (`occupied_by_other`) | Another process already holds port `8765` | Pick a free port (`nonlocal-bridge init --yes --port 8766 --force` or edit `server.port`) or stop the conflicting process |
| `bridge_live_handshake: fail` (port `free`) | Bridge is not running yet | Run `nonlocal-bridge start` or `nonlocal-bridge service install` |
| `config_security: fail` (`host`) | `server.host` set to `"localhost"` or a hostname | Use an explicit IP literal such as `"127.0.0.1"` or `"::1"` |
| `bearer_token: fail` | Permissions too wide or token placed inside a `.git` repo | Move token under `~/.config/nonlocal/` and `chmod 600` |
| `adapter_cli: fail` | `agy` not on `PATH` or not logged in | Install/login Antigravity CLI, or verify `which agy` |
| Ubuntu `service install` fails with D-Bus error | Non-login shell missing `XDG_RUNTIME_DIR` / user bus | Ensure `systemd --user` is active in your login session and enable linger |

---

## 6. Connect Your iPhone

1. Build and install the iOS app by opening the Xcode project under [`ios/`](../ios/).
2. Choose how your iPhone will reach the bridge in [Networking Overview](networking/README.md) (Tailscale Serve is recommended for remote access).
3. In the iOS app, enter your WebSocket URL (for example `wss://<your-machine>.<tailnet>.ts.net/acp`) and the Bearer token from `nonlocal-bridge token show --reveal`.
