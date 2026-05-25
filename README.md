# Routing Source IP Detection

检测 VPS 访问不同网站时，远端真实看到的出口 IP。

## How It Works

脚本对多个**会回显客户端 IP** 的远端服务发起 HTTPS 请求，把它们各自返回的"远端看到的源 IP"汇总在一起：

1. **ipecho 类**：直接命中通用 IP 回显接口（ipify、ifconfig.me、icanhazip 等），从响应 body 里提取 IPv4/IPv6。
2. **cf 类**：命中 Cloudflare 站点的 `/cdn-cgi/trace` 端点，严格解析 `ip=` 行 —— 这是该 CF 站点观察到你的真实源 IP。
3. **connectivity 类**：对不会回显 IP 的目标（政府、银行、电信、媒体等不在 CDN 上的站点）做 HEAD `/` 探测，只记录可达性、HTTP 状态、`Server` header、TTFB 和目的 IP —— **不会**返回你的出口 IP，但能告诉你"这个域名走得通吗、路由策略生效了吗"。

每次探测之后，脚本对所有 OK 的出口 IP 做 ASN/ISP/国家查询（`ipinfo.io`，自动缓存去重），最后输出：
- 每个探测的结果一行
- 出口 IP 分布（带强度条），多个 IP 时直接提示存在分流
- 结果中默认遮蔽 IP 后两段，截图分享更安全

整个过程一条进度条贯穿 `Probing` → `Resolving` 两个阶段，跑完清屏，只展示最终结果。

## Features

- 真实 HTTP 视角出口 IP，多源交叉验证
- 支持 IPv4 / IPv6 强制
- 自动汇总不同出口 IP 的分布，多 IP 直接提示分流
- 自动查询 ISP、ASN、国家/地区
- 可忽略本机代理环境变量检测直连出口；也可指定 `socks5h` / HTTP 代理检测代理出口
- 支持 Cloudflare 任意站点的 `/cdn-cgi/trace` 目标视角探测
- 内置一组覆盖社交、金融、购物、交易所、AI/办公、本地论坛/媒体的目标
- 开 `--targets-all` 可追加更多本地政府、银行、电信、传统媒体、运输等连通性探针
- 支持自定义 IP echo URL 和批量探测文件
- 支持 JSON Lines 输出，方便脚本化处理
- 默认遮蔽 IP 后两段，`--show-ip` 取消遮蔽

## One-line Run

不需要 clone 仓库，直接在 VPS 上一键运行：

```bash
bash <(curl -fsSL https://github.com/rexffan/routing-ip-check/raw/refs/heads/main/routing-ip-check.sh)
```

默认会包含基础 IP echo 和分类目标探测。带参数也可以：

```bash
bash <(curl -fsSL https://github.com/rexffan/routing-ip-check/raw/refs/heads/main/routing-ip-check.sh) --no-proxy
bash <(curl -fsSL https://github.com/rexffan/routing-ip-check/raw/refs/heads/main/routing-ip-check.sh) --no-targets
bash <(curl -fsSL https://github.com/rexffan/routing-ip-check/raw/refs/heads/main/routing-ip-check.sh) --cf example.com
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

强制 IPv4：

```bash
./routing-ip-check.sh -4
```

强制 IPv6：

```bash
./routing-ip-check.sh -6
```

忽略 `http_proxy`、`https_proxy` 等环境变量，检测直连出口：

```bash
./routing-ip-check.sh --no-proxy
```

检测指定代理的出口：

```bash
./routing-ip-check.sh --proxy socks5h://127.0.0.1:1080
```

探测 Cloudflare 站点视角：

```bash
./routing-ip-check.sh --cf example.com
```

分类目标探测默认开启。只跑基础 IP echo 探测：

```bash
./routing-ip-check.sh --no-targets
```

添加自定义 IP 回显接口：

```bash
./routing-ip-check.sh --add "my-echo=https://echo.example.com/ip"
```

输出 JSON Lines：

```bash
./routing-ip-check.sh --json
```

## Custom Probe File

可以用 `--file` 批量添加探测目标。每行支持三种格式：

```text
name|url
name|category|url
name|category|url|kind
```

`kind` 取值：`ipecho`、`cf`、`connectivity`（省略时默认 `ipecho`）。

示例：

```text
my echo|https://echo.example.com/ip
cloudflare target|CDN Trace|https://example.com/cdn-cgi/trace
local-bank|Finance|https://www.example-bank.com/|connectivity
```

运行：

```bash
./routing-ip-check.sh --file probes.txt
```

## Limitations

只有目标主动回显客户端 IP 才能得到真实出口 IP（`ipecho` 和 `cf` 类）。其余站点只能用 `connectivity` 类做可达性诊断，**无法**报告你的出口 IP。

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

默认串行探测，方便观察每个目标的请求顺序。想加速时用 `--concurrency` 开启并发：

```bash
./routing-ip-check.sh --concurrency 8
```

运行过程中只显示整体百分比进度（`Probing` 探测阶段 + `Resolving` ASN 解析阶段，同一条进度线平滑过渡）；完成后清屏，只保留本次检测结果。`--json` 模式不会清屏，也不会把进度混入 stdout。

也可以显式指定串行：

```bash
./routing-ip-check.sh --no-concurrency
```

### Probe Kinds

脚本有三种探测类型：

| Kind | 探测内容 | 能告诉你什么 |
|---|---|---|
| `ipecho` | 命中已知回显接口（ipify、ifconfig.me 等） | 远端 HTTP 服务看到的源 IP |
| `cf` | 命中 `/cdn-cgi/trace`（Cloudflare 站点专用） | 该 CF 站点真实观察到的源 IP |
| `connectivity` | HEAD 站点根路径 `/` | **仅可达性** — 状态码、Server header、TTFB、目的 IP。**不会**报告你的出口 IP |

默认目标只含 `ipecho` + `cf`（已实测确认）。开 `--targets-all` 会**额外**追加一批本地政府/银行/论坛/电信/媒体作为 `connectivity` 探针：

```bash
./routing-ip-check.sh --targets-all
```

这些 connectivity 目标**绝大多数不在 Cloudflare 上**，因此无法报告你的源 IP。但它们能回答另外两类问题：

- 我的出口能不能到这些域名？（`connect-timeout` vs 200）
- 路由策略是否对这些域名生效？（不同域名走不同出口时，TTFB 和目的 IP 会不同）

输出会自动**分两段**显示 —— Egress IP Probes 和 Connectivity Probes 各自一节，统计也分开。

自定义 connectivity 目标：

```bash
./routing-ip-check.sh --connectivity www.example-bank.com
./routing-ip-check.sh --connectivity www.example-gov.org
```

### Service Audit（`--audit`）

针对常见大型服务做"身份核验"：对比 dest IP 的 ASN 跟 TLS 证书 issuer 是否符合预期。任意一项不符即可怀疑被劫持/MITM。

```bash
./routing-ip-check.sh --audit meta
./routing-ip-check.sh --audit google --audit github
./routing-ip-check.sh --audit all              # 一次跑完所有 preset
```

支持的 preset：

| Preset | 覆盖域名 | 期望 ASN | 期望 cert issuer |
|---|---|---|---|
| `meta` | facebook.com / instagram.com / whatsapp.com / threads.net / messenger.com / fbcdn.net / cdninstagram.com | AS32934 | DigiCert / Meta Platforms |
| `google` | google.com / gmail.com / youtube.com / drive / docs / maps / play | AS15169 + AS396982 | Google Trust Services / GTS CA / WE1 / WR2 |
| `cloudflare` | cloudflare.com / 1.1.1.1 / dash / workers / developers | AS13335 | Cloudflare / DigiCert / SSL.com / WE1 |
| `openai` | openai.com / chatgpt.com / api / platform | AS13335 (CF-fronted) | DigiCert / WE1 / GTS CA |
| `reddit` | reddit.com / old.reddit.com / *.redd.it | AS54113 (Fastly) / AS16509 (AWS) | DigiCert / Amazon / Let's Encrypt |
| `github` | github.com / api / gist / codeload / githubusercontent | AS36459 / AS13335 | DigiCert / Sectigo / Let's Encrypt (R12) |

**判定逻辑（per-host short-circuit）**：

1. 先看 dest IP 的 ASN —— 不在期望列表里直接 `ASN mismatch`，**跳过证书检查**（第一种方法已经定案）
2. ASN 通过后再拉 TLS 证书 issuer，跟期望正则对比 —— 不符即 `cert mismatch`
3. 证书检查需要 `openssl`；缺则降级为 `ok-asn-only`（仅凭 ASN 判定）

输出形如：

```
─── Audit: Meta (Facebook, Instagram, WhatsApp, Threads, Messenger) ───
  Expected:  AS32934  •  cert issuer ~ DigiCert|Meta Platforms

  ✓  facebook.com       157.240.•••.•••   AS32934    DigiCert Global G2    ok
  ✓  instagram.com      157.240.•••.•••   AS32934    DigiCert Global G2    ok
  ⚠  whatsapp.com       211.21.•••.•••    AS3462     —                     ASN mismatch
  ⚠  messenger.com      157.240.•••.•••   AS32934    Local Root CA         cert mismatch

  Verdict: 2 mismatches detected
```

### Dependency management

脚本启动时会检查 `curl / sed / awk / grep / sort`（开 `--audit` 还会要求 `openssl`），缺啥就用系统包管理器（apt / dnf / yum / apk / pacman / zypper / brew）自动装。非 root 时会自动用 `sudo`。

如果你不希望被脚本自动安装，加 `--no-install`：

```bash
./routing-ip-check.sh --no-install --audit meta   # 不装直接报错
```

### Privacy & Aesthetics

默认 IP 后两段会用 `•` 遮蔽（IPv4 后 2 octets，IPv6 后 2 hextets），方便直接截图分享：

```
✓  Cloudflare trace        CDN Trace     104.16.•••.•••   US • AS13335 Cloudflare, Inc.
```

需要完整 IP（排障时）传 `--show-ip`。注意 `--json` 输出始终保留完整 IP，给脚本消费用。

终端不支持 Unicode/256-color 时会自动回退到 ASCII：

```bash
./routing-ip-check.sh --ascii         # 强制 ASCII 字形
NO_COLOR=1 ./routing-ip-check.sh      # 关闭所有 ANSI 颜色
./routing-ip-check.sh --verbose       # 输出中额外显示 URL 列
```
