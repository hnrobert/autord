#!/usr/bin/env bash
# autord source-mode unit tests (no root, no system changes)
# shellcheck disable=SC2034  # assignments to globals of the script under test are invisible to shellcheck
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/autord.sh"
TMP="$ROOT/test/tmp"
mkdir -p "$TMP"

# shellcheck disable=SC1090
source "$SRC"   # the BASH_SOURCE guard keeps main() from running

PASS=0 FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
assert_eq() { # $1=desc $2=got $3=want
  if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1 (got='$2' want='$3')"; fi
}
assert_rc() { # $1=desc $2=got_rc $3=want_rc
  if [[ $2 -eq $3 ]]; then ok "$1"; else bad "$1 (rc=$2 want=$3)"; fi
}

banner() { printf '\n== %s ==\n' "$1"; }

# ---------------------------------------------------------------- detect_distro
banner "detect_distro"
detect_distro
assert_eq "family=deb (this box is Ubuntu)" "$DISTRO_FAMILY" "deb"
assert_eq "pkg-mgr=apt" "$PKG_MGR" "apt"

# ---------------------------------------------------------------- pick_asset
banner "pick_asset"
ASSET_LIST="rustdesk-1.5.0-x86_64.deb
rustdesk-1.5.0-aarch64.deb
rustdesk-1.5.0-0.x86_64.rpm
rustdesk-1.5.0-0.aarch64.rpm
rustdesk-1.5.0-0.x86_64-suse.rpm
rustdesk-1.5.0-0-x86_64.pkg.tar.zst
rustdesk-1.5.0-x86_64.AppImage
rustdesk-1.5.0-aarch64.AppImage
rustdesk-1.5.0-x86_64-sciter.deb"

RESOLVED_VERSION=1.5.0 ARCH=x86_64 DISTRO_FAMILY=deb; pick_asset
assert_eq "deb asset name" "$ASSET_NAME" "rustdesk-1.5.0-x86_64.deb"

DISTRO_FAMILY=suse; pick_asset
assert_eq "suse asset name" "$ASSET_NAME" "rustdesk-1.5.0-0.x86_64-suse.rpm"

DISTRO_FAMILY=arch ARCH=aarch64; pick_asset
assert_eq "arch+aarch64 -> AppImage fallback" "$ASSET_NAME" "rustdesk-1.5.0-aarch64.AppImage"

DISTRO_FAMILY=arch ARCH=x86_64; pick_asset
assert_eq "arch asset name (extra dash)" "$ASSET_NAME" "rustdesk-1.5.0-0-x86_64.pkg.tar.zst"

DISTRO_FAMILY=unknown ARCH=x86_64; pick_asset
assert_eq "unknown -> AppImage" "$ASSET_NAME" "rustdesk-1.5.0-x86_64.AppImage"

# Decoy defense: the sciter build must never be picked
ASSET_LIST="rustdesk-1.5.0-x86_64-sciter.deb
rustdesk-1.5.0-x86_64.AppImage"
DISTRO_FAMILY=deb ARCH=x86_64; pick_asset 2>/dev/null
assert_eq "sciter decoy skipped, AppImage fallback" "$ASSET_NAME" "rustdesk-1.5.0-x86_64.AppImage"

# No usable asset at all -> die
ASSET_LIST="rustdesk-1.5.0-x86_64-sciter.deb"
if ( pick_asset ) 2>/dev/null; then bad "should die"; else ok "dies when no asset matches"; fi

# Empty list -> trust the constructed name
ASSET_LIST=""
DISTRO_FAMILY=deb ARCH=aarch64; pick_asset
assert_eq "empty list trusts constructed name" "$ASSET_NAME" "rustdesk-1.5.0-aarch64.deb"

# ---------------------------------------------------------------- toml (both python and awk paths)
for MODE in python awk; do
  banner "toml_upsert/toml_get ($MODE)"
  if [[ $MODE == "python" ]]; then HAVE_PYTHON=1; else HAVE_PYTHON=0; fi

  F="$TMP/t1.$MODE.toml"; cp "$ROOT/test/fixtures/RustDesk2.toml" "$F"
  toml_upsert "$F" custom-rendezvous-server "new.example.com"
  assert_eq "replace existing key" "$(toml_get "$F" custom-rendezvous-server)" "new.example.com"
  assert_eq "other keys untouched" "$(toml_get "$F" verification-method)" "use-both-passwords"
  assert_eq "other section untouched" "$(toml_get "$F" allow-remote-config-modification)" "Y"
  toml_upsert "$F" custom-rendezvous-server "new.example.com"
  assert_eq "repeat upsert is idempotent" "$(grep -c 'custom-rendezvous-server' "$F")" "1"
  toml_upsert "$F" enable-lan-discovery "Y"
  assert_eq "insert key into section" "$(toml_get "$F" enable-lan-discovery)" "Y"
  assert_eq "following section still present" "$(grep -c '^\[tcp\]' "$F")" "1"

  F="$TMP/t2.$MODE.toml"; cp "$ROOT/test/fixtures/RustDesk2.no-section.toml" "$F"
  toml_upsert "$F" direct-server "Y"
  assert_eq "no [options] section -> created" "$(toml_get "$F" direct-server)" "Y"
  assert_eq "original content kept" "$(grep -c 'envelope' "$F")" "1"

  F="$TMP/t3.$MODE.toml"; : > "$F"
  toml_upsert "$F" enable-lan-discovery "Y"
  assert_eq "empty file -> section created" "$(toml_get "$F" enable-lan-discovery)" "Y"
done

# ---------------------------------------------------------------- config-string parsing
banner "cs_parse"
HAVE_PYTHON=0; command -v python3 >/dev/null 2>&1 && HAVE_PYTHON=1
CONFIG_STRING="host=rs.example.com,key=OaVaBKeyIs3JwERcG1Qvw==,api=https://api.example.com,relay=relay.example.com"
if cs_parse; then ok "comma form parses"; else bad "comma form failed to parse"; fi
assert_eq "host" "$CS_HOST" "rs.example.com"
assert_eq "key" "$CS_KEY" "OaVaBKeyIs3JwERcG1Qvw=="
assert_eq "api" "$CS_API" "https://api.example.com"
assert_eq "relay" "$CS_RELAY" "relay.example.com"

CONFIG_STRING="rustdesk-host=server.example.net,key=Zm9vYmFyLiwyCg==,.exe"
cs_parse
assert_eq "prefix/.exe noise stripped from host" "$CS_HOST" "server.example.net"

# base64(JSON) form
B64=$(printf '{"host":"b64.example.com","key":"KEY1","api":"","relay":"r2.example.com"}' | base64 -w0)
CONFIG_STRING="$B64"
if cs_parse; then ok "base64 form parses"; else bad "base64 form failed to parse"; fi
assert_eq "b64 host" "$CS_HOST" "b64.example.com"
assert_eq "b64 relay" "$CS_RELAY" "r2.example.com"

CONFIG_STRING="not-a-valid-string!!"
if cs_parse; then bad "garbage string should not parse"; else ok "garbage string rejected"; fi

# ---------------------------------------------------------------- misc
banner "misc"
PW=$(gen_random_password)
if [[ $PW =~ ^[A-Za-z0-9]{12}$ ]]; then ok "random password format ($PW)"; else bad "random password format off: $PW"; fi
OUT=$(trim "  hello  ")
assert_eq "trim" "$OUT" "hello"

printf '\n== Results: %d passed, %d failed ==\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
