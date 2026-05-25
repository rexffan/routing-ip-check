#!/usr/bin/env bash
#
# routing-ip-check.sh
#
# Cloudflare Source IP Detection — ask Cloudflare-backed sites what source IP
# they see via /cdn-cgi/trace. This is intentionally narrow: arbitrary sites
# that do not echo the client IP cannot prove their site-specific source IP.

set -u

VERSION="1.7.0"
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

USE_COLOR=1
USE_UNICODE=1
[[ -n "${NO_COLOR:-}" ]] && USE_COLOR=0
[[ "${TERM:-}" == "dumb" || ! -t 1 ]] && USE_COLOR=0
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  C|POSIX|C.*|*8859*|*[Ee][Uu][Cc]*|*[Bb][Ii][Gg]5*|*[Gg][Bb][Kk]*|*[Gg][Bb]2312*|*[Ss][Hh][Ii][Ff][Tt]*[Jj][Ii][Ss]*)
    USE_UNICODE=0 ;;
esac

init_colors() {
  if [[ "$USE_COLOR" -eq 0 ]]; then
    R="" BOLD="" DIM=""
    C_ACCENT="" C_OK="" C_FAIL="" C_WARN="" C_DIM="" C_SUBTLE=""
    return
  fi
  R=$'\033[0m'
  BOLD=$'\033[1m'
  DIM=$'\033[2m'
  C_ACCENT=$'\033[38;5;108m'
  C_OK=$'\033[38;5;71m'
  C_FAIL=$'\033[38;5;167m'
  C_WARN=$'\033[38;5;215m'
  C_DIM=$'\033[38;5;240m'
  C_SUBTLE=$'\033[38;5;245m'
}

init_glyphs() {
  if [[ "$USE_UNICODE" -eq 1 && "$ASCII_MODE" -eq 0 ]]; then
    G_OK="✓"; G_FAIL="✗"; G_WARN="⚠"; G_BULLET="•"
    G_DASH="─"; G_VBAR="│"; G_TL="╭"; G_TR="╮"; G_BL="╰"; G_BR="╯"
    G_DOT="╌"; G_LEAD="─"; G_BAR_FILL="▰"; G_BAR_EMPTY="▱"; G_TIP="▸"; G_MASK="•"
  else
    G_OK="+"; G_FAIL="x"; G_WARN="!"; G_BULLET="*"
    G_DASH="-"; G_VBAR="|"; G_TL="+"; G_TR="+"; G_BL="+"; G_BR="+"
    G_DOT="-"; G_LEAD="-"; G_BAR_FILL="#"; G_BAR_EMPTY="."; G_TIP=">"; G_MASK="x"
  fi
}

R="" BOLD="" DIM=""
C_ACCENT="" C_OK="" C_FAIL="" C_WARN="" C_DIM="" C_SUBTLE=""
G_OK="" G_FAIL="" G_WARN="" G_BULLET="" G_DASH="" G_VBAR=""
G_TL="" G_TR="" G_BL="" G_BR="" G_DOT="" G_LEAD=""
G_BAR_FILL="" G_BAR_EMPTY="" G_TIP="" G_MASK=""

# Probe entry: name|category|url
# Every default probe must be a Cloudflare /cdn-cgi/trace URL.
PROBES=(
  "Cloudflare trace|CDN Trace|https://www.cloudflare.com/cdn-cgi/trace"
)

TARGET_PROBES=(
  # Global — Cloudflare-confirmed
  "x.com|Social|https://x.com/cdn-cgi/trace"
  "quora.com|Social|https://quora.com/cdn-cgi/trace"
  "wise.com|Finance|https://wise.com/cdn-cgi/trace"
  "revolut.com|Finance|https://revolut.com/cdn-cgi/trace"
  "coinbase.com|Crypto|https://coinbase.com/cdn-cgi/trace"
  "okx.com|Crypto|https://okx.com/cdn-cgi/trace"
  "kraken.com|Crypto|https://kraken.com/cdn-cgi/trace"
  "openai.com|AI/Work|https://openai.com/cdn-cgi/trace"
  "canva.com|AI/Work|https://canva.com/cdn-cgi/trace"
  "notion.so|AI/Work|https://notion.so/cdn-cgi/trace"
  # Local — Cloudflare-confirmed
  "Dcard|Forum|https://dcard.tw/cdn-cgi/trace"
  "Bahamut|Forum|https://www.gamer.com.tw/cdn-cgi/trace"
  "Plurk|Forum|https://www.plurk.com/cdn-cgi/trace"
  "PanSci|Media|https://pansci.asia/cdn-cgi/trace"
  "chinatimes.com|Media|https://www.chinatimes.com/cdn-cgi/trace"
  "104.com.tw|Career|https://www.104.com.tw/cdn-cgi/trace"
  "StockFeel|Finance|https://www.stockfeel.com.tw/cdn-cgi/trace"
  "PX Pay|Finance|https://www.pxpay.com/cdn-cgi/trace"
  "MaiCoin|Crypto|https://www.maicoin.com/cdn-cgi/trace"
  "MAX Exchange|Crypto|https://max.maicoin.com/cdn-cgi/trace"
  "books.com.tw|Shopping|https://www.books.com.tw/cdn-cgi/trace"
  "Buy123|Shopping|https://www.buy123.com.tw/cdn-cgi/trace"
  "citiesocial|Shopping|https://www.citiesocial.com/cdn-cgi/trace"
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
      --no-install        Don't auto-install missing system packages
  -h, --help              Show help

Environment:
  NO_COLOR=1              Disable ANSI colors entirely.

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
    printf '%s…' "${s:0:n-1}"
  else
    printf '%s' "$s"
  fi
}

section_header() {
  local label="$1"
  printf '\n  %s%s%s %s%s%s %s%s%s\n' \
    "$C_DIM" "$(repeat_str "$G_DASH" 3)" "$R" \
    "$C_ACCENT$BOLD" "$label" "$R" \
    "$C_DIM" "$(repeat_str "$G_DASH" 50)" "$R"
}

print_header() {
  local title="Cloudflare Source IP Detection"
  local mode="direct"
  [[ "$NO_PROXY" -eq 1 ]] && mode="no-proxy"
  [[ -n "$PROXY_URL" ]] && mode="proxy"
  local meta=" ${IP_LABEL}  ${G_BULLET}  ${mode}  ${G_BULLET}  ${#PROBES[@]} Cloudflare probes  ${G_BULLET}  ${CONCURRENCY} worker$([[ $CONCURRENCY -gt 1 ]] && echo s)"
  [[ "$MASK_IP" -eq 1 ]] && meta="${meta}  ${G_BULLET}  masked"
  local inner_w title_w meta_w pad_title pad_meta
  title_w=${#title}
  meta_w=${#meta}
  inner_w=$title_w
  [[ $meta_w -gt $inner_w ]] && inner_w=$meta_w
  inner_w=$((inner_w + 4))
  pad_title=$((inner_w - title_w - 3))
  pad_meta=$((inner_w - meta_w - 1))
  [[ $pad_title -lt 0 ]] && pad_title=0
  [[ $pad_meta -lt 0 ]] && pad_meta=0

  printf '\n'
  printf '%s%s%s %s%s%s %s%s\n' \
    "$C_DIM" "$G_TL$G_DASH" "$R" "$C_ACCENT$BOLD" "$title" "$R" \
    "$C_DIM$(repeat_str "$G_DASH" "$pad_title")$G_TR$R" ""
  printf '%s%s%s %s%s%s%s%s\n' \
    "$C_DIM" "$G_VBAR" "$R" "$C_SUBTLE" "$meta" "$R" \
    "$C_DIM" "$(repeat_str ' ' "$pad_meta")$G_VBAR$R"
  printf '%s%s%s%s\n' "$C_DIM" "$G_BL" "$(repeat_str "$G_DASH" "$inner_w")$G_BR" "$R"
  printf '\n'
}

print_row() {
  local status="$1" name="$2" cat="$3" ip="$4" isp="$5" asn="$6" country="$7" reason="$8" url="$9" ttfb="${10}"
  local total_w_name=22 total_w_cat=12 total_w_ip=18 glyph color name_color masked right=""
  if [[ "$status" == "OK" ]]; then
    glyph="$G_OK"; color="$C_OK"; name_color=""
  else
    glyph="$G_FAIL"; color="$C_FAIL"; name_color="$C_DIM"
  fi
  name=$(trunc "$name" "$total_w_name")
  cat=$(trunc "$cat" "$total_w_cat")

  if [[ "$status" == "OK" && -n "$ip" ]]; then
    masked=$(mask_ip "$ip")
    [[ -n "$country" && "$country" != "N/A" ]] && right="$country"
    [[ -n "$asn" && "$asn" != "N/A" ]] && right="${right:+$right $G_BULLET }$asn"
    [[ -n "$isp" && "$isp" != "N/A" ]] && right="${right:+$right }$(trunc "$isp" 26)"
    [[ -n "$ttfb" && "$ttfb" != "0" ]] && right="${right:+$right $G_BULLET }${ttfb}ms"
    printf '  %s%s%s  %-*s  %s%-*s%s  %s%-*s%s  %s%s%s\n' \
      "$color" "$glyph" "$R" "$total_w_name" "$name" \
      "$C_SUBTLE" "$total_w_cat" "$cat" "$R" \
      "$BOLD" "$total_w_ip" "$masked" "$R" \
      "$C_SUBTLE" "$right" "$R"
  else
    printf '  %s%s%s  %s%-*s%s  %s%-*s%s  %s%s %s%s\n' \
      "$color" "$glyph" "$R" "$name_color" "$total_w_name" "$name" "$R" \
      "$C_DIM" "$total_w_cat" "$cat" "$R" "$C_DIM" "$G_LEAD" "${reason:-no-data}" "$R"
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

render_bar() {
  local filled="$1" total="$2" i out=""
  for ((i=0; i<total; i++)); do
    if [[ $i -lt $filled ]]; then out="${out}${G_BAR_FILL}"; else out="${out}${G_BAR_EMPTY}"; fi
  done
  printf '%s' "$out"
}

print_summary() {
  local total ok fail unique max_count
  total=$(awk -F'|' '{n++} END{print n+0}' "$TMP_ROWS")
  ok=$(awk -F'|' '$1=="OK"{n++} END{print n+0}' "$TMP_ROWS")
  fail=$((total - ok))
  unique=$(awk -F'|' '$1=="OK" && $6!=""{print $6}' "$TMP_ROWS" | sort -u | wc -l | tr -d ' ')

  section_header "Summary"
  printf '    %sCloudflare%s   %s%s%s ok  %s%s%s  %s%s%s fail  %s%s%s  %s%s%s unique IP%s\n' \
    "$C_ACCENT$BOLD" "$R" \
    "$BOLD$C_OK" "$ok" "$R" "$C_DIM" "$G_BULLET" "$R" \
    "$BOLD$C_FAIL" "$fail" "$R" "$C_DIM" "$G_BULLET" "$R" \
    "$BOLD$C_ACCENT" "$unique" "$R" "$([[ $unique -ne 1 ]] && echo s)"

  if [[ "$ok" -gt 0 ]]; then
    section_header "Source IP Distribution"
    max_count=$(awk -F'|' '$1=="OK" && $6!=""{print $6 "|" $7 "|" $8 "|" $9}' "$TMP_ROWS" |
      sort | uniq -c | awk '{print $1}' | sort -nr | head -1)
    [[ -z "$max_count" || "$max_count" -eq 0 ]] && max_count=1

    awk -F'|' '$1=="OK" && $6!=""{print $6 "|" $7 "|" $8 "|" $9}' "$TMP_ROWS" |
      sort |
      awk -F'|' '{key=$1 "|" $2 "|" $3 "|" $4; count[key]++} END{for (k in count) print count[k] "|" k}' |
      sort -t'|' -k1,1nr |
      while IFS='|' read -r count ip isp asn country; do
        local filled bar masked_ip line_meta=""
        filled=$((count * 20 / max_count))
        [[ "$filled" -lt 1 && "$count" -gt 0 ]] && filled=1
        bar=$(render_bar "$filled" 20)
        masked_ip=$(mask_ip "$ip")
        [[ -n "$country" && "$country" != "N/A" ]] && line_meta="$country"
        [[ -n "$asn" && "$asn" != "N/A" ]] && line_meta="${line_meta:+$line_meta $G_BULLET }$asn"
        [[ -n "$isp" && "$isp" != "N/A" ]] && line_meta="${line_meta:+$line_meta }$(trunc "$isp" 26)"
        printf '    %s%s%s  %s%2d%s  %s%-16s%s  %s%s%s\n' \
          "$C_ACCENT" "$bar" "$R" "$BOLD" "$count" "$R" "$BOLD" "$masked_ip" "$R" "$C_SUBTLE" "$line_meta" "$R"
      done
  fi

  if [[ "$unique" -gt 1 ]]; then
    printf '\n  %s%s%s  %sDifferent Cloudflare sites observed different source IPs%s — likely split routing or policy NAT.\n' \
      "$C_WARN" "$G_WARN" "$R" "$BOLD" "$R"
  fi

  section_header "Hints"
  if [[ "$MASK_IP" -eq 1 ]]; then
    printf '    %s%s%s pass %s--show-ip%s to reveal full addresses\n' "$C_DIM" "$G_TIP" "$R" "$BOLD" "$R"
  fi
  printf '    %s%s%s add a specific Cloudflare-backed site with %s--cf example.com%s\n' \
    "$C_DIM" "$G_TIP" "$R" "$BOLD" "$R"
  printf '    %s%s%s non-Cloudflare sites that do not expose your IP cannot be verified by this script\n\n' \
    "$C_DIM" "$G_TIP" "$R"
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
  printf '\r%*s\r' 80 ''
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
