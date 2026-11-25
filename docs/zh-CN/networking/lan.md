# 局域网直连（仅限可信家庭 Wi-Fi）

[English](../../networking/lan.md) | **简体中文**

> **安全警示**：局域网直连走 **明文 `ws://`**，**没有任何应用层端到端加密（E2EE）**。只可在家里等完全可信的私有 Wi-Fi 使用，切勿在公共 Wi-Fi、咖啡馆、酒店或公网 IP 上使用——外网请改用 [Tailscale Serve](tailscale.md)。

---

## 1. 放开非回环监听时的内置护栏

- **双保险开关**：绑定非回环 IP 必须**同时**指定 `--host <局域网IP>` 与 `--allow-non-loopback`（或在 `config.json` 中设 `server.allowNonLoopback: true`）。
- **只认 IP 字面量**：`server.host` 必须是明确的 IPv4/IPv6 字面量（如 `192.168.1.50`），禁止填主机名。
- **单播伴随回环监听**：绑定具体局域网单播 IP 时，桥接会在同端口自动额外监听 `127.0.0.1`（或 `::1`），确保本机 `status` 和 `doctor` 依然正常工作。
- **`/health` 不外露**：来自局域网其他设备的 `/health` 请求一律返回 `404 Not Found`。
- **防暴力破解限流**：非回环 IP 在 `10` 分钟内鉴权失败 `10` 次会被封禁 `5` 分钟（`429 Too Many Requests`）。

---

## 2. 查看局域网模板

```bash
nonlocal-bridge template lan
```

---

## 3. 修改配置并重启桥接

查出电脑的私有局域网 IPv4 地址（例如 `192.168.1.50`），修改 `~/.config/nonlocal/config.json`：

```json
{
  "server": {
    "host": "192.168.1.50",
    "port": 8765,
    "allowNonLoopback": true
  }
}
```

或通过命令行重新初始化（注意：`--force` 会覆写已有配置并重新生成 Token）：

```bash
nonlocal-bridge init --yes \
  --host 192.168.1.50 \
  --port 8765 \
  --allow-non-loopback \
  --force
```

重启并体检：

```bash
nonlocal-bridge restart
nonlocal-bridge doctor --json
```

此时 `doctor --json` 中 `config_security` 会显示 `"warn"`（正常的明文局域网提醒），只要无 `fail` 项总退出码依然为 `0`。

---

## 4. 在 iPhone 上连接

确认 iPhone 与电脑连在同一个 Wi-Fi 下，然后填入：

- **地址**：`ws://<YOUR_LAN_IPV4>:8765/acp`
- **Bearer Token**：在电脑运行 `nonlocal-bridge token show --reveal` 获取。
