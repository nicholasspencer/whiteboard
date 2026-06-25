# Whiteboard Wi-Fi Provisioner

Set up a whiteboard Raspberry Pi's Wi-Fi **over Bluetooth** — no SSH, no existing
network. Carry a rig to a new place, open the app, pick the network, type the
password; the Pi joins and comes back online over mDNS/HTTP as usual.

## Why this exists

Normal provisioning (`../skill/whiteboard/assets/pi/provision.sh`) SSHes in over
an existing network — a chicken-and-egg problem for a rig that isn't on any
network you can reach yet. BLE is the out-of-band bootstrap channel that closes
the gap.

## Three packages

| Package | What it is |
|---------|-----------|
| [`protocol/`](protocol) | Pure-Dart shared contract: GATT UUIDs, command/status/info/network models, JSON codec, MTU chunk framing. Depended on by **both** sides. |
| [`pi/`](pi) | Headless BLE **peripheral** for the Pi. Uses `butane_bluez` (BlueZ/D-Bus, no Flutter); applies Wi-Fi with `nmcli`. Cross-compiled on the Mac to an arm64 Linux binary — **the Pi never installs Dart**. |
| [`app/`](app) | Flutter **central** (iOS + macOS) using `butane`. Scan → pick rig → pick Wi-Fi → enter password → watch it connect. |

Built on Nico's [`butane`](../../butane_flutter) BLE library: the app is the
`CentralManager`; the Pi is the `PeripheralManager` path (`butane_bluez`).

## Quick start

```bash
# 1. One-time: set up the provisioner on the Pi (while it's still SSH-reachable).
cd pi && ./provision.sh --host raspberrypi.local --user nico --label "Office"

# 2. Run the app and provision over BLE.
cd ../app && flutter run -d macos        # or: flutter run -d <your-iphone>
```

After step 1, every future Wi-Fi change happens over BLE from the app — that's
the whole point.

## Security

Plaintext, always-on (trusted-office posture, by design). The Pi advertises
continuously and accepts credential writes anytime. A BLE sniffer in range during
provisioning could see the PSK; acceptable here. The protocol is layered so an
encrypted/PIN envelope can be added later without changing the transport. See
[`pi/README.md`](pi/README.md).

## Status

The toolchain and both builds are verified end-to-end on the Mac (protocol tests
green; Pi binary cross-compiles to arm64; iOS + macOS apps build with the native
CoreBluetooth plugin). **Pending: the on-hardware runtime test** — run
`pi/provision.sh` against the real second rig and confirm advertising, connect,
Wi-Fi scan, and join from a phone (Milestone 0 in the build plan).
