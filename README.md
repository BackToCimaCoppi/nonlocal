<p align="center">
  <img src="docs/brand/nonlocal-logo-primary.png" alt="Nonlocal" width="200" />
</p>

<h1 align="center">Nonlocal</h1>

<p align="center">
  <strong>Local coding agents, nonlocal control.</strong>
</p>

<p align="center">
  <strong>English</strong> | <a href="README.zh-CN.md">简体中文</a>
</p>

---

**Nonlocal** is an open-source mobile remote-control suite for local AI coding agents. Your coding agent stays on your own workstation (`localhost`), while you steer sessions, review code/images, approve actions, and monitor usage from your iPhone.

- **`packages/bridge/` (`nonlocal-bridge`)**: Cross-platform TypeScript ACP ↔ WebSocket bridge (Node.js `>= 22.13.0`, minimal zero-transitive-dependency core using only `ws` + `commander` + Node built-ins).
- **`ios/`**: Native SwiftUI iOS client, evolved under the MIT License from [`rebornix/Agmente`](https://github.com/rebornix/Agmente).

## Architecture

```text
+-----------------------+        WSS (Tailscale / Cloudflare / VPS)         +-------------------------------+
|  iPhone (Nonlocal)    | <===============================================> |  nonlocal-bridge              |
|  Native SwiftUI App   |        or Trusted LAN WS (plaintext)              |  (127.0.0.1:8765 by default)  |
+-----------------------+                                                   +---------------+---------------+
                                                                                            | stdio ACP (NDJSON)
                                                                                            v
                                                                            +-------------------------------+
                                                                            |  Google Antigravity (agy acp) |
                                                                            |  or any generic stdio ACP CLI |
                                                                            +-------------------------------+
```

## Key Features

- **Built for Google Antigravity (`agy acp`), open to standard ACP**: Full Antigravity support (usage quota card, session details & subagent tree, safe cascade session deletion) plus a `generic-acp` adapter that gracefully degrades agent-specific extensions.
- **Low-memory per-cwd process pool**: Lazy-spawned worker processes per workspace directory with automatic idle reclamation, transparent wake-up, and session state recovery across bridge restarts.
- **Resilient mobile sync**: Incremental turn buffering (`nonlocal/sync`), disconnect recovery without losing streaming turns, and single-client preemption (`4001`) so multiple tabs/devices never fight in reconnect loops.
- **Remote workspace inspection**: Fast remote directory browsing (`nonlocal/fs_list`) and safe text/image file preview (`nonlocal/fs_read_file`, up to 512 KiB UTF-8 text / 10 MiB images).
- **Cross-platform CLI & user daemons**: One `nonlocal-bridge` CLI (`init`, `start`, `stop`, `restart`, `status`, `logs`, `token`, `doctor --json`, `service`, `template`) supporting macOS `launchd` and Linux Ubuntu `systemd --user`.
- **Secure by default**: Binds `127.0.0.1` only by default, stores Bearer tokens in isolated `0600` files outside `config.json`, restricts `/health` to pure loopback, and rate-limits failed handshakes.

## Quick Start

### Option 1: Let Your AI Agent Install It (Recommended)

Copy and paste this prompt into Antigravity, Claude Code, Codex, or Cursor:

```text
Please read docs/agent-install.md in this repository and follow its decision tree and safety rules to install, configure, and verify nonlocal-bridge on my machine. Ask me before choosing the adapter or network mode, never reveal or read my Bearer token file, and confirm completion with `nonlocal-bridge doctor --json`.
```

See the full machine-readable guide in [`docs/agent-install.md`](docs/agent-install.md).

### Option 2: Manual Setup (4 Commands)

**Prerequisites**: Node.js `>= 22.13.0` (Node 24 LTS recommended) and an authenticated `agy` CLI (or another standard stdio ACP CLI).

```bash
npm install -g nonlocal-bridge
nonlocal-bridge init
nonlocal-bridge service install
nonlocal-bridge doctor --json
```

> Developing locally or building from source? See the [Quickstart Guide](docs/quickstart.md#install-from-source) (`cd packages/bridge && npm install && npm run build`).

**iOS Client**: Open the Xcode project under [`ios/`](ios/) to build and install the app onto your iPhone (App Store distribution is not live yet).

## Remote & Local Network Access

`nonlocal-bridge` listens on `127.0.0.1:8765` by default and intentionally does not embed TLS certificates. Pick the access method that fits your setup — you can render ready-to-use templates anytime with `nonlocal-bridge template <name>`:

| Method | Encrypted (`wss://`) | Needs VPS / Domain | Template Command | Guide |
|---|---|---|---|---|
| **Tailscale Serve (Recommended)** | Yes (WireGuard + auto HTTPS) | No | `nonlocal-bridge template tailscale` | [`docs/networking/tailscale.md`](docs/networking/tailscale.md) |
| **Cloudflare Tunnel** | Yes (Cloudflare TLS) | Domain only | `nonlocal-bridge template cloudflare` | [`docs/networking/cloudflare.md`](docs/networking/cloudflare.md) |
| **Self-Hosted VPS (Caddy / Nginx + SSH)** | Yes (Let's Encrypt) | Yes | `nonlocal-bridge template vps-caddy` / `vps-nginx` / `vps-ssh-tunnel` | [`docs/networking/vps.md`](docs/networking/vps.md) |
| **Direct LAN (Trusted Wi-Fi Only)** | **No (plaintext `ws://`)** | No | `nonlocal-bridge template lan` | [`docs/networking/lan.md`](docs/networking/lan.md) |

Compare all four options in [`docs/networking/README.md`](docs/networking/README.md).

## Honest Scope & Security Boundaries

- **Encryption boundary**: External remote access relies on transport-layer encryption (`wss://`) via Tailscale, Cloudflare Tunnel, or a TLS reverse proxy. Direct LAN mode uses **plaintext `ws://`** with **no application-layer end-to-end encryption (E2EE)** — use it only on trusted home/private networks. See [`docs/security.md`](docs/security.md).
- **Agent scope**: Primarily tailored for **Google Antigravity (`agy acp`)**. Any standard stdio ACP agent can connect via `--adapter generic-acp`, with Antigravity-specific endpoints (`/usage`, session info, cascade delete) cleanly returning `-32601`.
- **Platform verification status**: **macOS** (`launchd`) is verified end-to-end with a physical iPhone. **Linux Ubuntu** (`systemd --user`) is fully implemented and unit-tested offline, pending real-host verification — community feedback is welcome.
- **iOS installation**: Currently installed by building [`ios/`](ios/) with Xcode.

## Documentation & Repository Layout

```text
nonlocal/
├── packages/bridge/   # TypeScript nonlocal-bridge CLI, gateway, adapters, and templates
├── ios/               # Native SwiftUI iOS client (Xcode project & Swift packages)
└── docs/              # Guides, networking tutorials, security model, and AI agent installer
```

- [Quickstart (macOS & Ubuntu)](docs/quickstart.md)
- [AI Agent Install Guide](docs/agent-install.md)
- [Networking Overview](docs/networking/README.md) ([Tailscale](docs/networking/tailscale.md) · [Cloudflare](docs/networking/cloudflare.md) · [VPS](docs/networking/vps.md) · [Direct LAN](docs/networking/lan.md))
- [Security Model & Encryption Boundaries](docs/security.md)
- [`nonlocal-bridge` Package & CLI Reference](packages/bridge/README.md)

## License & Attribution

Nonlocal is released under the [MIT License](LICENSE).

The iOS client incorporates and evolves [`Agmente`](https://github.com/rebornix/Agmente) (`Copyright (c) 2026 rebornix`), licensed under the MIT License. See [`LICENSE`](LICENSE) and [`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md) for full copyright notices and third-party dependency details.
