# 通过 Tailscale Serve 远程接入（外网首选）

[English](../../networking/tailscale.md) | **简体中文**

**Tailscale Serve** 是从外网连回家里或公司电脑的首推方案：

- 流量全程走私有 WireGuard 隧道，不暴露在公网上。
- Tailscale 自动签发受 iOS 原生信任的 HTTPS/WSS 证书，无需自己折腾域名和证书续期。
- `nonlocal-bridge` 保持仅监听 `127.0.0.1:8765`。

---

## 1. 前置准备

1. 本机 `nonlocal-bridge` 已在回环地址（`127.0.0.1:8765`）运行，且 `nonlocal-bridge doctor --json` 通过。
2. 电脑与 iPhone 均已安装 [Tailscale](https://tailscale.com/) 并登录同一 Tailnet。
3. 在 Tailscale 管理后台（DNS 页面）开启 **MagicDNS** 与 **HTTPS Certificates**。

---

## 2. 输出端口对齐的模板命令

```bash
nonlocal-bridge template tailscale
```

输出会给出与你当前端口匹配的精确命令：

```bash
tailscale serve --bg --https=443 --set-path=/acp http://127.0.0.1:8765/acp
```

在电脑终端执行上面这行命令即可。注意它只转发 `/acp`，`/health` 仍仅限本机访问。

---

## 3. 在 iPhone 上连接

1. 确认 Tailscale Serve 规则已生效：
   ```bash
   tailscale serve status
   ```
2. 在电脑终端手动查看 Bearer Token：
   ```bash
   nonlocal-bridge token show --reveal
   ```
3. 在 Nonlocal iOS 客户端填入：
   - **地址**：`wss://<YOUR_MACHINE_NAME>.<YOUR_TAILNET_SUFFIX>.ts.net/acp`
   - **Bearer Token**：第 2 步获取的 Token

---

## 4. 后续关闭规则

```bash
tailscale serve --https=443 --set-path=/acp off
```

## 常见排错

- **iOS 报 TLS 证书错**：检查 Tailscale 后台是否已打开 HTTPS Certificates 和 MagicDNS，首次开启等待 1–2 分钟签发生效。
- **连接被拒**：运行 `nonlocal-bridge status --json` 确认桥接监听端口与 `tailscale serve` 里填的端口一致。
