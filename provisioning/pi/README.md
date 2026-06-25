# whiteboard_provisioner (Pi side)

A headless BLE peripheral for a whiteboard Raspberry Pi. It advertises a GATT
provisioning service so the [sidecar app](../app) can hand it new Wi-Fi
credentials **over Bluetooth** — no SSH, no existing network. The Pi applies them
with `nmcli` and reports progress back over a notify characteristic.

Built on `butane_bluez` (BlueZ/D-Bus, **no Flutter**) and the shared
[`whiteboard_provisioning`](../protocol) protocol package.

## Why

Normal provisioning (`skill/whiteboard/assets/pi/provision.sh`) SSHes in over an
existing network. That can't bootstrap a rig carried somewhere new — there's no
network to reach it on yet. This closes that gap: BLE is the out-of-band channel.

## Build & deploy

The binary is **cross-compiled on your Mac** and shipped to the Pi — the Pi never
installs Dart or Flutter. Do this once while the Pi is still reachable over SSH:

```bash
./provision.sh --host raspberrypi.local --user nico --label "Office"
```

That runs `dart compile exe --target-os=linux --target-arch=arm64`, copies the
~7 MB binary + the systemd unit + `install.sh` to the Pi, and runs the installer
(which sets `ControllerMode = le`, installs `/opt/whiteboard-provisioner/…`, and
enables `whiteboard-provisioner.service`).

After that, every future Wi-Fi change happens over BLE from the app.

## GATT contract

Service `b9a7f4e0-…-0001` with four characteristics (UUIDs + payloads defined in
[`../protocol`](../protocol)):

| Characteristic | Props | Payload |
|----------------|-------|---------|
| Info     | read         | `{label, hostname, model, fwVersion, currentSsid, ip, state}` |
| Command  | write        | `{cmd:"scan"}` / `{cmd:"provision", ssid, psk, hidden?}` / `{cmd:"forget", ssid}` |
| Status   | read+notify  | `{state, ssid, ip, error, ts}` live progress |
| Networks | read+notify  | chunked Wi-Fi scan list (see protocol chunk framing) |

## Security

Plaintext, always-on (trusted-office posture): the Pi advertises continuously and
accepts credential writes anytime, so re-provisioning is "walk up and do it." A
BLE sniffer in range during provisioning could see the PSK — acceptable here. The
protocol is layered so an encrypted/PIN envelope can be added later without
changing the transport.

## Runtime notes

- **OS: use Raspberry Pi OS _Bookworm_, not Trixie.** Trixie (kernel 6.18 +
  BlueZ 5.82) can't enable BLE advertising on the Pi 4's onboard BCM43455
  (`LE Set Advertising Enable` → HCI status 0x12; fails at bluetoothd, btmgmt,
  and raw `hciconfig`) — a confirmed platform regression. Bookworm (kernel 6.12
  + BlueZ 5.66) advertises first try. Last Bookworm Lite arm64 image:
  `raspios_lite_arm64-2025-05-13`.
- Runs as `root` (systemd) so `nmcli` needs no polkit prompts.
- Requires BlueZ + D-Bus (already on Raspberry Pi OS) and `ControllerMode = le`.
- Independent of `whiteboard.service` — one manages Wi-Fi, the other the camera.
- Logs: `journalctl -u whiteboard-provisioner -f`.

## Develop

```bash
dart pub get
dart analyze
# Native run on a Linux box with BlueZ (won't do much on macOS — no BlueZ):
dart run bin/whiteboard_provisioner.dart
```
