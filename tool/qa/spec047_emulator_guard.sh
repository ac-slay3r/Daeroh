#!/usr/bin/env bash

set -Eeuo pipefail

readonly EXPECTED_AVD="Daeroh_API37_x86_64"
readonly EXPECTED_SDK="37"
readonly QA_PACKAGE="cool.n0thing.daeroh.qa"
readonly DEFAULT_SERIAL="emulator-5554"
readonly DEFAULT_APK="build/app/outputs/flutter-apk/app-qa-debug.apk"

ADB_BIN="${ADB_BIN:-adb}"
SERIAL="${ANDROID_SERIAL:-$DEFAULT_SERIAL}"

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

adb_emulator() {
  "$ADB_BIN" -s "$SERIAL" "$@"
}

require_exact_emulator() {
  local avd sdk qemu booted

  command -v "$ADB_BIN" >/dev/null 2>&1 || fail "adb no está disponible"
  [[ "$SERIAL" == emulator-* ]] ||
    fail "el serial no pertenece a un emulador: $SERIAL"
  [[ "$(adb_emulator get-state 2>/dev/null)" == "device" ]] ||
    fail "el emulador $SERIAL no está conectado"

  avd="$(adb_emulator emu avd name 2>/dev/null | tr -d '\r' | head -n 1)"
  sdk="$(adb_emulator shell getprop ro.build.version.sdk | tr -d '\r')"
  qemu="$(adb_emulator shell getprop ro.kernel.qemu | tr -d '\r')"
  booted="$(adb_emulator shell getprop sys.boot_completed | tr -d '\r')"

  [[ "$avd" == "$EXPECTED_AVD" ]] ||
    fail "AVD inesperado: '$avd' (se esperaba '$EXPECTED_AVD')"
  [[ "$sdk" == "$EXPECTED_SDK" ]] ||
    fail "API inesperada: '$sdk' (se esperaba '$EXPECTED_SDK')"
  [[ "$qemu" == "1" ]] || fail "ro.kernel.qemu no confirma un emulador"
  [[ "$booted" == "1" ]] || fail "el AVD todavía no terminó de arrancar"
}

package_version() {
  adb_emulator shell dumpsys package "$QA_PACKAGE" 2>/dev/null |
    awk -F= '/versionName=/{print $2; exit}' | tr -d '\r'
}

package_version_code() {
  adb_emulator shell dumpsys package "$QA_PACKAGE" 2>/dev/null |
    awk '/versionCode=/{for (i=1; i<=NF; i++) if ($i ~ /^versionCode=/) {sub(/^versionCode=/, "", $i); print $i; exit}}' |
    tr -d '\r'
}

installed_apk_path() {
  adb_emulator shell pm path "$QA_PACKAGE" 2>/dev/null |
    awk -F: '/^package:/{print $2; exit}' | tr -d '\r'
}

verify_installed_apk() {
  local apk_path="$1" device_path local_sha installed_sha
  command -v sha256sum >/dev/null 2>&1 || fail "sha256sum no está disponible"
  device_path="$(installed_apk_path)"
  [[ -n "$device_path" ]] || fail "Android no devolvió la ruta de la APK QA"
  local_sha="$(sha256sum "$apk_path" | awk '{print $1}')"
  installed_sha="$(adb_emulator exec-out cat "$device_path" | sha256sum | awk '{print $1}')"
  [[ "$local_sha" == "$installed_sha" ]] ||
    fail "la APK instalada no coincide byte a byte con el build QA"
  printf 'SHA-256 local/instalada: %s\n' "$local_sha"
}

doctor() {
  local installed version version_code
  require_exact_emulator
  installed="$(adb_emulator shell pm list packages "$QA_PACKAGE" | tr -d '\r')"
  version=""
  version_code=""
  if [[ "$installed" == "package:$QA_PACKAGE" ]]; then
    version="$(package_version)"
    version_code="$(package_version_code)"
  fi
  printf 'Guard OK: serial=%s avd=%s API=%s qemu=1\n' \
    "$SERIAL" "$EXPECTED_AVD" "$EXPECTED_SDK"
  printf 'Paquete QA: %s version=%s code=%s\n' \
    "${installed:-no instalado}" "${version:-n/a}" \
    "${version_code:-n/a}"
  printf 'Guard físico: solo se acepta un serial emulator-* confirmado por qemu.\n'
}

install_qa() {
  local apk_path="${1:-$DEFAULT_APK}" installed
  require_exact_emulator
  [[ -f "$apk_path" ]] || fail "APK QA no encontrada: $apk_path"

  adb_emulator install -r "$apk_path"
  installed="$(adb_emulator shell pm list packages "$QA_PACKAGE" | tr -d '\r')"
  [[ "$installed" == "package:$QA_PACKAGE" ]] ||
    fail "la APK instalada no expone el applicationId QA esperado"
  verify_installed_apk "$apk_path"
  printf 'APK QA actualizada: %s version=%s code=%s\n' \
    "$QA_PACKAGE" "$(package_version)" "$(package_version_code)"
}

launch_qa() {
  local installed
  require_exact_emulator
  installed="$(adb_emulator shell pm list packages "$QA_PACKAGE" | tr -d '\r')"
  [[ "$installed" == "package:$QA_PACKAGE" ]] ||
    fail "el paquete QA no está instalado"
  adb_emulator shell monkey -p "$QA_PACKAGE" \
    -c android.intent.category.LAUNCHER 1 >/dev/null
  printf 'QA abierta únicamente en %s\n' "$SERIAL"
}

usage() {
  printf '%s\n' \
    'Uso: tool/qa/spec047_emulator_guard.sh doctor' \
    '      tool/qa/spec047_emulator_guard.sh install [apk-qa]' \
    '      tool/qa/spec047_emulator_guard.sh launch'
}

case "${1:-}" in
  doctor) doctor ;;
  install) install_qa "${2:-$DEFAULT_APK}" ;;
  launch) launch_qa ;;
  -h|--help|help|'') usage ;;
  *) usage; fail "acción desconocida: $1" ;;
esac
