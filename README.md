# Routing Source IP Detection

检测 VPS 访问不同网站时，远端真实看到的出口 IP；并对常见大型服务（Meta / Google / Cloudflare / OpenAI / Reddit / GitHub）做"身份核验"，识别 DNS 劫持、BGP 劫持、本地机房中间人。对 Meta 这类不会公开回显 source IP 的服务，脚本只做非登录审计，不尝试登录账号或读取账号活动。

## What's New in 1.6.0

- `--audit PRESET` —— 内置 6 个服务身份核验 preset（meta、google、cloudflare、openai、reddit、github、all）。对比 dest IP 的 ASN 跟 TLS 证书 issuer，任一不符即提示异常；其中 `meta` 已扩展到 Facebook / Instagram / WhatsApp / Threads / Meta CDN/API 的非登录深度审计。
- 启动时**自动检查依赖**，缺什么就用系统包管理器（apt / dnf / yum / apk / pacman / zypper / brew）装上；非 root 时自动用 `sudo`。可用 `--no-install` 关掉。
- 内置便携 `timeout` wrapper —— BSD/macOS 没有 GNU `timeout` 也能跑 `openssl s_client`。

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
- `--audit PRESET` 服务身份核验（ASN + 证书指纹），内置 6 个常用服务 preset；`meta` 为非登录深度审计
- 启动时自动安装缺失的系统依赖（apt / dnf / yum / apk / pacman / zypper / brew）

## One-line Run

不需要 clone 仓库，直接在 VPS 上一键运行。下面这条默认就会包含**基础 IP echo** 和**分类目标探测**：

```bash
bash <(curl -fsSL https://github.com/rexffan/routing-ip-check/raw/refs/heads/main/routing-ip-check.sh)
```

也就是说，不加任何参数时已经会跑默认分类目标；只有想**只跑基础 IP echo** 时才需要加 `--no-targets`。带参数也可以：

```bash
# 直连出口
bash <(curl -fsSL https://github.com/rexffan/routing-ip-check/raw/refs/heads/main/routing-ip-check.sh) --no-proxy

# 只跑基础 IP echo
bash <(curl -fsSL https://github.com/rexffan/routing-ip-check/raw/refs/heads/main/routing-ip-check.sh) --no-targets

# 测某个 Cloudflare 站点的视角
bash <(curl -fsSL https://github.com/rexffan/routing-ip-check/raw/refs/heads/main/routing-ip-check.sh) --cf example.com

# 服务身份核验（首次跑会自动装 openssl）
bash <(curl -fsSL https://github.com/rexffan/routing-ip-check/raw/refs/heads/main/routing-ip-check.sh) --audit meta

# 一次跑完所有 6 个 preset
bash <(curl -fsSL https://github.com/rexffan/routing-ip-check/raw/refs/heads/main/routing-ip-check.sh) --no-targets --audit all --concurrency 8
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

**必需**（任何模式都要）：

- Bash
- curl
- sed / awk / grep / sort（一般系统都自带）

**`--audit` 才需要**：

- openssl（拉远端 TLS 证书核对 issuer）
- `timeout`（GNU coreutils；没有也能跑，会走内置 bash 模拟实现）

**自动安装**：脚本启动时会检查这些命令，缺什么就用系统包管理器装：`apt` / `dnf` / `yum` / `apk` / `pacman` / `zypper` / `brew`。非 root 时自动用 `sudo`。不希望自动装就加 `--no-install`，脚本会改成直接报错。

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

针对常见大型服务做"身份核验"：对比 dest IP 的 ASN 跟 TLS 证书 issuer 是否符合预期。任意一项不符即可标记为可疑，供人工复核。

注意：`--audit` 检查的是"目标服务身份"而不是"目标服务看到的 source IP"。Meta、GitHub、Google、OpenAI 等站点通常不会在普通请求里回显你的 source IP；因此在不登录账号、拿不到账号活动 IP 的前提下，脚本不会声称已经确认 Meta 看到的出口 IP。`--audit meta` 的作用是尽量覆盖更多 Meta 入口、API 与 CDN 域名，判断它们是否仍然解析/连接到 Meta 官方网络与正常证书链。

```bash
./routing-ip-check.sh --audit meta
./routing-ip-check.sh --audit google --audit github
./routing-ip-check.sh --audit all              # 一次跑完所有 preset
```

支持的 preset：

| Preset | 覆盖域名 | 期望 ASN | 期望 cert issuer |
|---|---|---|---|
| `meta` | facebook / m.facebook / l.facebook / business / graph / graph-video / connect.facebook.net / instagram / i.instagram / graph.instagram / help.instagram / whatsapp / web.whatsapp / whatsapp.net / threads / messenger / fbcdn / cdninstagram | AS32934 | DigiCert / Meta Platforms |
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

  › Non-login Meta audit: verifies destination ASN/TLS identity only; Meta does not expose the source IP seen by its servers.

  ✓  facebook.com       157.240.•••.•••   AS32934    DigiCert Global G2    ok
  ✓  instagram.com      157.240.•••.•••   AS32934    DigiCert Global G2    ok
  ⚠  whatsapp.com       211.21.•••.•••    AS3462     —                     ASN mismatch
  ⚠  messenger.com      157.240.•••.•••   AS32934    Local Root CA         cert mismatch

  Verdict: 2 mismatches detected
```

### 如何解读 Audit 输出

每个 audit 行最后一列是 `verdict`，含义对照：

| Verdict | 含义 | 是否报警 |
|---|---|---|
| `ok` | ASN 和证书都符合预期 | ✅ 正常 |
| `ok-asn-only` | ASN 符合，本地没装 openssl，无法验证证书 | ⚠️ 弱通过（建议装 openssl 再跑） |
| `ok-cert-only` | 证书符合，但 ASN 查询失败（比如 ipinfo.io 拒绝） | ⚠️ 弱通过 |
| `ASN mismatch` | dest IP 落在预期 ASN 之外 —— **可疑信号**：可能是 DNS/路由层被引到非官方机房，也可能是服务方合法 CDN/云路径变化，需要结合域名与证书复核 | 🟥 报警 |
| `cert mismatch` | ASN 对了，但 TLS 证书 issuer 不是该服务的合法 CA —— **MITM 铁证** | 🟥 报警 |
| `cert fetch failed` | openssl 连不上对端 / 握手失败 | ⚠️ 需要排查 |
| `unreachable` | 连接根本没建立（超时/refused） | ⚠️ 可能是本地网络问题 |
| `inconclusive` | ASN 和证书都没拿到 | ⚠️ 无法判定 |

**判定原则**（per-host short-circuit）：

1. 先看 ASN —— 不符合就直接 `ASN mismatch`，跳过证书检查（第一种方法已经定案，无需再查证书）。
2. ASN 符合才会拉证书，与该 preset 的期望 issuer regex 对比。
3. 出现任何 `ASN mismatch` 或 `cert mismatch` 都应当人工复核 —— 它们对应的劫持形态：
   - `ASN mismatch` → 可能是 **DNS 劫持**（本地 DNS 投毒到本地机房 IP）、**BGP 劫持**（路由层把服务方 IP 段引到别处），也可能是服务方合法使用了新的云/CDN ASN；需要结合证书、HTTP 行为和多地对照复核
   - `cert mismatch` → **DPI/透明代理 MITM**（流量到了真 IP，但被中间盒重新封 TLS）

**给在服务器自动判定的建议**：

```bash
# 跑完只看是否有任何 mismatch
output=$(./routing-ip-check.sh --audit all --no-targets 2>&1)
if grep -qE 'mismatch|unreachable' <<< "$output"; then
  echo "ABNORMAL"
else
  echo "ALL CLEAN"
fi

# 或者解析 JSON 输出（机器友好）
./routing-ip-check.sh --audit meta --json | jq 'select(.kind == "connectivity")'
```

**预期基线**（干净直连环境，无代理无劫持时应该看到）：

| Preset | 期望 verdict 分布 |
|---|---|
| `meta` | 22 个全部 `ok`（或 `ok-asn-only` 当 ipinfo 失败时） |
| `google` | 8 个全部 `ok` |
| `cloudflare` | 5 个全部 `ok`（`1.1.1.1` 的 cert issuer 是 `SSL.com`，已加入白名单） |
| `openai` | 5 个全部 `ok`（CF-fronted） |
| `reddit` | 5 个全部 `ok`（DigiCert/Fastly） |
| `github` | 6 个全部 `ok`（github.com 用 Sectigo，githubusercontent 用 Let's Encrypt R12） |

任何偏离这个基线（特别是出现 `ASN mismatch` / `cert mismatch`）都值得追查。

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
