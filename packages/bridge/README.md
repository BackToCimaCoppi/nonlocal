# `nonlocal-bridge`

**English** | [简体中文](README.zh-CN.md)

Cross-platform TypeScript ACP ↔ WebSocket bridge for [Nonlocal](../../README.md).

- **Runtime**: Node.js `>= 22.13.0` (Node 24 LTS recommended; uses built-in `node:sqlite`, `node:http`, `node:crypto`, and `fetch`).
- **Minimal dependencies**: Only `ws` and `commander` in `dependencies` (0 transitive dependencies).
- **Platforms**: macOS (`launchd`) verified end-to-end; Linux Ubuntu (`systemd --user`) implemented and unit-tested offline (pending real-host verification).

---

## Installation

### Global Install (Recommended)

```bash
npm install -g nonlocal-bridge
```

> Avoid running `service install` from ephemeral `npx` cache paths (`/_npx/`). `nonlocal-bridge service install` intentionally refuses ephemeral paths so your background daemon does not break after cache cleanup.

### Build from Source

```bash
cd packages/bridge
npm install
npm run build
# Optional: expose `nonlocal-bridge` globally on PATH
npm link
```

---

## CLI Command Reference

| Command | Description | Key Flags | Exit Codes |
|---|---|---|---|
| `nonlocal-bridge init` | Interactive wizard (or `--yes` non-interactive) to create `config.json` and a `0600` Bearer token | `-y, --yes`, `--force`, `--host <ip>`, `--port <port>`, `--allow-non-loopback`, `--adapter <antigravity\|generic-acp>`, `--adapter-command <cmd>`, `--adapter-args <json>`, `--default-model <id>`, `--default-thought-level <level>`, `--title-language <auto\|zh\|en>`, `--config <path>`, `--state-dir <path>`, `--token-file <path>`, `--log-file <path>` | `0` ok, `1` conflict/validation error |
| `nonlocal-bridge start` | Start the bridge server (uses installed service when running default config, or detached standalone) | `--foreground`, `--standalone`, plus config override flags | `0` healthy/already running, `1` error or port occupied by another process |
| `nonlocal-bridge stop` | Stop the running bridge instance (verifies PID + command fingerprint in `bridge.runtime.json`) | `--standalone`, `--config <path>` | `0` stopped/already stopped, `1` error |
| `nonlocal-bridge restart` | Restart the bridge and wait for loopback `/health` | `--standalone`, `--config <path>` | `0` healthy, `1` error |
| `nonlocal-bridge status` | Inspect process ownership, `/health`, security warnings, and daemon status | `--json`, `--config <path>` | `0` running & healthy, `1` stopped/unhealthy |
| `nonlocal-bridge logs` | Read bridge JSONL logs (`bridge.log`) or daemon stdout/stderr (`service.log`) | `-n <lines>`, `-f, --follow`, `--service` | `0` ok, `1` missing log file |
| `nonlocal-bridge token path` | Print Bearer token path, POSIX permissions, and byte length (never prints plaintext) | `--config <path>` | `0` ok, `1` error |
| `nonlocal-bridge token rotate` | Atomically generate a new 64-hex-char `0600` Bearer token (reminds you to restart) | `--config <path>` | `0` ok, `1` error |
| `nonlocal-bridge token show --reveal` | Explicitly print the plaintext Bearer token (`--reveal` is mandatory; fails without it) | `--reveal`, `--config <path>` | `0` with `--reveal`, `1` without `--reveal` |
| `nonlocal-bridge doctor` | Run all 8 diagnostics including a real WebSocket handshake against the running bridge | `--json`, `--config <path>` | `0` zero `fail` checks, `1` any `fail` check |
| `nonlocal-bridge service install\|uninstall\|status` | Manage user-level background daemon (`com.nonlocal.bridge` on macOS, `nonlocal-bridge.service` on Ubuntu) | `--target <launchd\|systemd>`, `--dry-run`, `--plist-path <path>`, `--unit-path <path>`, `--allow-ephemeral-path` | `0` ok, `1` error |
| `nonlocal-bridge template [name]` | Read-only render of sanitized remote-access config templates using your configured port | `list`, `tailscale`, `cloudflare`, `vps-caddy`, `vps-nginx`, `vps-ssh-tunnel`, `lan` | `0` ok, `1` unknown template |

### `doctor --json` Checks (8 Fixed IDs)

`nonlocal-bridge doctor --json` outputs `{ ok, timestamp, bridgeVersion, summary: { pass, warn, fail }, checks: [...] }` with 8 fixed check IDs:

1. `platform` — macOS / Linux check and Ubuntu `loginctl` linger advisory (read-only).
2. `node_runtime` — Verifies Node `>= 22.13.0` and native `node:sqlite`.
3. `config_security` — Strict Schema v1 validation, IP literal check, non-loopback plaintext warning, no plaintext secrets in `config.json`.
4. `bearer_token` — Exists, `>= 32` bytes after trim, `0600` permissions, and outside any `.git` repository.
5. `adapter_cli` — Adapter executable availability (`agy` or custom `generic-acp` command).
6. `antigravity_settings` — Read-only check of Antigravity CLI settings (marked N/A for `generic-acp`).
7. `port_binding` — Three-state port ownership check (`owned_running`, `free`, `occupied_by_other`) without calling `lsof`.
8. `bridge_live_handshake` — Real loopback WebSocket `initialize` probe (`fail` if bridge is stopped; skipped if port is `occupied_by_other`).

---

## Configuration (`config.json` v1 & Environment Variables)

Default XDG paths (directories `0700`, secret/state/log files `0600`):

- Config: `${XDG_CONFIG_HOME:-~/.config}/nonlocal/config.json`
- Token: `${XDG_CONFIG_HOME:-~/.config}/nonlocal/bearer.token`
- State & Logs: `${XDG_STATE_HOME:-~/.local/state}/nonlocal/` (`bridge-state.db`, `bridge.runtime.json`, `bridge.log`, `service.log`)

Priority order: **CLI flags > allowlisted `NONLOCAL_*` env vars > `config.json` > defaults**.

### Strict Schema v1 Defaults

`config.json` uses a **strict allowlist** — unknown keys or plaintext secret fields (`token`, `bearerToken`, `apiKey`, `key`, `secret`, `password`) fail closed at startup:

```json
{
  "schemaVersion": 1,
  "server": {
    "host": "127.0.0.1",
    "port": 8765,
    "allowNonLoopback": false,
    "maxFrameBytes": 16777216,
    "pingIntervalMs": 25000,
    "pongTimeoutMs": 60000
  },
  "security": {
    "tokenFile": "~/.config/nonlocal/bearer.token",
    "trustedProxies": [],
    "rateLimit": {
      "maxFailures": 10,
      "windowMs": 600000,
      "banMs": 300000,
      "loopbackBackoffMs": 200,
      "maxTrackedIps": 4096
    }
  },
  "adapter": {
    "type": "antigravity",
    "command": "agy",
    "args": ["acp"],
    "defaultModel": "",
    "defaultThoughtLevel": "",
    "fallbackCwd": "/tmp",
    "childIdleTimeoutMs": 86400000,
    "childStopGraceMs": 3000,
    "antigravity": {
      "dataDirs": ["~/.gemini/antigravity-cli", "~/.gemini/antigravity"],
      "disableDataDirs": false,
      "usageTimeoutMs": 15000,
      "usageCooldownMs": 60000
    }
  },
  "titleSummary": {
    "enabled": false,
    "endpoint": "",
    "model": "",
    "apiKeyFile": "",
    "language": "auto",
    "timeoutMs": 8000
  },
  "sync": {
    "maxEventsPerTurn": 2000,
    "maxTurnBytes": 2097152,
    "watchIntervalMs": 2500,
    "watchWindowMs": 300000,
    "settleWindowMs": 60000,
    "loadSettleQuietMs": 60,
    "loadSettleMaxWaitMs": 1000
  },
  "state": {
    "dir": "~/.local/state/nonlocal",
    "logFile": "~/.local/state/nonlocal/bridge.log",
    "logMaxBytes": 10485760,
    "logMaxBackups": 3
  }
}
```

### Allowlisted `NONLOCAL_*` Environment Variables (13)

`NONLOCAL_CONFIG`, `NONLOCAL_HOST`, `NONLOCAL_PORT`, `NONLOCAL_ALLOW_NON_LOOPBACK`, `NONLOCAL_TOKEN_FILE`, `NONLOCAL_STATE_DIR`, `NONLOCAL_LOG_FILE`, `NONLOCAL_ADAPTER_TYPE`, `NONLOCAL_ADAPTER_COMMAND`, `NONLOCAL_ADAPTER_ARGS` (JSON string array), `NONLOCAL_DEFAULT_MODEL`, `NONLOCAL_DEFAULT_THOUGHT_LEVEL`, `NONLOCAL_TITLE_SUMMARY_API_KEY` (injected in memory only, never written back to `config.json`).

---

## Three-Layer Architecture

```text
src/cli/        ─▶ config / service / templates / gateway
src/gateway/    ─▶ transport/types + adapter/types + store + sync + fs + log
src/adapter/    ─▶ antigravity-adapter ─▶ base-acp-adapter ─▶ types
```

- **Gateway (`src/gateway/`)**: Protocol routing, single-client `4001` preemption, session allowlist, title sanitization, and `BridgeTransport` SPI. Zero agent-specific coupling.
- **Adapter SPI (`src/adapter/types.ts`)**: `AgentAdapter` + `AdapterCapabilities` (`usage`, `sessionInfo`, `deleteSession`, `diskPresence`). Unsupported capabilities automatically return `-32601`.
- **Adapters (`src/adapter/base-acp-adapter.ts`, `antigravity-adapter.ts`)**: `BaseAcpAdapter` directly powers `generic-acp` (multi-cwd worker pool, NDJSON framing, wake-up recovery, optional default model lock); `AntigravityAdapter` adds Antigravity-specific `/usage`, read-only summary DB inspection, and multi-DB cascade deletion.

---

## Development & Testing

```bash
cd packages/bridge
npm run typecheck
npm run build
npm test
```

## Further Reading

- [Quickstart Guide](../../docs/quickstart.md)
- [Networking Guides](../../docs/networking/README.md)
- [Security Model](../../docs/security.md)
- [AI Agent Install Guide](../../docs/agent-install.md)
