#!/usr/bin/env bash

set -Eeuo pipefail

readonly QA_PACKAGE="cool.n0thing.daeroh.qa"
readonly DEFAULT_SERIAL=""

ADB_BIN="${ADB_BIN:-adb}"
SERIAL="${ANDROID_SERIAL:-$DEFAULT_SERIAL}"
NETWORK_CAPTURED=0
WIFI_WAS_ENABLED=0
DATA_WAS_ENABLED=0

usage() {
  cat <<'USAGE'
Uso: tool/qa/resilience_smoke.sh <acción> [argumento]

Acciones:
  doctor                 Comprueba ADB, dispositivo y paquete QA (solo lectura).
  launch                 Abre exclusivamente la aplicación QA.
  background             Envía el dispositivo a Inicio.
  force-stop             Fuerza el cierre exclusivamente del paquete QA.
  relaunch               Fuerza el cierre y vuelve a abrir QA.
  network-flap [seg]     Corta Wi-Fi/datos y los restaura (1-300 s; 10 por defecto).
  crash-check            Cuenta errores fatales del PID QA sin imprimir contenido.
  exit-info              Resume ApplicationExitInfo del paquete QA.
  meminfo                Resume memoria del proceso QA.
  menu                   Laboratorio interactivo con restauración al salir.

Variables opcionales:
  ANDROID_SERIAL         Serial ADB físico; obligatorio y nunca versionado.
  ADB_BIN                Ejecutable adb; por defecto "adb".

El script no borra datos, no desinstala, no instala APKs y no ejecuta comandos
contra servidores. Todas las mutaciones se limitan al paquete QA o a un corte de
red temporal cuyo estado anterior se restaura incluso al interrumpir el proceso.
USAGE
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

adb_device() {
  "$ADB_BIN" -s "$SERIAL" "$@"
}

require_device() {
  command -v "$ADB_BIN" >/dev/null 2>&1 || fail "adb no está disponible"
  [[ -n "$SERIAL" ]] ||
    fail "define ANDROID_SERIAL con el dispositivo físico autorizado"
  [[ "$(adb_device get-state 2>/dev/null)" == "device" ]] ||
    fail "el dispositivo $SERIAL no está conectado/autorizado"
}

require_qa_package() {
  local installed
  installed="$(adb_device shell pm list packages "$QA_PACKAGE" | tr -d '\r')"
  [[ "$installed" == "package:$QA_PACKAGE" ]] ||
    fail "no está instalado el paquete QA exacto: $QA_PACKAGE"
}

ready() {
  require_device
  require_qa_package
}

qa_pid() {
  adb_device shell pidof -s "$QA_PACKAGE" 2>/dev/null | tr -d '\r'
}

launch_qa() {
  ready
  adb_device shell monkey -p "$QA_PACKAGE" -c android.intent.category.LAUNCHER 1 \
    >/dev/null
  printf 'QA abierta: %s\n' "$QA_PACKAGE"
}

background_qa() {
  ready
  adb_device shell input keyevent KEYCODE_HOME
  printf 'Dispositivo enviado a Inicio; datos de QA intactos.\n'
}

force_stop_qa() {
  ready
  adb_device shell am force-stop "$QA_PACKAGE"
  printf 'Cierre forzado aplicado solo a %s\n' "$QA_PACKAGE"
}

setting_is_enabled() {
  local key="$1"
  local value
  value="$(adb_device shell settings get global "$key" 2>/dev/null | tr -d '\r')"
  [[ "$value" == "1" ]]
}

capture_network_state() {
  ((NETWORK_CAPTURED == 0)) || return 0
  WIFI_WAS_ENABLED=0
  DATA_WAS_ENABLED=0
  setting_is_enabled wifi_on && WIFI_WAS_ENABLED=1
  setting_is_enabled mobile_data && DATA_WAS_ENABLED=1
  NETWORK_CAPTURED=1
}

restore_network() {
  ((NETWORK_CAPTURED == 1)) || return 0

  if ((WIFI_WAS_ENABLED == 1)); then
    adb_device shell svc wifi enable >/dev/null 2>&1 || true
  else
    adb_device shell svc wifi disable >/dev/null 2>&1 || true
  fi

  if ((DATA_WAS_ENABLED == 1)); then
    adb_device shell svc data enable >/dev/null 2>&1 || true
  else
    adb_device shell svc data disable >/dev/null 2>&1 || true
  fi

  NETWORK_CAPTURED=0
  printf 'Red restaurada al estado previo (Wi-Fi=%s, datos=%s).\n' \
    "$WIFI_WAS_ENABLED" "$DATA_WAS_ENABLED"
}

network_flap() {
  local seconds="${1:-10}"
  [[ "$seconds" =~ ^[0-9]+$ ]] || fail "la duración debe ser un entero"
  ((seconds >= 1 && seconds <= 300)) || fail "la duración debe estar entre 1 y 300 s"
  ready
  capture_network_state
  trap restore_network EXIT INT TERM
  adb_device shell svc wifi disable >/dev/null
  adb_device shell svc data disable >/dev/null
  printf 'Red cortada durante %s s...\n' "$seconds"
  sleep "$seconds"
  restore_network
  trap - EXIT INT TERM
}

crash_check() {
  local pid output fatal_count flutter_count
  ready
  pid="$(qa_pid)"
  [[ -n "$pid" ]] || fail "QA no está en ejecución"
  output="$(adb_device logcat -d --pid="$pid" '*:E' 2>/dev/null || true)"
  fatal_count="$(grep -cE 'FATAL EXCEPTION|AndroidRuntime.*FATAL' <<<"$output" || true)"
  flutter_count="$(grep -cE 'FlutterError|Unhandled Exception' <<<"$output" || true)"
  printf 'PID=%s fatal_android=%s flutter_unhandled=%s\n' \
    "$pid" "$fatal_count" "$flutter_count"
}

exit_info() {
  local output
  ready
  output="$(adb_device shell dumpsys activity exit-info "$QA_PACKAGE" 2>/dev/null || true)"
  printf '%s\n' "$output" | awk '
    /ApplicationExitInfo #/ ||
    /timestamp=/ ||
    /reason=/ ||
    /status=/ ||
    /importance=/ ||
    /pss=/ ||
    /rss=/ {print}
  '
}

meminfo() {
  local pid output
  ready
  pid="$(qa_pid)"
  [[ -n "$pid" ]] || fail "QA no está en ejecución"
  output="$(adb_device shell dumpsys meminfo "$QA_PACKAGE" 2>/dev/null)"
  printf 'PID=%s\n' "$pid"
  printf '%s\n' "$output" | awk '
    /^[[:space:]]*TOTAL[[:space:]]/ ||
    /TOTAL PSS:/ ||
    /TOTAL RSS:/ ||
    /App Summary/ {print}
  '
}

doctor() {
  local model sdk release version
  ready
  model="$(adb_device shell getprop ro.product.model | tr -d '\r')"
  sdk="$(adb_device shell getprop ro.build.version.sdk | tr -d '\r')"
  release="$(adb_device shell getprop ro.build.version.release | tr -d '\r')"
  version="$(adb_device shell dumpsys package "$QA_PACKAGE" | awk -F= '/versionName=/{print $2; exit}' | tr -d '\r')"
  printf 'ADB OK: serial=%s modelo=%s Android=%s API=%s\n' \
    "$SERIAL" "$model" "$release" "$sdk"
  printf 'Paquete QA exacto instalado: %s version=%s\n' "$QA_PACKAGE" "$version"
  printf 'Guardas activas: sin clear-data, uninstall, install ni comandos de servidor.\n'
}

interactive_menu() {
  local choice
  ready
  trap restore_network EXIT INT TERM
  while true; do
    printf '\n[1] doctor  [2] launch  [3] background  [4] force-stop\n'
    printf '[5] relaunch [6] red 10 s [7] crash-check [8] exit-info\n'
    printf '[9] meminfo  [0] salir\n> '
    read -r choice
    case "$choice" in
      1) doctor ;;
      2) launch_qa ;;
      3) background_qa ;;
      4) force_stop_qa ;;
      5) force_stop_qa; launch_qa ;;
      6) network_flap 10 ;;
      7) crash_check ;;
      8) exit_info ;;
      9) meminfo ;;
      0) break ;;
      *) printf 'Opción no válida.\n' >&2 ;;
    esac
  done
  restore_network
  trap - EXIT INT TERM
}

main() {
  local action="${1:-}"
  case "$action" in
    doctor) doctor ;;
    launch) launch_qa ;;
    background) background_qa ;;
    force-stop) force_stop_qa ;;
    relaunch) force_stop_qa; launch_qa ;;
    network-flap) network_flap "${2:-10}" ;;
    crash-check) crash_check ;;
    exit-info) exit_info ;;
    meminfo) meminfo ;;
    menu) interactive_menu ;;
    -h|--help|help) usage ;;
    *) usage; [[ -z "$action" ]] || fail "acción desconocida: $action" ;;
  esac
}

main "$@"
