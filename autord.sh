#!/usr/bin/env bash
#
# autord — one-command RustDesk installer & configurator for Linux
#
# Features:
#   * Installs the latest GitHub release of RustDesk (deb/rpm/suse-rpm/arch/AppImage)
#   * LAN access: enable-lan-discovery + direct-server (+direct-access-port)
#   * Password access: permanent password (manual/random) + verification-method=use-permanent-password
#   * Optional self-hosted servers: paste the config string exported by the client
#     (--config) or specify id/relay/api/key individually
#   * Dual mode: unattended via flags / interactive wizard when run without args
#     (prompts go through /dev/tty, so `curl | bash` works)
#   * Falls back to editing RustDesk2.toml directly when the CLI/IPC is unavailable
#
# Usage:
#   sudo ./autord.sh                                    # interactive wizard
#   sudo ./autord.sh --yes --random-password            # unattended
#   sudo ./autord.sh --yes --config-string 'host=rs.example.com,key=Kx'
#   curl -fsSL <repo>/autord.sh | sudo bash -s -- --yes --random-password
#
set -Eeuo pipefail

# ---------------------------------------------------------------- constants
GH_API="https://api.github.com/repos/rustdesk/rustdesk"
GH_PATH="rustdesk/rustdesk"                 # download path: <mirror>/<GH_PATH>/releases/download/...
IPC_OK=0 IPC_ERR=1 IPC_NO=2                 # rd_cli classification return codes

# ---------------------------------------------------------------- globals
ASSUME_YES=0 DRY_RUN=0 FORCE=0 DO_STATUS=0 DO_UNINSTALL=0
PW_LITERAL=0 PW_RANDOM=0 PASSWORD="" PASSWORD_MODE="none" RANDOM_PW=0
CONFIG_STRING="" OPT_ID_SERVER="" OPT_RELAY_SERVER="" OPT_API_SERVER="" OPT_KEY=""
LAN_DISCOVERY=1 DIRECT_SERVER=1 DIRECT_PORT="" REMOTE_CONFIG_MOD=1
VERSION_SPEC="" RESOLVED_VERSION="" MIRROR_BASE=""
ARCH="" DISTRO_ID="" DISTRO_LIKE="" DISTRO_PRETTY="" DISTRO_VERSION_ID=""
DISTRO_FAMILY="unknown" PKG_MGR="" HAVE_SYSTEMD=0 HAVE_PYTHON=0
DESKTOP_USER="" DESKTOP_HOME="" DESKTOP_GROUP=""
ASSET_NAME="" ASSET_URL="" ASSET_LIST=""
CACHE_DIR="" CACHE_FILE="" PART_FILE="" DONE_FILE="" DL_PID=""
INSTALLED_VERSION="" NEED_INSTALL=0 SKIP_CONFIG=0
RD_BIN="" INSTALL_METHOD=""
C_G="" C_Y="" C_R="" C_B="" C_0=""
RD_CLI_OUT=""
TOML_FALLBACK=0 RD_PASSWORD_OK=0
declare -gA PENDING_TOML=()

# ---------------------------------------------------------------- colors & logging
setup_colors() {
  if [[ -t 2 && -z ${NO_COLOR:-} && ${TERM:-} != "dumb" ]]; then
    C_G=$'\e[32m' C_Y=$'\e[33m' C_R=$'\e[31m' C_B=$'\e[1m' C_0=$'\e[0m'
  else
    C_G="" C_Y="" C_R="" C_B="" C_0=""
  fi
  return 0
}
info() { printf '%s\n' "${C_G}[autord]${C_0} $*" >&2; }
warn() { printf '%s\n' "${C_Y}[autord warn]${C_0} $*" >&2; }
err()  { printf '%s\n' "${C_R}[autord err]${C_0} $*" >&2; }
die()  { err "$*"; exit 1; }
banner() { printf '\n%s== %s ==%s\n' "$C_B" "$*" "$C_0" >&2; }

# ---------------------------------------------------------------- basic utilities
cleanup() {
  # Stop a background download (its partial file stays for resume next run)
  if [[ -n ${DL_PID:-} ]]; then
    pkill -P "$DL_PID" 2>/dev/null || true
    kill "$DL_PID" 2>/dev/null || true
  fi
  return 0
}

trim() {
  local s=$1
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

usage() {
  cat <<'EOF'
autord — one-command RustDesk setup for Linux

Usage:
  sudo ./autord.sh [options]      # no options = interactive wizard
  curl -fsSL <url>/autord.sh | sudo bash -s -- [options]

Install:
  --yes, -y                 Assume yes, skip confirmations
  --version <ver>           Pin a version (default: latest), e.g. 1.5.0
  --mirror <prefix>         GitHub download prefix replacing https://github.com
                            (e.g. https://ghproxy.net/https://github.com)
  --force                   Reinstall even if the same version is installed
                            (packages are cached in /var/cache/autord and reused;
                             the download starts in the background before the
                             wizard questions so it overlaps with your input)

Configure:
  --no-lan-discovery        Do not enable LAN discovery (default: enabled)
  --no-direct-server        Do not enable direct IP access (default: enabled)
  --no-remote-config-modification
                            Do not allow the controlling side to change settings
                            (allow-remote-config-modification; default: enabled)
  --direct-port <port>      Direct IP access port / direct-access-port (default: 21118)
  --config-string <s>       Server config string exported by the RustDesk client
                            (base64 from Settings -> Network -> Export Server Config,
                             or the host=xx,key=xx,relay=xx,api=xx form)
  --id-server <host[:port]> Custom ID (rendezvous) server
  --relay-server <host[:port]>
  --api-server <url>
  --key <public-key>        Server public key
  --password <pw>           Set the permanent password
  --random-password         Generate a random permanent password and show it once

Misc:
  --status                  Show status (read-only)
  --uninstall               Uninstall RustDesk (user configs are kept)
  --dry-run                 Print actions only, change nothing
  -h, --help                Show this help

Environment variable equivalents (command line takes precedence):
  RD_YES RD_PASSWORD RD_RANDOM_PASSWORD RD_CONFIG_STRING RD_ID_SERVER
  RD_RELAY_SERVER RD_API_SERVER RD_KEY RD_NO_LAN_DISCOVERY RD_NO_DIRECT_SERVER
  RD_NO_REMOTE_CONFIG_MODIFICATION
  RD_DIRECT_PORT RD_VERSION RD_MIRROR RD_DRY_RUN

Examples:
  sudo ./autord.sh --yes --random-password
  sudo ./autord.sh --yes --config-string 'aG9zdD1ycy5leGFtcGxlLmNvbSxrZXk9S0s='
  sudo ./autord.sh --yes --id-server rs.example.com:21116 --key 'Kx9f...' --password 'mypass'
  sudo RD_YES=1 RD_RANDOM_PASSWORD=1 ./autord.sh
EOF
}

require_cmd() {
  local c missing=()
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if (( ${#missing[@]} > 0 )); then
    die "Missing commands, please install them first: ${missing[*]}"
  fi
  return 0
}

# The only mutation outlet (dry-run prints instead of executing)
maybe_run() {
  if (( DRY_RUN )); then
    info "[dry-run] $*"
    return 0
  fi
  "$@"
}

confirm() {
  local prompt=$1 ans=""
  if (( ASSUME_YES )); then return 0; fi
  # note: read -p prints the prompt on stderr; do not redirect it away
  if ! read -r -p "$prompt [Y/n] " ans </dev/tty; then
    err "Cannot read input (no tty?)"
    return 1
  fi
  ans=$(trim "$ans")
  if [[ -z $ans || $ans == [Yy]* ]]; then return 0; fi
  return 1
}

ask_yn() { # $1=prompt $2=default Y/N
  local prompt=$1 def=${2:-Y} ans=""
  if (( ASSUME_YES )); then
    ans=$def
  else
    # note: read -p prints the prompt on stderr; do not redirect it away
    if ! read -r -p "$prompt [$def]: " ans </dev/tty; then
      err "Cannot read input"; return 1
    fi
    ans=$(trim "$ans"); [[ -z $ans ]] && ans=$def
  fi
  if [[ $ans == [Yy]* ]]; then return 0; fi
  return 1
}

gen_random_password() {
  local pw=""
  pw=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 12 || true)
  [[ ${#pw} -ge 8 ]] || die "Random password generation failed"
  printf '%s' "$pw"
}

# ---------------------------------------------------------------- environment detection
detect_arch() {
  case $(uname -m) in
    x86_64) ARCH=x86_64 ;;
    aarch64|arm64) ARCH=aarch64 ;;
    *) die "Unsupported architecture $(uname -m) (only x86_64/aarch64)"; ;;
  esac
  return 0
}

detect_distro() {
  DISTRO_ID="" DISTRO_LIKE="" DISTRO_PRETTY="" DISTRO_VERSION_ID=""
  DISTRO_FAMILY="unknown" PKG_MGR=""
  if [[ ! -r /etc/os-release ]]; then
    warn "No /etc/os-release; treating as unknown distro (AppImage fallback)"
    return 0
  fi
  DISTRO_ID=$(sed -n 's/^ID=//p' /etc/os-release | head -n1 | tr -d '"')
  DISTRO_LIKE=$(sed -n 's/^ID_LIKE=//p' /etc/os-release | head -n1 | tr -d '"')
  DISTRO_PRETTY=$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release | head -n1 | tr -d '"')
  DISTRO_VERSION_ID=$(sed -n 's/^VERSION_ID=//p' /etc/os-release | head -n1 | tr -d '"')
  local id=${DISTRO_ID,,} like=${DISTRO_LIKE,,}
  case $id in
    ubuntu|debian|linuxmint|pop|elementary|zorin|kali|deepin|uos|raspbian) DISTRO_FAMILY=deb ;;
    opensuse*|sles|suse) DISTRO_FAMILY=suse ;;
    fedora|rhel|rocky|almalinux|alma|centos|amzn|ol) DISTRO_FAMILY=rpm ;;
    arch|manjaro|endeavouros|cachyos|garuda|artix)   DISTRO_FAMILY=arch ;;
  esac
  if [[ $DISTRO_FAMILY == "unknown" && -n $like ]]; then
    case $like in
      *arch*) DISTRO_FAMILY=arch ;;
      *suse*) DISTRO_FAMILY=suse ;;
      *debian*) DISTRO_FAMILY=deb ;;
      *fedora*|*rhel*|*centos*) DISTRO_FAMILY=rpm ;;
    esac
  fi
  case $DISTRO_FAMILY in
    deb) PKG_MGR=apt ;;
    rpm)
      local c
      for c in dnf yum microdnf; do
        if command -v "$c" >/dev/null 2>&1; then PKG_MGR=$c; break; fi
      done
      ;;
    suse) PKG_MGR=zypper ;;
    arch) PKG_MGR=pacman ;;
  esac
  if [[ -z $PKG_MGR ]]; then
    warn "Unknown package manager, falling back to AppImage"
    DISTRO_FAMILY="unknown"
  fi
  if [[ $DISTRO_ID == "centos" && ${DISTRO_VERSION_ID%%.*} == "7" ]]; then
    warn "CentOS 7 glibc is too old; RustDesk 1.5 may not run"
  fi
  return 0
}

have_systemd() {
  HAVE_SYSTEMD=0
  [[ -d /run/systemd/system ]] && HAVE_SYSTEMD=1
  return 0
}

desktop_user_info() {
  DESKTOP_USER="" DESKTOP_HOME="" DESKTOP_GROUP=""
  if [[ -z ${SUDO_USER:-} || $SUDO_USER == "root" ]]; then return 0; fi
  DESKTOP_HOME=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6) || return 0
  if [[ -z $DESKTOP_HOME ]]; then return 0; fi
  DESKTOP_USER=$SUDO_USER
  DESKTOP_GROUP=$(id -gn "$SUDO_USER" 2>/dev/null || echo "$SUDO_USER")
  return 0
}

require_root() {
  if (( EUID != 0 )); then
    die "Please run with sudo: sudo $0 ..."
  fi
  return 0
}

# ---------------------------------------------------------------- version & asset
gh_curl() {
  local -a cmd=(curl -fsSL --max-time 20 -H "User-Agent: autord")
  if [[ -n ${GITHUB_TOKEN:-} ]]; then
    cmd+=(-H "Authorization: Bearer $GITHUB_TOKEN")
  fi
  cmd+=("$1")
  "${cmd[@]}"
}

resolve_version() {
  if [[ -n $VERSION_SPEC && $VERSION_SPEC != "latest" ]]; then
    RESOLVED_VERSION=${VERSION_SPEC#v}
    info "Pinned version: $RESOLVED_VERSION"
    return 0
  fi
  local out=""
  RESOLVED_VERSION=""
  if out=$(gh_curl "$GH_API/releases/latest" 2>/dev/null); then
    if (( HAVE_PYTHON )); then
      RESOLVED_VERSION=$(printf '%s' "$out" | python3 -c '
import json,sys
try: print(json.load(sys.stdin)["tag_name"])
except Exception: pass' 2>/dev/null || true)
    fi
    if [[ -z $RESOLVED_VERSION ]]; then
      RESOLVED_VERSION=$(printf '%s' "$out" | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1 || true)
    fi
  fi
  if [[ -z $RESOLVED_VERSION ]]; then
    # Rate-limit fallback: parse the releases/latest 302 redirect
    local redir=""
    redir=$(curl -fsSI -o /dev/null -w '%{redirect_url}' --max-time 15 \
      "${MIRROR_BASE}/$GH_PATH/releases/latest" 2>/dev/null || true)
    [[ -n $redir ]] && RESOLVED_VERSION=${redir##*/}
  fi
  RESOLVED_VERSION=${RESOLVED_VERSION#v}
  if [[ -z $RESOLVED_VERSION ]]; then
    if (( DRY_RUN )); then
      RESOLVED_VERSION="unknown"
      warn "Cannot resolve latest version (continuing in dry-run)"
      return 0
    fi
    die "Cannot resolve the latest version (GitHub rate limit?). Pin it with e.g. --version 1.5.0"
  fi
  info "Latest version: $RESOLVED_VERSION"
  return 0
}

fetch_asset_list() {
  ASSET_LIST=""
  local out=""
  out=$(gh_curl "$GH_API/releases/tags/$RESOLVED_VERSION" 2>/dev/null) || return 0
  if (( HAVE_PYTHON )); then
    ASSET_LIST=$(printf '%s' "$out" | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
    print("\n".join(a["name"] for a in d.get("assets",[])))
except Exception: pass' 2>/dev/null || true)
  else
    ASSET_LIST=$(printf '%s' "$out" | grep -o '"name":[[:space:]]*"[^"]*"' | cut -d'"' -f4 || true)
  fi
  return 0
}

asset_exists() {
  # Trust the constructed name when the list is unavailable or in dry-run
  if [[ -z $ASSET_LIST ]] || (( DRY_RUN )); then return 0; fi
  printf '%s\n' "$ASSET_LIST" | grep -qxF -- "$1"
}

pick_asset() {
  local -a candidates=()
  case $DISTRO_FAMILY in
    deb)  candidates=("rustdesk-${RESOLVED_VERSION}-${ARCH}.deb") ;;
    rpm)  candidates=("rustdesk-${RESOLVED_VERSION}-0.${ARCH}.rpm") ;;
    suse) candidates=("rustdesk-${RESOLVED_VERSION}-0.${ARCH}-suse.rpm" "rustdesk-${RESOLVED_VERSION}-0.${ARCH}.rpm") ;;
    arch) candidates=("rustdesk-${RESOLVED_VERSION}-0-${ARCH}.pkg.tar.zst") ;;
  esac
  local cand
  for cand in "${candidates[@]}"; do
    if asset_exists "$cand"; then
      ASSET_NAME=$cand
      ASSET_URL="${MIRROR_BASE}/$GH_PATH/releases/download/$RESOLVED_VERSION/$ASSET_NAME"
      return 0
    fi
  done
  # AppImage fallback
  local ai="rustdesk-${RESOLVED_VERSION}-${ARCH}.AppImage"
  if asset_exists "$ai"; then
    if [[ $DISTRO_FAMILY == "arch" && $ARCH == "aarch64" ]]; then
      warn "No official package for Arch aarch64; falling back to AppImage (AUR 'rustdesk' is an alternative)"
    else
      warn "No package asset for this distro; falling back to AppImage (limited features)"
    fi
    ASSET_NAME=$ai
    ASSET_URL="${MIRROR_BASE}/$GH_PATH/releases/download/$RESOLVED_VERSION/$ASSET_NAME"
    return 0
  fi
  die "No usable release asset (arch=$ARCH family=$DISTRO_FAMILY ver=$RESOLVED_VERSION). Try another --version."
}

# ---------------------------------------------------------------- download & install
# Returns the installed rustdesk version, or "" when rustdesk is not installed
installed_version() {
  if [[ -z $RD_BIN ]]; then printf ''; return 0; fi
  local v=""
  v=$(timeout 10 "$RD_BIN" --version 2>/dev/null || true)
  v=$(trim "$v")
  printf '%s' "${v%% *}"
}

# Locate the rustdesk executable: PATH first, then common install locations.
# Presence of the executable is what counts as "installed" (--version output
# is only a best-effort version probe and may fail on odd/broken installs).
RD_SEARCH_PATHS=(/usr/bin/rustdesk /usr/local/bin/rustdesk /bin/rustdesk /opt/rustdesk/rustdesk.AppImage)
find_rustdesk_bin() {
  local b=""
  b=$(command -v rustdesk 2>/dev/null || true)
  if [[ -n $b ]]; then printf '%s' "$b"; return 0; fi
  for b in "${RD_SEARCH_PATHS[@]}"; do
    if [[ -x $b ]]; then printf '%s' "$b"; return 0; fi
  done
  printf ''
}

cache_paths() {
  CACHE_DIR="/var/cache/autord"
  CACHE_FILE="$CACHE_DIR/$ASSET_NAME"
  PART_FILE="$CACHE_FILE.part"
  DONE_FILE="$CACHE_FILE.done"
  return 0
}

cache_valid() {
  [[ -s $CACHE_FILE ]] || return 1
  local sz=0
  sz=$(stat -c%s "$CACHE_FILE" 2>/dev/null || echo 0)
  (( sz >= 1000000 ))
}

# Decide the download source: reuse the cache, or start a background download
# right away so the wizard/confirm runs while the package downloads
prepare_download() {
  if (( DRY_RUN )); then
    info "[dry-run] curl -fL --retry 3 -C - -o $PART_FILE $ASSET_URL"
    return 0
  fi
  mkdir -p "$CACHE_DIR"
  if cache_valid; then
    info "Using cached package: $CACHE_FILE"
    return 0
  fi
  rm -f "$DONE_FILE"
  info "Downloading $ASSET_NAME in the background while you answer the questions..."
  (
    if curl -fL --retry 3 -C - --connect-timeout 15 --max-time 1800 \
         -o "$PART_FILE" "$ASSET_URL" >/dev/null 2>&1; then
      printf 'ok\n' > "$DONE_FILE"
    else
      printf 'fail\n' > "$DONE_FILE"
    fi
  ) &
  DL_PID=$!
  return 0
}

# Wait for the background download (if any) and finalize the cache entry
finish_download() {
  (( DRY_RUN )) && return 0
  [[ -n $DL_PID ]] || return 0
  if [[ ! -s $DONE_FILE ]]; then
    info "Waiting for the background download to finish..."
    local sz=0
    while [[ ! -s $DONE_FILE ]]; do
      sz=$(stat -c%s "$PART_FILE" 2>/dev/null || echo 0)
      printf '\r  downloaded %s KB  ' "$(( sz / 1024 ))" >&2
      sleep 1
    done
    printf '\n' >&2
  fi
  wait "$DL_PID" 2>/dev/null || true
  DL_PID=""
  if ! grep -q '^ok$' "$DONE_FILE" 2>/dev/null; then
    rm -f "$DONE_FILE"
    die "Background download failed. Partial file kept for resume: $PART_FILE (delete it to start fresh)"
  fi
  rm -f "$DONE_FILE"
  mv -f "$PART_FILE" "$CACHE_FILE"
  local size=0
  size=$(stat -c%s "$CACHE_FILE" 2>/dev/null || echo 0)
  if (( size < 1000000 )); then
    rm -f "$CACHE_FILE"
    die "Downloaded file is only ${size} bytes (suspicious); aborting"
  fi
  info "Package cached at $CACHE_FILE ($(( size / 1048576 )) MB)"
  return 0
}

install_deb() {
  local f="$CACHE_FILE"
  if ! maybe_run env DEBIAN_FRONTEND=noninteractive apt-get update -qq; then
    warn "apt-get update failed (ignored)"
  fi
  maybe_run env DEBIAN_FRONTEND=noninteractive apt-get install -fy "$f"
  INSTALL_METHOD=deb
}

install_rpm() {
  local f="$CACHE_FILE"
  case $PKG_MGR in
    dnf)      maybe_run dnf install -y "$f" ;;
    yum)      maybe_run yum localinstall -y "$f" ;;
    microdnf) maybe_run microdnf install -y "$f" ;;
    *) die "No usable rpm package manager" ;;
  esac
  INSTALL_METHOD=rpm
}

install_suse() {
  local f="$CACHE_FILE"
  maybe_run zypper --non-interactive install --allow-unsigned-rpm "$f"
  INSTALL_METHOD=rpm
}

install_arch() {
  local f="$CACHE_FILE"
  maybe_run pacman -U --noconfirm "$f"
  INSTALL_METHOD=pacman
}

install_appimage() {
  warn "AppImage mode: no systemd service/IPC -> config is written to RustDesk2.toml directly; the password cannot be set via CLI"
  maybe_run mkdir -p /opt/rustdesk
  maybe_run install -m 0755 "$CACHE_FILE" /opt/rustdesk/rustdesk.AppImage
  maybe_run ln -sf /opt/rustdesk/rustdesk.AppImage /usr/local/bin/rustdesk
  INSTALL_METHOD=appimage
}

install_asset() {
  case $DISTRO_FAMILY in
    deb)  install_deb ;;
    rpm)  install_rpm ;;
    suse) install_suse ;;
    arch) install_arch ;;
    *)    install_appimage ;;
  esac
  if (( ! DRY_RUN )); then
    RD_BIN=$(find_rustdesk_bin)
  fi
  return 0
}

ensure_service() {
  if [[ $INSTALL_METHOD == "appimage" ]]; then
    warn "AppImage has no systemd service; skipping service management"
    return 0
  fi
  if (( HAVE_SYSTEMD )); then
    if ! maybe_run systemctl enable --now rustdesk 2>/dev/null; then
      maybe_run systemctl restart rustdesk || warn "Failed to start the rustdesk service"
    fi
    if (( ! DRY_RUN )); then
      local _
      for _ in 1 2 3 4 5; do
        systemctl is-active --quiet rustdesk 2>/dev/null && break
        sleep 1
      done
      if ! systemctl is-active --quiet rustdesk 2>/dev/null; then
        warn "rustdesk service is not active; CLI config may fail (will fall back to editing the config file)"
      fi
    fi
  else
    warn "No systemd; starting the server process directly (best effort)"
    maybe_run sh -c "nohup '$RD_BIN' --server >/dev/null 2>&1 &" || true
  fi
  return 0
}

# ---------------------------------------------------------------- RustDesk CLI/IPC layer
# Returns: 0=ok  2=IPC unavailable (fall back to toml)  1=other error (retry once)
rd_cli() {
  local out rc
  if [[ ${AUTORD_FORCE_NO_IPC:-0} == "1" ]]; then
    RD_CLI_OUT="(forced no-ipc test seam)"; return 2
  fi
  if [[ -z $RD_BIN ]]; then
    RD_CLI_OUT="rustdesk not installed"; return 2
  fi
  set +e
  out=$(timeout 20 "$RD_BIN" "$@" 2>&1)
  rc=$?
  set -e
  RD_CLI_OUT=$out
  # rustdesk prints its "not installed / not root" notice with exit code 0,
  # so classify by the output text first
  if [[ $out == *"administrative privileges"* ]]; then
    return $IPC_NO
  fi
  if [[ $rc -eq 0 ]]; then
    return $IPC_OK
  fi
  if [[ -z $out ]]; then
    return $IPC_NO   # timeout / silent IPC failure
  fi
  return $IPC_ERR
}

# Queue a key=value pair for the toml fallback
queue_toml() {
  PENDING_TOML[$1]=$2
  TOML_FALLBACK=1
  return 0
}

rd_option_set() {
  local key=$1 value=$2 rc=0
  if (( DRY_RUN )); then
    info "[dry-run] rustdesk --option $key $value"
    return 0
  fi
  rd_cli --option "$key" "$value" || rc=$?
  if [[ $rc -eq $IPC_ERR ]]; then
    sleep 1
    rd_cli --option "$key" "$value" || rc=$?
  fi
  if [[ $rc -eq $IPC_OK ]]; then
    return 0
  fi
  queue_toml "$key" "$value"
  warn "CLI write failed for $key; falling back to RustDesk2.toml"
  return 0
}

rd_option_get() {
  local key=$1 cur=""
  if (( DRY_RUN )); then printf ''; return 0; fi
  if rd_cli --option "$key"; then
    cur=${RD_CLI_OUT//$'\n'/}
    cur=$(trim "$cur")
  fi
  if [[ -z $cur ]]; then
    cur=$(toml_get /root/.config/rustdesk/RustDesk2.toml "$key")
    if [[ -z $cur && -n $DESKTOP_HOME ]]; then
      cur=$(toml_get "$DESKTOP_HOME/.config/rustdesk/RustDesk2.toml" "$key")
    fi
  fi
  printf '%s' "$cur"
}

# The password is stored encrypted, so it can only go through the CLI/IPC
rd_set_password() {
  local pw=$1 rc=0
  if [[ -z $pw ]]; then die "Empty password"; fi
  if [[ $pw == -* ]]; then die "Password must not start with '-' (it would be parsed as a flag); pick another one"; fi
  if (( DRY_RUN )); then info "[dry-run] rustdesk --password ***(hidden)"; return 0; fi
  rd_cli --password "$pw" || rc=$?
  if [[ $rc -eq $IPC_ERR ]]; then
    sleep 1
    rd_cli --password "$pw" || rc=$?
  fi
  if [[ $rc -eq $IPC_OK && $RD_CLI_OUT == *"Done!"* ]]; then
    RD_PASSWORD_OK=1
    info "Permanent password set"
    return 0
  fi
  warn "Could not set the permanent password via CLI (IPC unavailable or disabled)."
  warn "It is stored encrypted, so the script cannot write it to a file."
  warn "Set it later in the client (Settings -> Security), or run: sudo rustdesk --password '<password>'"
  return 0
}

rd_get_id() {
  if (( DRY_RUN )); then return 1; fi
  if rd_cli --get-id; then
    local id
    id=$(trim "$RD_CLI_OUT")
    if [[ -n $id ]]; then printf '%s' "$id"; return 0; fi
  fi
  local f id
  local -a files=(/root/.config/rustdesk/RustDesk.toml)
  [[ -n $DESKTOP_HOME ]] && files+=("$DESKTOP_HOME/.config/rustdesk/RustDesk.toml")
  [[ $HOME != "/root" ]] && files+=("$HOME/.config/rustdesk/RustDesk.toml")
  for f in "${files[@]}"; do
    [[ -r $f ]] || continue
    id=$(sed -n 's/^id[[:space:]]*=[[:space:]]*"\{0,1\}\([0-9]\{1,\}\)"\{0,1\}.*/\1/p' "$f" | head -n1)
    if [[ -n $id ]]; then printf '%s' "$id"; return 0; fi
  done
  return 1
}

# ---------------------------------------------------------------- config-string parsing
cs_get_field() { # $1=string $2=field -> value (may be empty)
  printf '%s' "$1" | awk -v f="$2" '{
    t=tolower($0); i=index(t,"host="); if(i>0) $0=substr($0,i)
    n=split($0,a,",")
    for(j=1;j<=n;j++){
      line=tolower(a[j]); sub(/^[ \t]+/,"",line)
      if (index(line, f)==1 && substr(line,length(f)+1,1)=="=") {
        v=a[j]; sub(/^[^=]*=/,"",v); gsub(/^[ \t]+|[ \t]+$/,"",v); sub(/\.exe$/,"",v)
        print v; exit
      }
    }
  }'
}

# Parse CONFIG_STRING into CS_HOST/CS_KEY/CS_API/CS_RELAY; returns 1 if unparseable
cs_parse() {
  CS_HOST=""; CS_KEY=""; CS_API=""; CS_RELAY=""
  local s
  s=$(trim "$CONFIG_STRING")
  [[ -n $s ]] || return 1
  if [[ ${s,,} == *"host="* ]]; then
    CS_HOST=$(cs_get_field "$s" host)
    CS_KEY=$(cs_get_field "$s" key)
    CS_API=$(cs_get_field "$s" api)
    CS_RELAY=$(cs_get_field "$s" relay)
    return 0
  fi
  if (( HAVE_PYTHON )); then
    local out=""
    out=$(python3 - "$s" 2>/dev/null <<'PY' || true
import sys, base64, json
s = sys.argv[1].strip()
for pad in range(4):
    for dec in (base64.urlsafe_b64decode, base64.b64decode):
        try:
            d = json.loads(dec(s + "=" * pad))
            if isinstance(d, dict) and d.get("host"):
                print(d.get("host", "")); print(d.get("key", ""))
                print(d.get("api", "")); print(d.get("relay", ""))
                sys.exit(0)
        except Exception:
            pass
sys.exit(1)
PY
) || true
    if [[ -n $out ]]; then
      CS_HOST=$(sed -n '1p' <<<"$out")
      CS_KEY=$(sed -n '2p' <<<"$out")
      CS_API=$(sed -n '3p' <<<"$out")
      CS_RELAY=$(sed -n '4p' <<<"$out")
      return 0
    fi
  fi
  return 1
}

# ---------------------------------------------------------------- TOML fallback layer
finalize_tmp() { # $1=original $2=temp file -> replace while keeping mode/owner
  local file=$1 tmp=$2
  if [[ -e $file ]]; then
    chmod --reference="$file" "$tmp" 2>/dev/null || chmod 600 "$tmp"
    chown --reference="$file" "$tmp" 2>/dev/null || true
  else
    chmod 600 "$tmp"
  fi
  mv -f "$tmp" "$file"
}

toml_upsert() { # $1=file $2=key $3=value
  local file=$1 key=$2 value=$3 tmp="$1.autordtmp"
  if (( HAVE_PYTHON )); then
    python3 - "$file" "$key" "$value" <<'PY'
import re, sys
path, key, value = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    lines = open(path, encoding="utf-8").read().splitlines()
except FileNotFoundError:
    lines = []
out, in_opts, done, opts_seen = [], False, False, False
for ln in lines:
    s = ln.strip()
    if s.startswith("[") and s.endswith("]"):
        if in_opts and not done:
            out.append('%s = "%s"' % (key, value)); done = True
        in_opts = (s == "[options]")
        opts_seen = opts_seen or in_opts
        out.append(ln)
        continue
    if in_opts and not done and re.match(r"^%s\s*=" % re.escape(key), ln):
        out.append('%s = "%s"' % (key, value)); done = True
        continue
    out.append(ln)
if not done:
    if not opts_seen:
        if out and out[-1].strip():
            out.append("")
        out.append("[options]")
    out.append('%s = "%s"' % (key, value))
open(path + ".autordtmp", "w", encoding="utf-8").write("\n".join(out) + "\n")
PY
  else
    if grep -q "^[[:space:]]*${key}[[:space:]]*=" "$file" 2>/dev/null; then
      awk -v k="$key" -v v="$value" '
        $0 ~ "^[[:space:]]*" k "[[:space:]]*=" { print k " = \"" v "\""; next }
        { print }' "$file" > "$tmp"
    elif grep -q '^[[:space:]]*\[options\]' "$file" 2>/dev/null; then
      awk -v k="$key" -v v="$value" '
        !done && $0 ~ /^[[:space:]]*\[options\]/ { print; print k " = \"" v "\""; done=1; next }
        { print }' "$file" > "$tmp"
    else
      { [[ -s $file ]] && cat "$file" && printf '\n'; printf '[options]\n%s = "%s"\n' "$key" "$value"; } > "$tmp"
    fi
  fi
  finalize_tmp "$file" "$tmp"
}

toml_get() { # $1=file $2=key -> value
  local file=$1 key=$2
  [[ -r $file ]] || return 0
  awk -v k="$key" '
    /^[[:space:]]*\[/ { in_opts = ($0 ~ /^[[:space:]]*\[options\][[:space:]]*$/); next }
    in_opts && $0 ~ "^[[:space:]]*" k "[[:space:]]*=" {
      sub(/^[^=]*=[[:space:]]*/, ""); gsub(/^"|"$/, ""); gsub(/[[:space:]]+$/, "")
      print; exit
    }' "$file"
}

toml_set_both() { # write to both root's and the desktop user's config
  local key=$1 value=$2 f
  local -a files=(/root/.config/rustdesk/RustDesk2.toml)
  if [[ -n $DESKTOP_HOME ]]; then
    files+=("$DESKTOP_HOME/.config/rustdesk/RustDesk2.toml")
  fi
  for f in "${files[@]}"; do
    if (( DRY_RUN )); then info "[dry-run] upsert $f: $key = $value"; continue; fi
    mkdir -p "$(dirname "$f")"
    if [[ ! -f $f ]]; then printf '[options]\n' > "$f"; fi
    toml_upsert "$f" "$key" "$value"
    if [[ -n $DESKTOP_USER && $f == "$DESKTOP_HOME"/* ]]; then
      chown -R "$DESKTOP_USER:$DESKTOP_GROUP" "$(dirname "$f")" 2>/dev/null || true
    fi
    chmod 600 "$f" 2>/dev/null || true
  done
  return 0
}

restart_rustdesk_service() {
  if (( HAVE_SYSTEMD )); then
    maybe_run systemctl restart rustdesk \
      || warn "Restart failed; do it manually: systemctl restart rustdesk"
  else
    warn "No systemd: restart the rustdesk process manually for changes to take effect"
  fi
  return 0
}

apply_toml_fallback_all() {
  if (( ${#PENDING_TOML[@]} == 0 )); then return 0; fi
  info "Applying RustDesk2.toml fallback (${#PENDING_TOML[@]} item(s))"
  local key
  for key in "${!PENDING_TOML[@]}"; do
    toml_set_both "$key" "${PENDING_TOML[$key]}"
  done
  restart_rustdesk_service
  return 0
}

# ---------------------------------------------------------------- high-level config steps
apply_lan_options() {
  if (( LAN_DISCOVERY )); then
    rd_option_set enable-lan-discovery Y
  fi
  if (( DIRECT_SERVER )); then
    rd_option_set direct-server Y
    if [[ -n $DIRECT_PORT ]]; then
      rd_option_set direct-access-port "$DIRECT_PORT"
    fi
  fi
  return 0
}

apply_remote_config_mod() {
  if (( REMOTE_CONFIG_MOD )); then
    rd_option_set allow-remote-config-modification Y
  fi
  return 0
}

apply_server_config() {
  if [[ -n $OPT_ID_SERVER || -n $OPT_RELAY_SERVER || -n $OPT_API_SERVER || -n $OPT_KEY ]]; then
    [[ -n $OPT_ID_SERVER ]]    && rd_option_set custom-rendezvous-server "$OPT_ID_SERVER"
    [[ -n $OPT_RELAY_SERVER ]] && rd_option_set relay-server "$OPT_RELAY_SERVER"
    [[ -n $OPT_API_SERVER ]]   && rd_option_set api-server "$OPT_API_SERVER"
    [[ -n $OPT_KEY ]]          && rd_option_set key "$OPT_KEY"
    return 0
  fi
  if [[ -n $CONFIG_STRING ]]; then
    local s rc=0
    s=$(trim "$CONFIG_STRING")
    if [[ -z $s ]]; then die "Empty config string"; fi
    if (( ${#s} > 4096 )); then die "Config string too long (>4096)"; fi
    if [[ $s != "${s//[$' \t']/}" ]]; then
      die "Config string contains whitespace; paste it as a single unbroken string"
    fi
    if (( DRY_RUN )); then
      info "[dry-run] rustdesk --config ${s:0:16}..."
      return 0
    fi
    info "Applying config string: ${s:0:24}..."
    rd_cli --config "$s" || rc=$?
    if [[ $rc -eq $IPC_ERR ]]; then
      sleep 1
      rd_cli --config "$s" || rc=$?
    fi
    if [[ $rc -ne $IPC_OK ]]; then
      warn "--config could not run (IPC unavailable); trying to parse it and write options directly"
      if cs_parse; then
        [[ -n $CS_HOST ]]  && queue_toml custom-rendezvous-server "$CS_HOST"
        [[ -n $CS_KEY ]]   && queue_toml key "$CS_KEY"
        [[ -n $CS_API ]]   && queue_toml api-server "$CS_API"
        [[ -n $CS_RELAY ]] && queue_toml relay-server "$CS_RELAY"
      else
        warn "Cannot parse this config string. Import it manually in the client: Settings -> Network -> Import server config"
      fi
    fi
  fi
  return 0
}

# Readback verification (guards against the historical --config relay bug)
verify_server_config() {
  if (( DRY_RUN )); then return 0; fi
  local -a pairs=()
  if [[ -n $OPT_ID_SERVER ]];   then pairs+=("custom-rendezvous-server=$OPT_ID_SERVER"); fi
  if [[ -n $OPT_RELAY_SERVER ]]; then pairs+=("relay-server=$OPT_RELAY_SERVER"); fi
  if [[ -n $OPT_API_SERVER ]];  then pairs+=("api-server=$OPT_API_SERVER"); fi
  if [[ -n $OPT_KEY ]];         then pairs+=("key=$OPT_KEY"); fi
  if (( ${#pairs[@]} == 0 )) && [[ -n $CONFIG_STRING ]]; then
    if cs_parse; then
      [[ -n $CS_HOST ]]  && pairs+=("custom-rendezvous-server=$CS_HOST")
      [[ -n $CS_KEY ]]   && pairs+=("key=$CS_KEY")
      [[ -n $CS_API ]]   && pairs+=("api-server=$CS_API")
      [[ -n $CS_RELAY ]] && pairs+=("relay-server=$CS_RELAY")
    fi
  fi
  if (( ${#pairs[@]} == 0 )); then
    local cur=""
    cur=$(rd_option_get custom-rendezvous-server)
    if [[ -z $cur ]]; then
      warn "Config string is unparseable, skipping readback check; verify in the client under Settings -> Network"
    fi
    return 0
  fi
  local p k want cur
  for p in "${pairs[@]}"; do
    k=${p%%=*}; want=${p#*=}
    cur=$(rd_option_get "$k")
    if [[ $cur == "$want" ]]; then
      info "OK $k = $cur"
    else
      warn "$k: want '$want' but got '${cur:-empty}'; re-applying"
      rd_option_set "$k" "$want"
      cur=$(rd_option_get "$k")
      if [[ $cur != "$want" ]]; then
        warn "$k is still '${cur:-empty}' -- please check Settings -> Network in the client"
      fi
    fi
  done
  return 0
}

apply_password() {
  if [[ $PASSWORD_MODE == "none" ]]; then
    info "No password requested (use --password/--random-password)"
    return 0
  fi
  if [[ $PASSWORD_MODE == "random" ]]; then
    PASSWORD=$(gen_random_password)
    RANDOM_PW=1
  fi
  rd_set_password "$PASSWORD"
  # Only tighten the verification method once a password is actually set,
  # otherwise the machine could end up with no usable password at all
  if (( RD_PASSWORD_OK )); then
    rd_option_set verification-method use-permanent-password
  fi
  return 0
}

print_summary() {
  banner "Summary"
  if (( DRY_RUN )); then
    printf '  [dry-run] Actions above were printed only; nothing was changed.\n'
    return 0
  fi
  local id="" svc="(no systemd)"
  id=$(rd_get_id 2>/dev/null || true)
  if (( HAVE_SYSTEMD )); then
    svc=$(systemctl is-active rustdesk 2>/dev/null || true)
  fi
  svc=${svc:-unknown}
  printf '  RustDesk ID  : %s\n' "${id:-unknown (check later with: sudo rustdesk --get-id)}"
  printf '  Service      : %s\n' "$svc"
  if (( RANDOM_PW )); then
    printf '  Perm password: %s  (randomly generated, shown only once -- save it!)\n' "$PASSWORD"
  elif (( RD_PASSWORD_OK )); then
    printf '  Perm password: (set, not echoed)\n'
  else
    printf '  Perm password: (not set -- see warnings above)\n'
  fi
  local k cur
  printf '  Options      :\n'
  for k in enable-lan-discovery direct-server direct-access-port \
           allow-remote-config-modification \
           custom-rendezvous-server relay-server api-server verification-method; do
    cur=$(rd_option_get "$k")
    printf '    %-26s %s\n' "$k" "${cur:-(not set)}"
  done
  printf '  Hint: open TCP 21115-21119 (hbbs/hbbr) for cross-subnet / self-hosted setups.\n'
  if [[ $INSTALL_METHOD == "appimage" ]]; then
    printf '  Note: AppImage mode has no system service; run rustdesk manually after reboot.\n'
  fi
  if (( TOML_FALLBACK )); then
    printf '  Note: options were written directly to the config file (IPC unavailable); restart the service if anything looks off.\n'
  fi
  printf '  Config files : /root/.config/rustdesk/RustDesk2.toml'
  [[ -n $DESKTOP_HOME ]] && printf ' and %s/.config/rustdesk/RustDesk2.toml' "$DESKTOP_HOME"
  printf '\n'
  return 0
}

print_plan() {
  banner "Plan"
  printf '  System   : %s (%s/%s)\n' "${DISTRO_PRETTY:-unknown}" "$DISTRO_FAMILY" "$ARCH"
  if (( NEED_INSTALL )); then
    printf '  Install  : download + install %s\n' "$RESOLVED_VERSION"
  else
    printf '  Install  : skipped (%s already installed)\n' "${INSTALLED_VERSION:-none}"
  fi
  printf '  Version  : %s  Asset: %s\n' "$RESOLVED_VERSION" "$ASSET_NAME"
  printf '  LAN      : discovery=%s direct=%s%s\n' \
    "$( (( LAN_DISCOVERY )) && echo on || echo off )" \
    "$( (( DIRECT_SERVER )) && echo on || echo off )" \
    "${DIRECT_PORT:+ (port $DIRECT_PORT)}"
  printf '  RemoteMod: allow-remote-config-modification=%s\n' \
    "$( (( REMOTE_CONFIG_MOD )) && echo Y || echo N )"
  local srv="(none)"
  if [[ -n $OPT_ID_SERVER || -n $OPT_RELAY_SERVER || -n $OPT_API_SERVER || -n $OPT_KEY ]]; then
    local key_desc="not provided"
    [[ -n $OPT_KEY ]] && key_desc="provided"
    srv="id=${OPT_ID_SERVER:-default} relay=${OPT_RELAY_SERVER:-auto} api=${OPT_API_SERVER:-default} key=$key_desc"
  elif [[ -n $CONFIG_STRING ]]; then
    srv="config string (${CONFIG_STRING:0:16}...)"
  fi
  printf '  Servers  : %s\n' "$srv"
  local pw_desc="skip"
  if [[ $PASSWORD_MODE == "literal" ]]; then
    pw_desc="manual"
  elif [[ $PASSWORD_MODE == "random" ]]; then
    pw_desc="random (shown at the end)"
  fi
  printf '  Password : %s\n' "$pw_desc"
  return 0
}

# ---------------------------------------------------------------- modes
do_status() {
  banner "RustDesk status"
  if [[ -n $RD_BIN ]]; then
    local v=""
    v=$(timeout 10 "$RD_BIN" --version 2>/dev/null || true)
    printf '  Installed : %s (%s)\n' "$RD_BIN" "${v:-?}"
  else
    printf '  Installed : no\n'
  fi
  if (( HAVE_SYSTEMD )); then
    local svc=""
    svc=$(systemctl is-active rustdesk 2>/dev/null || true)
    printf '  Service   : %s\n' "${svc:-unknown}"
  else
    printf '  Service   : (no systemd)\n'
  fi
  local id=""
  id=$(rd_get_id 2>/dev/null || true)
  printf '  ID        : %s\n' "${id:-unknown}"
  printf '  Options (from config files):\n'
  local k cur f
  local -a files=("$HOME/.config/rustdesk/RustDesk2.toml" /root/.config/rustdesk/RustDesk2.toml)
  [[ -n $DESKTOP_HOME ]] && files+=("$DESKTOP_HOME/.config/rustdesk/RustDesk2.toml")
  for k in enable-lan-discovery direct-server direct-access-port \
           allow-remote-config-modification \
           custom-rendezvous-server relay-server api-server verification-method; do
    cur=""
    for f in "${files[@]}"; do
      [[ -r $f ]] || continue
      cur=$(toml_get "$f" "$k")
      [[ -n $cur ]] && break
    done
    if [[ -z $cur && -n $RD_BIN ]] && (( EUID == 0 )); then
      cur=$(rd_option_get "$k")
    fi
    printf '    %-26s %s\n' "$k" "${cur:-(not set)}"
  done
  return 0
}

do_uninstall() {
  banner "Uninstall RustDesk"
  if (( EUID != 0 && ! DRY_RUN )); then die "Please run with sudo"; fi
  confirm "Uninstall RustDesk? (user configs are kept)" || die "Aborted"
  if (( HAVE_SYSTEMD )); then
    maybe_run systemctl disable --now rustdesk 2>/dev/null || true
  fi
  maybe_run pkill -x rustdesk 2>/dev/null || true
  case $DISTRO_FAMILY in
    deb)  maybe_run env DEBIAN_FRONTEND=noninteractive apt-get purge -y rustdesk
          maybe_run env DEBIAN_FRONTEND=noninteractive apt-get autoremove -y || true ;;
    rpm)  if command -v dnf >/dev/null 2>&1; then maybe_run dnf remove -y rustdesk
          elif command -v yum >/dev/null 2>&1; then maybe_run yum remove -y rustdesk
          elif command -v microdnf >/dev/null 2>&1; then maybe_run microdnf remove -y rustdesk
          fi ;;
    suse) maybe_run zypper --non-interactive remove rustdesk ;;
    arch) maybe_run pacman -Rns --noconfirm rustdesk ;;
  esac
  maybe_run rm -rf /opt/rustdesk
  maybe_run rm -f /usr/local/bin/rustdesk
  maybe_run rm -rf /var/cache/autord
  if (( DRY_RUN )); then return 0; fi
  if command -v rustdesk >/dev/null 2>&1; then
    warn "The rustdesk binary is still present; please check"
  else
    info "Uninstalled"
  fi
  warn "User configs kept:"
  warn "  /root/.config/rustdesk${DESKTOP_HOME:+ and $DESKTOP_HOME/.config/rustdesk}"
  warn "To remove them too: sudo rm -rf /root/.config/rustdesk '$DESKTOP_HOME/.config/rustdesk'"
  return 0
}

# ---------------------------------------------------------------- wizard
# Actually open /dev/tty ([[ -r ]] can still be true without a controlling tty)
require_tty() {
  if ! { : </dev/tty; } 2>/dev/null; then
    err "No configuration flags given, no --yes, and no interactive terminal available."
    err "Pass flags (see --help) or run in a terminal to use the wizard."
    usage
    exit 2
  fi
  return 0
}

# Existing installation: ask in order whether to update the binary and
# whether to re-apply the configuration
ask_existing_install() {
  banner "RustDesk ${INSTALLED_VERSION:-unknown version} is already installed"
  if [[ -z $INSTALLED_VERSION ]]; then
    if ask_yn "Reinstall RustDesk (installed version unknown)" "Y"; then
      NEED_INSTALL=1
      prepare_download
    fi
  elif [[ $INSTALLED_VERSION != "$RESOLVED_VERSION" ]]; then
    if ask_yn "Upgrade to $RESOLVED_VERSION" "Y"; then
      NEED_INSTALL=1
      prepare_download
    fi
  else
    local def=N
    (( FORCE )) && def=Y
    if ask_yn "Reinstall $RESOLVED_VERSION (same version)" "$def"; then
      NEED_INSTALL=1
      prepare_download
    fi
  fi
  if ! ask_yn "Re-apply configuration (LAN, password, servers)" "Y"; then
    SKIP_CONFIG=1
  fi
  return 0
}

run_wizard() {
  require_tty
  banner "autord wizard"
  printf '  System: %s (%s/%s)  Target version: %s\n' \
    "${DISTRO_PRETTY:-unknown}" "$DISTRO_FAMILY" "$ARCH" "$RESOLVED_VERSION"
  printf '  Tip: press Enter to accept the [default] value.\n'
  if (( NEED_INSTALL )); then
    confirm "Continue installing RustDesk?" || die "Aborted"
  else
    confirm "Continue configuring RustDesk (no reinstall)?" || die "Aborted"
  fi

  banner "1/3 Access"
  if ask_yn "Enable LAN discovery (enable-lan-discovery)" "Y"; then LAN_DISCOVERY=1; else LAN_DISCOVERY=0; fi
  if ask_yn "Enable direct IP access (direct-server)" "Y"; then
    DIRECT_SERVER=1
    local p=""
    if ! read -r -p "Direct access port (direct-access-port) [Enter=default 21118]: " p </dev/tty; then
      err "Cannot read input"; exit 2
    fi
    p=$(trim "$p")
    if [[ -n $p ]]; then
      [[ $p =~ ^[0-9]+$ ]] || die "Port must be numeric"
      DIRECT_PORT=$p
    fi
  else
    DIRECT_SERVER=0
  fi
  if ask_yn "Allow the controlling side to change settings (allow-remote-config-modification)" "Y"; then
    REMOTE_CONFIG_MOD=1
  else
    REMOTE_CONFIG_MOD=0
  fi

  banner "2/3 Servers"
  local s=""
  if ! read -r -p "Paste server config string (Settings->Network->Export Server Config, Enter to skip): " s </dev/tty; then
    err "Cannot read input"; exit 2
  fi
  s=$(trim "$s")
  if [[ -n $s ]]; then
    CONFIG_STRING=$s
  else
    local v=""
    read -r -p "ID server (id-server) [Enter=default public server]: " v </dev/tty; OPT_ID_SERVER=$(trim "$v")
    read -r -p "Relay server (relay-server) [Enter=auto]: " v </dev/tty; OPT_RELAY_SERVER=$(trim "$v")
    read -r -p "API server (api-server) [Enter=default]: " v </dev/tty; OPT_API_SERVER=$(trim "$v")
    read -r -p "Public key (key) [Enter=skip]: " v </dev/tty; OPT_KEY=$(trim "$v")
  fi

  banner "3/3 Password"
  local choice="" pw1="" pw2=""
  printf '  [1] Enter manually  [2] Generate random  [3] Skip\n'
  if ! read -r -p "Choose [1/2/3]: " choice </dev/tty; then err "Cannot read input"; exit 2; fi
  choice=$(trim "$choice")
  case $choice in
    1)
      while :; do
        read -rs -p "Password: " pw1 </dev/tty; printf '\n' >&2
        read -rs -p "Confirm password: " pw2 </dev/tty; printf '\n' >&2
        [[ -n $pw1 ]] || { warn "Empty password, retry"; continue; }
        [[ $pw1 == "$pw2" ]] || { warn "Passwords do not match, retry"; continue; }
        [[ $pw1 != -* ]] || { warn "Password must not start with '-'"; continue; }
        break
      done
      PASSWORD=$pw1; PASSWORD_MODE=literal
      ;;
    2) PASSWORD_MODE=random ;;
    *) info "Skipping password" ;;
  esac

  print_plan
  confirm "Execute this plan?" || die "Aborted"
  return 0
}

# ---------------------------------------------------------------- args
need_arg() {
  if [[ -z ${2:-} || $2 == --* ]]; then
    err "Missing value for $1"
    usage
    exit 2
  fi
  return 0
}

parse_args() {
  while (( $# > 0 )); do
    case $1 in
      --yes|-y)            ASSUME_YES=1 ;;
      --password)          need_arg "$1" "${2:-}"; PASSWORD=$2; PW_LITERAL=1; shift ;;
      --password=*)        PASSWORD=${1#*=}; PW_LITERAL=1 ;;
      --random-password)   PW_RANDOM=1 ;;
      --config-string)     need_arg "$1" "${2:-}"; CONFIG_STRING=$2; shift ;;
      --config-string=*)   CONFIG_STRING=${1#*=} ;;
      --id-server)         need_arg "$1" "${2:-}"; OPT_ID_SERVER=$2; shift ;;
      --id-server=*)       OPT_ID_SERVER=${1#*=} ;;
      --relay-server)      need_arg "$1" "${2:-}"; OPT_RELAY_SERVER=$2; shift ;;
      --relay-server=*)    OPT_RELAY_SERVER=${1#*=} ;;
      --api-server)        need_arg "$1" "${2:-}"; OPT_API_SERVER=$2; shift ;;
      --api-server=*)      OPT_API_SERVER=${1#*=} ;;
      --key)               need_arg "$1" "${2:-}"; OPT_KEY=$2; shift ;;
      --key=*)             OPT_KEY=${1#*=} ;;
      --no-lan-discovery)  LAN_DISCOVERY=0 ;;
      --no-direct-server)  DIRECT_SERVER=0 ;;
      --no-remote-config-modification) REMOTE_CONFIG_MOD=0 ;;
      --direct-port)       need_arg "$1" "${2:-}"; DIRECT_PORT=$2; shift ;;
      --direct-port=*)     DIRECT_PORT=${1#*=} ;;
      --version)           need_arg "$1" "${2:-}"; VERSION_SPEC=$2; shift ;;
      --version=*)         VERSION_SPEC=${1#*=} ;;
      --mirror)            need_arg "$1" "${2:-}"; MIRROR_BASE=${2%/}; shift ;;
      --mirror=*)          MIRROR_BASE=${1#*=}; MIRROR_BASE=${MIRROR_BASE%/} ;;
      --force)             FORCE=1 ;;
      --dry-run)           DRY_RUN=1 ;;
      --status)            DO_STATUS=1 ;;
      --uninstall)         DO_UNINSTALL=1 ;;
      --help|-h)           usage; exit 0 ;;
      *)                   err "Unknown option: $1"; usage; exit 2 ;;
    esac
    shift
  done
  return 0
}

truthy() { [[ ${1:-} == 1 || ${1,,} == true || ${1,,} == yes || ${1,,} == y ]]; }

apply_env_overrides() {
  truthy "${RD_YES:-}" && ASSUME_YES=1
  if [[ -n ${RD_PASSWORD:-} && $PW_LITERAL -eq 0 && $PW_RANDOM -eq 0 ]]; then
    PASSWORD=$RD_PASSWORD; PW_LITERAL=1
  fi
  truthy "${RD_RANDOM_PASSWORD:-}" && PW_RANDOM=1
  [[ -n ${RD_CONFIG_STRING:-} && -z $CONFIG_STRING ]] && CONFIG_STRING=$RD_CONFIG_STRING
  [[ -n ${RD_ID_SERVER:-} && -z $OPT_ID_SERVER ]] && OPT_ID_SERVER=$RD_ID_SERVER
  [[ -n ${RD_RELAY_SERVER:-} && -z $OPT_RELAY_SERVER ]] && OPT_RELAY_SERVER=$RD_RELAY_SERVER
  [[ -n ${RD_API_SERVER:-} && -z $OPT_API_SERVER ]] && OPT_API_SERVER=$RD_API_SERVER
  [[ -n ${RD_KEY:-} && -z $OPT_KEY ]] && OPT_KEY=$RD_KEY
  truthy "${RD_NO_LAN_DISCOVERY:-}" && LAN_DISCOVERY=0
  truthy "${RD_NO_DIRECT_SERVER:-}" && DIRECT_SERVER=0
  truthy "${RD_NO_REMOTE_CONFIG_MODIFICATION:-}" && REMOTE_CONFIG_MOD=0
  [[ -n ${RD_DIRECT_PORT:-} && -z $DIRECT_PORT ]] && DIRECT_PORT=$RD_DIRECT_PORT
  [[ -n ${RD_VERSION:-} && -z $VERSION_SPEC ]] && VERSION_SPEC=$RD_VERSION
  [[ -n ${RD_MIRROR:-} && -z $MIRROR_BASE ]] && MIRROR_BASE=${RD_MIRROR%/}
  truthy "${RD_DRY_RUN:-}" && DRY_RUN=1
  return 0
}

validate_args() {
  if [[ $PW_LITERAL -eq 1 && $PW_RANDOM -eq 1 ]]; then
    die "--password and --random-password are mutually exclusive; pick one"
  fi
  if [[ $PW_LITERAL -eq 1 ]]; then
    PASSWORD_MODE=literal
    [[ -z $PASSWORD ]] && die "--password value is empty"
  elif [[ $PW_RANDOM -eq 1 ]]; then
    PASSWORD_MODE=random
  fi
  if [[ -n $CONFIG_STRING && ( -n $OPT_ID_SERVER || -n $OPT_RELAY_SERVER || -n $OPT_API_SERVER || -n $OPT_KEY ) ]]; then
    die "--config-string and --id-server/--relay-server/--api-server/--key are mutually exclusive"
  fi
  if (( DO_STATUS && DO_UNINSTALL )); then
    die "--status and --uninstall are mutually exclusive"
  fi
  if [[ -n $DIRECT_PORT ]]; then
    [[ $DIRECT_PORT =~ ^[0-9]+$ ]] || die "--direct-port must be numeric"
    (( 1 <= 10#$DIRECT_PORT && 10#$DIRECT_PORT <= 65535 )) || die "--direct-port out of range"
    if (( DIRECT_SERVER == 0 )); then
      warn "--direct-port given but direct-server is off; the port will not be written"
    fi
  fi
  MIRROR_BASE="${MIRROR_BASE:-https://github.com}"
  return 0
}

has_config_args() {
  [[ $PASSWORD_MODE != "none" || -n $CONFIG_STRING || -n $OPT_ID_SERVER \
     || -n $OPT_RELAY_SERVER || -n $OPT_API_SERVER || -n $OPT_KEY \
     || $LAN_DISCOVERY -eq 0 || $DIRECT_SERVER -eq 0 || -n $DIRECT_PORT \
     || $REMOTE_CONFIG_MOD -eq 0 ]]
}

# ---------------------------------------------------------------- main
main() {
  setup_colors
  parse_args "$@"
  apply_env_overrides
  validate_args

  trap cleanup EXIT
  trap 'exit 130' INT TERM

  HAVE_PYTHON=0
  command -v python3 >/dev/null 2>&1 && HAVE_PYTHON=1
  have_systemd
  desktop_user_info
  RD_BIN=$(find_rustdesk_bin)

  if (( DO_STATUS )); then
    detect_distro
    do_status
    exit 0
  fi

  if (( ! DRY_RUN )); then
    require_root
  fi
  require_cmd curl awk timeout

  if (( DO_UNINSTALL )); then
    detect_distro
    do_uninstall
    exit 0
  fi

  detect_arch
  detect_distro
  resolve_version
  fetch_asset_list
  pick_asset
  cache_paths

  INSTALLED_VERSION=$(installed_version)
  NEED_INSTALL=0
  SKIP_CONFIG=0

  if [[ -z $RD_BIN ]]; then
    # Fresh install (no executable anywhere): start the download right away
    # so it overlaps with input
    NEED_INSTALL=1
    prepare_download
  elif ! has_config_args && (( ! ASSUME_YES )); then
    # Existing installation, interactive: ask update / re-config in order
    require_tty
    ask_existing_install
  elif [[ -z $INSTALLED_VERSION || $INSTALLED_VERSION != "$RESOLVED_VERSION" || $FORCE -eq 1 ]]; then
    # Existing installation, unattended (--yes or flags given): upgrade when
    # the version differs or is unknown (or --force), then apply configuration
    NEED_INSTALL=1
    prepare_download
  fi
  # else: same version already installed, unattended -> configure only

  if (( ! SKIP_CONFIG )); then
    if ! has_config_args && (( ! ASSUME_YES )); then
      run_wizard
    else
      print_plan
      confirm "Execute this plan?" || die "Aborted"
    fi
  fi

  if (( NEED_INSTALL )); then
    finish_download
    install_asset
  fi
  ensure_service

  if (( ! SKIP_CONFIG )); then
    apply_lan_options
    apply_remote_config_mod
    apply_server_config
    verify_server_config
    apply_password
    apply_toml_fallback_all
  fi

  print_summary
  exit 0
}

# Run main when executed as a file or piped into bash (BASH_SOURCE is unset for
# stdin scripts, which set -u would turn into an error); skip only when sourced
if [[ ${BASH_SOURCE[0]:-} == "$0" || -z ${BASH_SOURCE[0]:-} ]]; then
  main "$@"
fi
