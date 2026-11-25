# 通过自建 VPS 远程接入（Caddy / Nginx + SSH 隧道）

[English](../../networking/vps.md) | **简体中文**

如果你已有带域名的公网 VPS，想把内网无公网 IP 的电脑安全映射到外网并完全自主掌控中继，可按本方案配置。

```text
iPhone ──(wss://:443)──▶ VPS（Caddy 或 Nginx TLS）──▶ VPS 127.0.0.1:18765
                                                            ▲
                                                  反向 SSH 隧道 (-R)
                                                            │
                                          电脑 127.0.0.1:8765（nonlocal-bridge）
```

---

## 1. 输出内置模板

```bash
nonlocal-bridge template vps-ssh-tunnel
nonlocal-bridge template vps-caddy    # 方案 A：Caddy（自动申请 Let's Encrypt 证书）
nonlocal-bridge template vps-nginx    # 方案 B：Nginx + Certbot
```

---

## 2. 在 VPS 上配置反向代理

两份内置反代模板均强制落实三条安全规则：

1. **对外封禁 `/health`**（一律返 `404`）。
2. **外层按真实访客 IP 限流**，挡住 WebSocket 暴力试探。
3. **单跳覆盖写入 `X-Forwarded-For`**（Caddy 用 `{remote_host}`，Nginx 用 `$remote_addr`），防止客户端伪造来源 IP。

### 方案 A：Caddy（`vps-caddy`）

- 将 `nonlocal-bridge template vps-caddy` 输出写入 `Caddyfile`。
- 替换 `<YOUR_BRIDGE_DOMAIN>.example.com` 为你的域名，把 `reverse_proxy` 目标端口改为 VPS 侧隧道端口（如 `127.0.0.1:18765`）。
- 重载 Caddy。

### 方案 B：Nginx（`vps-nginx`）

- 将 `nonlocal-bridge template vps-nginx` 输出写入 Nginx 站点配置。
- 替换 `<YOUR_BRIDGE_DOMAIN>.example.com`、填好 Let's Encrypt 证书路径，并将 `proxy_pass` 改为 VPS 侧隧道端口（如 `127.0.0.1:18765`）。
- 保留 `proxy_read_timeout 3600s` 与 `proxy_send_timeout 3600s` 以维持长连接。
- 校验并重载：`sudo nginx -t && sudo systemctl reload nginx`。

---

## 3. 在电脑上启动跨平台 SSH 反向隧道

把 `nonlocal-bridge template vps-ssh-tunnel` 的输出存为脚本（如 `~/bin/nonlocal-tunnel.sh` 并 `chmod +x`），通过环境变量启动：

```bash
NONLOCAL_RELAY_HOST=203.0.113.10 \
NONLOCAL_RELAY_USER=tunnel \
NONLOCAL_REMOTE_PORT=18765 \
NONLOCAL_LOCAL_PORT=8765 \
NONLOCAL_SSH_KEY=~/.ssh/id_ed25519 \
~/bin/nonlocal-tunnel.sh
```

> 建议：在 VPS 上为隧道建一个专用受限 SSH 账号（`AllowTcpForwarding remote`、`PermitTTY no`、`ForceCommand /usr/sbin/nologin`），禁止交互式 Shell 登录。

---

## 4. 在桥接侧开启受信任反代限流

在电脑的 `~/.config/nonlocal/config.json` 中把 `security.trustedProxies` 设为 `["127.0.0.1"]`（对应本机 SSH 隧道的来源地址），然后重启桥接：

```bash
nonlocal-bridge restart
```

这样桥接就会依据 VPS 反代覆盖写入的单跳 `X-Forwarded-For` 对恶意外部 IP 单独限流，同时绝不会连累锁死你自己的正常重连。

---

## 5. 在 iPhone 上连接

- **地址**：`wss://<YOUR_BRIDGE_DOMAIN>.example.com/acp`
- **Bearer Token**：在电脑运行 `nonlocal-bridge token show --reveal` 获取。
