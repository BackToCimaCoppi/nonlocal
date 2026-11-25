# `nonlocal-bridge`

[English](README.md) | **简体中文**

[Nonlocal（超距）](../../README.zh-CN.md) 的跨平台 TypeScript ACP ↔ WebSocket 桥接程序。

- **运行环境**：Node.js `>= 22.13.0`（推荐 Node 24 LTS，直接使用原生 `node:sqlite`、`node:http`、`node:crypto` 与 `fetch`）。
- **极简依赖**：`dependencies` 仅包含 `ws` 与 `commander`（0 传递依赖）。
- **平台状态**：macOS（`launchd`）已完成真机端到端验收；Linux Ubuntu（`systemd --user`）已完成实现与离线单测（待真机复验）。

---

## 安装方式

### 全局安装（推荐）

```bash
npm install -g nonlocal-bridge
```

> 请勿在 `npx` 临时缓存路径（`/_npx/`）下执行 `service install`。`nonlocal-bridge service install` 会主动拦截临时缓存路径，避免缓存清理后开机自启失效。

### 从源码构建

```bash
cd packages/bridge
npm install
npm run build
# 可选：全局链接 nonlocal-bridge 命令到 PATH
npm link
```

---

## CLI 命令参考

| 命令 | 说明 | 常用参数 | 退出码 |
|---|---|---|---|
| `nonlocal-bridge init` | 交互向导（或 `--yes` 非交互）生成 `config.json` 与 `0600` Bearer Token | `-y, --yes`, `--force`, `--host <ip>`, `--port <port>`, `--allow-non-loopback`, `--adapter <antigravity\|generic-acp>`, `--adapter-command <cmd>`, `--adapter-args <json>`, `--default-model <id>`, `--default-thought-level <level>`, `--title-language <auto\|zh\|en>`, `--config <path>`, `--state-dir <path>`, `--token-file <path>`, `--log-file <path>` | `0` 成功，`1` 冲突或校验失败 |
| `nonlocal-bridge start` | 启动桥接（默认配置下优先托管给已安装守护，也可独立后台/前台启动） | `--foreground`, `--standalone` 及配置覆盖参数 | `0` 就绪或已运行，`1` 失败或端口被外进程占用 |
| `nonlocal-bridge stop` | 停止运行中的桥接（核验 `bridge.runtime.json` 的 PID 与命令行指纹防误杀） | `--standalone`, `--config <path>` | `0` 已停止，`1` 异常 |
| `nonlocal-bridge restart` | 重启桥接并等待本机回环 `/health` 就绪 | `--standalone`, `--config <path>` | `0` 就绪，`1` 失败 |
| `nonlocal-bridge status` | 查看进程归属、`/health`、安全警告与守护服务状态 | `--json`, `--config <path>` | `0` 运行且健康，`1` 未运行或异常 |
| `nonlocal-bridge logs` | 查看桥接 JSONL 日志（`bridge.log`）或守护输出（`service.log`） | `-n <行数>`, `-f, --follow`, `--service` | `0` 成功，`1` 日志缺失 |
| `nonlocal-bridge token path` | 显示 Token 路径、权限与长度（绝不输出明文） | `--config <path>` | `0` 成功，`1` 失败 |
| `nonlocal-bridge token rotate` | 原子生成 64 位十六进制 `0600` 新 Token（并提示重启） | `--config <path>` | `0` 成功，`1` 失败 |
| `nonlocal-bridge token show --reveal` | 显式输出明文 Bearer Token（必须传 `--reveal`，缺省直接报错） | `--reveal`, `--config <path>` | 传 `--reveal` 返 `0`，否则返 `1` |
| `nonlocal-bridge doctor` | 执行全部 8 项体检，包含对运行中桥接的真实 WebSocket 握手 | `--json`, `--config <path>` | 无 `fail` 返 `0`，任一 `fail` 返 `1` |
| `nonlocal-bridge service install\|uninstall\|status` | 管理用户级开机守护（macOS `com.nonlocal.bridge` / Ubuntu `nonlocal-bridge.service`） | `--target <launchd\|systemd>`, `--dry-run`, `--plist-path <path>`, `--unit-path <path>`, `--allow-ephemeral-path` | `0` 成功，`1` 失败 |
| `nonlocal-bridge template [name]` | 只读渲染当前配置端口对齐的外网/局域网模板 | `list`, `tailscale`, `cloudflare`, `vps-caddy`, `vps-nginx`, `vps-ssh-tunnel`, `lan` | `0` 成功，`1` 未知模板 |

### `doctor --json` 8 项固定检查

`nonlocal-bridge doctor --json` 输出 `{ ok, timestamp, bridgeVersion, summary: { pass, warn, fail }, checks: [...] }`，固定包含 8 个检查项：

1. `platform`：macOS / Linux 平台检测与 Ubuntu `loginctl` linger 只读提示。
2. `node_runtime`：校验 Node `>= 22.13.0` 与原生 `node:sqlite`。
3. `config_security`：Schema v1 严格白名单校验、IP 字面量校验、非回环明文警告与零明文密钥检查。
4. `bearer_token`：Token 存在、`trim()` 后 `>= 32` 字节、`0600` 权限且不在任何 `.git` 仓库内。
5. `adapter_cli`：适配器可执行文件检查（`agy` 或 `generic-acp` 自定义命令）。
6. `antigravity_settings`：Antigravity CLI 配置只读检查（`generic-acp` 下标记不适用）。
7. `port_binding`：零 `lsof` 的端口三态归属判定（`owned_running` / `free` / `occupied_by_other`）。
8. `bridge_live_handshake`：本机回环真实 WebSocket `initialize` 握手探测（未启动判 `fail`；端口被外进程占用时短路跳过）。

---

## 配置文件（`config.json` v1）与环境变量

默认采用 XDG 双目录（目录权限 `0700`，密钥/数据库/日志/运行态文件权限 `0600`）：

- 配置：`${XDG_CONFIG_HOME:-~/.config}/nonlocal/config.json`
- Token：`${XDG_CONFIG_HOME:-~/.config}/nonlocal/bearer.token`
- 状态与日志：`${XDG_STATE_HOME:-~/.local/state}/nonlocal/`（`bridge-state.db`、`bridge.runtime.json`、`bridge.log`、`service.log`）

优先级：**CLI 参数 > 白名单 `NONLOCAL_*` 环境变量 > `config.json` > 默认值**。

### 严格白名单默认配置

`config.json` 实行**严格白名单校验**——任何未知字段或明文密钥字段（`token`、`bearerToken`、`apiKey`、`key`、`secret`、`password`）都会在启动时直接报错拒绝：

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

### 13 个白名单 `NONLOCAL_*` 环境变量

`NONLOCAL_CONFIG`、`NONLOCAL_HOST`、`NONLOCAL_PORT`、`NONLOCAL_ALLOW_NON_LOOPBACK`、`NONLOCAL_TOKEN_FILE`、`NONLOCAL_STATE_DIR`、`NONLOCAL_LOG_FILE`、`NONLOCAL_ADAPTER_TYPE`、`NONLOCAL_ADAPTER_COMMAND`、`NONLOCAL_ADAPTER_ARGS`（JSON 字符串数组）、`NONLOCAL_DEFAULT_MODEL`、`NONLOCAL_DEFAULT_THOUGHT_LEVEL`、`NONLOCAL_TITLE_SUMMARY_API_KEY`（仅注入内存，绝不回写 `config.json`）。

---

## 三层架构与扩展

```text
src/cli/        ─▶ config / service / templates / gateway
src/gateway/    ─▶ transport/types + adapter/types + store + sync + fs + log
src/adapter/    ─▶ antigravity-adapter ─▶ base-acp-adapter ─▶ types
```

- **网关层（`src/gateway/`）**：协议路由、单连接 `4001` 抢占、自有会话白名单、标题净化与 `BridgeTransport` SPI，零特定 Agent 耦合。
- **适配器接口层（`src/adapter/types.ts`）**：`AgentAdapter` 与 `AdapterCapabilities`（`usage` / `sessionInfo` / `deleteSession` / `diskPresence`），不支持的可选能力自动返回 `-32601`。
- **适配器实现层（`src/adapter/base-acp-adapter.ts`、`antigravity-adapter.ts`）**：`BaseAcpAdapter` 直接支撑 `generic-acp`（按目录进程池、NDJSON 分帧、透明唤醒与可选默认模型锁定）；`AntigravityAdapter` 仅承载 Antigravity 专属的 `/usage`、只读摘要库与多库级联真删。

---

## 开发与测试

```bash
cd packages/bridge
npm run typecheck
npm run build
npm test
```

## 相关文档

- [快速开始（macOS 与 Ubuntu）](../../docs/zh-CN/quickstart.md)
- [网络接入指南](../../docs/zh-CN/networking/README.md)
- [安全模型与加密边界](../../docs/zh-CN/security.md)
- [AI Agent 标准安装说明书](../../docs/zh-CN/agent-install.md)
