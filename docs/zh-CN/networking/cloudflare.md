# 通过 Cloudflare Tunnel 远程接入

[English](../../networking/cloudflare.md) | **简体中文**

如果你在 Cloudflare 托管了自己的域名，且不想在 iPhone 上额外装 VPN 客户端，可以用 **Cloudflare Tunnel（`cloudflared`）** 提供受信任的 `wss://` 外网接入。

- `nonlocal-bridge` 保持监听 `127.0.0.1:8765`，无需路由器端口映射。
- Cloudflare 边缘自动完成 iOS 信任的 TLS 终止。

---

## 1. 前置准备

1. 本机 `nonlocal-bridge` 已在 `127.0.0.1:8765` 运行并通过 `nonlocal-bridge doctor --json`。
2. 拥有一个由 Cloudflare 管理的域名，且电脑已安装 `cloudflared`。

---

## 2. 输出隧道配置模板

```bash
nonlocal-bridge template cloudflare
```

输出示例（自动填入你配置的端口）：

```yaml
tunnel: <YOUR_CLOUDFLARE_TUNNEL_ID>
credentials-file: /path/to/<YOUR_TUNNEL_CREDENTIALS_FILE>.json

ingress:
  - hostname: <YOUR_BRIDGE_HOSTNAME>.example.com
    path: ^/(acp|ws)$
    service: http://127.0.0.1:8765
    originRequest:
      noTLSVerify: false
  - service: http_status:404
```

要点：
- `path: ^/(acp|ws)$` 只放行 WebSocket 路径，其余路径（含 `/health`）一律返回 `404`。
- 即便 `/health` 被误转发，桥接也会拒绝任何带有 `cf-connecting-ip` 或 `x-forwarded-for` 头的 `/health` 请求并返回 `404`。

---

## 3. 创建并启动隧道

1. 登录并创建命名隧道：
   ```bash
   cloudflared tunnel login
   cloudflared tunnel create nonlocal-bridge
   cloudflared tunnel route dns nonlocal-bridge <YOUR_BRIDGE_HOSTNAME>.example.com
   ```
2. 将模板内容保存到 `~/.cloudflared/config.yml`，替换为你真实的 Tunnel ID、凭据文件路径和域名。
3. 启动隧道：
   ```bash
   cloudflared tunnel run nonlocal-bridge
   ```

---

## 4. 可选加固与限流

- 如希望桥接按访客真实 IP 单独限流，可在 `~/.config/nonlocal/config.json` 中将 `security.trustedProxies` 设为 `["127.0.0.1"]`（不设时本机转发走短退避、绝不锁死自己）。
- 建议在 Cloudflare WAF 中为 `<YOUR_BRIDGE_HOSTNAME>.example.com` 增加外层限流规则。

---

## 5. 在 iPhone 上连接

- **地址**：`wss://<YOUR_BRIDGE_HOSTNAME>.example.com/acp`
- **Bearer Token**：在电脑运行 `nonlocal-bridge token show --reveal` 获取。
