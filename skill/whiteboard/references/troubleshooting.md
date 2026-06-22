# Troubleshooting

## `node scripts/...` errors (can't run TypeScript)

The scripts are `.ts`. They need **Node ≥ 23.6** (runs TypeScript directly):

```bash
node --version
```

If it's older, either upgrade Node, or run the scripts another way:

```bash
bun scripts/discover.ts
npx tsx scripts/discover.ts
```

`discover.ts` and `capture.ts` need no `npm install`. Only `process.ts` does
(`npm install @anthropic-ai/sdk`).

## discover.ts finds nothing

1. **Same network/subnet?** mDNS does not cross subnets or most VPNs. The Pi and
   this machine must be on the same LAN/Wi-Fi. Guest networks and "client
   isolation" / AP isolation block peer discovery — turn isolation off or join the
   main network.
2. **Is the service up on the Pi?**
   ```bash
   ssh <user>@<host>.local 'systemctl status whiteboard.service'
   ssh <user>@<host>.local 'curl -s http://localhost:8080/info'
   ```
3. **Is it advertising?**
   ```bash
   # macOS (what discover.ts uses):
   dns-sd -B _whiteboard._tcp
   # Linux:
   avahi-browse -rtp _whiteboard._tcp
   # On the Pi itself:
   avahi-browse -rt _whiteboard._tcp
   ```
   If the Pi self-test (`curl localhost`) works but nothing is advertised, restart
   Avahi on the Pi: `sudo systemctl restart avahi-daemon`.
4. **"No mDNS browser found":** discover.ts shells out to `dns-sd` (macOS, always
   present) or `avahi-browse` (Linux). On Linux install it: `sudo apt-get install
   avahi-utils`.
5. **Firewall:** a local firewall may block UDP 5353 (mDNS) or the HTTP port.

## capture.ts: HTTP 401

The server has a token set (`auth: token` in discovery). Pass it:
```bash
node scripts/capture.ts --url "<url>" --token "<secret>"
```

## capture.ts: HTTP 500 / "no camera capture binary" / camera errors

The Pi can't take a photo. On the Pi:
```bash
rpicam-hello --timeout 2000 --nopreview     # detect the camera
journalctl -u whiteboard.service -n 50      # server logs
```
Common causes: ribbon cable loose or backwards, plugged into the DSI (display)
port instead of CSI (camera), camera in use by another process, or the service
user isn't in the `video` group (re-run `install.sh`, which adds them).

Camera Module 3 autofocus: if images are blurry, reprovision with
`--extra "--autofocus-mode auto"`. That flag errors on fixed-focus modules —
remove it there.

## capture.ts can't reach the host / times out

- Use the `address` or `host` from discovery. On macOS, `<host>.local` resolves
  natively; on Linux you may need `avahi-daemon` + `libnss-mdns`.
- Confirm the port matches the server (`/info` reports it).
- If `.local` won't resolve, use the Pi's IP address (find it on your router) with
  `--host <ip> --port <port>`.

## Images are washed out / unreadable

Glare from windows or ceiling lights. Reposition the Pi for an oblique,
non-reflective angle and even lighting, then recapture. Raise resolution
(`--width`/`--height` at provision time) for dense text.

## Pi-side: install.sh installs Node

`install.sh` runs the server with Node and installs Node 24 LTS via NodeSource if
the Pi's Node can't run `.ts`. On a 32-bit OS NodeSource may not have a build —
use the 64-bit Raspberry Pi OS Lite image (recommended in hardware-setup.md).
