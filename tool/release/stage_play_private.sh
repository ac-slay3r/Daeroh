#!/usr/bin/env bash
# Google Play is not a Daeroh distribution channel.
set -Eeuo pipefail

printf 'ERROR: Google Play staging is unavailable for Daeroh.\n' >&2
exit 1
