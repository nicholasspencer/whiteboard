import 'dart:io';

import 'package:whiteboard_provisioning/whiteboard_provisioning.dart';

import 'nmcli.dart';

/// Firmware/version string reported on the Info characteristic.
const String provisionerVersion = '0.1.0';

/// Assemble the [DeviceInfo] advertised to the app: a friendly label (from
/// `$WHITEBOARD_LABEL`, falling back to the hostname), the Pi model, and the
/// current Wi-Fi association.
Future<DeviceInfo> gatherDeviceInfo({
  CurrentConnection? current,
  ProvisionState state = ProvisionState.idle,
}) async {
  final hostname = Platform.localHostname;
  final label = Platform.environment['WHITEBOARD_LABEL']?.trim();
  return DeviceInfo(
    label: (label != null && label.isNotEmpty) ? label : hostname,
    hostname: hostname,
    model: await _readModel(),
    fwVersion: provisionerVersion,
    currentSsid: current?.ssid,
    ip: current?.ip,
    state: state,
  );
}

/// Read the board model from the device tree (e.g. "Raspberry Pi 4 Model B").
/// The node is NUL-padded, so strip those. Returns "unknown" off a Pi.
Future<String> _readModel() async {
  for (final path in const [
    '/proc/device-tree/model',
    '/sys/firmware/devicetree/base/model',
  ]) {
    try {
      final file = File(path);
      if (await file.exists()) {
        final cleaned = (await file.readAsString()).replaceAll('\x00', '').trim();
        if (cleaned.isNotEmpty) return cleaned;
      }
    } catch (_) {
      // unreadable — try the next path
    }
  }
  return 'unknown';
}
