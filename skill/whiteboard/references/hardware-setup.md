# Hardware setup: blank SD card → discoverable whiteboard

One-time setup per Pi. Assumes the official camera module is already connected to
the camera (CSI) port. Works on any Pi capable of running Raspberry Pi OS Bookworm
(Pi 3 / 4 / 5 / Zero 2 W all fine for this).

## 1. Image the SD card

Use **Raspberry Pi Imager** (https://www.raspberrypi.com/software/). It can
preconfigure everything for a headless first boot — do this, it saves a lot of pain.

1. Choose OS → **Raspberry Pi OS Lite (64-bit)** (Bookworm). Lite is enough; no
   desktop needed.
2. Choose your SD card.
3. Click the gear / **Edit Settings** (OS customization) and set:
   - **Hostname** — e.g. `whiteboard-rooma` (this becomes `whiteboard-rooma.local`).
   - **Enable SSH** — use password or, better, paste your public key.
   - **Username & password** — note them; you'll SSH in with these.
   - **Wi-Fi** — SSID, password, and country (skip if using Ethernet).
   - **Locale / timezone** — optional.
4. Write the card, then boot it in the Pi.

The camera works out of the box on Bookworm (the legacy "enable camera" toggle is
gone — `libcamera`/`rpicam` autodetect the official module). Avahi (`.local` mDNS)
is installed by default.

## 2. Confirm the Pi is reachable

From your Mac, after the Pi boots (give it a minute on first boot):

```bash
ping -c1 <hostname>.local
ssh <user>@<hostname>.local
```

If `.local` doesn't resolve, find the Pi's IP from your router and use that. On
Linux you may need `avahi-daemon`/`libnss-mdns` for `.local` resolution; macOS has
it built in.

### (optional) verify the camera on the Pi

```bash
rpicam-hello --timeout 2000 --nopreview   # exits cleanly if the camera is detected
rpicam-still -o /tmp/test.jpg --nopreview && ls -l /tmp/test.jpg
```

If these fail: reseat the ribbon cable (blue side facing the right way), check it's
in the CSI port (not DSI/display), and confirm the OS is Bookworm.

## 3. Provision the capture server

From your Mac, in the skill directory:

```bash
assets/pi/provision.sh \
  --host <hostname>.local \
  --user <user> \
  --label "Conference Room A" \
  --extra "--autofocus-mode auto"     # Camera Module 3 only; omit for fixed-focus
```

This copies `whiteboard-server.ts` + `install.sh` to the Pi and runs the installer
with sudo. It installs Node.js (24 LTS via NodeSource) if the Pi can't already run
TypeScript, sets up a systemd service (`whiteboard.service`) that starts on boot,
and writes an Avahi service file advertising `_whiteboard._tcp`.

Useful flags (passed straight through to `install.sh`):

| Flag        | Default        | Meaning                                   |
|-------------|----------------|-------------------------------------------|
| `--label`   | hostname       | Friendly name shown during discovery      |
| `--port`    | `8080`         | HTTP port                                 |
| `--token`   | none           | Require this shared secret on every request |
| `--width` / `--height` | `2304`/`1296` | Capture resolution                |
| `--extra`   | none           | Extra `rpicam-still` args (e.g. autofocus) |

To change config later, just re-run `provision.sh` (or `sudo install.sh` on the Pi).

## 4. Verify discovery

Back in the skill directory on your Mac:

```bash
node scripts/discover.ts
```

The new board should appear with its label, address, and port. If not, see
`troubleshooting.md`.

## Manual install (no provision.sh)

On the Pi, with this skill's `assets/pi/` copied over:

```bash
sudo ./install.sh --label "Conference Room A"
curl -s http://localhost:8080/info | python3 -m json.tool
```

## Multiple whiteboards

Repeat per Pi with a distinct `--label` (and `--hostname` at imaging time). They
all advertise the same service type; the skill lists them by label and lets the
user pick.
