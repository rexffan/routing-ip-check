#!/usr/bin/env bash
#
# routing-ip-check.sh
#
# VPS Split-Routing Detector — ask a curated set of Cloudflare-backed sites
# what source IP they see via /cdn-cgi/trace, then summarise the distribution.
# A single source IP across all targets means a single egress; multiple IPs
# means split routing / policy NAT / per-domain proxy chains.

set -u

VERSION="1.8.0"
IP_FLAG="-4"
IP_LABEL="IPv4"
TIMEOUT=8
NO_PROXY=0
PROXY_URL=""
DO_ASN=1
JSON=0
INCLUDE_TARGETS=1
TARGETS_ADDED=0
CONCURRENCY=1
MASK_IP=1
ASCII_MODE=0
SHOW_VERBOSE=0
AUTO_INSTALL=1
BG_MODE=""               # "" = auto-detect, "dark" / "light" = manual override

USE_COLOR=1
USE_UNICODE=1
[[ -n "${NO_COLOR:-}" ]] && USE_COLOR=0
[[ "${TERM:-}" == "dumb" || ! -t 1 ]] && USE_COLOR=0
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  C|POSIX|C.*|*8859*|*[Ee][Uu][Cc]*|*[Bb][Ii][Gg]5*|*[Gg][Bb][Kk]*|*[Gg][Bb]2312*|*[Ss][Hh][Ii][Ff][Tt]*[Jj][Ii][Ss]*)
    USE_UNICODE=0 ;;
esac

# detect_bg_mode — return "light" or "dark" for the current terminal.
#   1) honor explicit override (--light/--dark flag or env var)
#   2) check COLORFGBG (xterm, urxvt, Konsole)
#   3) try OSC 11 query (xterm, iTerm2, Alacritty — fails silently on Apple
#      Terminal.app, so don't block on it)
#   4) default to dark — most SSH/server terminals are dark
detect_bg_mode() {
  if [[ -n "${ROUTING_IP_CHECK_BG:-}" ]]; then
    printf '%s' "${ROUTING_IP_CHECK_BG}"; return
  fi
  if [[ -n "$BG_MODE" ]]; then
    printf '%s' "$BG_MODE"; return
  fi
  if [[ -n "${COLORFGBG:-}" ]]; then
    local bg=${COLORFGBG##*;}
    case "$bg" in
      7|15|default) printf 'light'; return ;;
      0|1|2|3|4|5|6|8) printf 'dark'; return ;;
    esac
  fi
  if [[ -t 1 && -t 0 ]]; then
    local resp=""
    # Send OSC 11 query, read up to 200ms for the reply.
    IFS= read -rs -t 0.2 -d $'\a' -p $'\033]11;?\a' resp 2>/dev/null || true
    if [[ "$resp" =~ rgb:([0-9a-fA-F]+)/([0-9a-fA-F]+)/([0-9a-fA-F]+) ]]; then
      local r=$((16#${BASH_REMATCH[1]:0:2}))
      local g=$((16#${BASH_REMATCH[2]:0:2}))
      local b=$((16#${BASH_REMATCH[3]:0:2}))
      if (( (r + g + b) / 3 > 128 )); then printf 'light'; return; fi
      printf 'dark'; return
    fi
  fi
  printf 'dark'
}

# Two palettes, designed for ≥3:1 contrast on each background.
#   Dark-bg (default): brighter, slightly desaturated — easy on eyes on black.
#   Light-bg: deeper, more saturated — must survive being pasted on white
#     surfaces (Notion / chat / PR comments) where typical dark-bg colours
#     (sage, soft amber, light gray) disappear.
init_colors() {
  if [[ "$USE_COLOR" -eq 0 ]]; then
    R="" BOLD="" DIM=""
    C_ACCENT="" C_OK="" C_FAIL="" C_WARN="" C_DIM="" C_SUBTLE=""
    return
  fi
  R=$'\033[0m'
  BOLD=$'\033[1m'
  DIM=$'\033[2m'

  local mode
  mode=$(detect_bg_mode)
  if [[ "$mode" == "light" ]]; then
    # Light-bg palette — GitHub Light / VS Code Light Modern inspired.
    C_ACCENT=$'\033[38;5;30m'    # deep teal-green
    C_OK=$'\033[38;5;28m'        # forest green
    C_FAIL=$'\033[38;5;124m'     # dark red
    C_WARN=$'\033[38;5;130m'     # caramel orange (NOT yellow — yellow vanishes on white)
    C_DIM=$'\033[38;5;242m'      # mid-dark gray
    C_SUBTLE=$'\033[38;5;238m'   # darker gray (subtle MUST be darker than dim on light bg)
  else
    # Dark-bg palette — sage/clay/amber, soft on dark.
    C_ACCENT=$'\033[38;5;108m'   # sage
    C_OK=$'\033[38;5;78m'        # lively green (brighter than 71, pops on black)
    C_FAIL=$'\033[38;5;167m'     # clay red
    C_WARN=$'\033[38;5;215m'     # warm amber
    C_DIM=$'\033[38;5;240m'      # mid gray
    C_SUBTLE=$'\033[38;5;245m'   # light gray
  fi
}

init_glyphs() {
  if [[ "$USE_UNICODE" -eq 1 && "$ASCII_MODE" -eq 0 ]]; then
    # Status + chrome
    G_OK="✓"; G_FAIL="✗"; G_WARN="⚠"; G_BULLET="•"
    G_DASH="─"; G_VBAR="│"; G_TL="╭"; G_TR="╮"; G_BL="╰"; G_BR="╯"
    G_DOT="╌"; G_LEAD="─"; G_TIP="▸"; G_MASK="•"
    # New for v1.8 dashboard look
    G_DOT_OK="●"        # filled dot — OK rows
    G_DOT_FAIL="○"      # hollow dot — FAIL rows
    G_LEAD_BAR="▎"      # left accent bar for section headers
    # Smooth bar: full block + 7 fractional 1/8 sub-blocks (light → heavy)
    G_BAR_FILL="█"
    G_BAR_S1="▏"; G_BAR_S2="▎"; G_BAR_S3="▍"; G_BAR_S4="▌"
    G_BAR_S5="▋"; G_BAR_S6="▊"; G_BAR_S7="▉"
    G_BAR_EMPTY=" "     # empty cell is a space — the bar shape itself implies length
  else
    G_OK="+"; G_FAIL="x"; G_WARN="!"; G_BULLET="*"
    G_DASH="-"; G_VBAR="|"; G_TL="+"; G_TR="+"; G_BL="+"; G_BR="+"
    G_DOT="-"; G_LEAD="-"; G_TIP=">"; G_MASK="x"
    G_DOT_OK="+"; G_DOT_FAIL="-"; G_LEAD_BAR="|"
    G_BAR_FILL="#"
    G_BAR_S1="#"; G_BAR_S2="#"; G_BAR_S3="#"; G_BAR_S4="#"
    G_BAR_S5="#"; G_BAR_S6="#"; G_BAR_S7="#"
    G_BAR_EMPTY="."
  fi
}

R="" BOLD="" DIM=""
C_ACCENT="" C_OK="" C_FAIL="" C_WARN="" C_DIM="" C_SUBTLE=""
G_OK="" G_FAIL="" G_WARN="" G_BULLET="" G_DASH="" G_VBAR=""
G_TL="" G_TR="" G_BL="" G_BR="" G_DOT="" G_LEAD=""
G_BAR_FILL="" G_BAR_EMPTY="" G_TIP="" G_MASK=""
G_DOT_OK="" G_DOT_FAIL="" G_LEAD_BAR=""
G_BAR_S1="" G_BAR_S2="" G_BAR_S3="" G_BAR_S4=""
G_BAR_S5="" G_BAR_S6="" G_BAR_S7=""

# Probe entry: name|category|url
# Every default probe must be a Cloudflare /cdn-cgi/trace URL.
PROBES=(
  "Cloudflare trace|CDN Trace|https://www.cloudflare.com/cdn-cgi/trace"
)

TARGET_PROBES=(
  # Global — Cloudflare-confirmed
  "quora.com|Social|https://quora.com/cdn-cgi/trace"
  "Patreon|Creator|https://www.patreon.com/cdn-cgi/trace"
  "OnlyFans|Creator|https://onlyfans.com/cdn-cgi/trace"
  "Medium|Publishing|https://medium.com/cdn-cgi/trace"
  "Substack|Publishing|https://substack.com/cdn-cgi/trace"
  "Vimeo|Video|https://vimeo.com/cdn-cgi/trace"
  "wise.com|Finance|https://wise.com/cdn-cgi/trace"
  "revolut.com|Finance|https://revolut.com/cdn-cgi/trace"
  "eToro|Finance|https://www.etoro.com/cdn-cgi/trace"
  "coinbase.com|Crypto|https://coinbase.com/cdn-cgi/trace"
  "okx.com|Crypto|https://okx.com/cdn-cgi/trace"
  "kraken.com|Crypto|https://kraken.com/cdn-cgi/trace"
  "Crypto.com|Crypto|https://crypto.com/cdn-cgi/trace"
  "Bitget|Crypto|https://www.bitget.com/cdn-cgi/trace"
  "KuCoin|Crypto|https://www.kucoin.com/cdn-cgi/trace"
  "Bitfinex|Crypto|https://www.bitfinex.com/cdn-cgi/trace"
  "openai.com|AI/Work|https://openai.com/cdn-cgi/trace"
  "ChatGPT|AI/Work|https://chatgpt.com/cdn-cgi/trace"
  "Claude|AI/Work|https://claude.ai/cdn-cgi/trace"
  "Anthropic|AI/Work|https://www.anthropic.com/cdn-cgi/trace"
  "Perplexity|AI/Work|https://www.perplexity.ai/cdn-cgi/trace"
  "Poe|AI/Work|https://poe.com/cdn-cgi/trace"
  "canva.com|AI/Work|https://canva.com/cdn-cgi/trace"
  "notion.so|AI/Work|https://notion.so/cdn-cgi/trace"
  "Zoom|AI/Work|https://zoom.us/cdn-cgi/trace"
  "Udemy|Learning|https://www.udemy.com/cdn-cgi/trace"
  "Shopify|Shopping|https://www.shopify.com/cdn-cgi/trace"
  "iHerb|Shopping|https://www.iherb.com/cdn-cgi/trace"
  # Local — Cloudflare-confirmed
  "Dcard|Forum|https://dcard.tw/cdn-cgi/trace"
  "Bahamut|Forum|https://www.gamer.com.tw/cdn-cgi/trace"
  "Plurk|Forum|https://www.plurk.com/cdn-cgi/trace"
  "PanSci|Media|https://pansci.asia/cdn-cgi/trace"
  "chinatimes.com|Media|https://www.chinatimes.com/cdn-cgi/trace"
  "104.com.tw|Career|https://www.104.com.tw/cdn-cgi/trace"
  "GSN|TW Government|https://gsn.nat.gov.tw/cdn-cgi/trace"
  "LINE Bank TW|TW Finance|https://www.linebank.com.tw/cdn-cgi/trace"
  "JKO Pay|TW Finance|https://www.jkopay.com/cdn-cgi/trace"
  "PX Pay|TW Finance|https://www.pxpay.com/cdn-cgi/trace"
  "StockFeel|TW Finance|https://www.stockfeel.com.tw/cdn-cgi/trace"
  "WantGoo|TW Finance|https://www.wantgoo.com/cdn-cgi/trace"
  "FinLab|TW Finance|https://www.finlab.tw/cdn-cgi/trace"
  "MaiCoin|TW Crypto|https://www.maicoin.com/cdn-cgi/trace"
  "MAX Exchange|TW Crypto|https://max.maicoin.com/cdn-cgi/trace"
  "Books TW|TW Shopping|https://www.books.com.tw/cdn-cgi/trace"
  "Ruten|TW Shopping|https://www.ruten.com.tw/cdn-cgi/trace"
  "Buy123|TW Shopping|https://www.buy123.com.tw/cdn-cgi/trace"
  "citiesocial|TW Shopping|https://www.citiesocial.com/cdn-cgi/trace"
)

usage() {
  cat <<'EOF'
Usage:
  routing-ip-check.sh [options]

Options:
  -4, --ipv4              Force IPv4 checks (default)
  -6, --ipv6              Force IPv6 checks
  -t, --timeout SECONDS   Per-request timeout (default: 8)
      --no-proxy          Ignore proxy environment variables for curl
      --proxy URL         Use a curl proxy, for example socks5h://127.0.0.1:1080
      --no-asn            Do not query ISP/ASN metadata
      --json              Print machine-readable JSON lines (always full IP)
      --targets           Include curated Cloudflare trace targets (default)
      --no-targets        Only run the two baseline Cloudflare trace probes
      --concurrency N     Number of concurrent probes (default: 1)
      --no-concurrency    Run probes serially
      --cf HOST           Add Cloudflare trace probe: https://HOST/cdn-cgi/trace
      --file FILE         Add Cloudflare trace probes from FILE:
                          "name|url" or "name|category|url"
      --show-ip           Reveal full IP addresses (default: mask last 2 segments)
      --ascii             Disable Unicode glyphs and box-drawing (ASCII-only)
      --verbose           Show the URL column in the results table
      --light             Force light-background palette (darker, saturated)
      --dark              Force dark-background palette (default for SSH terms)
      --no-install        Don't auto-install missing system packages
  -h, --help              Show help

Environment:
  NO_COLOR=1                       Disable ANSI colors entirely.
  ROUTING_IP_CHECK_BG=light|dark   Pin palette without flags (e.g. for CI).

Examples:
  ./routing-ip-check.sh
  ./routing-ip-check.sh --cf example.com
  ./routing-ip-check.sh --no-targets --cf your-cf-site.com
  ./routing-ip-check.sh --show-ip
  ./routing-ip-check.sh --json --no-asn
EOF
}

die() {
  printf '%sError:%s %s\n' "${C_FAIL:-$'\033[31m'}" "${R:-$'\033[0m'}" "$*" >&2
  exit 1
}

detect_pkg_manager() {
  if   command -v apt-get >/dev/null 2>&1; then printf 'apt'
  elif command -v dnf     >/dev/null 2>&1; then printf 'dnf'
  elif command -v yum     >/dev/null 2>&1; then printf 'yum'
  elif command -v apk     >/dev/null 2>&1; then printf 'apk'
  elif command -v pacman  >/dev/null 2>&1; then printf 'pacman'
  elif command -v zypper  >/dev/null 2>&1; then printf 'zypper'
  elif command -v brew    >/dev/null 2>&1; then printf 'brew'
  else printf 'none'
  fi
}

pkg_name_for() {
  case "$1" in
    awk) printf 'gawk' ;;
    *)   printf '%s' "$1" ;;
  esac
}

install_packages() {
  local pkgs=("$@") pm sudo_prefix=""
  pm=$(detect_pkg_manager)
  [[ "$pm" != "none" ]] || die "missing dependencies (${pkgs[*]}) and no supported package manager found. Install manually."

  if [[ "$EUID" -ne 0 && "$pm" != "brew" ]]; then
    if command -v sudo >/dev/null 2>&1; then
      sudo_prefix="sudo"
    else
      die "missing dependencies (${pkgs[*]}). Re-run as root or install manually."
    fi
  fi

  printf '%s%s%s installing missing deps via %s%s%s: %s%s%s\n' \
    "${C_DIM:-}" "${G_BULLET:-*}" "${R:-}" \
    "${C_ACCENT:-}" "$pm" "${R:-}" \
    "${BOLD:-}" "${pkgs[*]}" "${R:-}" >&2

  case "$pm" in
    apt)
      $sudo_prefix apt-get update -qq >&2 || true
      $sudo_prefix DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}" >&2 \
        || die "apt-get install failed (${pkgs[*]})"
      ;;
    dnf)    $sudo_prefix dnf install -y -q "${pkgs[@]}"      >&2 || die "dnf install failed (${pkgs[*]})" ;;
    yum)    $sudo_prefix yum install -y -q "${pkgs[@]}"      >&2 || die "yum install failed (${pkgs[*]})" ;;
    apk)    $sudo_prefix apk add --no-cache "${pkgs[@]}"     >&2 || die "apk add failed (${pkgs[*]})" ;;
    pacman) $sudo_prefix pacman -Sy --noconfirm "${pkgs[@]}" >&2 || die "pacman install failed (${pkgs[*]})" ;;
    zypper) $sudo_prefix zypper --non-interactive install "${pkgs[@]}" >&2 || die "zypper install failed (${pkgs[*]})" ;;
    brew)   brew install "${pkgs[@]}"                        >&2 || die "brew install failed (${pkgs[*]})" ;;
  esac
}

check_deps() {
  local required=(curl sed awk grep sort)
  local missing_cmds=() missing_pkgs=() cmd pkg already p
  for cmd in "${required[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing_cmds+=("$cmd")
      pkg=$(pkg_name_for "$cmd")
      already=0
      for p in "${missing_pkgs[@]}"; do [[ "$p" == "$pkg" ]] && already=1 && break; done
      [[ "$already" -eq 0 ]] && missing_pkgs+=("$pkg")
    fi
  done

  [[ ${#missing_cmds[@]} -eq 0 ]] && return 0
  [[ "$AUTO_INSTALL" -eq 1 ]] || die "missing required commands: ${missing_cmds[*]} (auto-install disabled by --no-install)"
  install_packages "${missing_pkgs[@]}"
  for cmd in "${missing_cmds[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 || die "still missing after install: $cmd"
  done
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

add_cf_probe() {
  local name="$1" cat="$2" url="$3"
  [[ -n "$name" ]] || die "probe name is empty"
  [[ "$url" =~ ^https?:// ]] || die "probe URL must start with http:// or https://: $url"
  case "$url" in
    */cdn-cgi/trace|*/cdn-cgi/trace\?*) ;;
    *) die "Cloudflare probe URL must end with /cdn-cgi/trace: $url" ;;
  esac
  PROBES+=("$(clean_field "$name")|$(clean_field "$cat")|$(clean_field "$url")")
}

add_probe_file() {
  local file="$1"
  [[ -f "$file" ]] || die "probe file not found: $file"

  local line name cat url _
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=$(printf '%s' "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    [[ -z "$line" || "$line" == \#* ]] && continue

    IFS='|' read -r name cat url _ <<< "$line"
    if [[ -z "${url:-}" ]]; then
      [[ -n "${cat:-}" ]] || { printf 'warning: skipping bad line in %s: %s\n' "$file" "$line" >&2; continue; }
      url="$cat"
      cat="Custom"
    fi
    if [[ -z "$name" || ! "$url" =~ ^https?:// ]]; then
      printf 'warning: skipping bad line in %s: %s\n' "$file" "$line" >&2
      continue
    fi
    add_cf_probe "$name" "${cat:-Custom}" "$url"
  done < "$file"
}

add_target_probes() {
  local entry
  [[ "$TARGETS_ADDED" -eq 1 ]] && return
  for entry in "${TARGET_PROBES[@]}"; do
    PROBES+=("$entry")
  done
  TARGETS_ADDED=1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -4|--ipv4)
      IP_FLAG="-4"; IP_LABEL="IPv4"; shift ;;
    -6|--ipv6)
      IP_FLAG="-6"; IP_LABEL="IPv6"; shift ;;
    -t|--timeout)
      [[ $# -ge 2 ]] || die "--timeout needs a value"
      TIMEOUT="$2"
      [[ "$TIMEOUT" =~ ^[0-9]+$ ]] || die "--timeout must be an integer"
      shift 2 ;;
    --no-proxy)
      NO_PROXY=1; shift ;;
    --proxy)
      [[ $# -ge 2 ]] || die "--proxy needs a value"
      PROXY_URL="$2"; shift 2 ;;
    --no-asn)
      DO_ASN=0; shift ;;
    --json)
      JSON=1; shift ;;
    --targets)
      INCLUDE_TARGETS=1; shift ;;
    --no-targets)
      INCLUDE_TARGETS=0; shift ;;
    --concurrency)
      [[ $# -ge 2 ]] || die "--concurrency needs a value"
      CONCURRENCY="$2"
      [[ "$CONCURRENCY" =~ ^[0-9]+$ && "$CONCURRENCY" -ge 1 ]] || die "--concurrency must be a positive integer"
      shift 2 ;;
    --no-concurrency)
      CONCURRENCY=1; shift ;;
    --cf)
      [[ $# -ge 2 ]] || die "--cf needs a host"
      add_cf_probe "$2 Cloudflare trace" "Custom" "https://$2/cdn-cgi/trace"
      shift 2 ;;
    --file)
      [[ $# -ge 2 ]] || die "--file needs a path"
      add_probe_file "$2"; shift 2 ;;
    --show-ip)
      MASK_IP=0; shift ;;
    --mask-ip)
      MASK_IP=1; shift ;;
    --ascii)
      ASCII_MODE=1; USE_UNICODE=0; shift ;;
    --verbose)
      SHOW_VERBOSE=1; shift ;;
    --no-install)
      AUTO_INSTALL=0; shift ;;
    --light)
      BG_MODE="light"; shift ;;
    --dark)
      BG_MODE="dark"; shift ;;
    -h|--help)
      usage; exit 0 ;;
    --version)
      printf '%s\n' "$VERSION"; exit 0 ;;
    *)
      die "unknown option: $1" ;;
  esac
done

if [[ "$INCLUDE_TARGETS" -eq 1 ]]; then
  add_target_probes
fi

if [[ "$JSON" -eq 1 ]]; then
  USE_COLOR=0
  USE_UNICODE=0
fi

init_colors
init_glyphs
check_deps

mask_ip() {
  local ip="$1"
  [[ -z "$ip" || "$MASK_IP" -eq 0 ]] && { printf '%s' "$ip"; return; }

  if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    local a b
    IFS='.' read -r a b _ _ <<< "$ip"
    printf '%s.%s.%s.%s' "$a" "$b" "$G_MASK$G_MASK$G_MASK" "$G_MASK$G_MASK$G_MASK"
    return
  fi

  if [[ "$ip" == *:* ]]; then
    local expanded groups n missing i out left right lcount=0 rcount=0
    if [[ "$ip" == *"::"* ]]; then
      left="${ip%%::*}"
      right="${ip#*::}"
      [[ -n "$left" ]] && lcount=$(awk -F: '{print NF}' <<< "$left")
      [[ -n "$right" ]] && rcount=$(awk -F: '{print NF}' <<< "$right")
      missing=$((8 - lcount - rcount))
      [[ "$missing" -lt 0 ]] && missing=0
      expanded="$left"
      for ((i=0; i<missing; i++)); do expanded="${expanded}:0"; done
      [[ -n "$right" ]] && expanded="${expanded}:${right}"
      expanded="${expanded#:}"
    else
      expanded="$ip"
    fi
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
  --user-agent "Mozilla/5.0 (compatible; cloudflare-source-ip-detection/$VERSION; +https://github.com/rexffan/routing-ip-check)"
)

if [[ "$NO_PROXY" -eq 1 ]]; then
  curl_common+=(--noproxy '*')
fi
if [[ -n "$PROXY_URL" ]]; then
  curl_common+=(--proxy "$PROXY_URL")
fi

is_ip() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ || "$1" == *:* ]]
}

run_with_timeout() {
  local seconds="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$@"
  else
    "$@"
  fi
}

probe_cf() {
  local name="$1" cat="$2" url="$3"
  local host body rc ip http_code remote_ip ttfb reason
  host=$(strip_url_host "$url")

  body=$(curl "${curl_common[@]}" "$IP_FLAG" \
    --write-out $'\n__RIPC_HTTP_CODE=%{http_code}\n__RIPC_REMOTE_IP=%{remote_ip}\n__RIPC_TTFB=%{time_starttransfer}\n' \
    "$url" 2>"$TMP_DIR/curl.err.$BASHPID")
  rc=$?

  http_code=$(printf '%s\n' "$body" | sed -n 's/^__RIPC_HTTP_CODE=//p' | tail -1)
  remote_ip=$(printf '%s\n' "$body" | sed -n 's/^__RIPC_REMOTE_IP=//p' | tail -1)
  ttfb=$(printf '%s\n' "$body" | sed -n 's/^__RIPC_TTFB=//p' | tail -1)
  ttfb=$(awk -v t="${ttfb:-0}" 'BEGIN{printf "%.0f", t*1000}')
  body=$(printf '%s\n' "$body" | sed '/^__RIPC_/d')

  if [[ "$rc" -ne 0 ]]; then
    reason="curl-error-$rc"
    printf 'FAIL|%s|%s|%s|%s|||||%s|%s|%s|%s\n' \
      "$(clean_field "$name")" "$(clean_field "$cat")" "$host" "$url" \
      "${http_code:-000}" "$reason" "$remote_ip" "${ttfb:-0}" >> "$TMP_ROWS"
    return
  fi

  ip=$(printf '%s\n' "$body" | awk -F= '$1=="ip"{print $2; exit}' | tr -d '\r')
  if [[ -z "$ip" || ! "$(is_ip "$ip"; printf $?)" == "0" ]]; then
    reason="no-cloudflare-trace-ip"
    [[ -n "$http_code" && "$http_code" != "200" ]] && reason="http-status-$http_code"
    printf 'FAIL|%s|%s|%s|%s|||||%s|%s|%s|%s\n' \
      "$(clean_field "$name")" "$(clean_field "$cat")" "$host" "$url" \
      "${http_code:-000}" "$reason" "$remote_ip" "${ttfb:-0}" >> "$TMP_ROWS"
    return
  fi

  printf 'OK|%s|%s|%s|%s|%s||||%s||%s|%s\n' \
    "$(clean_field "$name")" "$(clean_field "$cat")" "$host" "$url" \
    "$ip" "${http_code:-200}" "$remote_ip" "${ttfb:-0}" >> "$TMP_ROWS"
}

probe_one() {
  local entry="$1" name cat url
  IFS='|' read -r name cat url <<< "$entry"
  probe_cf "$name" "$cat" "$url"
}

declare -A ASN_CACHE=()
asn_lookup() {
  local ip="$1"
  [[ "$DO_ASN" -eq 1 && -n "$ip" ]] || { printf '|||'; return; }
  if [[ -n "${ASN_CACHE[$ip]:-}" ]]; then
    printf '%s' "${ASN_CACHE[$ip]}"
    return
  fi

  local info country org asn isp result
  info=$(curl --silent --show-error --max-time 5 "https://ipinfo.io/$ip/json" 2>/dev/null || true)
  country=$(printf '%s' "$info" | sed -nE 's/.*"country"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -1)
  org=$(printf '%s' "$info" | sed -nE 's/.*"org"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -1)
  asn=$(printf '%s' "$org" | awk '{print $1}')
  isp=$(printf '%s' "$org" | sed -E 's/^AS[0-9]+[[:space:]]*//')
  result="$(clean_field "$isp")|$(clean_field "$asn")|$(clean_field "$country")"
  ASN_CACHE[$ip]="$result"
  printf '%s' "$result"
}

enrich_rows() {
  [[ "$DO_ASN" -eq 1 ]] || return
  local tmp="$TMP_DIR/rows.enriched"
  : > "$tmp"
  local ips total done_count ip meta status name cat host url row_ip isp asn country http_code reason remote_ip ttfb

  ips=$(awk -F'|' '$1=="OK" && $6!=""{print $6}' "$TMP_ROWS" | sort -u)
  total=$(printf '%s\n' "$ips" | sed '/^$/d' | wc -l | tr -d ' ')
  if [[ "$total" -gt 0 ]]; then
    print_progress "Resolving" 0 "$total"
    done_count=0
    while IFS= read -r ip; do
      [[ -z "$ip" ]] && continue
      asn_lookup "$ip" >/dev/null
      done_count=$((done_count + 1))
      print_progress "Resolving" "$done_count" "$total"
    done <<< "$ips"
  fi

  while IFS='|' read -r status name cat host url row_ip isp asn country http_code reason remote_ip ttfb; do
    if [[ "$status" == "OK" && -n "$row_ip" ]]; then
      meta=$(asn_lookup "$row_ip")
      IFS='|' read -r isp asn country <<< "$meta"
    fi
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
      "$status" "$name" "$cat" "$host" "$url" "$row_ip" "$isp" "$asn" "$country" \
      "$http_code" "$reason" "$remote_ip" "$ttfb" >> "$tmp"
  done < "$TMP_ROWS"
  mv "$tmp" "$TMP_ROWS"
}

repeat_str() {
  local s="$1" n="$2" out=""
  while [[ "$n" -gt 0 ]]; do out="${out}${s}"; n=$((n - 1)); done
  printf '%s' "$out"
}

trunc() {
  local s="$1" n="$2"
  if [[ ${#s} -gt $n ]]; then
    if [[ "$USE_UNICODE" -eq 1 ]]; then
      printf '%s…' "${s:0:n-1}"
    else
      printf '%s...' "${s:0:n-3}"
    fi
  else
    printf '%s' "$s"
  fi
}

# term_width — visible content width for rendering. Caps at 100 to avoid
# stretching wide on ultra-wide terminals. Falls back to 80 when stdout is
# not a tty (CI / piped to file).
term_width() {
  local cols=80
  if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
    cols=$(tput cols 2>/dev/null || echo 80)
  elif [[ -n "${COLUMNS:-}" ]]; then
    cols="$COLUMNS"
  fi
  [[ "$cols" -lt 60 ]] && cols=60
  [[ "$cols" -gt 100 ]] && cols=100
  printf '%s' "$cols"
}

# right_align — left-pad with spaces so $text ends at column $width.
right_align() {
  local text="$1" width="$2" pad
  pad=$((width - ${#text}))
  [[ "$pad" -lt 0 ]] && pad=0
  printf '%*s%s' "$pad" '' "$text"
}

# bar_smooth — render a horizontal bar using 1/8-cell sub-blocks for smoothness.
# Args: filled_percent (0-100), total_cells.
# Each cell renders as the full block, a 1/8-fractional block, or empty.
bar_smooth() {
  local pct="$1" cells="$2"
  [[ "$pct" -lt 0 ]] && pct=0
  [[ "$pct" -gt 100 ]] && pct=100
  local total_eighths=$(( pct * cells * 8 / 100 ))
  local full_cells=$(( total_eighths / 8 ))
  local remainder=$(( total_eighths % 8 ))
  local out=""
  local i
  for ((i=0; i<full_cells; i++)); do out+="${G_BAR_FILL}"; done
  if [[ "$remainder" -gt 0 && "$full_cells" -lt "$cells" ]]; then
    case "$remainder" in
      1) out+="${G_BAR_S1}" ;;
      2) out+="${G_BAR_S2}" ;;
      3) out+="${G_BAR_S3}" ;;
      4) out+="${G_BAR_S4}" ;;
      5) out+="${G_BAR_S5}" ;;
      6) out+="${G_BAR_S6}" ;;
      7) out+="${G_BAR_S7}" ;;
    esac
    full_cells=$((full_cells + 1))
  fi
  local empty=$(( cells - full_cells ))
  for ((i=0; i<empty; i++)); do out+="${G_BAR_EMPTY}"; done
  printf '%s' "$out"
}

section_header() {
  local label="$1"
  printf '\n  %s%s%s %s%s%s\n\n' \
    "$C_ACCENT" "$G_LEAD_BAR" "$R" \
    "$BOLD" "$label" "$R"
}

print_header() {
  local title="routing-ip-check"
  local version_tag="v${VERSION}"
  local mode="direct"
  [[ "$NO_PROXY" -eq 1 ]] && mode="no-proxy"
  [[ -n "$PROXY_URL" ]] && mode="proxy"
  local worker_label="worker"
  [[ "$CONCURRENCY" -gt 1 ]] && worker_label="workers"
  local probe_label="cf probe"
  [[ "${#PROBES[@]}" -gt 1 ]] && probe_label="cf probes"
  local meta="${IP_LABEL}  ${G_BULLET}  ${mode}  ${G_BULLET}  ${#PROBES[@]} ${probe_label}  ${G_BULLET}  ${CONCURRENCY} ${worker_label}"
  [[ "$MASK_IP" -eq 1 ]] && meta="${meta}  ${G_BULLET}  masked"

  local cols pad
  cols=$(term_width)
  # Title row: bold project name on left, dim version on right
  pad=$(( cols - 2 - ${#title} - ${#version_tag} ))
  [[ "$pad" -lt 1 ]] && pad=1
  printf '\n  %s%s%s%*s%s%s%s\n' \
    "$BOLD$C_ACCENT" "$title" "$R" \
    "$pad" '' \
    "$C_DIM" "$version_tag" "$R"

  # Horizontal rule under title — full content width
  local rule_w=$(( cols - 4 ))
  [[ "$rule_w" -lt 10 ]] && rule_w=10
  printf '  %s%s%s\n' "$C_DIM" "$(repeat_str "$G_DASH" "$rule_w")" "$R"

  # Meta line
  printf '  %s%s%s\n\n' "$C_SUBTLE" "$meta" "$R"
}

print_row() {
  local status="$1" name="$2" cat="$3" ip="$4" isp="$5" asn="$6" country="$7" reason="$8" url="$9" ttfb="${10}"
  local cols name_w ip_w meta_w glyph color masked right=""
  cols=$(term_width)
  # Layout budget: 2 (indent) + 1 (dot) + 2 (gap) + name_w + 2 (gap) + ip_w + 2 (gap) + meta_w = cols
  # Reserve 18 for IP column (masked IPv4 fits in 16, IPv6 needs more)
  ip_w=18
  # Name column scales with width; cap at 28 chars
  name_w=$(( cols - 7 - ip_w - 28 ))
  [[ "$name_w" -lt 18 ]] && name_w=18
  [[ "$name_w" -gt 28 ]] && name_w=28
  meta_w=$(( cols - 7 - name_w - ip_w ))
  [[ "$meta_w" -lt 12 ]] && meta_w=12

  if [[ "$status" == "OK" ]]; then
    glyph="$G_DOT_OK"; color="$C_OK"
  else
    glyph="$G_DOT_FAIL"; color="$C_DIM"
  fi
  name=$(trunc "$name" "$name_w")

  if [[ "$status" == "OK" && -n "$ip" ]]; then
    masked=$(mask_ip "$ip")
    # Right side: country · ASN · ms — joined with bullets, right-aligned
    [[ -n "$country" && "$country" != "N/A" ]] && right="$country"
    [[ -n "$asn" && "$asn" != "N/A" ]] && right="${right:+$right $G_BULLET }$asn"
    if [[ -n "$ttfb" && "$ttfb" != "0" ]]; then
      right="${right:+$right $G_BULLET }${ttfb}ms"
    fi
    # If verbose, also show ISP truncated
    if [[ "$SHOW_VERBOSE" -eq 1 && -n "$isp" && "$isp" != "N/A" ]]; then
      right="$right $G_BULLET $(trunc "$isp" 20)"
    fi
    right=$(trunc "$right" "$meta_w")
    printf '  %s%s%s  %-*s  %s%-*s%s  %s%s%s\n' \
      "$color" "$glyph" "$R" \
      "$name_w" "$name" \
      "$BOLD" "$ip_w" "$masked" "$R" \
      "$C_SUBTLE" "$(right_align "$right" "$meta_w")" "$R"
  else
    # FAIL row: dot + name + reason (dim) — no IP / meta columns
    local why="${reason:-no-data}"
    printf '  %s%s%s  %s%-*s%s  %s%s%s\n' \
      "$color" "$glyph" "$R" \
      "$C_DIM" "$name_w" "$name" "$R" \
      "$C_DIM" "$why" "$R"
  fi

  if [[ "$SHOW_VERBOSE" -eq 1 ]]; then
    printf '     %s%s %s%s\n' "$C_DIM" "$G_DOT" "$url" "$R"
  fi
}

print_table() {
  section_header "Cloudflare Trace Probes"
  while IFS='|' read -r status name cat host url ip isp asn country http_code reason remote_ip ttfb; do
    print_row "$status" "$name" "$cat" "$ip" "$isp" "$asn" "$country" "$reason" "$url" "$ttfb"
  done < "$TMP_ROWS"
}

print_json() {
  while IFS='|' read -r status name cat host url ip isp asn country http_code reason remote_ip ttfb; do
    printf '{"status":"%s","name":"%s","category":"%s","kind":"cf","host":"%s","url":"%s","ip":"%s","isp":"%s","asn":"%s","country":"%s","http_code":"%s","reason":"%s","remote_ip":"%s","ttfb_ms":"%s"}\n' \
      "$(json_escape "$status")" "$(json_escape "$name")" "$(json_escape "$cat")" \
      "$(json_escape "$host")" "$(json_escape "$url")" "$(json_escape "$ip")" \
      "$(json_escape "$isp")" "$(json_escape "$asn")" "$(json_escape "$country")" \
      "$(json_escape "$http_code")" "$(json_escape "$reason")" "$(json_escape "$remote_ip")" \
      "$(json_escape "$ttfb")"
  done < "$TMP_ROWS"
}

print_summary() {
  local total ok fail unique cols bar_cells
  total=$(awk -F'|' '{n++} END{print n+0}' "$TMP_ROWS")
  ok=$(awk -F'|' '$1=="OK"{n++} END{print n+0}' "$TMP_ROWS")
  fail=$((total - ok))
  unique=$(awk -F'|' '$1=="OK" && $6!=""{print $6}' "$TMP_ROWS" | sort -u | wc -l | tr -d ' ')

  cols=$(term_width)
  # Distribution bar width: more cells on wider terminals, min 14 on narrow.
  bar_cells=24
  [[ "$cols" -lt 80 ]] && bar_cells=18
  [[ "$cols" -lt 70 ]] && bar_cells=14

  section_header "Summary"
  printf '    %s%s%s ok   %s%s%s   %s%s%s fail   %s%s%s   %s%s%s unique IP%s\n' \
    "$BOLD$C_OK" "$ok" "$R" \
    "$C_DIM" "$G_BULLET" "$R" \
    "$BOLD$C_FAIL" "$fail" "$R" \
    "$C_DIM" "$G_BULLET" "$R" \
    "$BOLD$C_ACCENT" "$unique" "$R" \
    "$([[ $unique -ne 1 ]] && echo s)"

  if [[ "$ok" -gt 0 ]]; then
    section_header "Source IP Distribution"

    awk -F'|' -v tot="$ok" '$1=="OK" && $6!=""{print $6 "|" $7 "|" $8 "|" $9}' "$TMP_ROWS" |
      sort |
      awk -F'|' '{key=$1 "|" $2 "|" $3 "|" $4; count[key]++} END{for (k in count) print count[k] "|" k}' |
      sort -t'|' -k1,1nr |
      while IFS='|' read -r count ip isp asn country; do
        local pct bar masked_ip line_meta=""
        # Percentage of the OK subset (not total) — denominator that "feels right"
        pct=$(( count * 100 / ok ))
        # Minimum visible bar for any non-zero count
        [[ "$pct" -lt 1 && "$count" -gt 0 ]] && pct=1
        bar=$(bar_smooth "$pct" "$bar_cells")
        masked_ip=$(mask_ip "$ip")
        [[ -n "$country" && "$country" != "N/A" ]] && line_meta="$country"
        [[ -n "$asn" && "$asn" != "N/A" ]] && line_meta="${line_meta:+$line_meta $G_BULLET }$asn"
        [[ -n "$isp" && "$isp" != "N/A" ]] && line_meta="${line_meta:+$line_meta }$(trunc "$isp" 26)"
        # Layout: bar | count | pct | ip | meta
        printf '    %s%s%s  %s%3d%s %s%s%s %s%4d%%%s   %s%-16s%s  %s%s%s\n' \
          "$C_ACCENT" "$bar" "$R" \
          "$BOLD" "$count" "$R" \
          "$C_DIM" "$G_BULLET" "$R" \
          "$C_SUBTLE" "$pct" "$R" \
          "$BOLD" "$masked_ip" "$R" \
          "$C_SUBTLE" "$line_meta" "$R"
      done
  fi

  if [[ "$unique" -gt 1 ]]; then
    printf '\n  %s%s%s  %sDifferent Cloudflare sites observed different source IPs%s — likely split routing or policy NAT.\n' \
      "$C_WARN" "$G_WARN" "$R" "$BOLD" "$R"
  fi

  section_header "Tips"
  if [[ "$MASK_IP" -eq 1 ]]; then
    printf '    %s%s%s  %s--show-ip%s          reveal full IPs\n' \
      "$C_DIM" "$G_TIP" "$R" "$BOLD" "$R"
  fi
  printf '    %s%s%s  %s--cf example.com%s   add a specific Cloudflare site\n' \
    "$C_DIM" "$G_TIP" "$R" "$BOLD" "$R"
  printf '    %s%s%s  %s--json%s             machine-readable output\n\n' \
    "$C_DIM" "$G_TIP" "$R" "$BOLD" "$R"
}

print_progress() {
  [[ "$JSON" -eq 1 || ! -t 1 ]] && return
  local label="$1" done_count="$2" total="$3"
  [[ "$total" -le 0 ]] && total=1
  local pct=$((done_count * 100 / total))
  printf '\r%s%s%s %-10s %3d%% (%d/%d)        ' "$C_DIM" "$G_BULLET" "$R" "$label" "$pct" "$done_count" "$total"
}

finish_progress() {
  [[ "$JSON" -eq 1 || ! -t 1 ]] && return
  local cols
  cols=$(term_width)
  printf '\r%*s\r' "$cols" ''
}

clear_for_results() {
  [[ "$JSON" -eq 1 || ! -t 1 ]] && return
  if command -v tput >/dev/null 2>&1; then
    tput clear 2>/dev/null || printf '\033[2J\033[H'
  else
    printf '\033[2J\033[H'
  fi
}

count_completed_rows() {
  local total="$1" n
  n=$(wc -l < "$TMP_ROWS" 2>/dev/null | tr -d ' ')
  [[ -z "$n" ]] && n=0
  [[ "$n" -gt "$total" ]] && n="$total"
  printf '%s' "$n"
}

run_probes() {
  local total="${#PROBES[@]}" idx=0 running=0 pids=() pid
  print_progress "Probing" 0 "$total"
  if [[ "$CONCURRENCY" -le 1 ]]; then
    local entry
    for entry in "${PROBES[@]}"; do
      idx=$((idx + 1))
      probe_one "$entry"
      print_progress "Probing" "$idx" "$total"
    done
  else
    local entry
    for entry in "${PROBES[@]}"; do
      while :; do
        running=0
        for pid in "${pids[@]:-}"; do kill -0 "$pid" 2>/dev/null && running=$((running + 1)); done
        [[ "$running" -lt "$CONCURRENCY" ]] && break
        print_progress "Probing" "$(count_completed_rows "$total")" "$total"
        sleep 0.2
      done
      probe_one "$entry" &
      pids+=("$!")
    done
    for pid in "${pids[@]:-}"; do
      while kill -0 "$pid" 2>/dev/null; do
        print_progress "Probing" "$(count_completed_rows "$total")" "$total"
        sleep 0.2
      done
      wait "$pid" 2>/dev/null || true
    done
    print_progress "Probing" "$total" "$total"
  fi
}

run_probes
enrich_rows
finish_progress

if [[ "$JSON" -eq 1 ]]; then
  print_json
else
  clear_for_results
  print_header
  print_table
  print_summary
fi
