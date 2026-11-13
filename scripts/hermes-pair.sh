#!/bin/sh
# Daeroh GPL-3.0-only: pair an existing Hermes installation; never install or replace it.
# Tailnet is selected by default. LAN pairing is allowed only with an explicit
# HERMES_PAIR_HOST canonical RFC1918/CGNAT IPv4 literal. Set
# HERMES_DASHBOARD_PORT to opt in to a separately confirmed Dashboard URL.
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
command -v python3 >/dev/null 2>&1 || { echo "python3 is required for read-only pairing checks." >&2; exit 1; }
HH=${HERMES_HOME:-"$HOME/.hermes"}
[ -r "$HH/.env" ] || { echo "No readable Hermes environment at HERMES_HOME." >&2; exit 1; }
systemctl --user is-active --quiet hermes-gateway.service || { echo "hermes-gateway.service is not active." >&2; exit 1; }

is_private_ipv4() {
  value=$1
  case "$value" in *[!0-9.]*|.*|*..*|*.) return 1 ;; esac
  old_ifs=$IFS
  IFS=.
  # shellcheck disable=SC2086 # intentional split into the four validated octets
  set -- $value
  IFS=$old_ifs
  [ "$#" -eq 4 ] || return 1
  for octet in "$@"; do
    case "$octet" in 0|[1-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5]) ;; *) return 1 ;; esac
  done
  first=$1 second=$2
  [ "$first" -eq 10 ] && return 0
  [ "$first" -eq 172 ] && [ "$second" -ge 16 ] && [ "$second" -le 31 ] && return 0
  [ "$first" -eq 192 ] && [ "$second" -eq 168 ] && return 0
  [ "$first" -eq 100 ] && [ "$second" -ge 64 ] && [ "$second" -le 127 ] && return 0
  return 1
}

HOST=${HERMES_PAIR_HOST:-}
if [ -z "$HOST" ] && command -v tailscale >/dev/null 2>&1; then HOST=$(tailscale ip -4 2>/dev/null | sed -n '1p' || true); fi
[ -n "$HOST" ] || { echo "No tailnet address found; set HERMES_PAIR_HOST to a literal private address." >&2; exit 1; }
is_private_ipv4 "$HOST" || { echo "Refusing pairing host: require canonical 10/8, 172.16/12, 192.168/16, or 100.64/10 IPv4; loopback and 0.0.0.0 are not reachable from a phone." >&2; exit 1; }
PORT=${HERMES_PAIR_PORT:-8642}
case "$PORT" in ''|*[!0-9]*) echo "Invalid pairing port." >&2; exit 1;; esac
[ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || { echo "Invalid pairing port." >&2; exit 1; }
DASHBOARD_PORT=${HERMES_DASHBOARD_PORT:-}
case "$DASHBOARD_PORT" in ''|*[!0-9]*) ;; *) [ "$DASHBOARD_PORT" -ge 1 ] && [ "$DASHBOARD_PORT" -le 65535 ] || { echo "Invalid HERMES_DASHBOARD_PORT." >&2; exit 1; } ;; esac

# The Python child reads API_SERVER_KEY itself, retaining it only in process memory.
# It is never in argv, environment, a header argument, or a persistent file.
# Each probe has a two-second monotonic deadline; all network checks together
# are capped at six seconds, including connect, response headers, and 4096 body bytes.
LINK=$(python3 - "$HH/.env" "$HOST" "$PORT" "$DASHBOARD_PORT" <<'PY'
import re
import socket
import sys
import time
import urllib.parse

env_path, host, port_text, dashboard_port = sys.argv[1:]
keys = []
try:
    with open(env_path, encoding="utf-8", newline="") as source:
        for raw in source:
            line = raw[:-2] if raw.endswith("\r\n") else raw[:-1] if raw.endswith("\n") else raw
            match = re.fullmatch(r"[ \t]*(?:export[ \t]+)?API_SERVER_KEY[ \t]*=[ \t]*(.*?)[ \t]*", line)
            if match:
                value = match.group(1)
                if len(value) >= 2 and value[0] in "\"'" and value[-1] == value[0]:
                    value = value[1:-1]
                elif value.startswith(("\"", "'")) or value.endswith(("\"", "'")):
                    raise ValueError()
                if not value or "\r" in value or "\n" in value:
                    raise ValueError()
                keys.append(value)
except (OSError, UnicodeError, ValueError):
    sys.exit(20)
if len(keys) != 1:
    sys.exit(20)
token = keys[0]
network_deadline = time.monotonic() + 6.0

def status(target_port, path, bearer=None):
    deadline = min(network_deadline, time.monotonic() + 2.0)
    def remaining():
        value = deadline - time.monotonic()
        if value <= 0:
            raise TimeoutError()
        return value
    request = "GET %s HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n" % (path, host)
    if bearer is not None:
        request += "Authorization: Bearer %s\r\n" % bearer
    request += "\r\n"
    try:
        with socket.create_connection((host, target_port), timeout=remaining()) as connection:
            connection.settimeout(remaining())
            connection.sendall(request.encode("ascii"))
            response = bytearray()
            while b"\r\n\r\n" not in response:
                if len(response) >= 16384:
                    return None
                connection.settimeout(remaining())
                chunk = connection.recv(1)
                if not chunk:
                    return None
                response.extend(chunk)
            head, body = bytes(response).split(b"\r\n\r\n", 1)
            first = head.split(b"\r\n", 1)[0].split()
            if len(first) < 2 or not first[1].isdigit():
                return None
            content_length = 0
            for header in head.split(b"\r\n")[1:]:
                if header.lower().startswith(b"content-length:"):
                    content_length = int(header.split(b":", 1)[1].strip())
                    break
            wanted = min(content_length, 4096)
            while len(body) < wanted:
                connection.settimeout(remaining())
                chunk = connection.recv(min(256, wanted - len(body)))
                if not chunk:
                    return None
                body += chunk
            return int(first[1])
    except (OSError, ValueError, TimeoutError):
        return None

port = int(port_text)
wrong = status(port, "/api/sessions", "daeroh-pairing-wrong-bearer")
if wrong not in (401, 403):
    sys.exit(21)
right = status(port, "/api/sessions", token)
if right is None or not 200 <= right < 300:
    sys.exit(21)
query = {"host": host, "port": str(port), "token": token, "label": "Daeroh"}
dashboard_state = "not requested"
# Dashboard needs an explicit configured port and a live endpoint; Bridge fields
# are deliberately omitted because this script never resolves a Bridge token.
if dashboard_port:
    dashboard_status = status(int(dashboard_port), "/api/health")
    if dashboard_status is not None and 200 <= dashboard_status < 300:
        query["dashboard"] = "http://%s:%s" % (host, dashboard_port)
        dashboard_state = "confirmed"
    else:
        dashboard_state = "not confirmed"
print("hermes://pair?" + urllib.parse.urlencode(query))
print(dashboard_state)
PY
) || { code=$?; case "$code" in 20) echo "API_SERVER_KEY is missing, duplicated, or has unsupported quoting in .env." >&2 ;; *) echo "Gateway pairing endpoint did not prove bearer authentication." >&2 ;; esac; exit 1; }

DASHBOARD_STATE=$(printf '%s\n' "$LINK" | tail -n 1)
LINK=$(printf '%s\n' "$LINK" | sed '$d')
if [ -t 1 ]; then
  if command -v qrencode >/dev/null 2>&1; then printf '%s' "$LINK" | qrencode -t ANSIUTF8; else echo "Pairing QR renderer is unavailable; install qrencode to display it." >&2; fi
  if [ "$show_link" -eq 1 ]; then printf '%s\n' "$LINK"; fi
else
  echo "Gateway authentication was checked; dashboard was $DASHBOARD_STATE." >&2
fi
