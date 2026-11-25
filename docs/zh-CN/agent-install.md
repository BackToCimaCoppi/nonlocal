# AI Agent 标准安装说明书（`nonlocal-bridge`）

[English](../agent-install.md) | **简体中文**

> **适用对象**：帮助用户在电脑上安装、配置并验证 `nonlocal-bridge` 的 AI 编程 Agent（Antigravity、Claude Code、Codex、Cursor 等）。
> **唯一完成判据**：`nonlocal-bridge doctor --json` 返回退出码 `0` 且输出 `"ok": true`。

---

## 1. 绝对安全红线（严禁违反）

1. **严禁读取或回显密钥明文**：
   - 严禁执行 `nonlocal-bridge token show --reveal`。
   - 严禁 `cat`、读取或向对话输出 `~/.config/nonlocal/bearer.token`、`title-summary.key` 或任何私钥文件内容。
   - 正确做法：运行 `nonlocal-bridge token path`，然后告知用户自行在终端执行 `nonlocal-bridge token show --reveal` 复制到手机。
2. **严禁静默放开非回环监听**：
   - 默认保持 `server.host` 为 `127.0.0.1`；只有用户**明确选择局域网直连**并确认知晓局域网 `ws://` 为明文（无 E2EE）后，才能传入 `--allow-non-loopback`。
3. **严禁越权修改外部或系统级配置**：
   - 严禁修改 `~/.gemini/antigravity-cli/settings.json`。
   - 严禁自动执行 `loginctl enable-linger`；若 Ubuntu 下 `service install` 或 `doctor` 提示未开 linger，只把命令原样展示给用户手动执行。
   - 未经用户明确许可，严禁修改用户的 Tailscale、Cloudflare、Nginx 或 Caddy 配置；只允许通过 `nonlocal-bridge template <模板名>` 只读输出样板。
4. **严禁未经询问覆盖已有配置**：
   - 若 `init` 提示配置、Token 或数据库已存在，必须停下来询问用户，严禁擅自加 `--force`。

---

## 2. 步骤 0：只读环境探测

先执行只读命令摸清环境：

```bash
uname -s
node -v
which nonlocal-bridge || true
which agy || true
```

判定：
- **Node.js**：必须 `>= 22.13.0`（推荐 Node 24 LTS）。缺失或版本过低时，停下引导用户升级后再继续。
- **系统**：`Darwin`（macOS `launchd`）或 `Linux`（Ubuntu `systemd --user`；如实告知用户 Ubuntu 已完成实现与离线单测，待真机复验）。

---

## 3. 步骤 1：先向用户确认 2 个选择（不可替用户瞎猜）

初始化前，简明询问用户：

1. **接入哪个编码 Agent？**
   - `antigravity`（默认，Google Antigravity `agy acp`）
   - `generic-acp`（其他标准 stdio ACP CLI——向用户确认可执行命令与可选 JSON 参数数组）
2. **手机打算怎么连电脑？**
   - **Tailscale Serve（外网首选）**：桥接保持 `127.0.0.1`
   - **Cloudflare Tunnel**：桥接保持 `127.0.0.1`
   - **自建 VPS（Caddy / Nginx + SSH 隧道）**：桥接保持 `127.0.0.1`
   - **局域网直连（仅限可信家庭 Wi-Fi，明文 `ws://` 无 E2EE）**：需明确局域网 IPv4 字面量并显式开启 `--allow-non-loopback`

---

## 4. 步骤 2：安装与非交互初始化

### 4.1 安装 `nonlocal-bridge`

- 优先全局安装：
  ```bash
  npm install -g nonlocal-bridge
  ```
- 若当前已在克隆仓库内且未全局安装：
  ```bash
  cd packages/bridge && npm install && npm run build && npm link
  ```
- **禁止**使用 `npx nonlocal-bridge service install`，也**禁止**加 `--allow-ephemeral-path` 绕过临时路径拦截。

### 4.2 非交互初始化

按用户在步骤 1 的选择执行 `init --yes`（未经用户同意覆盖，严禁加 `--force`）：

- **本机回环（Tailscale / Cloudflare / VPS）+ Antigravity**：
  ```bash
  nonlocal-bridge init --yes
  ```
- **本机回环 + 通用 ACP**：
  ```bash
  nonlocal-bridge init --yes \
    --adapter generic-acp \
    --adapter-command "<USER_CMD>" \
    --adapter-args '<JSON_STRING_ARRAY>'
  ```
- **局域网直连（仅限用户明确确认后，填具体私网 IPv4 字面量，禁止填 `"localhost"` 或主机名）**：
  ```bash
  nonlocal-bridge init --yes \
    --host "<USER_LAN_IPV4>" \
    --allow-non-loopback
  ```

---

## 5. 步骤 3：启动或安装开机守护（OS 分支）

按用户是否需要开机自启执行：

- **安装用户级后台守护（推荐）**：
  ```bash
  nonlocal-bridge service install
  ```
  - **macOS**：自动安装并校验 `~/Library/LaunchAgents/com.nonlocal.bridge.plist`。
  - **Linux Ubuntu**：自动安装 `~/.config/systemd/user/nonlocal-bridge.service`。若输出未开启 linger 的警告，把下面命令转告用户手动执行：
    ```bash
    loginctl enable-linger "$USER"
    ```
- **临时独立启动**：
  ```bash
  nonlocal-bridge start --standalone
  ```

---

## 6. 步骤 4：只读输出网络接入样板

根据用户在步骤 1 选的网络方案，运行对应模板命令并给出教程链接：

| 用户选择 | 只读模板命令 | 对应中文教程 |
|---|---|---|
| Tailscale | `nonlocal-bridge template tailscale` | `docs/zh-CN/networking/tailscale.md` |
| Cloudflare Tunnel | `nonlocal-bridge template cloudflare` | `docs/zh-CN/networking/cloudflare.md` |
| 自建 VPS | `nonlocal-bridge template vps-ssh-tunnel` 以及 `vps-caddy` 或 `vps-nginx` | `docs/zh-CN/networking/vps.md` |
| 局域网直连 | `nonlocal-bridge template lan` | `docs/zh-CN/networking/lan.md` |

---

## 7. 步骤 5：端到端验收与交接

运行 8 项体检与 Token 路径检查：

```bash
nonlocal-bridge doctor --json
nonlocal-bridge token path
```

- **验收通过**：`doctor --json` 退出码 `0` 且 `"ok": true`。向用户汇报：
  1. 当前监听地址与运行模式（`launchd` / `systemd` / `standalone`）。
  2. Token 文件路径，并告知用户自行运行以下命令查看明文 Token：
     ```bash
     nonlocal-bridge token show --reveal
     ```
  3. 对应网络方案的下一步配置指引，以及用 Xcode 编译安装 `ios/` 客户端的提示。

### `doctor --json` 失败定位速查表

| 失败的 `check.id` | 处理方式 |
|---|---|
| `node_runtime` | 引导用户升级 Node.js 至 `>= 22.13.0`（推荐 24 LTS） |
| `config_security` | 查看 `summary` / `fixHint`（例如 `server.host` 必须是 IP 字面量、禁止未知键、禁止明文密钥进 `config.json`） |
| `bearer_token` | 修正权限（`chmod 600`）或移出 `.git` 仓库（严禁读取文件内容） |
| `adapter_cli` | 确认 `agy`（或自定义 CLI）在 `PATH` 中且已完成登录 |
| `port_binding` | 端口处于 `occupied_by_other`：询问用户是停掉占口进程还是改用其他端口（`--port`） |
| `bridge_live_handshake` | 运行 `nonlocal-bridge status --json` 与 `nonlocal-bridge logs -n 50` 定位启动失败原因 |
