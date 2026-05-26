# routing-ip-check

> **VPS 分流测试** —— 检测一台 VPS 是不是对不同站点走不同出口 IP。
>
> 用 Cloudflare 站点的 `/cdn-cgi/trace` 作为可信的"源 IP 镜子"，让多个 CF 站点告诉你它们各自看到的 source IP。**所有结果一致 = 单出口；出现多个 IP = 分流 / 策略 NAT / 按域名代理。**

## When to use

- 跨境业务 VPS 配置了多线路 / 多公网 IP，想验证是不是真在按域名分流
- 企业网关 / 防火墙做了策略 NAT，想知道哪些站点被重写了 source IP
- WARP / WireGuard / Tunnel 配置完，验证 split-tunnel 是否按预期工作
- 代理选择器（V2Ray / sing-box / clash 等）规则调试 —— 不同 CF 站点是否真走不同出口
- 调试 anycast CDN edge 地理路由：看 CF 边缘节点是不是稳定命中预期机房

## One-line Run

不需要 clone 仓库，直接在 VPS 上：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/rexffan/routing-ip-check/main/routing-ip-check.sh)
```

只检测某个 Cloudflare 站点：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/rexffan/routing-ip-check/main/routing-ip-check.sh) --no-targets --cf example.com
```

显示完整 IP（默认遮蔽后两段）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/rexffan/routing-ip-check/main/routing-ip-check.sh) --show-ip
```

## Sample Output

```
  routing-ip-check                                                        v1.8.0
  ────────────────────────────────────────────────────────────────────────────
  IPv4  •  direct  •  44 cf probes  •  4 workers  •  masked


  ▎ Cloudflare Trace Probes

  ●  Cloudflare trace            175.180.•••.•••                          98ms
  ●  openai.com                  175.180.•••.•••              US · AS13335  142ms
  ●  wise.com                    175.180.•••.•••              US · AS13335  201ms
  ●  LINE Bank TW                121.18.•••.•••               TW · AS13335   18ms
  ●  PX Pay                      121.18.•••.•••               TW · AS13335   21ms
  ○  some-broken.com             http-404

  ▎ Summary

    42 ok   •   1 fail   •   2 unique IPs

  ▎ Source IP Distribution

    ████████████████████████   42 •   95%   175.180.•••.•••   US · AS13335
    █▍                          2 •    5%   121.18.•••.•••   TW · AS13335

  ⚠  Different Cloudflare sites observed different source IPs — likely split routing or policy NAT.

  ▎ Tips
    ▸  --show-ip          reveal full IPs
    ▸  --cf example.com   add a specific Cloudflare site
    ▸  --json             machine-readable output
```

## Install

```bash
curl -fsSLO https://raw.githubusercontent.com/rexffan/routing-ip-check/main/routing-ip-check.sh
chmod +x routing-ip-check.sh
```

## Options

| Flag | 作用 |
|---|---|
| `--cf HOST` | 加一个 Cloudflare trace 目标 `https://HOST/cdn-cgi/trace` |
| `--file FILE` | 从文件批量加 CF trace 目标 |
| `--no-targets` | 不跑内置目标列表，只跑你显式 `--cf` 加的 |
| `--show-ip` | 显示完整 IP（默认遮蔽后两段，截图友好） |
| `--no-proxy` | 忽略 `http_proxy` / `https_proxy` 环境变量 |
| `--proxy URL` | 走指定代理，例如 `socks5h://127.0.0.1:1080` |
| `--concurrency N` | 并发数（默认 1 串行） |
| `--no-asn` | 不查询 ASN / ISP / 国家（更快） |
| `--json` | 输出 JSON Lines，机器消费用 |
| `--light` / `--dark` | 手动指定白底 / 黑底配色（自动探测失败时） |
| `--ascii` | 关闭 Unicode 字形，纯 ASCII |
| `--no-install` | 不要自动安装缺失依赖 |

## Custom Cloudflare Targets

直接 `--cf` 加一个：

```bash
./routing-ip-check.sh --cf shop.example.com
```

或者用 `--file probes.txt` 批量：

```text
my-site|https://shop.example.com/cdn-cgi/trace
api|CDN Trace|https://api.example.com/cdn-cgi/trace
```

```bash
./routing-ip-check.sh --file probes.txt
```

`--file` 只接受 Cloudflare trace URL，路径必须是 `/cdn-cgi/trace`。

## JSON

```bash
./routing-ip-check.sh --json --no-asn
```

每行一条记录：

```json
{"status":"OK","name":"Cloudflare trace","kind":"cf","host":"www.cloudflare.com","ip":"203.0.113.10","ttfb_ms":"120", ...}
```

## How It Works

Cloudflare 在每个站点上挂了一个 `/cdn-cgi/trace` 端点，返回里有 `ip=` 字段 —— 这是该站点观察到的客户端源 IP。脚本对一组确认会回显的 CF 站点跑这个端点，汇总它们各自看到的 IP；**全部一致 = 单出口；出现差异 = 该 VPS 有分流 / 策略 NAT / 按域名代理**。

## Limitations

- 只适合 Cloudflare 站点。
- 非 Cloudflare 站点（Meta / Google 等）如果没有等价的 source-IP 回显端点，脚本不能确认它看到的源 IP。
- 如果机房只对某个白名单域名做源地址替换，而你没有该目标的回显能力，脚本无法直接证明。
- 如果 Cloudflare 站点关闭或拦截 `/cdn-cgi/trace`，该目标会失败。

## Requirements

必需：

- Bash
- curl
- sed / awk / grep / sort

脚本启动时会自动检查依赖，缺少时尝试用系统包管理器安装：`apt` / `dnf` / `yum` / `apk` / `pacman` / `zypper` / `brew`。不希望自动安装可以加 `--no-install`。

## License

MIT
