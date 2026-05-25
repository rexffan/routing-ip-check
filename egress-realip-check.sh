#!/usr/bin/env bash
#
# egress-realip-check.sh
#
# Show the real egress IP observed by remote HTTP services.
#
# Why this exists:
#   mtr/traceroute hops are routers. The first public hop is not necessarily the
#   source IP seen by websites, especially with policy routing, NAT, WARP, proxy,
#   relay, or CDN-specific egress.
#
# Important limitation:
#   A target website must return your client IP for us to know what that exact
#   website sees. For arbitrary domains, no script can prove the site-specific
#   source IP without cooperation from that remote side. For Cloudflare-backed
#   sites, try: --cf example.com

set -u

VERSION="1.5.0"
IP_FLAG="-4"
IP_LABEL="IPv4"
TIMEOUT=8
NO_PROXY=0
PROXY_URL=""
DO_ASN=1
JSON=0
INCLUDE_TARGETS=1
INCLUDE_TARGETS_ALL=0
TARGETS_ADDED=0
CONCURRENCY=1
MASK_IP=1
ASCII_MODE=0
SHOW_VERBOSE=0

# Terminal capability detection
USE_COLOR=1
USE_UNICODE=1
[[ -n "${NO_COLOR:-}" ]] && USE_COLOR=0
[[ "${TERM:-}" == "dumb" || ! -t 1 ]] && { USE_COLOR=0; }
# Default to UTF-8 unless an explicit non-UTF-8 locale is set.
# (Empty LANG is treated as modern UTF-8 — true on most VPSes these days.)
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  C|POSIX|C.*|*8859*|*[Ee][Uu][Cc]*|*[Bb][Ii][Gg]5*|*[Gg][Bb][Kk]*|*[Gg][Bb]2312*|*[Ss][Hh][Ii][Ff][Tt]*[Jj][Ii][Ss]*)
    USE_UNICODE=0 ;;
esac

# Color palette (256-color, falls back to ANSI 8-color)
init_colors() {
  if [[ "$USE_COLOR" -eq 0 ]]; then
    R="" BOLD="" DIM=""
    C_ACCENT="" C_OK="" C_FAIL="" C_WARN="" C_DIM="" C_SUBTLE=""
    return
  fi
  R=$'\033[0m'
  BOLD=$'\033[1m'
  DIM=$'\033[2m'
  # Soft, restrained palette — sage + amber, not primary RGB
  C_ACCENT=$'\033[38;5;108m'   # sage green (titles, accents)
  C_OK=$'\033[38;5;71m'        # success green
  C_FAIL=$'\033[38;5;167m'     # muted clay red
  C_WARN=$'\033[38;5;215m'     # warm amber
  C_DIM=$'\033[38;5;240m'      # mid gray (chrome, borders)
  C_SUBTLE=$'\033[38;5;245m'   # light gray (secondary text)
}

# Glyph set (Unicode → ASCII fallback)
init_glyphs() {
  if [[ "$USE_UNICODE" -eq 1 && "$ASCII_MODE" -eq 0 ]]; then
    G_OK="✓"
    G_FAIL="✗"
    G_WARN="⚠"
    G_BULLET="•"
    G_DASH="─"
    G_VBAR="│"
    G_TL="╭"
    G_TR="╮"
    G_BL="╰"
    G_BR="╯"
    G_DOT="╌"
    G_LEAD="─"
    G_BAR_FILL="▰"
    G_BAR_EMPTY="▱"
    G_TIP="▸"
    G_MASK="•"
  else
    G_OK="+"
    G_FAIL="x"
    G_WARN="!"
    G_BULLET="*"
    G_DASH="-"
    G_VBAR="|"
    G_TL="+"
    G_TR="+"
    G_BL="+"
    G_BR="+"
    G_DOT="-"
    G_LEAD="-"
    G_BAR_FILL="#"
    G_BAR_EMPTY="."
    G_TIP=">"
    G_MASK="x"
  fi
}

# Backwards-compat color refs (legacy code paths still in script).
R="" BOLD="" DIM="" RED="" GREEN="" YELLOW="" BLUE="" CYAN="" GRAY=""
C_ACCENT="" C_OK="" C_FAIL="" C_WARN="" C_DIM="" C_SUBTLE=""
G_OK="" G_FAIL="" G_WARN="" G_BULLET="" G_DASH="" G_VBAR=""
G_TL="" G_TR="" G_BL="" G_BR="" G_DOT="" G_LEAD=""
G_BAR_FILL="" G_BAR_EMPTY="" G_TIP="" G_MASK=""

# Probe entry: name|category|url|kind
#   kind=ipecho       — generic IP echo, scan response body for our IP
#   kind=cf           — Cloudflare /cdn-cgi/trace, strict parse
#   kind=connectivity — reachability probe only (HEAD /), no IP extraction
PROBES=(
  "ipify|IP Echo|https://api.ipify.org|ipecho"
  "ifconfig.me|IP Echo|https://ifconfig.me/ip|ipecho"
  "icanhazip|IP Echo|https://icanhazip.com|ipecho"
  "ident.me|IP Echo|https://ident.me|ipecho"
  "ifconfig.co|IP Echo|https://ifconfig.co/ip|ipecho"
  "ipinfo.io|IP Echo|https://ipinfo.io/ip|ipecho"
  "ip.sb|IP Echo|https://api.ip.sb/ip|ipecho"
  "AWS checkip|Cloud|https://checkip.amazonaws.com|ipecho"
  "Cloudflare trace|CDN Trace|https://www.cloudflare.com/cdn-cgi/trace|cf"
  "Cloudflare 1.1.1.1|CDN Trace|https://one.one.one.one/cdn-cgi/trace|cf"
  "ipip.net|Asia Echo|https://myip.ipip.net|ipecho"
)

TARGET_PROBES=(
  # Global — Cloudflare-confirmed
  "x.com|Social|https://x.com/cdn-cgi/trace|cf"
  "quora.com|Social|https://quora.com/cdn-cgi/trace|cf"
  "wise.com|Finance|https://wise.com/cdn-cgi/trace|cf"
  "revolut.com|Finance|https://revolut.com/cdn-cgi/trace|cf"
  "coinbase.com|Crypto|https://coinbase.com/cdn-cgi/trace|cf"
  "okx.com|Crypto|https://okx.com/cdn-cgi/trace|cf"
  "kraken.com|Crypto|https://kraken.com/cdn-cgi/trace|cf"
  "openai.com|AI/Work|https://openai.com/cdn-cgi/trace|cf"
  "canva.com|AI/Work|https://canva.com/cdn-cgi/trace|cf"
  "notion.so|AI/Work|https://notion.so/cdn-cgi/trace|cf"
  # Taiwan — Cloudflare-confirmed
  "Dcard|TW Forum|https://dcard.tw/cdn-cgi/trace|cf"
  "Bahamut|TW Forum|https://www.gamer.com.tw/cdn-cgi/trace|cf"
  "Plurk|TW Forum|https://www.plurk.com/cdn-cgi/trace|cf"
  "PanSci|TW Media|https://pansci.asia/cdn-cgi/trace|cf"
  "中時新聞網|TW Media|https://www.chinatimes.com/cdn-cgi/trace|cf"
  "104 人力銀行|TW Career|https://www.104.com.tw/cdn-cgi/trace|cf"
  "StockFeel 股感|TW Finance|https://www.stockfeel.com.tw/cdn-cgi/trace|cf"
  "LINE Bank TW|TW Finance|https://www.linebank.com.tw/cdn-cgi/trace|cf"
  "PX Pay|TW Finance|https://www.pxpay.com/cdn-cgi/trace|cf"
  "MaiCoin|TW Crypto|https://www.maicoin.com/cdn-cgi/trace|cf"
  "MAX Exchange|TW Crypto|https://max.maicoin.com/cdn-cgi/trace|cf"
  "博客來 Books|TW Shopping|https://www.books.com.tw/cdn-cgi/trace|cf"
  "露天市集 Ruten|TW Shopping|https://www.ruten.com.tw/cdn-cgi/trace|cf"
  "Buy123|TW Shopping|https://www.buy123.com.tw/cdn-cgi/trace|cf"
  "citiesocial|TW Shopping|https://www.citiesocial.com/cdn-cgi/trace|cf"
)

# CONNECTIVITY_PROBES — only run with --targets-all.
# These hit the site root (HEAD /) for pure reachability diagnostics — they
# can NOT report your egress IP (the site doesn't echo it). What they do show:
#   • whether your egress can reach this domain at all (connect-timeout vs 200)
#   • whether route to this domain is split / blocked / via a CGN/proxy
#   • the destination IP we connected to (helps spot DNS or anycast routing)
# Reclassified from the old "guess" CF-trace probes after we confirmed almost
# none of these are actually on Cloudflare.
CONNECTIVITY_PROBES=(
  # Global
  "twitter.com|Social|https://twitter.com/|connectivity"
  "linkedin.com|Social|https://www.linkedin.com/|connectivity"
  "medium.com|Social|https://medium.com/|connectivity"
  "facebook.com|Social|https://www.facebook.com/|connectivity"
  "instagram.com|Social|https://www.instagram.com/|connectivity"
  "paypal.com|Finance|https://www.paypal.com/|connectivity"
  "amazon.com|Shopping|https://www.amazon.com/|connectivity"
  "temu.com|Shopping|https://www.temu.com/|connectivity"
  "shopify.com|Shopping|https://www.shopify.com/|connectivity"
  "ikea.com|Shopping|https://www.ikea.com/|connectivity"
  # Taiwan — Forums / community
  "Mobile01|TW Forum|https://www.mobile01.com/|connectivity"
  "PTT 批踢踢|TW Forum|https://www.ptt.cc/|connectivity"
  "PIXNET 痞客邦|TW Forum|https://www.pixnet.net/|connectivity"
  # Taiwan — Media / news
  "聯合新聞網 UDN|TW Media|https://udn.com/|connectivity"
  "自由時報 LTN|TW Media|https://www.ltn.com.tw/|connectivity"
  "ETtoday|TW Media|https://www.ettoday.net/|connectivity"
  "TVBS|TW Media|https://news.tvbs.com.tw/|connectivity"
  "民視 FTV|TW Media|https://www.ftvnews.com.tw/|connectivity"
  # Taiwan — Finance / banks
  "玉山銀行 E.SUN|TW Finance|https://www.esunbank.com.tw/|connectivity"
  "國泰世華|TW Finance|https://www.cathaybk.com.tw/|connectivity"
  "中國信託 CTBC|TW Finance|https://www.ctbcbank.com/|connectivity"
  "富邦銀行|TW Finance|https://www.fubon.com/|connectivity"
  "兆豐銀行|TW Finance|https://www.megabank.com.tw/|connectivity"
  "台灣銀行|TW Finance|https://www.bot.com.tw/|connectivity"
  "永豐銀行 SinoPac|TW Finance|https://bank.sinopac.com/|connectivity"
  "台新銀行|TW Finance|https://www.taishinbank.com.tw/|connectivity"
  "第一銀行|TW Finance|https://www.firstbank.com.tw/|connectivity"
  "MoneyDJ 理財網|TW Finance|https://www.moneydj.com/|connectivity"
  "鉅亨網 cnYES|TW Finance|https://www.cnyes.com/|connectivity"
  # Taiwan — Government / public
  "總統府|TW Gov|https://www.president.gov.tw/|connectivity"
  "行政院|TW Gov|https://www.ey.gov.tw/|connectivity"
  "立法院|TW Gov|https://www.ly.gov.tw/|connectivity"
  "司法院|TW Gov|https://www.judicial.gov.tw/|connectivity"
  "內政部|TW Gov|https://www.moi.gov.tw/|connectivity"
  "財政部|TW Gov|https://www.mof.gov.tw/|connectivity"
  "衛福部|TW Gov|https://www.mohw.gov.tw/|connectivity"
  "教育部|TW Gov|https://www.moe.gov.tw/|connectivity"
  "健保署 NHI|TW Gov|https://www.nhi.gov.tw/|connectivity"
  "疾管署 CDC|TW Gov|https://www.cdc.gov.tw/|connectivity"
  "國稅局|TW Gov|https://www.etax.nat.gov.tw/|connectivity"
  "中華郵政|TW Gov|https://www.post.gov.tw/|connectivity"
  # Taiwan — Telecom / ISP
  "中華電信|TW Telecom|https://www.cht.com.tw/|connectivity"
  "台灣大哥大|TW Telecom|https://www.taiwanmobile.com/|connectivity"
  "遠傳電信|TW Telecom|https://www.fetnet.net/|connectivity"
  # Taiwan — Career / shopping fallbacks
  "1111 人力銀行|TW Career|https://www.1111.com.tw/|connectivity"
  "591 房屋|TW Shopping|https://www.591.com.tw/|connectivity"
  "momoshop|TW Shopping|https://www.momoshop.com.tw/|connectivity"
  "PChome|TW Shopping|https://24h.pchome.com.tw/|connectivity"
  "Shopee 蝦皮|TW Shopping|https://shopee.tw/|connectivity"
  # Taiwan — Transport / ticketing
  "高鐵 THSR|TW Transport|https://www.thsrc.com.tw/|connectivity"
  "台鐵 TRA|TW Transport|https://www.railway.gov.tw/|connectivity"
  "悠遊卡|TW Transport|https://www.easycard.com.tw/|connectivity"
  # Misc
  "KKBOX|TW Media|https://www.kkbox.com/|connectivity"
  "LINE|TW App|https://line.me/|connectivity"
)

# Legacy alias — older code paths may still reference TARGET_ALL_PROBES.
TARGET_ALL_PROBES=("${CONNECTIVITY_PROBES[@]}")

usage() {
  cat <<'EOF'
Usage:
  egress-realip-check.sh [options]

Options:
  -4, --ipv4              Force IPv4 checks (default)
  -6, --ipv6              Force IPv6 checks
  -t, --timeout SECONDS   Per-request timeout (default: 8)
      --no-proxy          Ignore proxy environment variables for curl
      --proxy URL         Use a curl proxy, for example socks5h://127.0.0.1:1080
      --no-asn            Do not query ISP/ASN metadata
      --json              Print machine-readable JSON lines (always full IP)
      --targets           Include categorized target-site probes (default)
      --targets-all       Include unconfirmed target probes too (TW gov, banks, forums...)
      --no-targets        Only run the basic IP echo probes
      --concurrency N     Number of concurrent probes (default: 1)
      --no-concurrency    Run probes serially
      --add NAME=URL      Add a custom IP echo URL
      --cf HOST           Add Cloudflare trace probe: https://HOST/cdn-cgi/trace
      --connectivity HOST Add a reachability probe (HEAD https://HOST/)
      --file FILE         Add probes from FILE — "name|url" or "name|cat|url"
                          or "name|cat|url|kind" (kind: ipecho|cf|connectivity)
      --show-ip           Reveal full IP addresses (default: mask last 2 segments)
      --ascii             Disable Unicode glyphs and box-drawing (ASCII-only)
      --verbose           Show the URL column in the results table
  -h, --help              Show help

Environment:
  NO_COLOR=1              Disable ANSI colors entirely.

Examples:
  ./egress-realip-check.sh -4
  ./egress-realip-check.sh --no-proxy
  ./egress-realip-check.sh --proxy socks5h://127.0.0.1:1080
  ./egress-realip-check.sh --targets-all
  ./egress-realip-check.sh --concurrency 8
  ./egress-realip-check.sh --show-ip
  ./egress-realip-check.sh --cf example.com
  ./egress-realip-check.sh --add "my echo=https://echo.example.com/ip"

Notes:
  This script measures the real source IP seen by remote HTTP endpoints.
  It does not use mtr/traceroute, because route hops are not egress source IPs.
  By default the last 2 octets (IPv4) or hextets (IPv6) are masked so screenshots
  are safer to share. Use --show-ip when you actually need the full address.
EOF
}

die() {
  printf '%sError:%s %s\n' "${C_FAIL:-$'\033[31m'}" "${R:-$'\033[0m'}" "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

strip_url_host() {
  printf '%s' "$1" | sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://([^/:?#]+).*#\1#'
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g'
}

clean_field() {
  printf '%s' "$1" | tr '\r\n|' '   ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
}

add_probe() {
  local name="$1" cat="$2" url="$3" kind="${4:-ipecho}"
  [[ -n "$name" ]] || die "probe name is empty"
  [[ "$url" =~ ^https?:// ]] || die "probe URL must start with http:// or https://: $url"
  case "$kind" in
    ipecho|cf|connectivity) ;;
    *) die "probe kind must be one of: ipecho, cf, connectivity (got: $kind)" ;;
  esac
  PROBES+=("$(clean_field "$name")|$(clean_field "$cat")|$(clean_field "$url")|$kind")
}

add_probe_file() {
  local file="$1"
  [[ -f "$file" ]] || die "probe file not found: $file"

  # Supported line formats (pipe-separated, comments start with #):
  #   name|url
  #   name|category|url
  #   name|category|url|kind        (kind ∈ ipecho|cf|connectivity)
  local line name cat url kind
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=$(printf '%s' "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    [[ -z "$line" || "$line" == \#* ]] && continue

    IFS='|' read -r name cat url kind _ <<< "$line"
    if [[ -z "${url:-}" ]]; then
      if [[ -z "${cat:-}" ]]; then
        printf 'warning: skipping bad line in %s: %s\n' "$file" "$line" >&2
        continue
      fi
      url="$cat"
      cat="Custom"
    fi
    if [[ -z "$name" || ! "$url" =~ ^https?:// ]]; then
      printf 'warning: skipping bad line in %s: %s\n' "$file" "$line" >&2
      continue
    fi
    case "${kind:-ipecho}" in
      ipecho|cf|connectivity) ;;
      *)
        printf 'warning: skipping bad line in %s: %s\n' "$file" "$line" >&2
        continue
        ;;
    esac
    add_probe "$name" "$cat" "$url" "${kind:-ipecho}"
  done < "$file"
}

add_target_probes() {
  local entry
  [[ "$TARGETS_ADDED" -eq 1 ]] && return
  for entry in "${TARGET_PROBES[@]}"; do
    PROBES+=("$entry")
  done
  if [[ "$INCLUDE_TARGETS_ALL" -eq 1 ]]; then
    for entry in "${CONNECTIVITY_PROBES[@]}"; do
      PROBES+=("$entry")
    done
  fi
  TARGETS_ADDED=1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -4|--ipv4)
      IP_FLAG="-4"
      IP_LABEL="IPv4"
      shift
      ;;
    -6|--ipv6)
      IP_FLAG="-6"
      IP_LABEL="IPv6"
      shift
      ;;
    -t|--timeout)
      [[ $# -ge 2 ]] || die "--timeout needs a value"
      TIMEOUT="$2"
      [[ "$TIMEOUT" =~ ^[0-9]+$ ]] || die "--timeout must be an integer"
      shift 2
      ;;
    --no-proxy)
      NO_PROXY=1
      shift
      ;;
    --proxy)
      [[ $# -ge 2 ]] || die "--proxy needs a value"
      PROXY_URL="$2"
      shift 2
      ;;
    --no-asn)
      DO_ASN=0
      shift
      ;;
    --json)
      JSON=1
      shift
      ;;
    --targets)
      INCLUDE_TARGETS=1
      shift
      ;;
    --targets-all)
      INCLUDE_TARGETS=1
      INCLUDE_TARGETS_ALL=1
      shift
      ;;
    --no-targets)
      INCLUDE_TARGETS=0
      shift
      ;;
    --concurrency)
      [[ $# -ge 2 ]] || die "--concurrency needs a value"
      CONCURRENCY="$2"
      [[ "$CONCURRENCY" =~ ^[0-9]+$ && "$CONCURRENCY" -ge 1 ]] || die "--concurrency must be a positive integer"
      shift 2
      ;;
    --no-concurrency)
      CONCURRENCY=1
      shift
      ;;
    --add)
      [[ $# -ge 2 ]] || die "--add needs NAME=URL"
      [[ "$2" == *=* ]] || die "--add expects NAME=URL"
      add_probe "${2%%=*}" "Custom" "${2#*=}"
      shift 2
      ;;
    --cf)
      [[ $# -ge 2 ]] || die "--cf needs a host"
      add_probe "$2 Cloudflare trace" "CDN Trace" "https://$2/cdn-cgi/trace" "cf"
      shift 2
      ;;
    --connectivity)
      [[ $# -ge 2 ]] || die "--connectivity needs a host"
      add_probe "$2" "Custom" "https://$2/" "connectivity"
      shift 2
      ;;
    --file)
      [[ $# -ge 2 ]] || die "--file needs a path"
      add_probe_file "$2"
      shift 2
      ;;
    --show-ip)
      MASK_IP=0
      shift
      ;;
    --mask-ip)
      MASK_IP=1
      shift
      ;;
    --ascii)
      ASCII_MODE=1
      USE_UNICODE=0
      shift
      ;;
    --verbose)
      SHOW_VERBOSE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --version)
      printf '%s\n' "$VERSION"
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

if [[ "$INCLUDE_TARGETS" -eq 1 ]]; then
  add_target_probes
fi

# JSON output is machine-consumed: force plain mode regardless of stdout TTY.
if [[ "$JSON" -eq 1 ]]; then
  USE_COLOR=0
  USE_UNICODE=0
fi

init_colors
init_glyphs

need_cmd curl
need_cmd sed
need_cmd awk
need_cmd grep
need_cmd sort

# mask_ip — hide the last two segments of an IP for safer screenshot sharing.
#   IPv4: 203.0.113.42      → 203.0.•.•
#   IPv6: 2001:db8:abcd:... → 2001:db8:abcd:1234:5678:9abc:••••:••••
# Returns the input unchanged when MASK_IP=0 or when the value doesn't look
# like an IP. JSON output never calls this.
mask_ip() {
  local ip="$1"
  [[ -z "$ip" || "$MASK_IP" -eq 0 ]] && { printf '%s' "$ip"; return; }

  if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    local a b
    IFS='.' read -r a b _ _ <<< "$ip"
    printf '%s.%s.%s.%s' "$a" "$b" "$G_MASK$G_MASK$G_MASK" "$G_MASK$G_MASK$G_MASK"
    return
  fi

  # IPv6 — expand :: shorthand into the right number of empty groups, then
  # mask the last two 16-bit hextets.
  if [[ "$ip" == *:* ]]; then
    local expanded groups n missing i out
    if [[ "$ip" == *"::"* ]]; then
      local left right
      left="${ip%%::*}"
      right="${ip#*::}"
      local lcount=0 rcount=0
      [[ -n "$left" ]] && lcount=$(awk -F: '{print NF}' <<< "$left")
      [[ -n "$right" ]] && rcount=$(awk -F: '{print NF}' <<< "$right")
      missing=$((8 - lcount - rcount))
      [[ "$missing" -lt 0 ]] && missing=0
      expanded="$left"
      for ((i=0; i<missing; i++)); do
        expanded="${expanded}:0"
      done
      [[ -n "$right" ]] && expanded="${expanded}:${right}"
      expanded="${expanded#:}"
    else
      expanded="$ip"
    fi
    groups=()
    IFS=':' read -ra groups <<< "$expanded"
    n=${#groups[@]}
    if [[ "$n" -ge 2 ]]; then
      groups[n-1]="$G_MASK$G_MASK$G_MASK$G_MASK"
      groups[n-2]="$G_MASK$G_MASK$G_MASK$G_MASK"
    fi
    out=""
    for ((i=0; i<n; i++)); do
      [[ -n "$out" ]] && out="${out}:"
      out="${out}${groups[i]}"
    done
    printf '%s' "$out"
    return
  fi

  printf '%s' "$ip"
}

TMP_ROWS=$(mktemp)
TMP_DIR=$(mktemp -d)
trap 'rm -f "$TMP_ROWS"; rm -rf "$TMP_DIR"' EXIT

curl_common=(
  --silent
  --show-error
  --location
  --max-time "$TIMEOUT"
  --connect-timeout "$TIMEOUT"
  --user-agent "Mozilla/5.0 (compatible; egress-realip-check/$VERSION; +https://github.com/rexffan/egress-realip-check)"
)

if [[ "$NO_PROXY" -eq 1 ]]; then
  curl_common+=(--noproxy '*')
fi

if [[ -n "$PROXY_URL" ]]; then
  curl_common+=(--proxy "$PROXY_URL")
fi

is_bogon_ipv4() {
  local ip="$1" a b c d
  IFS='.' read -r a b c d <<< "$ip"
  [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ && "$c" =~ ^[0-9]+$ && "$d" =~ ^[0-9]+$ ]] || return 0
  [[ "$a" -le 255 && "$b" -le 255 && "$c" -le 255 && "$d" -le 255 ]] || return 0
  [[ "$a" -eq 0 || "$a" -eq 10 || "$a" -eq 127 ]] && return 0
  [[ "$a" -eq 169 && "$b" -eq 254 ]] && return 0
  [[ "$a" -eq 172 && "$b" -ge 16 && "$b" -le 31 ]] && return 0
  [[ "$a" -eq 192 && "$b" -eq 168 ]] && return 0
  [[ "$a" -eq 100 && "$b" -ge 64 && "$b" -le 127 ]] && return 0
  [[ "$a" -eq 198 && "$b" -eq 18 ]] && return 0
  [[ "$a" -eq 192 && "$b" -eq 0 && "$c" -eq 2 ]] && return 0
  [[ "$a" -eq 198 && "$b" -eq 51 && "$c" -eq 100 ]] && return 0
  [[ "$a" -eq 203 && "$b" -eq 0 && "$c" -eq 113 ]] && return 0
  [[ "$a" -ge 224 ]] && return 0
  return 1
}

is_bogon_ipv6() {
  local ip
  ip=$(printf '%s' "$1" | tr 'A-F' 'a-f')
  [[ "$ip" == "::" || "$ip" == "::1" || "$ip" == "0:0:0:0:0:0:0:1" ]] && return 0
  [[ "$ip" =~ ^f[c-d] ]] && return 0
  [[ "$ip" =~ ^fe[89ab] ]] && return 0
  [[ "$ip" =~ ^2001:db8: ]] && return 0
  return 1
}

is_bogon_ip() {
  local ip="$1"
  if [[ "$IP_FLAG" == "-4" ]]; then
    is_bogon_ipv4 "$ip"
  else
    is_bogon_ipv6 "$ip"
  fi
}

extract_ip() {
  local body="$1" url="$2" candidate saw_bogon ip
  saw_bogon=0

  if [[ "$url" == *"/cdn-cgi/trace"* ]]; then
    if ! printf '%s\n' "$body" | grep -Eq '^(fl|h)='; then
      printf '|not-cf-trace'
      return
    fi
    ip=$(printf '%s\n' "$body" | awk -F= '$1=="ip"{print $2; exit}')
    if [[ -z "$ip" ]]; then
      printf '|no-ip-in-body'
      return
    fi
    if is_bogon_ip "$ip"; then
      printf '|bogon-ip'
      return
    fi
    printf '%s|' "$ip"
    return
  fi

  if [[ "$IP_FLAG" == "-4" ]]; then
    while IFS= read -r candidate; do
      [[ -z "$candidate" ]] && continue
      if is_bogon_ip "$candidate"; then
        saw_bogon=1
        continue
      fi
      printf '%s|' "$candidate"
      return
    done < <(printf '%s\n' "$body" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | awk -F. '($1<=255 && $2<=255 && $3<=255 && $4<=255){print}')
  else
    while IFS= read -r candidate; do
      [[ -z "$candidate" ]] && continue
      if is_bogon_ip "$candidate"; then
        saw_bogon=1
        continue
      fi
      printf '%s|' "$candidate"
      return
    done < <(printf '%s\n' "$body" | grep -Eio '([0-9a-f]{1,4}:){2,7}[0-9a-f]{0,4}|::1')
  fi

  if [[ "$saw_bogon" -eq 1 ]]; then
    printf '|bogon-ip'
  else
    printf '|no-ip-in-body'
  fi
}

declare -A ASN_CACHE=()

asn_lookup() {
  local ip="$1" info org country isp asn status cache_key
  cache_key="$ip"

  if [[ "$DO_ASN" -eq 0 ]]; then
    printf '|||'
    return
  fi

  if [[ -n "${ASN_CACHE[$cache_key]+x}" ]]; then
    printf '%s' "${ASN_CACHE[$cache_key]}"
    return
  fi

  info=$(curl --silent --show-error --max-time 5 "https://ipinfo.io/$ip/json" 2>/dev/null || true)
  org=$(printf '%s\n' "$info" | sed -nE 's/.*"org"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -1)
  country=$(printf '%s\n' "$info" | sed -nE 's/.*"country"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -1)

  if [[ -n "$org" ]]; then
    asn="${org%% *}"
    isp="$org"
    [[ "$isp" == "$asn" ]] && isp="N/A"
    [[ "$isp" != "N/A" ]] && isp="${isp#"$asn"}" && isp="${isp# }"
    [[ -z "$country" ]] && country="N/A"
    ASN_CACHE[$cache_key]="$(clean_field "$country")|$(clean_field "$isp")|$(clean_field "$asn")"
    printf '%s' "${ASN_CACHE[$cache_key]}"
    return
  fi

  info=$(curl --silent --show-error --max-time 5 \
    "http://ip-api.com/line/$ip?fields=status,country,isp,as" 2>/dev/null || true)

  status=$(printf '%s\n' "$info" | sed -n '1p')
  country=$(printf '%s\n' "$info" | sed -n '2p')
  isp=$(printf '%s\n' "$info" | sed -n '3p')
  asn=$(printf '%s\n' "$info" | sed -n '4p')

  if [[ "$status" != "success" ]]; then
    ASN_CACHE[$cache_key]="N/A|N/A|N/A"
  else
    ASN_CACHE[$cache_key]="$(clean_field "$country")|$(clean_field "$isp")|$(clean_field "$asn")"
  fi

  printf '%s' "${ASN_CACHE[$cache_key]}"
}

probe_one() {
  local name="$1" cat="$2" url="$3" kind="${4:-ipecho}"
  case "$kind" in
    connectivity) probe_connectivity "$name" "$cat" "$url" ;;
    *)            probe_egress "$name" "$cat" "$url" "$kind" ;;
  esac
}

# Egress IP probe — actually reveals our outbound IP via remote echo / CF trace.
probe_egress() {
  local name="$1" cat="$2" url="$3" kind="$4"
  local host body_file body meta rc http_code remote_ip ip_result ip reason status

  host=$(strip_url_host "$url")
  body_file=$(mktemp "$TMP_DIR/body.XXXXXX")
  meta=$(curl "${curl_common[@]}" "$IP_FLAG" -o "$body_file" \
    --write-out 'http=%{http_code}\nremote=%{remote_ip}\n' "$url" 2>/dev/null)
  rc=$?
  body=$(<"$body_file")
  rm -f "$body_file"

  http_code=$(printf '%s\n' "$meta" | sed -n 's/^http=//p' | tail -1)
  remote_ip=$(printf '%s\n' "$meta" | sed -n 's/^remote=//p' | tail -1)
  [[ -z "$http_code" ]] && http_code="000"

  ip=""
  reason=""

  if [[ "$http_code" =~ ^[1-9][0-9][0-9]$ && ! "$http_code" =~ ^2 ]]; then
    status="FAIL"
    reason="http-status-$http_code"
  elif [[ "$rc" -ne 0 ]]; then
    status="FAIL"
    if [[ "$rc" -eq 28 ]]; then
      reason="connect-timeout"
    else
      reason="curl-error-$rc"
    fi
  else
    ip_result=$(extract_ip "$body" "$url")
    IFS='|' read -r ip reason <<< "$ip_result"
    if [[ -z "$ip" ]]; then
      status="FAIL"
      [[ -z "$reason" ]] && reason="no-ip-in-body"
    else
      status="OK"
    fi
  fi

  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "$status" "$(clean_field "$name")" "$(clean_field "$cat")" "$(clean_field "$host")" \
    "$(clean_field "$url")" "$(clean_field "$ip")" "" "" "" \
    "$(clean_field "$http_code")" "$(clean_field "$reason")" "$(clean_field "$remote_ip")" \
    "egress" "" ""
}

# Connectivity probe — only checks reachability. Records HTTP status, Server
# header, TTFB and the destination IP we actually connected to. Does NOT
# attempt to learn our egress IP — the target wouldn't echo it.
probe_connectivity() {
  local name="$1" cat="$2" url="$3"
  local host body_file meta rc http_code remote_ip ttfb server status reason ttfb_ms

  host=$(strip_url_host "$url")
  body_file=$(mktemp "$TMP_DIR/body.XXXXXX")
  # -I sends a HEAD; --max-filesize keeps us safe if a misconfigured server
  # streams a body anyway. Capture headers via -D for the Server: lookup.
  meta=$(curl "${curl_common[@]}" "$IP_FLAG" -I -D "$body_file" -o /dev/null \
    --write-out 'http=%{http_code}\nremote=%{remote_ip}\nttfb=%{time_starttransfer}\n' \
    "$url" 2>/dev/null)
  rc=$?

  http_code=$(printf '%s\n' "$meta" | sed -n 's/^http=//p' | tail -1)
  remote_ip=$(printf '%s\n' "$meta" | sed -n 's/^remote=//p' | tail -1)
  ttfb=$(printf '%s\n' "$meta" | sed -n 's/^ttfb=//p' | tail -1)
  [[ -z "$http_code" ]] && http_code="000"

  server=$(grep -iE '^Server:' "$body_file" 2>/dev/null | head -1 | \
    sed -E 's/^[Ss]erver:[[:space:]]*//; s/[[:space:]]*$//; s/\r$//')
  rm -f "$body_file"

  ttfb_ms=""
  if [[ -n "$ttfb" ]]; then
    ttfb_ms=$(awk -v t="$ttfb" 'BEGIN{printf "%d", t*1000}')
  fi

  # Any HTTP response (incl. 4xx/5xx) means we reached the server — that's a
  # successful connectivity result. Only network-layer failures are FAIL.
  if [[ "$http_code" != "000" ]]; then
    status="OK"
    reason="$http_code"
  elif [[ "$rc" -eq 28 ]]; then
    status="FAIL"
    reason="connect-timeout"
  elif [[ "$rc" -ne 0 ]]; then
    status="FAIL"
    reason="curl-error-$rc"
  else
    status="FAIL"
    reason="no-response"
  fi

  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "$status" "$(clean_field "$name")" "$(clean_field "$cat")" "$(clean_field "$host")" \
    "$(clean_field "$url")" "" "" "" "" \
    "$(clean_field "$http_code")" "$(clean_field "$reason")" "$(clean_field "$remote_ip")" \
    "connectivity" "$(clean_field "$server")" "$(clean_field "$ttfb_ms")"
}

enrich_rows() {
  local enriched status name cat host url ip isp asn country http_code reason remote_ip kind server ttfb_ms meta
  enriched=$(mktemp)

  while IFS='|' read -r status name cat host url ip isp asn country http_code reason remote_ip kind server ttfb_ms; do
    if [[ "$status" == "OK" && -n "$ip" ]]; then
      meta=$(asn_lookup "$ip")
      IFS='|' read -r country isp asn <<< "$meta"
    fi
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
      "$status" "$name" "$cat" "$host" "$url" "$ip" "$isp" "$asn" "$country" \
      "$http_code" "$reason" "$remote_ip" "$kind" "$server" "$ttfb_ms" >> "$enriched"
  done < "$TMP_ROWS"

  mv "$enriched" "$TMP_ROWS"
}

repeat_str() {
  local s="$1" n="$2" out=""
  while [[ "$n" -gt 0 ]]; do
    out="${out}${s}"
    n=$((n - 1))
  done
  printf '%s' "$out"
}

# Visual character width.
# Bash 5+ ${#var} already counts characters (not bytes) for UTF-8 strings even
# under a "C" parent locale, so this is just an alias. On bash < 4 the box
# alignment may be off by a handful of columns; we accept that.
visual_width() {
  printf '%s' "${#1}"
}

# Visual-width truncate (byte-aware; mostly safe for ASCII).
# Adds an ellipsis-like indicator when truncated.
trunc() {
  local s="$1" n="$2"
  if [[ ${#s} -gt $n ]]; then
    printf '%s…' "${s:0:n-1}"
  else
    printf '%s' "$s"
  fi
}

print_header() {
  local title="Egress Real-IP Check"
  local meta=" ${IP_LABEL}  ${G_BULLET}  "
  local mode
  if [[ "$NO_PROXY" -eq 1 ]]; then
    mode="no-proxy"
  elif [[ -n "$PROXY_URL" ]]; then
    mode="proxy"
  else
    mode="direct"
  fi
  meta="${meta}${mode}  ${G_BULLET}  ${#PROBES[@]} probes  ${G_BULLET}  ${CONCURRENCY} worker$([[ $CONCURRENCY -gt 1 ]] && echo s)"
  [[ "$MASK_IP" -eq 1 ]] && meta="${meta}  ${G_BULLET}  masked"

  # Compute box width based on the longer of title/meta (visible width, not bytes).
  local inner_w title_w meta_w
  title_w=$(visual_width "$title")
  meta_w=$(visual_width "$meta")
  inner_w=$title_w
  [[ $meta_w -gt $inner_w ]] && inner_w=$meta_w
  inner_w=$((inner_w + 4))
  # Visible layout: '╭─ TITLE pad─╮' (3 chrome chars between dashes and title)
  #                 '│ META pad │' (2 chrome spaces — one each side)
  local pad_title=$((inner_w - title_w - 3))
  local pad_meta=$((inner_w - meta_w - 1))
  [[ $pad_title -lt 0 ]] && pad_title=0
  [[ $pad_meta -lt 0 ]] && pad_meta=0
  local hbar
  hbar=$(repeat_str "$G_DASH" "$inner_w")

  printf '\n'
  printf '%s%s%s %s%s%s %s%s\n' \
    "$C_DIM" "$G_TL$G_DASH" "$R" \
    "$C_ACCENT$BOLD" "$title" "$R" \
    "$C_DIM$(repeat_str "$G_DASH" "$pad_title")$G_TR$R" ""
  printf '%s%s%s %s%s%s%s%s\n' \
    "$C_DIM" "$G_VBAR" "$R" \
    "$C_SUBTLE" "$meta" "$R" \
    "$C_DIM" "$(repeat_str ' ' "$pad_meta")$G_VBAR$R"
  printf '%s%s%s%s\n' "$C_DIM" "$G_BL" "$hbar$G_BR" "$R"
  printf '\n'
}

print_egress_row() {
  local status="$1" name="$2" cat="$3" ip="$4" isp="$5" asn="$6" country="$7" reason="$8" url="$9"
  local total_w_name=22 total_w_cat=12 total_w_ip=18
  local glyph color name_color masked

  if [[ "$status" == "OK" ]]; then
    glyph="$G_OK"; color="$C_OK"; name_color=""
  else
    glyph="$G_FAIL"; color="$C_FAIL"; name_color="$C_DIM"
  fi

  name=$(trunc "$name" "$total_w_name")
  cat=$(trunc "$cat" "$total_w_cat")

  if [[ "$status" == "OK" && -n "$ip" ]]; then
    masked=$(mask_ip "$ip")
    local netinfo="" right=""
    [[ -n "$asn" && "$asn" != "N/A" ]] && netinfo="$asn"
    if [[ -n "$isp" && "$isp" != "N/A" ]]; then
      local short_isp
      short_isp=$(trunc "$isp" 26)
      [[ -n "$netinfo" ]] && netinfo="$netinfo $short_isp" || netinfo="$short_isp"
    fi
    [[ -n "$country" && "$country" != "N/A" ]] && right="$country"
    [[ -n "$netinfo" ]] && right="${right:+$right $G_BULLET }$netinfo"

    printf '  %s%s%s  %-*s  %s%-*s%s  %s%-*s%s  %s%s%s\n' \
      "$color" "$glyph" "$R" \
      "$total_w_name" "$name" \
      "$C_SUBTLE" "$total_w_cat" "$cat" "$R" \
      "$BOLD" "$total_w_ip" "$masked" "$R" \
      "$C_SUBTLE" "$right" "$R"
  else
    local why="${reason:-no-data}"
    printf '  %s%s%s  %s%-*s%s  %s%-*s%s  %s%s %s%s\n' \
      "$color" "$glyph" "$R" \
      "$name_color" "$total_w_name" "$name" "$R" \
      "$C_DIM" "$total_w_cat" "$cat" "$R" \
      "$C_DIM" "$G_LEAD" "$why" "$R"
  fi

  if [[ "$SHOW_VERBOSE" -eq 1 ]]; then
    printf '     %s%s %s%s\n' "$C_DIM" "$G_DOT" "$url" "$R"
  fi
}

# Connectivity probes — different semantics, different layout.
# Glyph + color encodes HTTP outcome:
#   2xx → green ✓        (clean response)
#   3xx → amber ✓        (redirect)
#   4xx/5xx → amber ✓    (reachable but blocked/erroring — TLS handshake worked)
#   timeout/refused → red ✗
print_conn_row() {
  local status="$1" name="$2" cat="$3" http_code="$4" reason="$5" remote_ip="$6" server="$7" ttfb_ms="$8" url="$9"
  local total_w_name=22 total_w_cat=12 total_w_code=4 total_w_rip=16
  local glyph color

  if [[ "$status" != "OK" ]]; then
    glyph="$G_FAIL"; color="$C_FAIL"
  else
    case "$http_code" in
      2*) glyph="$G_OK"; color="$C_OK" ;;
      3*) glyph="$G_OK"; color="$C_WARN" ;;
      4*|5*) glyph="$G_OK"; color="$C_WARN" ;;
      *)  glyph="$G_OK"; color="$C_SUBTLE" ;;
    esac
  fi

  name=$(trunc "$name" "$total_w_name")
  cat=$(trunc "$cat" "$total_w_cat")
  local code_disp="$http_code"
  [[ "$status" != "OK" ]] && code_disp="—"

  local masked_dst=""
  [[ -n "$remote_ip" ]] && masked_dst=$(mask_ip "$remote_ip")

  local right_bits=""
  [[ -n "$ttfb_ms" && "$ttfb_ms" -gt 0 ]] && right_bits="${ttfb_ms}ms"
  if [[ -n "$server" ]]; then
    local short_server
    short_server=$(trunc "$server" 22)
    [[ -n "$right_bits" ]] && right_bits="$right_bits $G_BULLET $short_server" || right_bits="$short_server"
  fi
  if [[ "$status" != "OK" ]]; then
    right_bits="$reason"
  fi

  printf '  %s%s%s  %-*s  %s%-*s%s  %s%-*s%s  %s%-*s%s  %s%s%s\n' \
    "$color" "$glyph" "$R" \
    "$total_w_name" "$name" \
    "$C_SUBTLE" "$total_w_cat" "$cat" "$R" \
    "$BOLD" "$total_w_code" "$code_disp" "$R" \
    "$C_SUBTLE" "$total_w_rip" "${masked_dst:-—}" "$R" \
    "$C_SUBTLE" "$right_bits" "$R"

  if [[ "$SHOW_VERBOSE" -eq 1 ]]; then
    printf '     %s%s %s%s\n' "$C_DIM" "$G_DOT" "$url" "$R"
  fi
}

print_table() {
  local has_egress has_conn
  has_egress=$(awk -F'|' '$13!="connectivity"{print; exit}' "$TMP_ROWS")
  has_conn=$(awk -F'|' '$13=="connectivity"{print; exit}' "$TMP_ROWS")

  if [[ -n "$has_egress" ]]; then
    section_header "Egress IP Probes"
    while IFS='|' read -r status name cat host url ip isp asn country http_code reason remote_ip kind server ttfb_ms; do
      [[ "$kind" == "connectivity" ]] && continue
      print_egress_row "$status" "$name" "$cat" "$ip" "$isp" "$asn" "$country" "$reason" "$url"
    done < "$TMP_ROWS"
  fi

  if [[ -n "$has_conn" ]]; then
    section_header "Connectivity Probes"
    printf '  %s%s%s %sReachability only — these targets do NOT report your egress IP.%s\n' \
      "$C_DIM" "$G_TIP" "$R" "$C_DIM" "$R"
    while IFS='|' read -r status name cat host url ip isp asn country http_code reason remote_ip kind server ttfb_ms; do
      [[ "$kind" != "connectivity" ]] && continue
      print_conn_row "$status" "$name" "$cat" "$http_code" "$reason" "$remote_ip" "$server" "$ttfb_ms" "$url"
    done < "$TMP_ROWS"
  fi
}

print_json() {
  while IFS='|' read -r status name cat host url ip isp asn country http_code reason remote_ip kind server ttfb_ms; do
    [[ -z "$kind" ]] && kind="egress"
    printf '{"status":"%s","name":"%s","category":"%s","kind":"%s","host":"%s","url":"%s","ip":"%s","isp":"%s","asn":"%s","country":"%s","http_code":"%s","reason":"%s","remote_ip":"%s","server":"%s","ttfb_ms":"%s"}\n' \
      "$(json_escape "$status")" "$(json_escape "$name")" "$(json_escape "$cat")" \
      "$(json_escape "$kind")" \
      "$(json_escape "$host")" "$(json_escape "$url")" "$(json_escape "$ip")" \
      "$(json_escape "$isp")" "$(json_escape "$asn")" "$(json_escape "$country")" \
      "$(json_escape "$http_code")" "$(json_escape "$reason")" "$(json_escape "$remote_ip")" \
      "$(json_escape "$server")" "$(json_escape "$ttfb_ms")"
  done < "$TMP_ROWS"
}

section_header() {
  local label="$1"
  local rule
  rule=$(repeat_str "$G_DASH" 3)
  printf '\n  %s%s%s %s%s%s %s%s%s\n' \
    "$C_DIM" "$rule" "$R" \
    "$C_ACCENT$BOLD" "$label" "$R" \
    "$C_DIM" "$(repeat_str "$G_DASH" 50)" "$R"
}

# Render a bar of N filled blocks within a total width.
render_bar() {
  local filled="$1" total="$2"
  local i out=""
  for ((i=0; i<total; i++)); do
    if [[ $i -lt $filled ]]; then
      out="${out}${G_BAR_FILL}"
    else
      out="${out}${G_BAR_EMPTY}"
    fi
  done
  printf '%s' "$out"
}

print_summary() {
  local eg_total eg_ok eg_fail unique max_count
  local cn_total cn_ok cn_fail cn_block

  # Egress stats (kind != connectivity)
  eg_total=$(awk -F'|' '$13!="connectivity"{n++} END{print n+0}' "$TMP_ROWS")
  eg_ok=$(awk -F'|' '$1=="OK" && $13!="connectivity"{n++} END{print n+0}' "$TMP_ROWS")
  eg_fail=$(( eg_total - eg_ok ))
  unique=$(awk -F'|' '$1=="OK" && $13!="connectivity" && $6!=""{print $6}' "$TMP_ROWS" | sort -u | wc -l | tr -d ' ')

  # Connectivity stats
  cn_total=$(awk -F'|' '$13=="connectivity"{n++} END{print n+0}' "$TMP_ROWS")
  cn_ok=$(awk -F'|' '$13=="connectivity" && $1=="OK"{n++} END{print n+0}' "$TMP_ROWS")
  cn_fail=$(( cn_total - cn_ok ))
  cn_block=$(awk -F'|' '$13=="connectivity" && $1=="OK" && ($10 ~ /^4/ || $10 ~ /^5/){n++} END{print n+0}' "$TMP_ROWS")

  section_header "Summary"
  if [[ "$eg_total" -gt 0 ]]; then
    printf '    %sEgress%s        %s%s%s ok  %s%s%s  %s%s%s fail  %s%s%s  %s%s%s unique IP%s\n' \
      "$C_ACCENT$BOLD" "$R" \
      "$BOLD$C_OK" "$eg_ok" "$R" \
      "$C_DIM" "$G_BULLET" "$R" \
      "$BOLD$C_FAIL" "$eg_fail" "$R" \
      "$C_DIM" "$G_BULLET" "$R" \
      "$BOLD$C_ACCENT" "$unique" "$R" \
      "$([[ $unique -ne 1 ]] && echo s)"
  fi
  if [[ "$cn_total" -gt 0 ]]; then
    printf '    %sConnectivity%s  %s%s%s reachable  %s%s%s  %s%s%s unreachable  %s%s%s  %s%s%s blocked (4xx/5xx)\n' \
      "$C_ACCENT$BOLD" "$R" \
      "$BOLD$C_OK" "$cn_ok" "$R" \
      "$C_DIM" "$G_BULLET" "$R" \
      "$BOLD$C_FAIL" "$cn_fail" "$R" \
      "$C_DIM" "$G_BULLET" "$R" \
      "$BOLD$C_WARN" "$cn_block" "$R"
  fi

  local ok="$eg_ok"
  if [[ "$ok" -gt 0 ]]; then
    section_header "Egress distribution"

    # First pass: find max count for bar scaling.
    max_count=$(awk -F'|' '$1=="OK" && $13!="connectivity" && $6!=""{print $6 "|" $7 "|" $8 "|" $9}' "$TMP_ROWS" |
      sort | uniq -c | awk '{print $1}' | sort -nr | head -1)
    [[ -z "$max_count" || "$max_count" -eq 0 ]] && max_count=1

    local bar_width=20
    awk -F'|' '$1=="OK" && $13!="connectivity" && $6!=""{print $6 "|" $7 "|" $8 "|" $9}' "$TMP_ROWS" |
      sort |
      awk -F'|' '
        {
          key=$1 "|" $2 "|" $3 "|" $4
          count[key]++
        }
        END {
          for (k in count) print count[k] "|" k
        }
      ' |
      sort -t'|' -k1,1nr |
      while IFS='|' read -r count ip isp asn country; do
        local filled bar masked_ip line_meta
        filled=$(( count * bar_width / max_count ))
        [[ "$filled" -lt 1 && "$count" -gt 0 ]] && filled=1
        bar=$(render_bar "$filled" "$bar_width")
        masked_ip=$(mask_ip "$ip")

        line_meta=""
        [[ -n "$country" && "$country" != "N/A" ]] && line_meta="$country"
        if [[ -n "$asn" && "$asn" != "N/A" ]]; then
          [[ -n "$line_meta" ]] && line_meta="$line_meta $G_BULLET $asn" || line_meta="$asn"
        fi
        if [[ -n "$isp" && "$isp" != "N/A" ]]; then
          local short_isp
          short_isp=$(trunc "$isp" 26)
          [[ -n "$line_meta" ]] && line_meta="$line_meta $short_isp" || line_meta="$short_isp"
        fi

        printf '    %s%s%s  %s%2d%s  %s%-16s%s  %s%s%s\n' \
          "$C_ACCENT" "$bar" "$R" \
          "$BOLD" "$count" "$R" \
          "$BOLD" "$masked_ip" "$R" \
          "$C_SUBTLE" "$line_meta" "$R"
      done
  fi

  if [[ "$unique" -gt 1 ]]; then
    printf '\n  %s%s%s  %sMultiple egress IPs detected%s — likely domain/proxy/policy split routing.\n' \
      "$C_WARN" "$G_WARN" "$R" "$BOLD" "$R"
  fi

  local cmd_name
  cmd_name="$0"
  if [[ "$cmd_name" == /dev/fd/* || "$cmd_name" == "bash" ]]; then
    cmd_name="egress-realip-check.sh"
  fi

  section_header "Hints"
  if [[ "$MASK_IP" -eq 1 ]]; then
    printf '    %s%s%s pass %s--show-ip%s to reveal full addresses\n' \
      "$C_DIM" "$G_TIP" "$R" "$BOLD" "$R"
  fi
  printf '    %s%s%s try %s%s --cf example.com%s to test a Cloudflare-fronted target\n' \
    "$C_DIM" "$G_TIP" "$R" "$BOLD" "$cmd_name" "$R"
  if [[ "$INCLUDE_TARGETS_ALL" -eq 0 ]]; then
    printf '    %s%s%s use %s--targets-all%s to add reachability probes for TW gov/banks/forums\n' \
      "$C_DIM" "$G_TIP" "$R" "$BOLD" "$R"
    printf '    %s%s%s connectivity probes %s%s%s %sreport reachability + latency only — they do not echo your IP%s\n' \
      "$C_DIM" "$G_TIP" "$R" "$C_DIM" "$G_DASH" "$R" "$C_DIM" "$R"
  fi
  printf '\n'
}

count_completed_rows() {
  local total="$1" idx=0 done_count=0
  while [[ "$idx" -lt "$total" ]]; do
    [[ -f "$TMP_DIR/$idx.row" ]] && done_count=$((done_count + 1))
    idx=$((idx + 1))
  done
  printf '%s' "$done_count"
}

print_progress() {
  local done_count="$1" total="$2" pct=100
  [[ "$JSON" -eq 1 ]] && return
  if [[ "$total" -gt 0 ]]; then
    pct=$((done_count * 100 / total))
  fi
  printf '\r%s%s%s Running: %3d%% (%d/%d)' "$C_DIM" "$G_BULLET" "$R" "$pct" "$done_count" "$total" >&2
}

finish_progress() {
  [[ "$JSON" -eq 1 ]] && return
  printf '\r%s\n' "$(repeat_str ' ' 48)" >&2
}

clear_for_results() {
  [[ "$JSON" -eq 1 ]] && return
  printf '\033[2J\033[H'
}

run_probes() {
  local total idx entry name cat url out running
  total=${#PROBES[@]}
  print_progress 0 "$total"

  if [[ "$CONCURRENCY" -le 1 ]]; then
    idx=0
    for entry in "${PROBES[@]}"; do
      IFS='|' read -r name cat url kind <<< "$entry"
      [[ -z "$kind" ]] && kind="ipecho"
      probe_one "$name" "$cat" "$url" "$kind" > "$TMP_DIR/$idx.row"
      idx=$((idx + 1))
      print_progress "$idx" "$total"
    done
  else
    idx=0
    for entry in "${PROBES[@]}"; do
      while true; do
        running=$(jobs -pr | wc -l | tr -d ' ')
        [[ "$running" -lt "$CONCURRENCY" ]] && break
        print_progress "$(count_completed_rows "$total")" "$total"
        sleep 0.1
      done
      IFS='|' read -r name cat url kind <<< "$entry"
      [[ -z "$kind" ]] && kind="ipecho"
      out="$TMP_DIR/$idx.row"
      ( probe_one "$name" "$cat" "$url" "$kind" > "$out" ) &
      idx=$((idx + 1))
    done
    while [[ "$(jobs -pr | wc -l | tr -d ' ')" -gt 0 ]]; do
      print_progress "$(count_completed_rows "$total")" "$total"
      sleep 0.1
    done
    wait
    print_progress "$total" "$total"
  fi
  finish_progress

  idx=0
  while [[ "$idx" -lt "$total" ]]; do
    if [[ -f "$TMP_DIR/$idx.row" ]]; then
      cat "$TMP_DIR/$idx.row" >> "$TMP_ROWS"
    fi
    idx=$((idx + 1))
  done
}

run_probes
enrich_rows

if [[ "$JSON" -eq 1 ]]; then
  print_json
else
  clear_for_results
  print_header
  print_table
  print_summary
fi
