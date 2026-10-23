#!/usr/bin/env bash

set -euo pipefail

readonly EXPECTED_PACKAGE="cool.n0thing.daeroh.qa"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRATCH_DIR=""

usage() {
  cat <<'EOF'
Usage: tool/qa/verify_qa_profile_network_policy.sh <app-qa-profile.apk>

Verifies that the packaged qaProfile APK, not merely a source manifest,
contains the same LAN/Tailscale platform policy used by release. The separate
Flutter TransportPrivacy regression remains responsible for rejecting public
HTTP/WS before application traffic is sent.
EOF
}

fail() {
  printf 'qaProfile network policy: FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  [[ -z "$SCRATCH_DIR" ]] || rm -rf -- "$SCRATCH_DIR"
}

list_archive_entries() {
  local archive="$1"

  python3 - "$archive" <<'PY'
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as apk:
    for name in apk.namelist():
        print(name)
PY
}

resolve_tool() {
  local name="$1"
  local candidate sdk_dir=""
  if command -v "$name" >/dev/null 2>&1; then
    command -v "$name"
    return
  fi
  if [[ -r "$PROJECT_ROOT/android/local.properties" ]]; then
    sdk_dir="$(sed -n 's/^sdk\.dir=//p' \
      "$PROJECT_ROOT/android/local.properties" | tail -n 1)"
  fi
  for candidate in \
    "${ANDROID_SDK_ROOT:-}/cmdline-tools/latest/bin/$name" \
    "${ANDROID_HOME:-}/cmdline-tools/latest/bin/$name" \
    "${ANDROID_SDK_ROOT:-}/build-tools/36.0.0/$name" \
    "${ANDROID_HOME:-}/build-tools/36.0.0/$name" \
    "$sdk_dir/cmdline-tools/latest/bin/$name" \
    "$sdk_dir/build-tools/36.0.0/$name"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return
    fi
  done
  fail "required Android SDK tool not found: $name"
}

main() {
  case "${1:-}" in
    -h|--help|help)
      usage
      return
      ;;
  esac

  [[ $# -eq 1 ]] || { usage >&2; exit 2; }
  local apk="$1"
  [[ -f "$apk" ]] || fail "APK does not exist: $apk"

  local apkanalyzer aapt2 archive_entries manifest_tree resource_table
  local xmltree
  local application_id network_config_id forbidden_permission
  local -a network_config_ids policy_entries resource_matches
  apkanalyzer="$(resolve_tool apkanalyzer)"
  aapt2="$(resolve_tool aapt2)"
  SCRATCH_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hermes-qaprofile-policy.XXXXXX")"
  chmod 700 "$SCRATCH_DIR"
  trap cleanup EXIT
  archive_entries="$SCRATCH_DIR/archive-entries.txt"
  manifest_tree="$SCRATCH_DIR/manifest-tree.txt"
  resource_table="$SCRATCH_DIR/resources.txt"
  xmltree="$SCRATCH_DIR/network-security.txt"

  application_id="$("$apkanalyzer" manifest application-id "$apk")"
  [[ "$application_id" == "$EXPECTED_PACKAGE" ]] ||
    fail "unexpected package; expected $EXPECTED_PACKAGE"

  "$aapt2" dump xmltree --file AndroidManifest.xml "$apk" >"$manifest_tree"
  grep -q 'usesCleartextTraffic.*=false' "$manifest_tree" ||
    fail "main manifest default is not closed"
  for forbidden_permission in \
    android.permission.READ_PHONE_STATE \
    android.permission.READ_EXTERNAL_STORAGE; do
    if grep -q "$forbidden_permission" "$manifest_tree"; then
      fail "packaged manifest contains forbidden implied permission: $forbidden_permission"
    fi
  done
  mapfile -t network_config_ids < <(sed -n \
    's|^[[:space:]]*A: http://schemas.android.com/apk/res/android:networkSecurityConfig([^)]*)=@\(0x7f[[:xdigit:]]\{6\}\)$|\1|p' \
    "$manifest_tree")
  [[ ${#network_config_ids[@]} -eq 1 ]] ||
    fail "manifest must contain exactly one compiled app networkSecurityConfig reference"
  network_config_id="${network_config_ids[0]}"

  "$aapt2" dump resources "$apk" >"$resource_table"
  mapfile -t resource_matches < <(grep -E \
    "^[[:space:]]*resource ${network_config_id} xml/network_security_config$" \
    "$resource_table" || true)
  [[ ${#resource_matches[@]} -eq 1 ]] ||
    fail "manifest networkSecurityConfig must resolve exactly once to release policy"

  list_archive_entries "$apk" >"$archive_entries"
  mapfile -t policy_entries < <(grep -Fx \
    'res/xml/network_security_config.xml' "$archive_entries" || true)
  [[ ${#policy_entries[@]} -eq 1 ]] ||
    fail "packaged network_security_config.xml must exist exactly once"
  "$aapt2" dump xmltree \
    --file res/xml/network_security_config.xml "$apk" >"$xmltree"
  grep -q 'A: cleartextTrafficPermitted=true' "$xmltree" ||
    fail "packaged policy does not permit private cleartext transport"
  grep -q 'A: src="system"' "$xmltree" ||
    fail "packaged policy does not retain system trust anchors"

  cleanup
  trap - EXIT
  SCRATCH_DIR=""

  printf 'qaProfile network policy: PASS\n'
  printf 'package=%s\n' "$EXPECTED_PACKAGE"
  printf 'apk=%s\n' "$apk"
  printf 'manifest=closed-default+release-network-config\n'
  printf 'resource=private-cleartext-platform-mechanism+system-trust\n'
}

main "$@"
