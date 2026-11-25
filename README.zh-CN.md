<p align="center">
  <img src="docs/brand/nonlocal-logo-primary.png" alt="Nonlocal" width="200" />
</p>

<h1 align="center">Nonlocal（超距）</h1>

<p align="center">
  <strong>Local coding agents, nonlocal control.</strong><br />
  引擎留在本地电脑，用手机随时安全远控你的 AI 编程 Agent。
</p>

<p align="center">
  <a href="README.md">English</a> | <strong>简体中文</strong>
</p>

---

**Nonlocal（超距）** 是一套开源的移动端 AI 编程远控套件。你的编码 Agent 始终跑在自己的电脑上（`localhost`），你在 iPhone 上就能随时发起会话、查看代码和图片预览、审批工具调用以及监控模型额度。

- **`packages/bridge/`（`nonlocal-bridge`）**：跨平台 TypeScript ACP ↔ WebSocket 桥接程序（Node.js `>= 22.13.0`，生产依赖仅 `ws` 与 `commander` 两个零传递依赖库，其余全走 Node 原生模块）。
- **`ios/`**：原生 SwiftUI iOS 客户端（基于 MIT 协议从 [`rebornix/Agmente`](https://github.com/rebornix/Agmente) 演进重构）。

## 系统架构

```text
+-----------------------+        WSS（Tailscale / Cloudflare / 自建 VPS）    +-------------------------------+
|  iPhone（Nonlocal）    | <===============================================> |  nonlocal-bridge              |
|  原生 SwiftUI 客户端   |        或可信局域网明文 WS                        |  （默认仅监听 127.0.0.1:8765） |
+-----------------------+                                                   +---------------+---------------+
                                                                                            | stdio ACP (NDJSON)
                                                                                            v
                                                                            +-------------------------------+
                                                                            |  Google Antigravity (agy acp) |
                                                                            |  或任意标准 stdio ACP CLI     |
                                                                            +-------------------------------+
```

## 核心特性

- **主攻 Google Antigravity（`agy acp`），开放兼容标准 ACP**：完整支持 Antigravity 专属能力（额度卡片、会话详情与子代理树、多库安全级联真删），同时内置 `generic-acp` 适配器，接入其他标准 stdio ACP 助手时专属能力自动优雅降级。
- **低内存按目录进程池**：按工作区目录懒派生子进程，支持空闲自动回收、透明唤醒与桥接重启后的会话配置恢复。
- **稳健的移动端断线同步**：内置增量轮次缓冲（`nonlocal/sync`）、切后台/断网恢复不丢流，以及单连接 `4001` 抢占机制，杜绝多端互踢重连死循环。
- **远程工作区只读浏览**：支持快速浏览目录（`nonlocal/fs_list`）与安全预览文本/图片（`nonlocal/fs_read_file`，支持 512 KiB UTF-8 文本与 10 MiB 图片）。
- **跨平台 CLI 与用户级守护**：统一的 `nonlocal-bridge` 命令（`init`、`start`、`stop`、`restart`、`status`、`logs`、`token`、`doctor --json`、`service`、`template`），自动适配 macOS `launchd` 与 Linux Ubuntu `systemd --user`。
- **默认安全隔离**：默认仅绑定 `127.0.0.1`，Bearer Token 独立存放于 `0600` 文件绝不写入 `config.json`，`/health` 仅限纯本机回环访问，内置防暴力破解限流。

## 快速上手

### 方式一：让你的 AI Agent 自动安装（推荐）

直接复制下面这句话发给你的 Antigravity、Claude Code、Codex 或 Cursor：

```text
请阅读本仓库的 docs/zh-CN/agent-install.md，严格按照其中的决策树和安全红线帮我安装、配置并验收 nonlocal-bridge。在决定适配器和网络模式前必须先问我，严禁读取或输出我的 Bearer Token 文件，最后以 `nonlocal-bridge doctor --json` 退出码为 0 作为完成标准。
```

完整的 AI 机读安装说明书见 [`docs/zh-CN/agent-install.md`](docs/zh-CN/agent-install.md)。

### 方式二：手动安装（4 条命令）

**前置要求**：Node.js `>= 22.13.0`（推荐 Node 24 LTS）以及已登录的 `agy` CLI（或任意标准 stdio ACP CLI）。

```bash
npm install -g nonlocal-bridge
nonlocal-bridge init
nonlocal-bridge service install
nonlocal-bridge doctor --json
```

> 需要从源码编译或参与开发？见 [快速开始 · 源码构建](docs/zh-CN/quickstart.md#从源码构建)（`cd packages/bridge && npm install && npm run build`）。

**iOS 客户端**：目前请使用 Xcode 打开 [`ios/`](ios/) 工程自行编译安装到 iPhone（暂未上架 App Store）。

## 外网与局域网接入

`nonlocal-bridge` 默认只监听 `127.0.0.1:8765` 且不内置 TLS 证书。请按你的网络条件任选一种方案，随时可用只读命令 `nonlocal-bridge template <模板名>` 输出端口对齐的配置样板：

| 方案 | 是否加密（`wss://`） | 需要 VPS / 域名 | 模板命令 | 详细教程 |
|---|---|---|---|---|
| **Tailscale Serve（外网首选）** | 是（WireGuard + 自动 HTTPS） | 不需要 | `nonlocal-bridge template tailscale` | [`docs/zh-CN/networking/tailscale.md`](docs/zh-CN/networking/tailscale.md) |
| **Cloudflare Tunnel** | 是（Cloudflare TLS） | 仅需域名 | `nonlocal-bridge template cloudflare` | [`docs/zh-CN/networking/cloudflare.md`](docs/zh-CN/networking/cloudflare.md) |
| **自建 VPS（Caddy / Nginx + SSH）** | 是（Let's Encrypt） | 需要 | `nonlocal-bridge template vps-caddy` / `vps-nginx` / `vps-ssh-tunnel` | [`docs/zh-CN/networking/vps.md`](docs/zh-CN/networking/vps.md) |
| **局域网直连（仅限可信内网）** | **否（明文 `ws://`）** | 不需要 | `nonlocal-bridge template lan` | [`docs/zh-CN/networking/lan.md`](docs/zh-CN/networking/lan.md) |

完整选型对比见 [`docs/zh-CN/networking/README.md`](docs/zh-CN/networking/README.md)。

## 安全与现阶段能力边界说明

- **加密边界**：外网连接统一依赖传输层加密（`wss://`，通过 Tailscale、Cloudflare Tunnel 或自建反代提供）。局域网直连走 **明文 `ws://`**，**不做应用层端到端加密（E2EE）**，仅限家庭等可信内网使用。详见 [`docs/zh-CN/security.md`](docs/zh-CN/security.md)。
- **Agent 支持范围**：主力适配 **Google Antigravity（`agy acp`）**；其他标准 stdio ACP 助手可通过 `--adapter generic-acp` 接入（用量查询、会话详情、级联真删等专属接口会规范返回 `-32601` 优雅降级）。
- **系统验证状态**：**macOS**（`launchd`）已完成物理 iPhone 真机端到端验收；**Linux Ubuntu**（`systemd --user`）已完成全部代码实现与离线单元测试，待真实 Ubuntu 宿主机复验，欢迎社区反馈。
- **iOS 装机方式**：现阶段通过 Xcode 打开 [`ios/`](ios/) 自行编译安装。

## 文档导航与仓库结构

```text
nonlocal/
├── packages/bridge/   # TypeScript 跨平台 nonlocal-bridge CLI、网关、适配器与网络模板
├── ios/               # 原生 SwiftUI iOS 客户端（Xcode 工程与 Swift 包）
└── docs/              # 安装教程、四类网络教程、安全说明与 AI Agent 安装说明书
```

- [快速开始（macOS 与 Ubuntu）](docs/zh-CN/quickstart.md)
- [AI Agent 标准安装说明书](docs/zh-CN/agent-install.md)
- [网络接入选型总览](docs/zh-CN/networking/README.md)（[Tailscale](docs/zh-CN/networking/tailscale.md) · [Cloudflare](docs/zh-CN/networking/cloudflare.md) · [自建 VPS](docs/zh-CN/networking/vps.md) · [局域网直连](docs/zh-CN/networking/lan.md)）
- [安全模型与加密边界](docs/zh-CN/security.md)
- [`nonlocal-bridge` 包主页与 CLI 参考](packages/bridge/README.zh-CN.md)

## 开源协议与版权归属

Nonlocal 采用 [MIT License](LICENSE) 开源。

iOS 客户端基于 MIT 协议演进自 [`Agmente`](https://github.com/rebornix/Agmente)（`Copyright (c) 2026 rebornix`）。完整版权声明与第三方依赖清单见 [`LICENSE`](LICENSE) 与 [`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md)。
