---
name: whiteboard
description: >-
  Capture a photo from a Raspberry Pi camera pointed at a physical whiteboard and
  read it with a vision model. Discovers one or more whiteboard Pis on the local
  network over mDNS. Use when the user types /whiteboard or says "capture the
  whiteboard", "what's on the whiteboard", "transcribe the board", "snap the
  whiteboard", "digitize the board", or names a specific room's whiteboard. Also
  handles first-time hardware setup (imaging the SD card, provisioning the Pi).
version: 0.1.0
tags: [raspberry-pi, camera, mdns, vision, whiteboard, typescript]
---

# whiteboard

Snap a photo from a Raspberry Pi camera aimed at a whiteboard, then read it.
Each Pi advertises itself over mDNS (`_whiteboard._tcp`), so multiple boards are
discoverable and selectable by name.

`scripts/` are TypeScript, run on this machine. `assets/pi/` get deployed to the
Pi (setup only).

## Runtime

Scripts are `.ts`. Run them with **Node ≥ 23.6** (runs TypeScript directly):
`node scripts/discover.ts`. If `node x.ts` errors on this machine, use `bun x.ts`
or `npx tsx x.ts` instead. `discover.ts` and `capture.ts` use only Node built-ins
— **no `npm install`**. Run from the skill directory so relative paths resolve.

## Workflow

### 1. Discover

```bash
node scripts/discover.ts            # ~3s mDNS scan → JSON array
```

Uses the OS mDNS browser (`dns-sd` on macOS, `avahi-browse` on Linux). Each entry
has `label`, `host`, `port`, `path`, `auth`, and a ready-to-use `url`.

- **No results?** See `references/troubleshooting.md` (subnet/isolation/firewall).
  If the user has never set up a Pi, go to **First-time setup** below.
- **One result:** use it.
- **Multiple results:** if the user named a board ("the kitchen one"), match it
  against `label` (or rerun with `--name kitchen`). Otherwise list the labels and
  ask which one.

### 2. Capture

```bash
node scripts/capture.ts --url "<url from step 1>"
# or:  node scripts/capture.ts --host <host> --port <port>
```

Pass `--token <secret>` if the entry's `auth` is `token`. The script prints the
saved JPEG path (default `/tmp/whiteboard-<timestamp>.jpg`).

### 3. Process

**Read the saved image with the Read tool** — you (the running model) are
vision-capable, so no API call is needed. Then do what the user asked: transcribe
to Markdown, extract action items, answer a question about the board, etc. If they
gave no specific instruction, default to a faithful Markdown transcription.

See `references/processing.md` for output conventions and image-quality tips.

> Headless/automation only (no agent in the loop): `node scripts/process.ts IMAGE`
> calls the Claude API instead (default `claude-opus-4-8`; `--model
> claude-sonnet-4-6` for a cheaper vision model). This is the only script that
> needs an install: `npm install @anthropic-ai/sdk` + `ANTHROPIC_API_KEY`.

## First-time setup (blank SD card → working Pi)

The user is "starting from a disk that needs to be imaged." Walk them through
`references/hardware-setup.md`: flash Raspberry Pi OS Lite (64-bit, Bookworm) with
SSH + Wi-Fi + hostname preconfigured, boot, then from this machine:

```bash
assets/pi/provision.sh --host <pi-hostname>.local --user <user> --label "Room name"
```

That copies the server to the Pi and runs `install.sh`, which installs Node (if
needed), registers a systemd service, and advertises `_whiteboard._tcp`. Re-run
`scripts/discover.ts` to confirm it shows up.

## Notes

- The official camera module is assumed already connected. Camera Module 3 has
  autofocus — provision with `--extra "--autofocus-mode auto"` for sharper text.
- All discovery and capture stays on the local network. Only `process.ts` (opt-in)
  sends the image off-device.
