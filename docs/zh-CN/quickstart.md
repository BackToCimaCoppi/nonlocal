# 快速开始（macOS 与 Linux Ubuntu）

[English](../quickstart.md) | **简体中文**

本指南带你完成 `nonlocal-bridge` 的安装、用户级开机守护配置以及端到端自检。

---

## 1. 前置要求

- **Node.js `>= 22.13.0`**（推荐 Node 24 LTS）。`nonlocal-bridge` 直接使用 Node 原生 `node:sqlite`，无需编译 C++ 扩展。
- **编码 Agent CLI**：
  - 默认（`antigravity`）：已安装并登录 Google Antigravity CLI（`agy`），且在 `PATH` 中可执行。
  - 通用（`generic-acp`）：任意标准 stdio ACP 命令行工具。
- **操作系统**：
  - **macOS**：已完成物理 iPhone 真机端到端验收（`launchd` 用户级守护）。
  - **Linux Ubuntu**：已完成全部代码实现与离线单元测试（`systemd --user`），待真实宿主机复验。

---

## 2. 安装 `nonlocal-bridge`

### 通过 npm 全局安装（推荐）

```bash
npm install -g nonlocal-bridge
nonlocal-bridge --version
```

> 请勿通过 `npx` 临时缓存路径（`/_npx/`）执行 `nonlocal-bridge service install`。安装器会主动拦截临时路径，防止缓存被清理后后台守护启动失败。

### 从源码构建

如果你克隆了仓库或需要参与开发：

```bash
git clone https://github.com/BackToCimaCoppi/nonlocal.git
cd nonlocal/packages/bridge
npm install
npm run build
# 可选：将 nonlocal-bridge 链接到全局 PATH
npm link
```

---

## 3. 初始化配置与 Bearer Token

运行交互式向导：

```bash
nonlocal-bridge init
```

或非交互初始化：

```bash
# 默认：Antigravity (agy acp)，监听 127.0.0.1:8765
nonlocal-bridge init --yes

# 通用标准 stdio ACP 助手示例
nonlocal-bridge init --yes \
  --adapter generic-acp \
  --adapter-command my-acp-cli \
  --adapter-args '["serve"]'
```

`init` 会创建符合 XDG 规范的目录（`0700`）与密钥文件（`0600`）：

- `~/.config/nonlocal/config.json`：主配置文件（绝不保存明文密钥）。
- `~/.config/nonlocal/bearer.token`：64 位十六进制 Bearer Token（`0600`）。
- `~/.local/state/nonlocal/`：`bridge-state.db`、`bridge.runtime.json`、`bridge.log`、`service.log`。

后续查看或轮换 Token：

```bash
nonlocal-bridge token path
nonlocal-bridge token show --reveal   # 显式输出明文 Token 供粘贴到 iPhone
nonlocal-bridge token rotate          # 生成新 Token（轮换后记得重启桥接）
```

---

## 4. 启动与开启开机守护

### 安装用户级后台守护（推荐）

```bash
nonlocal-bridge service install
nonlocal-bridge service status
```

- **macOS（`launchd`）**：生成并用 `plutil -lint` 校验 `~/Library/LaunchAgents/com.nonlocal.bridge.plist`（自动保活、`Umask=0077`、`bridge.log` 与 `service.log` 分离）。
- **Linux Ubuntu（`systemd --user`）**：生成 `~/.config/systemd/user/nonlocal-bridge.service`（`UMask=0077`、`Restart=always`、`KillMode=control-group`）。
  - **Ubuntu 特别提醒**：默认情况下断开 SSH 登录会话后用户级 systemd 服务会被停止。`service install` 和 `doctor` 会只读检查 linger 状态，未开启时给出复制即用的开启命令：
    ```bash
    loginctl enable-linger "$USER"
    ```

卸载守护：

```bash
nonlocal-bridge service uninstall
```

### 手动 / 独立模式管理

不想装开机守护时可直接手动启停：

```bash
nonlocal-bridge start                # 后台独立运行
nonlocal-bridge start --foreground   # 前台运行（打印 LISTENING host=... port=... pid=...）
nonlocal-bridge status --json        # 查看运行态、/health 与守护状态
nonlocal-bridge logs -n 50           # 查看桥接 JSONL 日志（加 --service 看守护输出）
nonlocal-bridge restart
nonlocal-bridge stop
```

---

## 5. 用 `doctor --json` 验收

安装或修改配置后，务必运行一次体检：

```bash
nonlocal-bridge doctor --json
```

退出码为 `0`（`"ok": true`）代表全部 8 项检查通过，包括对运行中桥接的真实 WebSocket `initialize` 握手。

### 常见故障排错

| 报错项 / 现象 | 常见原因 | 解决方法 |
|---|---|---|
| `port_binding: fail`（`occupied_by_other`） | `8765` 端口被其他进程占用 | 换一个空闲端口（`nonlocal-bridge init --yes --port 8766 --force` 或改 `server.port`），或先停掉占口进程 |
| `bridge_live_handshake: fail`（端口 `free`） | 桥接尚未启动 | 运行 `nonlocal-bridge start` 或 `nonlocal-bridge service install` |
| `config_security: fail`（`host`） | `server.host` 误填了 `"localhost"` 或主机名 | 改为明确 IP 字面量（如 `"127.0.0.1"` 或 `"::1"`） |
| `bearer_token: fail` | 文件权限过宽，或放在了 `.git` 仓库内 | 移至 `~/.config/nonlocal/` 并执行 `chmod 600` |
| `adapter_cli: fail` | `agy` 不在 `PATH` 中或未登录 | 安装并登录 Antigravity CLI，确认 `which agy` 可见 |
| Ubuntu `service install` 报 D-Bus 错 | 非登录 Shell 缺少 `XDG_RUNTIME_DIR` 或用户总线 | 在正常登录会话中确认 `systemd --user` 活跃并开启 linger |

---

## 6. 连接你的 iPhone

1. 用 Xcode 打开 [`ios/`](../../ios/) 工程，编译并安装到你的 iPhone。
2. 前往 [网络接入选型总览](networking/README.md) 选择外网或局域网连接方式（外网首选 Tailscale Serve）。
3. 在 Nonlocal iOS 客户端里填入 WebSocket 地址（例如 `wss://<your-machine>.<tailnet>.ts.net/acp`）以及通过 `nonlocal-bridge token show --reveal` 获取的 Bearer Token。
