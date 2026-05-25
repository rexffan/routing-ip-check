# egress-realip-check

检测 VPS 访问不同网站时，远端真实看到的出口 IP。

很多 VPS、代理、WARP、NAT、策略路由或 CDN 分流环境里，`mtr` / `traceroute` 的第一个公网 hop 并不等于网站看到的源 IP。这个脚本不使用路由 hop 作为结果，而是直接请求多个远端 IP 回显服务，让远端服务返回它实际观察到的 HTTP/HTTPS 客户端 IP，再汇总 IP、ISP、ASN 和国家/地区。

## Features

- 显示真实 HTTP 视角出口 IP，而不是路由器 hop
- 支持 IPv4 / IPv6
- 对多个 IP 回显服务进行交叉验证
- 自动汇总不同出口 IP 的分布
- 查询 ISP、ASN、国家/地区
- 可忽略本机代理环境变量，检测直连出口
- 可指定 `socks5h` / HTTP 代理，检测代理出口
- 支持 Cloudflare 站点的 `/cdn-cgi/trace` 目标站视角探测
- 支持社交、金融、购物、交易所、AI/办公、台湾本地金融/购物等分类目标探测
- 支持自定义 IP echo URL 和批量探测文件
- 支持 JSON Lines 输出，方便脚本化处理

## One-line Run

不需要 clone 仓库，直接在 VPS 上一键运行：

```bash
bash <(curl -fsSL https://github.com/rexffan/egress-realip-check/raw/refs/heads/main/egress-realip-check.sh)
```

默认会包含基础 IP echo 和分类目标探测。带参数也可以：

```bash
bash <(curl -fsSL https://github.com/rexffan/egress-realip-check/raw/refs/heads/main/egress-realip-check.sh) --no-proxy
bash <(curl -fsSL https://github.com/rexffan/egress-realip-check/raw/refs/heads/main/egress-realip-check.sh) --no-targets
bash <(curl -fsSL https://github.com/rexffan/egress-realip-check/raw/refs/heads/main/egress-realip-check.sh) --cf example.com
```

## Install

```bash
curl -fsSLO https://github.com/rexffan/egress-realip-check/raw/refs/heads/main/egress-realip-check.sh
chmod +x egress-realip-check.sh
```

## Usage

```bash
./egress-realip-check.sh
```

强制 IPv4：

```bash
./egress-realip-check.sh -4
```

强制 IPv6：

```bash
./egress-realip-check.sh -6
```

忽略 `http_proxy`、`https_proxy` 等环境变量，检测直连出口：

```bash
./egress-realip-check.sh --no-proxy
```

检测指定代理的出口：

```bash
./egress-realip-check.sh --proxy socks5h://127.0.0.1:1080
```

探测 Cloudflare 站点视角：

```bash
./egress-realip-check.sh --cf example.com
```

分类目标探测默认开启。只跑基础 IP echo 探测：

```bash
./egress-realip-check.sh --no-targets
```

默认会追加一组可回显 IP 的常见目标，覆盖社交、金融、购物、交易所、AI/办公、台湾本地金融/购物等分类。它主要使用目标网站的 `/cdn-cgi/trace`，所以只有支持该接口的站点才能返回真实观察到的 IP。

添加自定义 IP 回显接口：

```bash
./egress-realip-check.sh --add "my-echo=https://echo.example.com/ip"
```

输出 JSON Lines：

```bash
./egress-realip-check.sh --json
```

## Custom Probe File

可以用 `--file` 批量添加探测目标。每行一种格式：

```text
name|url
name|category|url
```

示例：

```text
my echo|https://echo.example.com/ip
cloudflare target|CDN Trace|https://example.com/cdn-cgi/trace
```

运行：

```bash
./egress-realip-check.sh --file probes.txt
```

## Why Not mtr?

`mtr` 和 `traceroute` 看到的是网络路径上的路由节点。第一个公网 hop 可能是运营商网关、上游路由器、NAT 前后的中间节点，不能证明目标网站看到的源 IP。

这个脚本的结果来自远端 HTTP 服务返回的客户端 IP，因此更接近“网站视角”。如果不同服务返回不同 IP，通常说明存在按域名、线路、代理、CDN 或策略路由的出口分流。

## Limitations

任意网站如果不主动回显客户端 IP，外部脚本无法凭空知道该网站最终看到的源 IP。对 Cloudflare 支持 `/cdn-cgi/trace` 的站点，可以用 `--cf HOST` 做更接近目标站的验证。

## Requirements

- Bash
- curl
- sed
- awk
- grep
- sort

## License

MIT

## Advanced Options

默认会串行探测，方便观察每个目标的请求顺序。想加速时可以用 `--concurrency` 开启并发：

```bash
./egress-realip-check.sh --concurrency 8
```

运行过程中只显示整体百分比进度；完成后会清屏并只保留本次检测结果。`--json` 模式不会清屏，也不会把进度混入 stdout。

也可以显式指定串行模式：

```bash
./egress-realip-check.sh --no-concurrency
```

### Probe Kinds

脚本有三种探测类型，各自语义不同：

| Kind | 探测内容 | 能告诉你什么 |
|---|---|---|
| `ipecho` | 命中已知回显接口（ipify、ifconfig.me 等） | 远端 HTTP 服务看到的源 IP |
| `cf` | 命中 `/cdn-cgi/trace`（Cloudflare 站点专用） | 该 CF 站点真实观察到的源 IP |
| `connectivity` | HEAD 站点根路径 `/` | **仅可达性** — 状态码、Server header、TTFB、目的 IP。**不会**报告你的出口 IP |

默认目标只含 `ipecho` + `cf`（已实测确认）。开 `--targets-all` 会**额外**追加一批台湾政府/银行/论坛/电信/媒体作为 `connectivity` 探针：

```bash
./egress-realip-check.sh --targets-all
```

这些 connectivity 目标**绝大多数不在 Cloudflare 上**，因此**无法**报告你的源 IP。但它们能回答另外两类问题：

- 我的出口能不能到这些域名？（`connect-timeout` vs 200）
- 路由策略是否对这些域名生效？（不同域名走不同出口时，TTFB 和目的 IP 会不同）

输出会自动**分两段**显示 —— Egress IP Probes 和 Connectivity Probes 各自一节，统计也分开。

自定义 connectivity 目标：

```bash
./egress-realip-check.sh --connectivity www.bot.com.tw
./egress-realip-check.sh --connectivity www.president.gov.tw
```

或用 `--file probes.txt`，每行格式：`name|category|url|kind`，例如：

```
總統府|TW Gov|https://www.president.gov.tw/|connectivity
```

### Privacy & Aesthetics

默认 IP 后两段会用 `•` 遮蔽（IPv4 后 2 octets，IPv6 后 2 hextets），方便直接截图分享：

```
✓  Cloudflare trace        CDN Trace     175.180.•••.•••  TW • AS4780 Digital United Inc.
```

需要完整 IP（排障时）传 `--show-ip`。注意 `--json` 输出始终保留完整 IP，给脚本消费用。

终端不支持 Unicode/256-color 时会自动回退到 ASCII：

```bash
./egress-realip-check.sh --ascii         # 强制 ASCII 字形
NO_COLOR=1 ./egress-realip-check.sh      # 关闭所有 ANSI 颜色
./egress-realip-check.sh --verbose       # 输出中额外显示 URL 列
```
