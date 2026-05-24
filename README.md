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
- 支持社交、金融、购物、交易所、AI/办公等分类目标探测
- 支持自定义 IP echo URL 和批量探测文件
- 支持 JSON Lines 输出，方便脚本化处理

## One-line Run

不需要 clone 仓库，直接在 VPS 上一键运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/rexffan/egress-realip-check/main/egress-realip-check.sh)
```

带参数也可以：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/rexffan/egress-realip-check/main/egress-realip-check.sh) --no-proxy
bash <(curl -fsSL https://raw.githubusercontent.com/rexffan/egress-realip-check/main/egress-realip-check.sh) --targets
bash <(curl -fsSL https://raw.githubusercontent.com/rexffan/egress-realip-check/main/egress-realip-check.sh) --cf example.com
```

## Install

```bash
curl -fsSLO https://raw.githubusercontent.com/rexffan/egress-realip-check/main/egress-realip-check.sh
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

加入常见分类目标探测：

```bash
./egress-realip-check.sh --targets
```

`--targets` 会追加一组可回显 IP 的常见目标，覆盖社交、金融、购物、交易所、AI/办公等分类。它主要使用目标网站的 `/cdn-cgi/trace`，所以只有支持该接口的站点才能返回真实观察到的 IP。

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
