#!/usr/bin/env bash
# Provision a Raspberry Pi from your Mac/Linux machine over SSH.
# Copies this directory to the Pi and runs install.sh there.
#
#   ./provision.sh --host whiteboard.local [--user pi] \
#                  [--label "Conference Room A"] [--port 8080] \
#                  [--token SECRET] [--extra "--autofocus-mode auto"]
#
# Prereqs: the Pi is booted, on the network, and reachable over SSH
# (Raspberry Pi Imager can preconfigure SSH + Wi-Fi + hostname + user).
set -euo pipefail

HOST=""
USER="pi"
INSTALL_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)  HOST="$2"; shift 2 ;;
    --user)  USER="$2"; shift 2 ;;
    --label|--port|--token|--width|--height|--extra)
      INSTALL_ARGS+=("$1" "$2"); shift 2 ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//' | sed -n '2,9p'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$HOST" ]]; then
  echo "error: --host is required (e.g. --host whiteboard.local)" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$USER@$HOST"

echo "==> Copying server files to $TARGET:/tmp/whiteboard-install/"
ssh "$TARGET" 'rm -rf /tmp/whiteboard-install && mkdir -p /tmp/whiteboard-install'
scp -q "$SCRIPT_DIR/whiteboard-server.ts" "$SCRIPT_DIR/install.sh" "$SCRIPT_DIR/90-avahi-republish" \
    "$TARGET:/tmp/whiteboard-install/"

echo "==> Running install.sh on the Pi (sudo)"
# shellcheck disable=SC2029 - we intend the args to expand locally
ssh -t "$TARGET" "chmod +x /tmp/whiteboard-install/install.sh && sudo /tmp/whiteboard-install/install.sh ${INSTALL_ARGS[*]}"

echo "==> Done. Verify discovery from this machine with the skill's discover.py."
