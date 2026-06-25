#!/usr/bin/env bash
# Build and deploy the whiteboard BLE provisioner to a Raspberry Pi.
# Run on your Mac while the Pi is still reachable over SSH (this one-time setup
# happens on a known network; BLE handles every re-provision afterward).
#
#   ./provision.sh --host raspberrypi.local [--user nico] [--label "Office"]
#
# Cross-compiles a self-contained arm64 Linux binary on the Mac (no Dart on the
# Pi), ships it + the systemd unit + install.sh, then runs install.sh over SSH.
set -euo pipefail

HOST=""
USER="nico"
LABEL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)  HOST="$2"; shift 2 ;;
    --user)  USER="$2"; shift 2 ;;
    --label) LABEL="$2"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//' | sed -n '2,11p'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[[ -n $HOST ]] || { echo "error: --host is required (e.g. --host raspberrypi.local)" >&2; exit 2; }
command -v dart >/dev/null || { echo "error: 'dart' not on PATH (install the Flutter SDK)" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$USER@$HOST"

echo "==> dart pub get"
( cd "$SCRIPT_DIR" && dart pub get )

echo "==> Cross-compiling arm64 Linux binary"
mkdir -p "$SCRIPT_DIR/build"
( cd "$SCRIPT_DIR" && dart compile exe --target-os=linux --target-arch=arm64 \
    bin/whiteboard_provisioner.dart -o build/whiteboard-provisioner )
file "$SCRIPT_DIR/build/whiteboard-provisioner" | sed 's/^/    /'

echo "==> Shipping to $TARGET"
ssh "$TARGET" 'rm -rf /tmp/wb-provisioner && mkdir -p /tmp/wb-provisioner'
scp -q "$SCRIPT_DIR/build/whiteboard-provisioner" \
       "$SCRIPT_DIR/whiteboard-provisioner.service" \
       "$SCRIPT_DIR/install.sh" \
       "$TARGET:/tmp/wb-provisioner/"

echo "==> Running install.sh on the Pi (sudo)"
# shellcheck disable=SC2029 - args intentionally expand locally
ssh -t "$TARGET" "chmod +x /tmp/wb-provisioner/install.sh && sudo /tmp/wb-provisioner/install.sh ${LABEL:+--label \"$LABEL\"}"

echo "==> Done. The Pi advertises over BLE; open the sidecar app to set Wi-Fi."
