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

VERSION="1.3.0"
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

R=$'\033[0m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
RED=$'\033[31m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
BLUE=$'\033[34m'
CYAN=$'\033[36m'
GRAY=$'\033[90m'

PROBES=(
  "ipify|IP Echo|https://api.ipify.org"
  "ifconfig.me|IP Echo|https://ifconfig.me/ip"
  "icanhazip|IP Echo|https://icanhazip.com"
  "ident.me|IP Echo|https://ident.me"
  "ifconfig.co|IP Echo|https://ifconfig.co/ip"
  "ipinfo.io|IP Echo|https://ipinfo.io/ip"
  "ip.sb|IP Echo|https://api.ip.sb/ip"
  "AWS checkip|Cloud|https://checkip.amazonaws.com"
  "Cloudflare trace|CDN Trace|https://www.cloudflare.com/cdn-cgi/trace"
  "Cloudflare 1.1.1.1|CDN Trace|https://one.one.one.one/cdn-cgi/trace"
  "ipip.net|Asia Echo|https://myip.ipip.net"
)

TARGET_PROBES=(
  "x.com|Social|https://x.com/cdn-cgi/trace|cf"
  "twitter.com|Social|https://twitter.com/cdn-cgi/trace|cf"
  "linkedin.com|Social|https://linkedin.com/cdn-cgi/trace|cf"
  "quora.com|Social|https://quora.com/cdn-cgi/trace|cf"
  "medium.com|Social|https://medium.com/cdn-cgi/trace|cf"
  "wise.com|Finance|https://wise.com/cdn-cgi/trace|cf"
  "revolut.com|Finance|https://revolut.com/cdn-cgi/trace|cf"
  "LINE Bank TW|TW Finance|https://www.linebank.com.tw/cdn-cgi/trace|cf"
  "PX Pay|TW Finance|https://www.pxpay.com/cdn-cgi/trace|cf"
  "coinbase.com|Crypto|https://coinbase.com/cdn-cgi/trace|cf"
  "okx.com|Crypto|https://okx.com/cdn-cgi/trace|cf"
  "kraken.com|Crypto|https://kraken.com/cdn-cgi/trace|cf"
  "MaiCoin|TW Crypto|https://www.maicoin.com/cdn-cgi/trace|cf"
  "MAX Exchange|TW Crypto|https://max.maicoin.com/cdn-cgi/trace|cf"
  "temu.com|Shopping|https://temu.com/cdn-cgi/trace|cf"
  "shopify.com|Shopping|https://shopify.com/cdn-cgi/trace|cf"
  "ikea.com|Shopping|https://ikea.com/cdn-cgi/trace|cf"
  "Books TW|TW Shopping|https://www.books.com.tw/cdn-cgi/trace|cf"
  "Ruten|TW Shopping|https://www.ruten.com.tw/cdn-cgi/trace|cf"
  "Buy123|TW Shopping|https://www.buy123.com.tw/cdn-cgi/trace|cf"
  "citiesocial|TW Shopping|https://www.citiesocial.com/cdn-cgi/trace|cf"
  "openai.com|AI/Work|https://openai.com/cdn-cgi/trace|cf"
  "canva.com|AI/Work|https://canva.com/cdn-cgi/trace|cf"
  "notion.so|AI/Work|https://notion.so/cdn-cgi/trace|cf"
)

TARGET_ALL_PROBES=(
  "facebook.com|Social|https://facebook.com/cdn-cgi/trace|guess"
  "instagram.com|Social|https://instagram.com/cdn-cgi/trace|guess"
  "paypal.com|Finance|https://paypal.com/cdn-cgi/trace|guess"
  "amazon.com|Shopping|https://amazon.com/cdn-cgi/trace|guess"
  "momo TW|TW Shopping|https://www.momoshop.com.tw/cdn-cgi/trace|guess"
  "PChome TW|TW Shopping|https://24h.pchome.com.tw/cdn-cgi/trace|guess"
)

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
      --json              Print machine-readable JSON lines
      --targets           Include categorized target-site probes (default)
      --targets-all       Include unconfirmed target probes too
      --no-targets        Only run the basic IP echo probes
      --concurrency N     Number of concurrent probes (default: 1)
      --no-concurrency    Run probes serially
      --add NAME=URL      Add a custom IP echo URL
      --cf HOST           Add Cloudflare trace probe: https://HOST/cdn-cgi/trace
      --file FILE         Add probes from FILE, one "name|url" or "name|cat|url" per line
  -h, --help              Show help

Examples:
  ./egress-realip-check.sh -4
  ./egress-realip-check.sh --no-proxy
  ./egress-realip-check.sh --proxy socks5h://127.0.0.1:1080
  ./egress-realip-check.sh --targets
  ./egress-realip-check.sh --targets-all
  ./egress-realip-check.sh --concurrency 4
  ./egress-realip-check.sh --no-targets
  ./egress-realip-check.sh --cf example.com
  ./egress-realip-check.sh --add "my echo=https://echo.example.com/ip"

Notes:
  This script measures the real source IP seen by remote HTTP endpoints.
  It does not use mtr/traceroute, because route hops are not egress source IPs.
EOF
}

die() {
  printf '%sError:%s %s\n' "$RED" "$R" "$*" >&2
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
  local name="$1" cat="$2" url="$3"
  [[ -n "$name" ]] || die "probe name is empty"
  [[ "$url" =~ ^https?:// ]] || die "probe URL must start with http:// or https://: $url"
  PROBES+=("$(clean_field "$name")|$(clean_field "$cat")|$(clean_field "$url")")
}

add_probe_file() {
  local file="$1"
  [[ -f "$file" ]] || die "probe file not found: $file"

  local line name cat url
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=$(printf '%s' "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    [[ -z "$line" || "$line" == \#* ]] && continue

    IFS='|' read -r name cat url _ <<< "$line"
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
    add_probe "$name" "$cat" "$url"
  done < "$file"
}

add_target_probes() {
  local entry
  [[ "$TARGETS_ADDED" -eq 1 ]] && return
  for entry in "${TARGET_PROBES[@]}"; do
    PROBES+=("$entry")
  done
  if [[ "$INCLUDE_TARGETS_ALL" -eq 1 ]]; then
    for entry in "${TARGET_ALL_PROBES[@]}"; do
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
      add_probe "$2 Cloudflare trace" "CDN Trace" "https://$2/cdn-cgi/trace"
      shift 2
      ;;
    --file)
      [[ $# -ge 2 ]] || die "--file needs a path"
      add_probe_file "$2"
      shift 2
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

need_cmd curl
need_cmd sed
need_cmd awk
need_cmd grep
need_cmd sort

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
  local name="$1" cat="$2" url="$3"
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

  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "$status" "$(clean_field "$name")" "$(clean_field "$cat")" "$(clean_field "$host")" \
    "$(clean_field "$url")" "$(clean_field "$ip")" "" "" "" \
    "$(clean_field "$http_code")" "$(clean_field "$reason")" "$(clean_field "$remote_ip")"
}

enrich_rows() {
  local enriched status name cat host url ip isp asn country http_code reason remote_ip meta
  enriched=$(mktemp)

  while IFS='|' read -r status name cat host url ip isp asn country http_code reason remote_ip; do
    if [[ "$status" == "OK" && -n "$ip" ]]; then
      meta=$(asn_lookup "$ip")
      IFS='|' read -r country isp asn <<< "$meta"
    fi
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
      "$status" "$name" "$cat" "$host" "$url" "$ip" "$isp" "$asn" "$country" \
      "$http_code" "$reason" "$remote_ip" >> "$enriched"
  done < "$TMP_ROWS"

  mv "$enriched" "$TMP_ROWS"
}

print_header() {
  printf '\n%sReal Egress IP Check%s %s%s%s\n' "$BOLD" "$R" "$DIM" "($IP_LABEL, remote HTTP-observed source IP)" "$R"
  printf '%s\n' "${GRAY}No mtr/traceroute hop is used as an IP result.${R}"
  if [[ "$NO_PROXY" -eq 1 ]]; then
    printf '%s\n' "${GRAY}Proxy mode: ignored curl proxy environment variables.${R}"
  elif [[ -n "$PROXY_URL" ]]; then
    printf '%s\n' "${GRAY}Proxy mode: using $PROXY_URL.${R}"
  else
    printf '%s\n' "${GRAY}Proxy mode: curl default environment, if any.${R}"
  fi
  printf '%s\n' "${GRAY}Concurrency: $CONCURRENCY.${R}"
  printf '\n'
}

print_table() {
  printf '  %-4s  %-24s  %-11s  %-16s  %-39s  %-18s  %-28s  %-12s  %s\n' \
    "OK" "Probe" "Category" "IP / Reason" "Host" "ASN" "ISP" "Country" "URL"
  printf '  %s\n' "$(printf '%*s' 160 '' | tr ' ' '-')"

  while IFS='|' read -r status name cat host url ip isp asn country http_code reason remote_ip; do
    local mark color shown_ip shown_isp shown_asn shown_country

    if [[ "$status" == "OK" ]]; then
      mark="yes"
      color="$GREEN"
    else
      mark="no"
      color="$RED"
    fi

    shown_ip="${ip:-${reason:-timeout/no-ip}}"
    shown_isp="${isp:-N/A}"
    shown_asn="${asn:-N/A}"
    shown_country="${country:-N/A}"

    [[ ${#name} -gt 24 ]] && name="${name:0:21}..."
    [[ ${#cat} -gt 11 ]] && cat="${cat:0:8}..."
    [[ ${#host} -gt 39 ]] && host="${host:0:36}..."
    [[ ${#shown_isp} -gt 28 ]] && shown_isp="${shown_isp:0:25}..."
    [[ ${#shown_asn} -gt 18 ]] && shown_asn="${shown_asn:0:15}..."

    printf '  %b%-4s%b  %-24s  %-11s  %-16s  %-39s  %-18s  %-28s  %-12s  %s\n' \
      "$color" "$mark" "$R" "$name" "$cat" "$shown_ip" "$host" \
      "$shown_asn" "$shown_isp" "$shown_country" "$url"
  done < "$TMP_ROWS"
}

print_json() {
  while IFS='|' read -r status name cat host url ip isp asn country http_code reason remote_ip; do
    printf '{"status":"%s","name":"%s","category":"%s","host":"%s","url":"%s","ip":"%s","isp":"%s","asn":"%s","country":"%s","http_code":"%s","reason":"%s","remote_ip":"%s"}\n' \
      "$(json_escape "$status")" "$(json_escape "$name")" "$(json_escape "$cat")" \
      "$(json_escape "$host")" "$(json_escape "$url")" "$(json_escape "$ip")" \
      "$(json_escape "$isp")" "$(json_escape "$asn")" "$(json_escape "$country")" \
      "$(json_escape "$http_code")" "$(json_escape "$reason")" "$(json_escape "$remote_ip")"
  done < "$TMP_ROWS"
}

print_summary() {
  local total ok fail unique
  total=$(wc -l < "$TMP_ROWS" | tr -d ' ')
  ok=$(awk -F'|' '$1=="OK"{n++} END{print n+0}' "$TMP_ROWS")
  fail=$(( total - ok ))
  unique=$(awk -F'|' '$1=="OK" && $6!=""{print $6}' "$TMP_ROWS" | sort -u | wc -l | tr -d ' ')

  printf '\n%sSummary%s\n' "$BOLD" "$R"
  printf '  Total probes: %s, OK: %s, Fail: %s, unique observed IPs: %s\n' "$total" "$ok" "$fail" "$unique"

  if [[ "$ok" -gt 0 ]]; then
    printf '\n  %sObserved IP distribution%s\n' "$BOLD" "$R"
    awk -F'|' '$1=="OK"{print $6 "|" $7 "|" $8 "|" $9}' "$TMP_ROWS" |
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
        [[ ${#isp} -gt 38 ]] && isp="${isp:0:35}..."
        printf '  %-4s %-16s  %-38s  %-18s  %s\n' "$count" "$ip" "$isp" "$asn" "$country"
      done
  fi

  if [[ "$unique" -gt 1 ]]; then
    printf '\n  %s%sMultiple observed egress IPs detected.%s This usually means domain/proxy/policy routing is active.\n' "$YELLOW" "$BOLD" "$R"
  fi

  local cmd_name
  cmd_name="$0"
  if [[ "$cmd_name" == /dev/fd/* || "$cmd_name" == "bash" ]]; then
    cmd_name="egress-realip-check.sh"
  fi
  printf '\n%sTip:%s for a Cloudflare-backed target, run: %s --cf example.com\n' "$CYAN" "$R" "$cmd_name"
}

run_probes() {
  local total idx entry name cat url out running
  total=${#PROBES[@]}

  if [[ "$CONCURRENCY" -le 1 ]]; then
    idx=0
    for entry in "${PROBES[@]}"; do
      IFS='|' read -r name cat url _ <<< "$entry"
      printf '  %schecking%s %s\n' "$GRAY" "$R" "$name" >&2
      probe_one "$name" "$cat" "$url" > "$TMP_DIR/$idx.row"
      idx=$((idx + 1))
    done
  else
    printf '  %srunning %s probes with concurrency %s...%s\n' "$GRAY" "$total" "$CONCURRENCY" "$R" >&2
    idx=0
    for entry in "${PROBES[@]}"; do
      while true; do
        running=$(jobs -pr | wc -l | tr -d ' ')
        [[ "$running" -lt "$CONCURRENCY" ]] && break
        sleep 0.1
      done
      IFS='|' read -r name cat url _ <<< "$entry"
      out="$TMP_DIR/$idx.row"
      ( probe_one "$name" "$cat" "$url" > "$out" ) &
      idx=$((idx + 1))
    done
    wait
  fi

  idx=0
  while [[ "$idx" -lt "$total" ]]; do
    if [[ -f "$TMP_DIR/$idx.row" ]]; then
      cat "$TMP_DIR/$idx.row" >> "$TMP_ROWS"
    fi
    idx=$((idx + 1))
  done
}

if [[ "$JSON" -ne 1 ]]; then
  print_header
fi
run_probes
enrich_rows

if [[ "$JSON" -eq 1 ]]; then
  print_json
else
  printf '\033[2K\r' >&2
  print_table
  print_summary
fi
