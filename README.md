# whiteboard

Point a Raspberry Pi camera at a physical whiteboard and read it from anywhere with
one command. A Claude Code / [agentskills.io](https://agentskills.io) skill discovers
the Pi over mDNS, captures a fresh photo, and a vision-capable model transcribes /
answers questions about what's on the board.

Multiple whiteboards are supported — each Pi advertises itself as `_whiteboard._tcp`,
so the `/whiteboard` skill finds them all and you pick by name.

Everything is **TypeScript / Node** (client) and a small **Node** service on the Pi —
no Python anywhere.

```
┌──────────────┐   mDNS  _whiteboard._tcp     ┌────────────────────────────┐
│  /whiteboard │ ◀──────── discover ────────── │  Raspberry Pi + Camera     │
│  skill (TS)  │                               │  whiteboard-server.ts      │
│              │ ──── GET /capture ──────────▶ │  rpicam-still → jpegtran   │
└──────┬───────┘        (curl)                 │  Avahi advertises service  │
       │ Read image (vision model)             └────────────────────────────┘
       ▼
  transcription · diagram description · action items · Q&A
```

## Quick start

On a provisioned Pi, from Claude Code:

```
/whiteboard transcribe what's on the board
```

The skill discovers the Pi, captures a frame, and reads it. Or drive the scripts
directly (Node ≥ 23.6, or `bun` / `npx tsx` — no `npm install` for these two):

```bash
cd skill/whiteboard
node scripts/discover.ts                 # → JSON list of whiteboards on the LAN
node scripts/capture.ts --url <url>      # → saves a fresh JPEG, prints the path
```

## Repo layout

```
skill/whiteboard/              the publishable skill (self-contained)
├── SKILL.md                   entry point + workflow
├── package.json               "type": "module"
├── scripts/                   run on your machine
│   ├── discover.ts            mDNS discovery (shells out to dns-sd / avahi-browse)
│   ├── capture.ts             download a frame (shells out to curl)
│   └── process.ts             OPTIONAL headless analysis via the Claude API
├── references/                loaded on demand (processing, hardware, troubleshooting)
└── assets/pi/                 deployed onto the Pi
    ├── whiteboard-server.ts   the capture server (Node stdlib + rpicam-still + jpegtran)
    ├── install.sh             run on the Pi (Node, systemd, Avahi, dispatcher)
    ├── provision.sh           run from your Mac (copies + installs over SSH)
    ├── 90-avahi-republish     NetworkManager dispatcher (mDNS-on-Wi-Fi fix)
    └── whiteboard.conf.example every config knob, documented
```

## Hardware setup (blank SD card → working appliance)

Full walkthrough in [`references/hardware-setup.md`](skill/whiteboard/references/hardware-setup.md).
Short version:

1. **Image the card** with Raspberry Pi Imager → Raspberry Pi OS Lite (64-bit). Use the
   Imager's built-in customization to set hostname, enable SSH (paste your key), and
   configure Wi-Fi. (See the Trixie note below — don't rely on a hand-dropped
   `custom.toml`.)
2. **Connect the official camera module**, boot, and get it on the network (Ethernet is
   the most reliable for first contact).
3. **Provision** from your Mac:
   ```bash
   cd skill/whiteboard
   assets/pi/provision.sh --host <pi>.local --user <you> --label "Whiteboard" \
     --extra "--autofocus-mode auto"
   ```
   `install.sh` installs Node 24, `jpegtran`, a systemd service, the Avahi
   advertisement, and the dispatcher fix. Re-run anytime to change settings.

### Tuning the camera (from real-world use)

- **Sideways mount** (portrait board): mount the camera rotated 90° to fill the frame,
  then `--rotate 90` — the server losslessly rotates the JPEG (`rpicam-still` only does
  0/180).
- **Dark room, static board**: use a long exposure with locked focus — bright, no blur,
  no autofocus hunting:
  ```
  --extra "--shutter 1000000 --gain 2 --awb auto --autofocus-mode manual --lens-position 1.0" \
  --timeout 2000
  ```
- The running Claude Code model reads the image directly (no API key). `process.ts` is
  an optional headless path that calls the Claude API (default `claude-opus-4-8`).

### Mount it

It works hung from the ceiling looking back at the board. A rigid cardboard tilt-wedge
is plenty — see the geometry notes in the build log if you want the math.

## Build log — hard-won lessons

Things that bit us getting the first unit live, documented so they don't bite again:

1. **Raspberry Pi OS *Trixie* ignores a hand-dropped `/boot/firmware/custom.toml`.** The
   hostname / Wi-Fi / SSH-key block silently didn't apply. The independent `ssh` and
   `userconf.txt` first-boot files *do* work. Use Raspberry Pi Imager's own customization,
   or configure Wi-Fi (`nmcli`) and hostname (`hostnamectl`) on the box after first boot.
2. **Node `fetch` / `node:http` are unreliable on real LANs (macOS).** With a VPN
   (Tailscale `utun`) and cloned/reject routes present, both throw `EHOSTUNREACH` for a
   host `curl` reaches fine, and undici doesn't use the OS mDNS resolver so `.local`
   names don't resolve. `capture.ts` therefore shells out to **`curl`**, and
   `discover.ts` to **`dns-sd`** — using the OS network stack, like everything else that
   worked.
3. **mDNS service discovery fails on Wi-Fi after a reboot.** Avahi establishes static
   services at startup *before* `wlan0` has an address, binding them only to `lo`; the
   hostname still resolves but `_whiteboard._tcp` doesn't advertise on Wi-Fi. Fix: a
   NetworkManager dispatcher (`90-avahi-republish`) restarts Avahi whenever an interface
   comes up.
4. **`rpicam-still --rotation` only does 0/180.** For a 90°-mounted camera, rotate the
   JPEG afterward with `jpegtran -rotate` (lossless). The server does this when
   `WHITEBOARD_ROTATE` is set.
5. **Autofocus hunts forever in the dark** and can hang a capture. For a static board on
   a fixed mount, lock focus (`--autofocus-mode manual --lens-position`) and brighten
   with a long shutter instead.
6. **Pi 4 Wi-Fi is 2.4/5 GHz only** — no 6 GHz. Joining a Wi-Fi 6E SSID just uses the
   lower bands; make sure the network broadcasts one.

## Install the skill

Claude Code loads skills from `~/.claude/skills/`. Clone the repo and link the skill
there:

```bash
git clone https://github.com/nicholasspencer/whiteboard
ln -s "$PWD/whiteboard/skill/whiteboard" ~/.claude/skills/whiteboard
```

It's then available as `/whiteboard`. (During development you can also point Claude
Code straight at the `skill/whiteboard/` directory.)

## License

MIT — see [LICENSE](LICENSE).
