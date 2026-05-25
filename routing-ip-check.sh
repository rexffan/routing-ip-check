#!/usr/bin/env bash
#
# routing-ip-check.sh
#
# Routing Source IP Detection — show the real egress IP observed by remote
# HTTP services.
#
# How it works:
#   Sends HTTPS requests to a curated list of endpoints that echo back the
#   client IP they see (ipify, ifconfig.me, Cloudflare /cdn-cgi/trace, …),
#   then summarises the results with ASN / ISP / country lookups. Multiple
#   distinct egress IPs in one run usually means policy-based split routing.
#
# Important limitation:
#   A target website must return your client IP for us to know what that exact
#   website sees. For arbitrary domains, no script can prove the site-specific
#   source IP without cooperation from that remote side. For Cloudflare-backed
#   sites, try: --cf example.com

set -u

VERSION="1.6.0"
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
AUDIT_PRESETS=()        # set by --audit PRESET (may repeat)

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
  # Local — Cloudflare-confirmed
  "Dcard|Forum|https://dcard.tw/cdn-cgi/trace|cf"
  "Bahamut|Forum|https://www.gamer.com.tw/cdn-cgi/trace|cf"
  "Plurk|Forum|https://www.plurk.com/cdn-cgi/trace|cf"
  "PanSci|Media|https://pansci.asia/cdn-cgi/trace|cf"
  "chinatimes.com|Media|https://www.chinatimes.com/cdn-cgi/trace|cf"
  "104.com.tw|Career|https://www.104.com.tw/cdn-cgi/trace|cf"
  "StockFeel|Finance|https://www.stockfeel.com.tw/cdn-cgi/trace|cf"
  "LINE Bank|Finance|https://www.linebank.com.tw/cdn-cgi/trace|cf"
  "PX Pay|Finance|https://www.pxpay.com/cdn-cgi/trace|cf"
  "MaiCoin|Crypto|https://www.maicoin.com/cdn-cgi/trace|cf"
  "MAX Exchange|Crypto|https://max.maicoin.com/cdn-cgi/trace|cf"
  "books.com.tw|Shopping|https://www.books.com.tw/cdn-cgi/trace|cf"
  "Ruten|Shopping|https://www.ruten.com.tw/cdn-cgi/trace|cf"
  "Buy123|Shopping|https://www.buy123.com.tw/cdn-cgi/trace|cf"
  "citiesocial|Shopping|https://www.citiesocial.com/cdn-cgi/trace|cf"
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
  # Forums / community
  "Mobile01|Forum|https://www.mobile01.com/|connectivity"
  "PTT|Forum|https://www.ptt.cc/|connectivity"
  "PIXNET|Forum|https://www.pixnet.net/|connectivity"
  # Media / news
  "UDN|Media|https://udn.com/|connectivity"
  "LTN|Media|https://www.ltn.com.tw/|connectivity"
  "ETtoday|Media|https://www.ettoday.net/|connectivity"
  "TVBS|Media|https://news.tvbs.com.tw/|connectivity"
  "FTV|Media|https://www.ftvnews.com.tw/|connectivity"
  # Finance / banks
  "E.SUN Bank|Finance|https://www.esunbank.com.tw/|connectivity"
  "Cathay United|Finance|https://www.cathaybk.com.tw/|connectivity"
  "CTBC|Finance|https://www.ctbcbank.com/|connectivity"
  "Fubon|Finance|https://www.fubon.com/|connectivity"
  "Mega Bank|Finance|https://www.megabank.com.tw/|connectivity"
  "bot.com.tw|Finance|https://www.bot.com.tw/|connectivity"
  "SinoPac|Finance|https://bank.sinopac.com/|connectivity"
  "Taishin|Finance|https://www.taishinbank.com.tw/|connectivity"
  "First Bank|Finance|https://www.firstbank.com.tw/|connectivity"
  "MoneyDJ|Finance|https://www.moneydj.com/|connectivity"
  "cnYES|Finance|https://www.cnyes.com/|connectivity"
  # Government / public
  "president.gov.tw|Gov|https://www.president.gov.tw/|connectivity"
  "ey.gov.tw|Gov|https://www.ey.gov.tw/|connectivity"
  "ly.gov.tw|Gov|https://www.ly.gov.tw/|connectivity"
  "judicial.gov.tw|Gov|https://www.judicial.gov.tw/|connectivity"
  "moi.gov.tw|Gov|https://www.moi.gov.tw/|connectivity"
  "mof.gov.tw|Gov|https://www.mof.gov.tw/|connectivity"
  "mohw.gov.tw|Gov|https://www.mohw.gov.tw/|connectivity"
  "moe.gov.tw|Gov|https://www.moe.gov.tw/|connectivity"
  "NHI|Gov|https://www.nhi.gov.tw/|connectivity"
  "CDC|Gov|https://www.cdc.gov.tw/|connectivity"
  "etax.nat.gov.tw|Gov|https://www.etax.nat.gov.tw/|connectivity"
  "post.gov.tw|Gov|https://www.post.gov.tw/|connectivity"
  # Telecom / ISP
  "Chunghwa Telecom|Telecom|https://www.cht.com.tw/|connectivity"
  "TWM|Telecom|https://www.taiwanmobile.com/|connectivity"
  "FET|Telecom|https://www.fetnet.net/|connectivity"
  # Career / shopping fallbacks
  "1111.com.tw|Career|https://www.1111.com.tw/|connectivity"
  "591.com.tw|Shopping|https://www.591.com.tw/|connectivity"
  "momoshop|Shopping|https://www.momoshop.com.tw/|connectivity"
  "PChome|Shopping|https://24h.pchome.com.tw/|connectivity"
  "Shopee|Shopping|https://shopee.tw/|connectivity"
  # Transport / ticketing
  "THSR|Transport|https://www.thsrc.com.tw/|connectivity"
  "TRA|Transport|https://www.railway.gov.tw/|connectivity"
  "EasyCard|Transport|https://www.easycard.com.tw/|connectivity"
  # Misc
  "KKBOX|Media|https://www.kkbox.com/|connectivity"
  "LINE|App|https://line.me/|connectivity"
)

# Legacy alias — older code paths may still reference TARGET_ALL_PROBES.
TARGET_ALL_PROBES=("${CONNECTIVITY_PROBES[@]}")

# ----------------------------------------------------------------------------
# Audit presets — service-identity checks.
#
# Each preset declares:
#   audit_preset_<name>_hosts   — pipe-separated entries "label|url"
#   audit_preset_<name>_asn     — space-separated AS numbers expected
#   audit_preset_<name>_issuer  — regex of cert issuer keywords expected
#
# Verdict logic (per host):
#   1. If dest IP ASN matches one of the expected ASNs       → ASN ok
#      Otherwise                                             → ASN mismatch
#      (short-circuit: cert check skipped on ASN mismatch)
#   2. If ASN ok, fetch TLS cert issuer:
#      Issuer matches expected regex                          → cert ok
#      Otherwise                                              → cert mismatch
# ----------------------------------------------------------------------------

audit_preset_list() {
  printf 'meta google cloudflare openai reddit github'
}

audit_preset_hosts() {
  case "$1" in
    meta) cat <<'EOF'
facebook.com|https://www.facebook.com/
m.facebook.com|https://m.facebook.com/
l.facebook.com|https://l.facebook.com/
business.facebook.com|https://business.facebook.com/
instagram.com|https://www.instagram.com/
i.instagram.com|https://i.instagram.com/
graph.instagram.com|https://graph.instagram.com/
help.instagram.com|https://help.instagram.com/
whatsapp.com|https://www.whatsapp.com/
web.whatsapp.com|https://web.whatsapp.com/
whatsapp.net|https://whatsapp.net/
static.whatsapp.net|https://static.whatsapp.net/
messenger.com|https://www.messenger.com/
threads.net|https://www.threads.net/
graph.facebook.com|https://graph.facebook.com/
graph-video.facebook.com|https://graph-video.facebook.com/
connect.facebook.net|https://connect.facebook.net/
static.xx.fbcdn.net|https://static.xx.fbcdn.net/
video.xx.fbcdn.net|https://video.xx.fbcdn.net/
scontent.xx.fbcdn.net|https://scontent.xx.fbcdn.net/
scontent.cdninstagram.com|https://scontent.cdninstagram.com/
static.cdninstagram.com|https://static.cdninstagram.com/
EOF
      ;;
    google) cat <<'EOF'
google.com|https://www.google.com/
gmail.com|https://mail.google.com/
youtube.com|https://www.youtube.com/
drive.google.com|https://drive.google.com/
docs.google.com|https://docs.google.com/
maps.google.com|https://maps.google.com/
translate.google.com|https://translate.google.com/
play.google.com|https://play.google.com/
EOF
      ;;
    cloudflare) cat <<'EOF'
cloudflare.com|https://www.cloudflare.com/
1.1.1.1|https://1.1.1.1/
dash.cloudflare.com|https://dash.cloudflare.com/
workers.cloudflare.com|https://workers.cloudflare.com/
developers.cloudflare.com|https://developers.cloudflare.com/
EOF
      ;;
    openai) cat <<'EOF'
openai.com|https://openai.com/
chatgpt.com|https://chatgpt.com/
chat.openai.com|https://chat.openai.com/
api.openai.com|https://api.openai.com/
platform.openai.com|https://platform.openai.com/
EOF
      ;;
    reddit) cat <<'EOF'
reddit.com|https://www.reddit.com/
old.reddit.com|https://old.reddit.com/
i.redd.it|https://i.redd.it/
v.redd.it|https://v.redd.it/
preview.redd.it|https://preview.redd.it/
EOF
      ;;
    github) cat <<'EOF'
github.com|https://github.com/
api.github.com|https://api.github.com/
gist.github.com|https://gist.github.com/
codeload.github.com|https://codeload.github.com/
raw.githubusercontent.com|https://raw.githubusercontent.com/
objects.githubusercontent.com|https://objects.githubusercontent.com/
EOF
      ;;
  esac
}

audit_preset_asn() {
  case "$1" in
    meta)        printf '32934' ;;
    google)      printf '15169 396982 396981' ;;
    cloudflare)  printf '13335' ;;
    openai)      printf '13335' ;;                # CF-fronted
    reddit)      printf '54113 16509' ;;          # Fastly + AWS for media subdomains
    github)      printf '36459 13335' ;;          # GitHub own + CF for githubusercontent
  esac
}

audit_preset_issuer() {
  case "$1" in
    meta)        printf 'DigiCert|Meta Platforms' ;;
    google)      printf 'Google Trust Services|GTS CA|GTS Root|WE1|WR2' ;;
    cloudflare)  printf 'Cloudflare|Google Trust Services|DigiCert|Lets Encrypt|Let.s Encrypt|SSL Corp|SSL\.com|WE1|WR2' ;;
    openai)      printf 'Cloudflare|DigiCert|WE1|GTS CA' ;;
    reddit)      printf 'Let.s Encrypt|DigiCert|Amazon|Cloudflare' ;;
    github)      printf 'DigiCert|Sectigo|Cloudflare|Lets Encrypt|Let.s Encrypt|^R[0-9]+$|^E[0-9]+$|R10|R11|R12' ;;
  esac
}

audit_preset_label() {
  case "$1" in
    meta)        printf 'Meta (Facebook, Instagram, WhatsApp, Threads, Messenger)' ;;
    google)      printf 'Google (Search, Gmail, YouTube, Drive, Maps)' ;;
    cloudflare)  printf 'Cloudflare' ;;
    openai)      printf 'OpenAI / ChatGPT' ;;
    reddit)      printf 'Reddit' ;;
    github)      printf 'GitHub' ;;
  esac
}

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
      --targets           Include categorized target-site probes (default)
      --targets-all       Include unconfirmed target probes too (gov, banks, forums, etc.)
      --no-targets        Only run the basic IP echo probes
      --concurrency N     Number of concurrent probes (default: 1)
      --no-concurrency    Run probes serially
      --add NAME=URL      Add a custom IP echo URL
      --cf HOST           Add Cloudflare trace probe: https://HOST/cdn-cgi/trace
      --connectivity HOST Add a reachability probe (HEAD https://HOST/)
      --audit PRESET      Service-identity audit (compare dest IP ASN + TLS
                          cert issuer to expected). Repeatable. PRESET ∈
                          { meta, google, cloudflare, openai, reddit, github,
                          all }. Cert check is skipped when ASN already
                          disagrees with expected.
      --file FILE         Add probes from FILE — "name|url" or "name|cat|url"
                          or "name|cat|url|kind" (kind: ipecho|cf|connectivity)
      --show-ip           Reveal full IP addresses (default: mask last 2 segments)
      --ascii             Disable Unicode glyphs and box-drawing (ASCII-only)
      --verbose           Show the URL column in the results table
      --no-install        Don't auto-install missing system packages — abort
                          instead. By default missing deps (curl, openssl,
                          etc.) are installed via apt/dnf/apk/brew.
  -h, --help              Show help

Environment:
  NO_COLOR=1              Disable ANSI colors entirely.

Examples:
  ./routing-ip-check.sh -4
  ./routing-ip-check.sh --no-proxy
  ./routing-ip-check.sh --proxy socks5h://127.0.0.1:1080
  ./routing-ip-check.sh --targets-all
  ./routing-ip-check.sh --concurrency 8
  ./routing-ip-check.sh --show-ip
  ./routing-ip-check.sh --cf example.com
  ./routing-ip-check.sh --add "my echo=https://echo.example.com/ip"

Notes:
  Routing Source IP Detection measures the real source IP seen by remote HTTP
  endpoints. By default the last 2 octets (IPv4) or hextets (IPv6) are masked
  so screenshots are safer to share. Use --show-ip when you actually need the
  full address.
EOF
}

die() {
  printf '%sError:%s %s\n' "${C_FAIL:-$'\033[31m'}" "${R:-$'\033[0m'}" "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

# ----------------------------------------------------------------------------
# Dependency check & auto-install
#
# Required at all times: curl sed awk grep sort
# Required if --audit is used: openssl
# Optional but nice: timeout (provided by coreutils on most distros)
#
# When something is missing the script tries to install it via the system
# package manager (apt-get / dnf / yum / apk / pacman / brew). If that fails
# or the user isn't root and sudo isn't available, the script aborts with a
# clear "please install X" message.
#
# Disable auto-install with --no-install.
# ----------------------------------------------------------------------------
AUTO_INSTALL=1

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

# Map command name → package name (most are identical; only override when not).
pkg_name_for() {
  case "$1" in
    awk)     printf 'gawk' ;;     # most distros, mawk on some, but gawk works
    timeout) printf 'coreutils' ;;
    *)       printf '%s' "$1" ;;
  esac
}

install_packages() {
  local pkgs=("$@") pm sudo_prefix=""

  pm=$(detect_pkg_manager)
  if [[ "$pm" == "none" ]]; then
    die "missing dependencies (${pkgs[*]}) and no supported package manager found. Install manually."
  fi

  if [[ "$EUID" -ne 0 && "$pm" != "brew" ]]; then
    if command -v sudo >/dev/null 2>&1; then
      sudo_prefix="sudo"
    else
      die "missing dependencies (${pkgs[*]}). Re-run as root or install manually with your package manager."
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
    dnf)    $sudo_prefix dnf install -y -q "${pkgs[@]}" >&2     || die "dnf install failed (${pkgs[*]})" ;;
    yum)    $sudo_prefix yum install -y -q "${pkgs[@]}" >&2     || die "yum install failed (${pkgs[*]})" ;;
    apk)    $sudo_prefix apk add --no-cache "${pkgs[@]}" >&2    || die "apk add failed (${pkgs[*]})" ;;
    pacman) $sudo_prefix pacman -Sy --noconfirm "${pkgs[@]}" >&2 || die "pacman install failed (${pkgs[*]})" ;;
    zypper) $sudo_prefix zypper --non-interactive install "${pkgs[@]}" >&2 || die "zypper install failed (${pkgs[*]})" ;;
    brew)   brew install "${pkgs[@]}" >&2                       || die "brew install failed (${pkgs[*]})" ;;
  esac
}

check_deps() {
  local required=(curl sed awk grep sort)
  local optional=()

  # Only enforce openssl when an audit was requested (cert chain verification).
  if [[ ${#AUDIT_PRESETS[@]} -gt 0 ]]; then
    required+=(openssl)
  fi

  local missing_cmds=() missing_pkgs=() cmd pkg
  for cmd in "${required[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing_cmds+=("$cmd")
      pkg=$(pkg_name_for "$cmd")
      # de-dupe
      local already=0 p
      for p in "${missing_pkgs[@]}"; do [[ "$p" == "$pkg" ]] && already=1 && break; done
      [[ "$already" -eq 0 ]] && missing_pkgs+=("$pkg")
    fi
  done

  [[ ${#missing_cmds[@]} -eq 0 ]] && return 0

  if [[ "$AUTO_INSTALL" -eq 0 ]]; then
    die "missing required commands: ${missing_cmds[*]} (auto-install disabled by --no-install)"
  fi

  install_packages "${missing_pkgs[@]}"

  # Re-verify
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
    --audit)
      [[ $# -ge 2 ]] || die "--audit needs a PRESET name"
      if [[ "$2" == "all" ]]; then
        for p in $(audit_preset_list); do AUDIT_PRESETS+=("$p"); done
      else
        case "$2" in
          meta|google|cloudflare|openai|reddit|github) AUDIT_PRESETS+=("$2") ;;
          *) die "--audit: unknown preset '$2' (valid: $(audit_preset_list), or all)" ;;
        esac
      fi
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
    --no-install)
      AUTO_INSTALL=0
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

# Inject audit-preset hosts as connectivity probes (kind=connectivity), tagged
# with category "audit:<preset>" so the verdict phase can find them later.
if [[ ${#AUDIT_PRESETS[@]} -gt 0 ]]; then
  for preset in "${AUDIT_PRESETS[@]}"; do
    while IFS='|' read -r label url; do
      [[ -z "$label" || -z "$url" ]] && continue
      add_probe "$label" "audit:$preset" "$url" "connectivity"
    done < <(audit_preset_hosts "$preset")
  done
fi

# JSON output is machine-consumed: force plain mode regardless of stdout TTY.
if [[ "$JSON" -eq 1 ]]; then
  USE_COLOR=0
  USE_UNICODE=0
fi

init_colors
init_glyphs

check_deps

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
  --user-agent "Mozilla/5.0 (compatible; routing-source-ip-detection/$VERSION; +https://github.com/rexffan/routing-ip-check)"
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

# Cert issuer lookup — used by the audit phase. Returns a single-line issuer
# string (e.g. "C=US, O=DigiCert Inc, CN=DigiCert SHA2 ..."). Empty on failure.
# Requires openssl; gracefully degrades if openssl is missing.
declare -A CERT_CACHE=()
CERT_AVAILABLE=1
command -v openssl >/dev/null 2>&1 || CERT_AVAILABLE=0

# Portable timeout: prefer GNU `timeout` / `gtimeout`; fall back to bg+kill.
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_CMD="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_CMD="gtimeout"
else
  TIMEOUT_CMD=""
fi

_run_with_deadline() {
  # $1 = seconds, rest = command. stdout captured by caller via $(...).
  local secs="$1"; shift
  if [[ -n "$TIMEOUT_CMD" ]]; then
    "$TIMEOUT_CMD" "$secs" "$@"
    return $?
  fi
  # Pure-bash fallback (less precise but works on BSD/macOS without coreutils).
  local outfile rc
  outfile=$(mktemp)
  ( "$@" > "$outfile" 2>/dev/null ) &
  local pid=$!
  ( sleep "$secs" && kill -KILL "$pid" 2>/dev/null ) &
  local killer=$!
  wait "$pid" 2>/dev/null
  rc=$?
  kill -KILL "$killer" 2>/dev/null
  wait "$killer" 2>/dev/null
  cat "$outfile"
  rm -f "$outfile"
  return "$rc"
}

get_cert_issuer() {
  local host="$1"
  [[ -z "$host" ]] && { printf ''; return; }
  if [[ "$CERT_AVAILABLE" -eq 0 ]]; then
    printf 'openssl-not-installed'; return
  fi
  if [[ -n "${CERT_CACHE[$host]+x}" ]]; then
    printf '%s' "${CERT_CACHE[$host]}"
    return
  fi
  local issuer
  issuer=$( _run_with_deadline 6 bash -c \
    "echo | openssl s_client -connect '$host:443' -servername '$host' 2>/dev/null \
       | openssl x509 -noout -issuer 2>/dev/null" \
    | sed -E 's/^issuer=//; s/[[:space:]]+/ /g; s/^ //; s/ $//')
  CERT_CACHE[$host]="$issuer"
  printf '%s' "$issuer"
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

  # Phase 1: pre-resolve ASN for unique IPs with progress reporting.
  # asn_lookup() caches by IP, so subsequent calls in the main loop are free.
  # This phase is the "几秒等待" the user was complaining about — surface it.
  if [[ "$DO_ASN" -eq 1 ]]; then
    local -a unique_ips=()
    while IFS= read -r ip; do
      [[ -n "$ip" ]] && unique_ips+=("$ip")
    done < <(awk -F'|' '$1=="OK" && $13!="connectivity" && $6!=""{print $6}' "$TMP_ROWS" | sort -u)

    local total_ips=${#unique_ips[@]} done_ips=0
    if [[ "$total_ips" -gt 0 ]]; then
      print_progress "Resolving" 0 "$total_ips"
      for ip in "${unique_ips[@]}"; do
        asn_lookup "$ip" >/dev/null
        done_ips=$((done_ips + 1))
        print_progress "Resolving" "$done_ips" "$total_ips"
      done
    fi
  fi

  # Phase 2: emit enriched rows (ASN cache hits are instant).
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

# ----------------------------------------------------------------------------
# Audit phase
#
# For each row tagged category="audit:<preset>":
#   1. Look up the ASN of remote_ip (the destination we actually reached).
#   2. If that ASN isn't in the preset's expected list → asn-mismatch (skip
#      cert check; the first detection method already concluded).
#   3. Otherwise fetch the TLS cert issuer:
#      - matches the preset's issuer regex          → ok
#      - doesn't match                              → cert-mismatch
#      - openssl not available                      → ok-asn-only (caveat)
#
# Writes one line per audit host to $TMP_DIR/audit.txt:
#   preset|name|host|verdict|asn_id|asn_name|cert_issuer|remote_ip
# ----------------------------------------------------------------------------
run_audit() {
  [[ ${#AUDIT_PRESETS[@]} -eq 0 ]] && return
  : > "$TMP_DIR/audit.txt"

  # Count audit-tagged rows for progress reporting.
  local total
  total=$(awk -F'|' '$3 ~ /^audit:/{n++} END{print n+0}' "$TMP_ROWS")
  [[ "$total" -eq 0 ]] && return
  print_progress "Auditing" 0 "$total"

  local done_audit=0
  while IFS='|' read -r status name cat host url ip isp asn country http_code reason remote_ip kind server ttfb_ms; do
    [[ "$cat" != audit:* ]] && continue
    local preset="${cat#audit:}"
    local expected_asn expected_issuer asn_meta observed_asn_name observed_asn_id
    local verdict="" cert_issuer="" asn_ok=0

    expected_asn=$(audit_preset_asn "$preset")
    expected_issuer=$(audit_preset_issuer "$preset")

    if [[ "$status" != "OK" || -z "$remote_ip" ]]; then
      verdict="unreachable"
    else
      asn_meta=$(asn_lookup "$remote_ip")
      observed_asn_name=$(printf '%s' "$asn_meta" | awk -F'|' '{print $3}')
      observed_asn_id=$(printf '%s' "$observed_asn_name" | grep -oE 'AS[0-9]+' | head -1 | sed 's/AS//')

      if [[ -z "$observed_asn_id" ]]; then
        # ASN lookup failed — fall through to cert check for what evidence we can get.
        cert_issuer=$(get_cert_issuer "$host")
        if [[ "$cert_issuer" == "openssl-not-installed" || -z "$cert_issuer" ]]; then
          verdict="inconclusive"
        elif printf '%s' "$cert_issuer" | grep -qiE "$expected_issuer"; then
          verdict="ok-cert-only"
        else
          verdict="cert-mismatch"
        fi
      else
        local a
        for a in $expected_asn; do
          [[ "$observed_asn_id" == "$a" ]] && { asn_ok=1; break; }
        done
        if [[ "$asn_ok" -eq 0 ]]; then
          verdict="asn-mismatch"     # short-circuit: skip cert check
        else
          cert_issuer=$(get_cert_issuer "$host")
          if [[ "$cert_issuer" == "openssl-not-installed" ]]; then
            verdict="ok-asn-only"
          elif [[ -z "$cert_issuer" ]]; then
            verdict="cert-fetch-failed"
          elif printf '%s' "$cert_issuer" | grep -qiE "$expected_issuer"; then
            verdict="ok"
          else
            verdict="cert-mismatch"
          fi
        fi
      fi
    fi

    printf '%s|%s|%s|%s|%s|%s|%s|%s\n' \
      "$preset" "$name" "$host" "$verdict" "${observed_asn_id:-}" \
      "$(clean_field "${observed_asn_name:-}")" \
      "$(clean_field "$cert_issuer")" "$remote_ip" \
      >> "$TMP_DIR/audit.txt"

    done_audit=$((done_audit + 1))
    print_progress "Auditing" "$done_audit" "$total"
  done < "$TMP_ROWS"
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
  local title="Routing Source IP Detection"
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
    cmd_name="routing-ip-check.sh"
  fi

  section_header "Hints"
  if [[ "$MASK_IP" -eq 1 ]]; then
    printf '    %s%s%s pass %s--show-ip%s to reveal full addresses\n' \
      "$C_DIM" "$G_TIP" "$R" "$BOLD" "$R"
  fi
  printf '    %s%s%s try %s%s --cf example.com%s to test a Cloudflare-fronted target\n' \
    "$C_DIM" "$G_TIP" "$R" "$BOLD" "$cmd_name" "$R"
  if [[ "$INCLUDE_TARGETS_ALL" -eq 0 ]]; then
    printf '    %s%s%s use %s--targets-all%s to add reachability probes for gov/banks/forums\n' \
      "$C_DIM" "$G_TIP" "$R" "$BOLD" "$R"
    printf '    %s%s%s connectivity probes %s%s%s %sreport reachability + latency only — they do not echo your IP%s\n' \
      "$C_DIM" "$G_TIP" "$R" "$C_DIM" "$G_DASH" "$R" "$C_DIM" "$R"
  fi
  printf '\n'
}

# ----------------------------------------------------------------------------
# Audit rendering — one block per preset, deduped by preset name.
# ----------------------------------------------------------------------------
declare -A _AUDIT_PRINTED=()

print_audit() {
  [[ ${#AUDIT_PRESETS[@]} -eq 0 ]] && return
  [[ ! -s "$TMP_DIR/audit.txt" ]] && return

  local preset
  for preset in "${AUDIT_PRESETS[@]}"; do
    [[ -n "${_AUDIT_PRINTED[$preset]:-}" ]] && continue
    _AUDIT_PRINTED[$preset]=1
    print_audit_preset "$preset"
  done
}

print_audit_preset() {
  local preset="$1"
  local label expected_asn expected_issuer asn_disp_list
  label=$(audit_preset_label "$preset")
  expected_asn=$(audit_preset_asn "$preset")
  expected_issuer=$(audit_preset_issuer "$preset")
  asn_disp_list=$(printf 'AS%s' "$(printf '%s' "$expected_asn" | sed 's/ /, AS/g')")

  section_header "Audit: $label"
  printf '    %sExpected:%s  %s  %s  cert issuer ~ %s\n\n' \
    "$C_SUBTLE" "$R" "$asn_disp_list" "$G_BULLET" "$expected_issuer"

  if [[ "$preset" == "meta" ]]; then
    printf '    %s%s%s %sNon-login Meta audit:%s verifies destination ASN/TLS identity only; Meta does not expose the source IP seen by its servers.\n\n' \
      "$C_DIM" "$G_TIP" "$R" "$C_SUBTLE" "$R"
  fi

  local ok_count=0 warn_count=0 unreach_count=0

  while IFS='|' read -r p name host verdict asn_id asn_name cert_issuer remote_ip; do
    [[ "$p" != "$preset" ]] && continue

    local glyph color status_text
    case "$verdict" in
      ok)
        glyph="$G_OK"; color="$C_OK"; status_text="ok"
        ok_count=$((ok_count + 1)) ;;
      ok-asn-only)
        glyph="$G_OK"; color="$C_OK"; status_text="asn ok (no openssl)"
        ok_count=$((ok_count + 1)) ;;
      ok-cert-only)
        glyph="$G_OK"; color="$C_OK"; status_text="cert ok (asn unknown)"
        ok_count=$((ok_count + 1)) ;;
      asn-mismatch)
        glyph="$G_WARN"; color="$C_WARN"; status_text="ASN mismatch"
        warn_count=$((warn_count + 1)) ;;
      cert-mismatch)
        glyph="$G_WARN"; color="$C_WARN"; status_text="cert mismatch"
        warn_count=$((warn_count + 1)) ;;
      cert-fetch-failed)
        glyph="$G_FAIL"; color="$C_DIM"; status_text="cert fetch failed"
        unreach_count=$((unreach_count + 1)) ;;
      inconclusive)
        glyph="$G_FAIL"; color="$C_DIM"; status_text="inconclusive"
        unreach_count=$((unreach_count + 1)) ;;
      unreachable)
        glyph="$G_FAIL"; color="$C_FAIL"; status_text="unreachable"
        unreach_count=$((unreach_count + 1)) ;;
      *)
        glyph="$G_FAIL"; color="$C_FAIL"; status_text="$verdict"
        unreach_count=$((unreach_count + 1)) ;;
    esac

    local masked_ip=""
    [[ -n "$remote_ip" ]] && masked_ip=$(mask_ip "$remote_ip")
    local asn_disp="${asn_id:+AS$asn_id}"
    [[ -z "$asn_disp" ]] && asn_disp="—"

    local issuer_disp=""
    if [[ -n "$cert_issuer" && "$cert_issuer" != "openssl-not-installed" ]]; then
      issuer_disp=$(printf '%s' "$cert_issuer" | sed -nE 's/.*CN=([^,]+).*/\1/p' | head -1)
      [[ -z "$issuer_disp" ]] && issuer_disp=$(printf '%s' "$cert_issuer" | sed -nE 's/.*O=([^,]+).*/\1/p' | head -1)
      issuer_disp=$(trunc "$issuer_disp" 26)
    elif [[ -z "$cert_issuer" ]]; then
      issuer_disp="—"
    else
      issuer_disp="(no openssl)"
    fi

    printf '    %s%s%s  %-22s  %-16s  %-10s  %-26s  %s%s%s\n' \
      "$color" "$glyph" "$R" \
      "$(trunc "$name" 22)" \
      "${masked_ip:-—}" \
      "$asn_disp" \
      "$issuer_disp" \
      "$color" "$status_text" "$R"
  done < "$TMP_DIR/audit.txt"

  printf '\n    %sVerdict:%s ' "$BOLD" "$R"
  if [[ "$warn_count" -gt 0 ]]; then
    printf '%s%d mismatch%s' "$C_WARN$BOLD" "$warn_count" "$R"
    [[ "$warn_count" -ne 1 ]] && printf '%ses%s' "$C_WARN" "$R"
    printf ' detected'
  else
    printf '%sno anomalies%s detected' "$C_OK$BOLD" "$R"
  fi
  [[ "$unreach_count" -gt 0 ]] && printf '  %s(%d unreachable/inconclusive)%s' "$C_DIM" "$unreach_count" "$R"
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
  local label="$1" done_count="$2" total="$3" pct=100
  [[ "$JSON" -eq 1 ]] && return
  if [[ "$total" -gt 0 ]]; then
    pct=$((done_count * 100 / total))
  fi
  # Pad with trailing spaces to fully overwrite any longer previous line.
  printf '\r%s%s%s %-10s %3d%% (%d/%d)        ' \
    "$C_DIM" "$G_BULLET" "$R" "$label" "$pct" "$done_count" "$total" >&2
}

finish_progress() {
  [[ "$JSON" -eq 1 ]] && return
  printf '\r%s\r' "$(repeat_str ' ' 64)" >&2
}

clear_for_results() {
  [[ "$JSON" -eq 1 ]] && return
  printf '\033[2J\033[H'
}

run_probes() {
  local total idx entry name cat url out running
  total=${#PROBES[@]}
  print_progress "Probing" 0 "$total"

  if [[ "$CONCURRENCY" -le 1 ]]; then
    idx=0
    for entry in "${PROBES[@]}"; do
      IFS='|' read -r name cat url kind <<< "$entry"
      [[ -z "$kind" ]] && kind="ipecho"
      probe_one "$name" "$cat" "$url" "$kind" > "$TMP_DIR/$idx.row"
      idx=$((idx + 1))
      print_progress "Probing" "$idx" "$total"
    done
  else
    idx=0
    for entry in "${PROBES[@]}"; do
      while true; do
        running=$(jobs -pr | wc -l | tr -d ' ')
        [[ "$running" -lt "$CONCURRENCY" ]] && break
        print_progress "Probing" "$(count_completed_rows "$total")" "$total"
        sleep 0.1
      done
      IFS='|' read -r name cat url kind <<< "$entry"
      [[ -z "$kind" ]] && kind="ipecho"
      out="$TMP_DIR/$idx.row"
      ( probe_one "$name" "$cat" "$url" "$kind" > "$out" ) &
      idx=$((idx + 1))
    done
    while [[ "$(jobs -pr | wc -l | tr -d ' ')" -gt 0 ]]; do
      print_progress "Probing" "$(count_completed_rows "$total")" "$total"
      sleep 0.1
    done
    wait
    print_progress "Probing" "$total" "$total"
  fi
  # NOTE: do not finish_progress here — enrich_rows will keep updating the
  # same line with the "Resolving" label, so the user never sees the bar
  # freeze at 100%.

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
run_audit
finish_progress

if [[ "$JSON" -eq 1 ]]; then
  print_json
else
  clear_for_results
  print_header
  print_table
  print_summary
  print_audit
fi
