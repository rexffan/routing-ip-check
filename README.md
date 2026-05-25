# Cloudflare Source IP Detection

一个专门检测 **Cloudflare 站点实际看到的源 IP** 的 Bash 脚本。

它只请求 Cloudflare 站点的 `/cdn-cgi/trace`，并严格解析返回里的 `ip=`。这类结果能回答一个很具体的问题：

> 这个 Cloudflare 站点看到我的 source IP 是什么？

如果机房对不同 Cloudflare 站点做了分流、策略 NAT、透明代理或源地址替换，多个 `/cdn-cgi/trace` 结果可能会出现不同 IP。

## 重要边界

这个脚本**不检测**普通站点的可达性，也**不做** Meta / Google / GitHub / Reddit 之类 ASN/TLS audit。

原因很简单：如果目标站点不主动回显你的 source IP，脚本就无法证明该站点看到的真实源 IP。Facebook 这类非 Cloudflare trace 目标即使在浏览器里一切正常，脚本也不能直接知道 Facebook 服务器看到的 source IP。

所以从 `1.7.0` 开始，脚本只保留 Cloudflare trace 检测。

## One-line Run

不需要 clone 仓库，直接在 VPS 上运行：

```bash
bash <(curl -fsSL https://github.com/rexffan/routing-ip-check/raw/refs/heads/main/routing-ip-check.sh)
```

默认会检测一组已知支持 `/cdn-cgi/trace` 的 Cloudflare 站点，并汇总这些站点看到的 source IP 分布。

只检测某个 Cloudflare 站点：

```bash
bash <(curl -fsSL https://github.com/rexffan/routing-ip-check/raw/refs/heads/main/routing-ip-check.sh) --no-targets --cf example.com
```

显示完整 IP：

```bash
bash <(curl -fsSL https://github.com/rexffan/routing-ip-check/raw/refs/heads/main/routing-ip-check.sh) --show-ip
```

## Install

```bash
curl -fsSLO https://github.com/rexffan/routing-ip-check/raw/refs/heads/main/routing-ip-check.sh
chmod +x routing-ip-check.sh
```

## Usage

```bash
./routing-ip-check.sh
```

常用参数：

```bash
./routing-ip-check.sh --cf example.com
./routing-ip-check.sh --no-targets --cf example.com
./routing-ip-check.sh --show-ip
./routing-ip-check.sh --json --no-asn
./routing-ip-check.sh --concurrency 8
./routing-ip-check.sh --proxy socks5h://127.0.0.1:1080
./routing-ip-check.sh --no-proxy
```

## How It Works

Cloudflare 提供一个调试端点：

```text
https://example.com/cdn-cgi/trace
```

返回内容里通常会有：

```text
ip=203.0.113.10
colo=NRT
http=http/2
tls=TLSv1.3
...
```

脚本只提取 `ip=`。这个 IP 就是该 Cloudflare 站点观察到的客户端源 IP。

输出会包含：

- 每个 Cloudflare trace 目标看到的 source IP
- IP 分布统计
- 如果出现多个 source IP，会提示可能存在分流或策略 NAT
- 默认遮蔽 IP 后两段，便于截图

## Custom Cloudflare Targets

手动添加一个 Cloudflare 站点：

```bash
./routing-ip-check.sh --cf example.com
```

批量添加：

```text
my site|https://example.com/cdn-cgi/trace
shop cf|Shopping|https://shop.example.com/cdn-cgi/trace
```

运行：

```bash
./routing-ip-check.sh --file probes.txt
```

`--file` 只接受 Cloudflare trace URL，路径必须是 `/cdn-cgi/trace`。

## JSON

```bash
./routing-ip-check.sh --json --no-asn
```

示例：

```json
{"status":"OK","name":"Cloudflare trace","category":"CDN Trace","kind":"cf","host":"www.cloudflare.com","url":"https://www.cloudflare.com/cdn-cgi/trace","ip":"203.0.113.10","isp":"","asn":"","country":"","http_code":"200","reason":"","remote_ip":"104.16.123.96","ttfb_ms":"120"}
```

## Requirements

必需：

- Bash
- curl
- sed / awk / grep / sort

脚本启动时会自动检查依赖，缺少时尝试用系统包管理器安装：`apt` / `dnf` / `yum` / `apk` / `pacman` / `zypper` / `brew`。不希望自动安装可以加：

```bash
./routing-ip-check.sh --no-install
```

## Limitations

- 只适合 Cloudflare 站点。
- 非 Cloudflare 站点如果没有等价的 source-IP 回显端点，脚本不能确认它看到的源 IP。
- 如果机房只对白名单域名例如 `facebook.com` 做源地址替换，而你没有该目标的 source-IP 回显能力，这个脚本无法直接证明。
- 如果 Cloudflare 站点关闭或拦截 `/cdn-cgi/trace`，该目标会失败。

## License

MIT
