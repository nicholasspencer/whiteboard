#!/usr/bin/env bash
# Install the whiteboard capture server on a Raspberry Pi.
# Run ON THE PI with sudo. Idempotent — safe to re-run to change config.
#
#   sudo ./install.sh [--label "Conference Room A"] [--port 8080] [--token SECRET] \
#                     [--width 2304] [--height 1296] [--timeout 1200] \
#                     [--extra "--shutter 1000000 --gain 2 --autofocus-mode manual --lens-position 1.0"] \
#                     [--rotate 90] [--webrtc-port 8889] [--no-webrtc] [--user pi]
#
# Runs the server with Node.js (installs Node 24 LTS via NodeSource if the
# current Node can't run TypeScript directly). mDNS advertising is handled by a
# static Avahi service file — no Node packages required. Also installs MediaMTX
# (unless --no-webrtc) for the setup app's live framing preview; it is left
# disabled at boot and toggled on demand by the capture server.
set -euo pipefail

LABEL=""
PORT="8080"
TOKEN=""
WIDTH="2304"
HEIGHT="1296"
EXTRA=""
ROTATE=""
TIMEOUT_MS="1200"
SERVICE_USER="${SUDO_USER:-pi}"
WEBRTC="1"
WEBRTC_PORT="8889"
STATE_DIR="/var/lib/whiteboard"
# Pinned fallback used only if the GitHub "latest release" lookup fails.
MEDIAMTX_FALLBACK_VERSION="v1.19.1"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --label)  LABEL="$2"; shift 2 ;;
    --port)   PORT="$2"; shift 2 ;;
    --token)  TOKEN="$2"; shift 2 ;;
    --width)  WIDTH="$2"; shift 2 ;;
    --height) HEIGHT="$2"; shift 2 ;;
    --extra)   EXTRA="$2"; shift 2 ;;
    --rotate)  ROTATE="$2"; shift 2 ;;
    --timeout) TIMEOUT_MS="$2"; shift 2 ;;
    --webrtc-port) WEBRTC_PORT="$2"; shift 2 ;;
    --no-webrtc)   WEBRTC="0"; shift ;;
    --user)    SERVICE_USER="$2"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//' | sed -n '2,16p'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "error: run with sudo (needs to write systemd + avahi config)" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="${LABEL:-$(hostname)}"

echo "==> Installing whiteboard server"
echo "    label=$LABEL port=$PORT user=$SERVICE_USER auth=$([[ -n $TOKEN ]] && echo token || echo none)"

# 1. Ensure a Node that can run TypeScript directly (>= 23.6; we install 24 LTS).
ts_runs() {
  local node; node="$(command -v node || true)"
  [[ -n "$node" ]] || return 1
  printf 'const x:number=1;if(x!==1)throw 0;\n' > /tmp/_wb_probe.ts
  "$node" /tmp/_wb_probe.ts >/dev/null 2>&1
}
if ! ts_runs; then
  echo "    Installing Node.js 24 (NodeSource)..."
  curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
  apt-get install -y nodejs
  ts_runs || { echo "error: installed Node still cannot run .ts files" >&2; exit 1; }
fi
rm -f /tmp/_wb_probe.ts
NODE_BIN="$(command -v node)"
echo "    node: $NODE_BIN ($("$NODE_BIN" --version))"

# 1b. jpegtran — lossless 90/270 rotation for a sideways-mounted camera
#     (rpicam-still itself only flips 0/180). Only needed when --rotate is used.
if ! command -v jpegtran >/dev/null 2>&1; then
  echo "    Installing jpegtran (libjpeg-turbo-progs)..."
  apt-get install -y libjpeg-turbo-progs || echo "    WARNING: jpegtran install failed; --rotate 90/270 will be skipped" >&2
fi

# 1c. enfuse — Mertens exposure fusion for HDR capture (WHITEBOARD_HDR). Lets
#     /capture survive big lighting swings (bright<->dim) without recalibrating a
#     fixed exposure. Optional: the server falls back to a single capture without it.
if ! command -v enfuse >/dev/null 2>&1; then
  echo "    Installing enfuse (enblend-enfuse) for HDR capture..."
  apt-get install -y enblend-enfuse || echo "    WARNING: enfuse install failed; HDR falls back to a single capture" >&2
fi

# 2. Camera binary check (warn, don't fail — the camera may be wired up later).
if ! command -v rpicam-still >/dev/null 2>&1 && ! command -v libcamera-still >/dev/null 2>&1; then
  echo "    WARNING: neither rpicam-still nor libcamera-still found." >&2
  echo "             On Raspberry Pi OS Bookworm they ship by default; check the camera cable." >&2
fi

# 3. Ensure the service user can reach the camera.
if id "$SERVICE_USER" >/dev/null 2>&1; then
  usermod -aG video "$SERVICE_USER" || true
else
  echo "    WARNING: user '$SERVICE_USER' does not exist; falling back to root" >&2
  SERVICE_USER="root"
fi

# 4. Program files. The package.json marks the dir as ESM so node runs the .ts cleanly.
install -d -m 0755 /opt/whiteboard
install -m 0644 "$SCRIPT_DIR/whiteboard-server.ts" /opt/whiteboard/whiteboard-server.ts
printf '{\n  "type": "module"\n}\n' > /opt/whiteboard/package.json

# 4b. NetworkManager dispatcher — re-publish Avahi services when an interface
#     comes up. Without this, mDNS discovery (_whiteboard._tcp) fails on Wi-Fi
#     after a reboot: avahi establishes the service before wlan0 has an address,
#     binding it only to lo. See 90-avahi-republish.
if [[ -f "$SCRIPT_DIR/90-avahi-republish" ]]; then
  install -d -m 0755 /etc/NetworkManager/dispatcher.d
  install -o root -g root -m 0755 "$SCRIPT_DIR/90-avahi-republish" \
    /etc/NetworkManager/dispatcher.d/90-avahi-republish
fi

# 5. Config (systemd EnvironmentFile).
install -d -m 0755 /etc/whiteboard
umask 077
cat > /etc/whiteboard/whiteboard.conf <<EOF
WHITEBOARD_PORT=$PORT
WHITEBOARD_LABEL=$LABEL
WHITEBOARD_TOKEN=$TOKEN
WHITEBOARD_WIDTH=$WIDTH
WHITEBOARD_HEIGHT=$HEIGHT
WHITEBOARD_TIMEOUT=$TIMEOUT_MS
WHITEBOARD_EXTRA=$EXTRA
WHITEBOARD_ROTATE=$ROTATE
WHITEBOARD_HDR=auto
WHITEBOARD_STATE_DIR=$STATE_DIR
WHITEBOARD_WEBRTC_PORT=$WEBRTC_PORT
WHITEBOARD_WEBRTC_PATH=cam
WHITEBOARD_MEDIAMTX_UNIT=mediamtx
EOF
umask 022

# 6. systemd unit.
cat > /etc/systemd/system/whiteboard.service <<EOF
[Unit]
Description=Whiteboard capture server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
SupplementaryGroups=video
EnvironmentFile=/etc/whiteboard/whiteboard.conf
# Creates /var/lib/whiteboard owned by the service user, where the server
# persists live config edits (overrides.json) from the setup app.
StateDirectory=whiteboard
ExecStart=$NODE_BIN /opt/whiteboard/whiteboard-server.ts
WorkingDirectory=/opt/whiteboard
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# 7. Avahi service file — advertises _whiteboard._tcp. The token is NEVER
#    advertised; only whether auth is required.
AUTH=$([[ -n "$TOKEN" ]] && echo token || echo none)
MODEL="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo unknown)"
xml_escape() { sed -e 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'; }
LABEL_X="$(printf '%s' "$LABEL" | xml_escape)"
MODEL_X="$(printf '%s' "$MODEL" | xml_escape)"
install -d -m 0755 /etc/avahi/services
cat > /etc/avahi/services/whiteboard.service <<EOF
<?xml version="1.0" standalone='no'?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name replace-wildcards="yes">Whiteboard (%h)</name>
  <service>
    <type>_whiteboard._tcp</type>
    <port>$PORT</port>
    <txt-record>label=$LABEL_X</txt-record>
    <txt-record>path=/capture</txt-record>
    <txt-record>auth=$AUTH</txt-record>
    <txt-record>model=$MODEL_X</txt-record>
  </service>
</service-group>
EOF

# 7b. MediaMTX — live WebRTC preview for the setup app's framing screen. The
#     camera is single-owner, so this unit is installed but NOT enabled at boot:
#     the capture server toggles it on demand (via the scoped sudoers rule below)
#     only while you're framing, so it never fights /capture for the camera.
if [[ "$WEBRTC" == "1" ]]; then
  if [[ ! -f "$SCRIPT_DIR/mediamtx.yml" ]]; then
    echo "    WARNING: mediamtx.yml not found next to install.sh; skipping WebRTC preview." >&2
  else
    case "$(uname -m)" in
      aarch64|arm64) MTX_ARCH="arm64" ;;
      armv7l)        MTX_ARCH="armv7" ;;
      armv6l)        MTX_ARCH="armv6" ;;
      x86_64|amd64)  MTX_ARCH="amd64" ;;
      *)             MTX_ARCH="" ;;
    esac
    if [[ -z "$MTX_ARCH" ]]; then
      echo "    WARNING: unknown CPU arch '$(uname -m)'; skipping MediaMTX install." >&2
    else
      # Install the binary if absent (re-run with the binary removed to upgrade).
      if [[ ! -x /usr/local/bin/mediamtx ]]; then
        # Resolve the asset URL straight from the latest release so we track
        # GitHub's arch-suffix naming (it changed arm64v8 → arm64) automatically.
        MTX_JSON="$(curl -fsSL https://api.github.com/repos/bluenviron/mediamtx/releases/latest 2>/dev/null || true)"
        MTX_URL="$(printf '%s' "$MTX_JSON" | grep -oE "https://[^\"]*_linux_${MTX_ARCH}\.tar\.gz" | head -1)"
        if [[ -z "$MTX_URL" ]]; then
          MTX_URL="https://github.com/bluenviron/mediamtx/releases/download/${MEDIAMTX_FALLBACK_VERSION}/mediamtx_${MEDIAMTX_FALLBACK_VERSION}_linux_${MTX_ARCH}.tar.gz"
        fi
        echo "    Installing MediaMTX from ${MTX_URL}..."
        MTX_TMP="$(mktemp -d)"
        if curl -fsSL "$MTX_URL" -o "$MTX_TMP/mediamtx.tar.gz" \
           && tar -xzf "$MTX_TMP/mediamtx.tar.gz" -C "$MTX_TMP" mediamtx; then
          install -m 0755 "$MTX_TMP/mediamtx" /usr/local/bin/mediamtx
        else
          echo "    WARNING: MediaMTX download failed ($MTX_URL); live preview unavailable." >&2
        fi
        rm -rf "$MTX_TMP"
      else
        echo "    MediaMTX already installed: $(/usr/local/bin/mediamtx --version 2>/dev/null | head -1 || echo present)"
      fi

      if [[ -x /usr/local/bin/mediamtx ]]; then
        # Config (port-substituted from --webrtc-port).
        install -d -m 0755 /etc/mediamtx
        install -m 0644 "$SCRIPT_DIR/mediamtx.yml" /etc/mediamtx/mediamtx.yml
        sed -i "s/^webrtcAddress: .*/webrtcAddress: :$WEBRTC_PORT/" /etc/mediamtx/mediamtx.yml

        # Unit — intentionally NOT enabled; started on demand for framing.
        cat > /etc/systemd/system/mediamtx.service <<EOF
[Unit]
Description=MediaMTX (whiteboard live-framing preview)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
SupplementaryGroups=video
ExecStart=/usr/local/bin/mediamtx /etc/mediamtx/mediamtx.yml
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

        # Scoped NOPASSWD rule so the (non-root) capture server can toggle
        # MediaMTX for framing mode — and nothing else.
        SYSTEMCTL_BIN="$(command -v systemctl || echo /usr/bin/systemctl)"
        cat > /etc/sudoers.d/whiteboard-mediamtx <<EOF
$SERVICE_USER ALL=(root) NOPASSWD: $SYSTEMCTL_BIN start mediamtx, $SYSTEMCTL_BIN stop mediamtx, $SYSTEMCTL_BIN restart mediamtx
EOF
        chmod 0440 /etc/sudoers.d/whiteboard-mediamtx
        if ! visudo -cf /etc/sudoers.d/whiteboard-mediamtx >/dev/null 2>&1; then
          echo "    WARNING: generated sudoers rule failed validation; removing it." >&2
          rm -f /etc/sudoers.d/whiteboard-mediamtx
        fi
        echo "    MediaMTX ready: WebRTC/WHEP on :$WEBRTC_PORT/cam/whep (started on demand for framing)."
      fi
    fi
  fi
else
  echo "    Skipping MediaMTX (--no-webrtc); the live framing preview will be unavailable."
fi

# 8. Start everything. NOTE: mediamtx.service is deliberately left disabled —
#    the capture server starts/stops it on demand for framing mode.
systemctl daemon-reload
systemctl enable whiteboard.service >/dev/null
systemctl restart whiteboard.service
systemctl restart avahi-daemon || true

sleep 1
echo "==> Status"
systemctl --no-pager --lines=0 status whiteboard.service || true
echo
echo "==> Smoke test (from this Pi):"
echo "    curl -s http://localhost:$PORT/info"
echo "    curl -s http://localhost:$PORT/config"
echo "    curl -s http://localhost:$PORT/capture$([[ -n $TOKEN ]] && echo "?token=$TOKEN") -o /tmp/test.jpg && ls -l /tmp/test.jpg"
if [[ "$WEBRTC" == "1" ]]; then
  echo "    # live framing preview (toggles MediaMTX on this rig):"
  echo "    curl -s -X POST http://localhost:$PORT/framing -d '{\"on\":true}'   # then open the WHEP stream"
  echo "    curl -s -X POST http://localhost:$PORT/framing -d '{\"on\":false}'  # stop it"
fi
echo
echo "Done. The Pi now advertises _whiteboard._tcp as '$LABEL'."
