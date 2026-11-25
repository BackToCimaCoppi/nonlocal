# 网络接入选型总览

[English](../../networking/README.md) | **简体中文**

`nonlocal-bridge` 默认仅监听 `127.0.0.1:8765` 且不内置 TLS 证书。请根据你的网络环境，从下面 4 种方案中选一种让 iPhone 连接桥接。

---

## 4 种接入方案对比

| 方案 | 是否加密（`wss://`） | 需要 VPS / 域名 | 桥接监听地址 | 最适合谁 | 教程 |
|---|---|---|---|---|---|
| **Tailscale Serve（外网首选）** | 是（WireGuard + 自动 HTTPS） | 不需要 | `127.0.0.1` | 零端口映射、在外随时私密连回家里/公司电脑 | [Tailscale 教程](tailscale.md) |
| **Cloudflare Tunnel** | 是（Cloudflare TLS） | 仅需自有域名 | `127.0.0.1` | 不想在手机装 VPN 客户端的外网用户 | [Cloudflare 教程](cloudflare.md) |
| **自建 VPS（Caddy / Nginx + SSH）** | 是（Let's Encrypt TLS） | 需要 VPS + 域名 | `127.0.0.1` | 家宽无公网 IP、希望完全自主掌控中继的用户 | [自建 VPS 教程](vps.md) |
| **局域网直连** | **否（明文 `ws://`）** | 不需要 | 局域网 IPv4 + `--allow-non-loopback` | 仅在家里可信 Wi-Fi 使用、追求零额外工具 | [局域网直连教程](lan.md) |

---

## 内置只读模板命令

`nonlocal-bridge` 内置 6 个脱敏模板，会自动把你当前配置里的端口填进去输出到终端（绝不擅自改动你的外部网络软件配置）：

```bash
nonlocal-bridge template list
nonlocal-bridge template tailscale
nonlocal-bridge template cloudflare
nonlocal-bridge template vps-caddy
nonlocal-bridge template vps-nginx
nonlocal-bridge template vps-ssh-tunnel
nonlocal-bridge template lan
```

---

## 安全提醒

- 保护 `/health`：所有反代与隧道模板都只转发 WebSocket 路径（`/acp` 与 `/ws`），桥接自身也会对非回环或带代理头的 `/health` 一律返回 `404`。
- 切勿把明文 `ws://` 直接暴露在公网。详见 [安全模型与加密边界](../security.md)。
