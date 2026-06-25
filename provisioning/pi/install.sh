#!/usr/bin/env bash
# Install the whiteboard BLE Wi-Fi provisioner on a Raspberry Pi.
# Run ON THE PI with sudo. Expects the cross-compiled `whiteboard-provisioner`
# binary and `whiteboard-provisioner.service` to sit next to this script
# (provision.sh ships them for you). Idempotent — safe to re-run.
#
#   sudo ./install.sh [--label "Conference Room A"]
#
# No Dart/Flutter is installed here: the binary is self-contained. The only
# runtime dependencies are the Pi's own BlueZ + D-Bus, which Raspberry Pi OS
# already ships.
set -euo pipefail

LABEL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --label) LABEL="$2"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//' | sed -n '2,12p'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "error: run with sudo (writes systemd + bluetooth config)" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINARY="$SCRIPT_DIR/whiteboard-provisioner"
UNIT="$SCRIPT_DIR/whiteboard-provisioner.service"
[[ -f $BINARY ]] || { echo "error: missing binary at $BINARY" >&2; exit 1; }
[[ -f $UNIT   ]] || { echo "error: missing unit at $UNIT" >&2; exit 1; }

echo "==> Installing whiteboard BLE provisioner"

# 1. Force LE controller mode. BlueZ's default dual mode breaks LE bearer
#    selection with Apple centrals (the connection hangs); LE-only fixes it.
MAIN=/etc/bluetooth/main.conf
if [[ -f $MAIN ]]; then
  if grep -qE '^[[:space:]]*#?[[:space:]]*ControllerMode' "$MAIN"; then
    sed -i -E 's/^[[:space:]]*#?[[:space:]]*ControllerMode[[:space:]]*=.*/ControllerMode = le/' "$MAIN"
  elif grep -qE '^\[General\]' "$MAIN"; then
    sed -i -E '/^\[General\]/a ControllerMode = le' "$MAIN"
  else
    printf '\n[General]\nControllerMode = le\n' >> "$MAIN"
  fi
  echo "    set ControllerMode = le in $MAIN"
  # AutoEnable: power the controller on at boot. Without it the adapter stays
  # down and the provisioner can't advertise (manual `bluetoothctl power on`
  # doesn't persist across reboots).
  if grep -qE '^[[:space:]]*#?[[:space:]]*AutoEnable' "$MAIN"; then
    sed -i -E 's/^[[:space:]]*#?[[:space:]]*AutoEnable[[:space:]]*=.*/AutoEnable=true/' "$MAIN"
  elif grep -qE '^\[Policy\]' "$MAIN"; then
    sed -i -E '/^\[Policy\]/a AutoEnable=true' "$MAIN"
  else
    printf '\n[Policy]\nAutoEnable=true\n' >> "$MAIN"
  fi
  echo "    set AutoEnable = true in $MAIN"
else
  echo "    WARNING: $MAIN not found; skipping ControllerMode (verify BlueZ)" >&2
fi

# 2. Optional friendly label, shared with the capture server's env file.
if [[ -n $LABEL ]]; then
  install -d -m 0755 /etc/whiteboard
  CONF=/etc/whiteboard/whiteboard.conf
  touch "$CONF"; chmod 600 "$CONF"
  if grep -qE '^WHITEBOARD_LABEL=' "$CONF"; then
    sed -i -E "s|^WHITEBOARD_LABEL=.*|WHITEBOARD_LABEL=$LABEL|" "$CONF"
  else
    printf 'WHITEBOARD_LABEL=%s\n' "$LABEL" >> "$CONF"
  fi
  echo "    label: $LABEL"
fi

# 3. Install the binary.
install -d -m 0755 /opt/whiteboard-provisioner
install -m 0755 "$BINARY" /opt/whiteboard-provisioner/whiteboard-provisioner

# 4. Install + start the service.
install -m 0644 "$UNIT" /etc/systemd/system/whiteboard-provisioner.service
systemctl daemon-reload
systemctl enable whiteboard-provisioner.service >/dev/null
systemctl restart bluetooth || true
systemctl restart whiteboard-provisioner.service

sleep 1
echo "==> Status"
systemctl --no-pager --lines=0 status whiteboard-provisioner.service || true
echo
echo "Done. The Pi now advertises '${LABEL:-$(hostname)}' over BLE for Wi-Fi setup."
echo "Logs: journalctl -u whiteboard-provisioner -f"
