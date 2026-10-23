#!/usr/bin/env bash
# Captura un log LIMPIO del modo voz desde el móvil para depurar.
#
# Uso:
#   scripts/voice-log.sh            # imprime en pantalla en vivo
#   scripts/voice-log.sh -f         # además guarda a voice-<fecha>.log
#
# Filtra solo lo relevante:
#   [VOICE]       — eventos del ciclo de voz (ENTER/EXIT, ruta, acuse,
#                   full-duplex: STT listo/eco/barge-in/WS caído).
#   [VOICE-PERF]  — latencias por turno (endpointing, first token, TTS).
#   FATAL/crash   — errores duros.
#
# Sugerencia: ejecuta esto, entra al modo voz en la app y habla; al terminar
# corta con Ctrl-C y pásame el .log (o el texto de pantalla).
set -euo pipefail

DEVICE="${HERMES_DEVICE:-}"
PKG="${HERMES_PACKAGE:-cool.n0thing.daeroh.qa}"
FILTER='\[VOICE|\[VOICE-PERF|FATAL EXCEPTION|AndroidRuntime'

ADB=(adb)
device_label="the default ADB device"
if [[ -n "$DEVICE" ]]; then
  ADB+=( -s "$DEVICE" )
  device_label="$DEVICE"
fi

save=""
[[ "${1:-}" == "-f" ]] && save="voice-$(date +%Y%m%d-%H%M%S).log"

echo "» Limpiando buffer y capturando de $device_label ($PKG)…"
echo "» Entra al modo voz y habla. Corta con Ctrl-C cuando termines."
[[ -n "$save" ]] && echo "» Guardando en: $save"
echo "────────────────────────────────────────────────────────"

"${ADB[@]}" logcat -c || true
if [[ -n "$save" ]]; then
  "${ADB[@]}" logcat -s flutter:* AndroidRuntime:E \
    | grep --line-buffered -E "$FILTER" | tee "$save"
else
  "${ADB[@]}" logcat -s flutter:* AndroidRuntime:E \
    | grep --line-buffered -E "$FILTER"
fi
