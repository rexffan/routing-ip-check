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

VERSION="1.0.0"
IP_FLAG="-4"
IP_LABEL="IPv4"
TIMEOUT=8
NO_PROXY=0
PROXY_URL=""
DO_ASN=1
JSON=0

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
      --add NAME=URL      Add a custom IP echo URL
      --cf HOST           Add Cloudflare trace probe: https://HOST/cdn-cgi/trace
      --file FILE         Add probes from FILE, one "name|url" or "name|cat|url" per line
  -h, --help              Show help

Examples:
  ./egress-realip-check.sh -4
  ./egress-realip-check.sh --no-proxy
  ./egress-realip-check.sh --proxy socks5h://127.0.0.1:1080
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
      url="$cat"
      cat="Custom"
    fi
    add_probe "$name" "$cat" "$url"
  done < "$file"
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

need_cmd curl
need_cmd sed
need_cmd awk
need_cmd grep
need_cmd sort

TMP_ROWS=$(mktemp)
trap 'rm -f "$TMP_ROWS"' EXIT

curl_common=(
  --silent
  --show-error
  --location
  --max-time "$TIMEOUT"
  --connect-timeout "$TIMEOUT"
  --user-agent "egress-realip-check/$VERSION"
)

if [[ "$NO_PROXY" -eq 1 ]]; then
  curl_common+=(--noproxy '*')
fi

if [[ -n "$PROXY_URL" ]]; then
  curl_common+=(--proxy "$PROXY_URL")
fi

extract_ip() {
  local body="$1"

  if [[ "$IP_FLAG" == "-4" ]]; then
    printf '%s\n' "$body" |
      grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' |
      awk -F. '($1<=255 && $2<=255 && $3<=255 && $4<=255){print; exit}'
  else
    printf '%s\n' "$body" |
      grep -Eio '([0-9a-f]{0,4}:){2,7}[0-9a-f]{0,4}' |
      awk 'length($0) >= 3 {print; exit}'
  fi
}

asn_lookup() {
  local ip="$1"
  local info status country isp asn

  if [[ "$DO_ASN" -eq 0 ]]; then
    printf '|||'
    return
  fi

  info=$(curl --silent --show-error --max-time 5 \
    "http://ip-api.com/line/$ip?fields=status,country,isp,as" 2>/dev/null || true)

  status=$(printf '%s\n' "$info" | sed -n '1p')
  country=$(printf '%s\n' "$info" | sed -n '2p')
  isp=$(printf '%s\n' "$info" | sed -n '3p')
  asn=$(printf '%s\n' "$info" | sed -n '4p')

  if [[ "$status" != "success" ]]; then
    printf 'N/A|N/A|N/A'
    return
  fi

  printf '%s|%s|%s' "$(clean_field "$country")" "$(clean_field "$isp")" "$(clean_field "$asn")"
}

probe_one() {
  local name="$1" cat="$2" url="$3"
  local host body rc ip meta country isp asn status

  host=$(strip_url_host "$url")
  body=$(curl "${curl_common[@]}" "$IP_FLAG" "$url" 2>/dev/null)
  rc=$?
  ip=""

  if [[ "$rc" -eq 0 && -n "$body" ]]; then
    ip=$(extract_ip "$body")
  fi

  if [[ -z "$ip" ]]; then
    status="FAIL"
    country=""
    isp=""
    asn=""
  else
    status="OK"
    meta=$(asn_lookup "$ip")
    IFS='|' read -r country isp asn <<< "$meta"
  fi

  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "$status" "$(clean_field "$name")" "$(clean_field "$cat")" "$(clean_field "$host")" \
    "$(clean_field "$url")" "$(clean_field "$ip")" "$(clean_field "$isp")" \
    "$(clean_field "$asn")" "$(clean_field "$country")" >> "$TMP_ROWS"
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
  printf '\n'
}

print_table() {
  printf '  %-4s  %-24s  %-11s  %-16s  %-39s  %-18s  %-28s  %-12s  %s\n' \
    "OK" "Probe" "Category" "Observed IP" "Host" "ASN" "ISP" "Country" "URL"
  printf '  %s\n' "$(printf '%*s' 160 '' | tr ' ' '-')"

  while IFS='|' read -r status name cat host url ip isp asn country; do
    local mark color shown_ip shown_isp shown_asn shown_country

    if [[ "$status" == "OK" ]]; then
      mark="yes"
      color="$GREEN"
    else
      mark="no"
      color="$RED"
    fi

    shown_ip="${ip:-timeout/no-ip}"
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
  while IFS='|' read -r status name cat host url ip isp asn country; do
    printf '{"status":"%s","name":"%s","category":"%s","host":"%s","url":"%s","ip":"%s","isp":"%s","asn":"%s","country":"%s"}\n' \
      "$(json_escape "$status")" "$(json_escape "$name")" "$(json_escape "$cat")" \
      "$(json_escape "$host")" "$(json_escape "$url")" "$(json_escape "$ip")" \
      "$(json_escape "$isp")" "$(json_escape "$asn")" "$(json_escape "$country")"
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

  printf '\n%sTip:%s for a Cloudflare-backed target, run: %s --cf example.com\n' "$CYAN" "$R" "$0"
}

print_header

for entry in "${PROBES[@]}"; do
  IFS='|' read -r name cat url <<< "$entry"
  printf '  %schecking%s %s\n' "$GRAY" "$R" "$name" >&2
  probe_one "$name" "$cat" "$url"
done

if [[ "$JSON" -eq 1 ]]; then
  print_json
else
  printf '\033[2K\r' >&2
  print_table
  print_summary
fi
