/// Shared BLE provisioning contract for the whiteboard Raspberry Pi.
///
/// This package is the single source of truth for the wire format spoken
/// between the Flutter sidecar app (BLE central) and the headless Pi binary
/// (BLE peripheral). Keep it pure Dart — the Pi side compiles it into a
/// non-Flutter binary, so nothing here may import `dart:ui` or `package:flutter`.
library whiteboard_provisioning;

export 'src/uuids.dart';
export 'src/models.dart';
export 'src/commands.dart';
export 'src/chunking.dart';
