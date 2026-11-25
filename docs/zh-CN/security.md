# 安全模型与加密边界

[English](../security.md) | **简体中文**

`nonlocal-bridge` 拥有读取宿主机工作区文件和驱动本地编码 Agent 的能力，因此默认采用 fail-closed 防护，并如实写清哪些流量加密、哪些不加密。

---

## 1. 默认回环监听与非回环双保险

- **默认监听**：`127.0.0.1:8765`（`server.allowNonLoopback = false`）。
- **只接受 IP 字面量**：`server.host` 只允许合法的 IPv4 / IPv6 字面量。填 `"localhost"` 或其他主机名会在配置校验、启动和 `doctor` 阶段直接报错拒绝。
- **非回环双保险**：绑定任何非回环地址（私网单播、`0.0.0.0`、`::` 或公网 IP）必须**同时**设置 `server.host` 且显式开启 `server.allowNonLoopback = true`（`--allow-non-loopback` / `NONLOCAL_ALLOW_NON_LOOPBACK=1`），否则拒绝启动（退出码 `1`，零端口监听）。
- **两级明文警告**：
  - 私网单播 IP（`lan_plaintext`）：提示局域网 `ws://` 为明文，仅限可信私网。
  - 通配地址（`0.0.0.0`、`::`）或公网 IP（`public_or_wildcard_plaintext`）：升级警告，建议改回 `127.0.0.1` 并改用 Tailscale / Cloudflare / 反代 `wss://`。
  - 警告在 `init`、启动日志（`non_loopback_listening`）、`status --json` 与 `doctor --json` 全路径一致输出。
- **单播伴随回环监听**：绑定具体非回环单播 IP 时，桥接会在同端口自动伴随监听本机回环（IPv4 伴随 `127.0.0.1`，IPv6 伴随 `::1`），确保本机 `status` / `doctor` 继续安全走回环通信。

---

## 2. 鉴权与密钥物理隔离

- **仅接受请求头 Bearer Token**：WebSocket 升级只认 `Authorization: Bearer <token>`，携带 `?token=` 或 `?access_token=` 一律返 `401 Unauthorized`。
- **常量时间比对**：使用进程启动随机 32 字节 Key 做 HMAC-SHA256 + `crypto.timingSafeEqual` 校验。
- **独立 `0600` 密钥文件**：
  - Bearer Token（`trim()` 后 `>= 32` 字节）单独存放在 `~/.config/nonlocal/bearer.token`（`0600`），绝不写入 `config.json`。
  - 可选的 `titleSummary` API Key 同样走独立 `0600` 文件或内存环境变量 `NONLOCAL_TITLE_SUMMARY_API_KEY`。
  - 若 `config.json` 中出现任何明文密钥字段（`token`/`bearerToken`/`apiKey`/`key`/`secret`/`password`）、密钥文件权限宽于 `0600` 或位于 `.git` 仓库内，启动直接 fail-closed 报错。
- **脱敏日志**：`bridge.log`（`0600`，JSONL）采用严格字段白名单，不落消息正文与文件内容，并在写入前对已注册密钥自动脱敏。

---

## 3. 防暴力破解限流（兼顾防自锁）

- **非回环访客**：滑动窗口限流（默认 `10` 分钟内失败 `10` 次触发 `429 Too Many Requests` + `Retry-After` 封禁 `5` 分钟）；任一合法握手立即清零失败计数。
- **本机回环（`127.0.0.1` / `::1`）**：永不长期封禁（绝不返 `429`），失败仅施加 `200ms` 短退避，防止经本机转发时外部扫描连累锁死自己。
- **反代真实 IP 解析**：通过 `security.trustedProxies` 显式列出受信任反代 IP/CIDR（拒绝 `0.0.0.0/0` 与 `::/0`）。只有来自受信任反代的连接才会自右向左解析 `X-Forwarded-For`，外部直连无法伪造。

---

## 4. `/health` 纯回环隔离

`GET /health` **仅当同时满足**以下两条时才返回 `200 OK`（`{"ok":true,"childAlive":...,"activeClient":...}`）：

1. TCP 来源地址属于本机回环（`127.0.0.1`、`127.0.0.0/8` 或 `::1`）。
2. 请求头中**不含** `x-forwarded-for`、`forwarded`、`x-real-ip`、`cf-connecting-ip` 中任何一项。

任何非回环来源或经代理转发的 `/health` 请求一律返回 `404 Not Found`。

---

## 5. 诚实的加密边界（为何不内置 TLS 与不做 E2EE）

- **不内置 TLS**：苹果 `NWConnection` 默认拒绝自签名证书。与其让用户折腾本地证书续期，`nonlocal-bridge` 专注回环纯 HTTP/WS，把受 iOS 原生信任的 `wss://` 证书终止交给 Tailscale Serve、Cloudflare Tunnel、Caddy 或 Nginx + Let's Encrypt。
- **不做应用层 E2EE**：
  - 经 **Tailscale**、**Cloudflare Tunnel** 或 **自建 VPS 反代** 时，流量由传输层加密（`wss://` / WireGuard）保护。
  - 经 **局域网直连** 时，流量为 **明文 `ws://`**——切勿在公共 Wi-Fi、咖啡馆、酒店或公网使用局域网直连。

---

## 6. 会话与文件系统边界

- **封闭自有会话白名单**：桥接只列出和管理通过 Nonlocal 创建的自有会话，不暴露、不接管也不允许误删电脑端原生会话。
- **远程文件安全读取**：`nonlocal/fs_read_file` 对文本限额 `512 KiB`（UTF-8 安全截断不出现乱码字符）、对图片限额 `10 MiB`，快拒二进制与 FIFO，日志零文件内容。
- **符号链接逃逸拦截**：Antigravity 级联删会话拦截中间目录软链逃逸（`-32023`），绝不误删无关会话。
