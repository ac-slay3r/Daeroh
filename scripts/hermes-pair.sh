#!/bin/sh
# Daeroh GPL-3.0-only: pair an existing Hermes installation; never install or replace it.
set -eu

show_link=0
case "${1:-}" in
  --show-link) show_link=1 ;;
  '') ;;
  *) echo "Usage: $0 [--show-link]" >&2; exit 2 ;;
esac

# All checks are read-only. This script deliberately creates no files and never
# invokes a systemctl mutation command.
[ "$(uname -s)" = Linux ] || { echo "Daeroh pairing supports Linux systemd user services only." >&2; exit 1; }
command -v systemctl >/dev/null 2>&1 || { echo "systemctl is required." >&2; exit 1; }
command -v hermes >/dev/null 2>&1 || { echo "The public hermes CLI is required." >&2; exit 1; }
HH=${HERMES_HOME:-"$HOME/.hermes"}
[ -r "$HH/.env" ] || { echo "No readable Hermes environment at HERMES_HOME." >&2; exit 1; }
TOKEN=$(sed -n 's/^API_SERVER_KEY=//p' "$HH/.env" | head -n 1 | tr -d '\r\n')
[ -n "$TOKEN" ] || { echo "API_SERVER_KEY is unavailable." >&2; exit 1; }
systemctl --user is-active --quiet hermes-gateway.service || { echo "hermes-gateway.service is not healthy." >&2; exit 1; }
systemctl --user is-active --quiet hermes-dashboard.service || { echo "hermes-dashboard.service is not healthy." >&2; exit 1; }

is_private_ipv4() {
  case "$1" in
    10.*|192.168.*|127.*|100.6[4-9].*|100.[7-9][0-9].*|100.1[0-1][0-9].*|100.12[0-7].*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) return 0 ;;
    *) return 1 ;;
  esac
}
HOST=${HERMES_PAIR_HOST:-}
if [ -z "$HOST" ] && command -v tailscale >/dev/null 2>&1; then
  HOST=$(tailscale ip -4 2>/dev/null | sed -n '1p' || true)
fi
[ -n "$HOST" ] || { echo "No tailnet address found; set HERMES_PAIR_HOST to a literal private address." >&2; exit 1; }
is_private_ipv4 "$HOST" || { echo "Refusing cleartext pairing outside literal private/tailnet IPv4." >&2; exit 1; }
PORT=${HERMES_PAIR_PORT:-8642}
case "$PORT" in ''|*[!0-9]*) echo "Invalid pairing port." >&2; exit 1;; esac
[ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || { echo "Invalid pairing port." >&2; exit 1; }

LINK=$(python3 - "$HOST" "$PORT" "$TOKEN" <<'PY'
import sys, urllib.parse
host, port, token = sys.argv[1:]
print('hermes://pair?' + urllib.parse.urlencode({
  'host': host, 'port': port, 'token': token,
  'dashboard': 'http://%s:9119' % host,
  'bridge': 'http://%s:9131' % host,
  'bridge_token': token, 'label': 'Daeroh',
}))
PY
)

if [ -t 1 ]; then
  if command -v qrencode >/dev/null 2>&1; then
    printf '%s' "$LINK" | qrencode -t ANSIUTF8
  else
    echo "Pairing QR renderer is unavailable; install qrencode to display it." >&2
  fi
  if [ "$show_link" -eq 1 ]; then printf '%s\n' "$LINK"; fi
else
  echo "Pairing verified. Re-run from a trusted TTY to display the QR." >&2
fi
