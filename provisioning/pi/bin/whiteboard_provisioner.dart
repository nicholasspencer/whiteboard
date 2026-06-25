import 'dart:io';

import 'package:whiteboard_provisioner/provisioner.dart';

/// Entry point for the headless BLE Wi-Fi provisioner. Runs forever under
/// systemd; SIGINT/SIGTERM trigger a clean shutdown (stop advertising, drop the
/// GATT service).
Future<void> main() async {
  final provisioner = Provisioner();

  Future<void> shutdown(ProcessSignal _) async {
    stderr.writeln('[provisioner] shutting down…');
    try {
      await provisioner.stop();
    } catch (_) {}
    exit(0); // exit explicitly — stream/signal listeners keep the loop alive
  }

  ProcessSignal.sigint.watch().listen(shutdown);
  ProcessSignal.sigterm.watch().listen(shutdown);

  try {
    await provisioner.start();
  } catch (e, st) {
    stderr.writeln('[provisioner] failed to start: $e\n$st');
    exit(1); // must exit(): the signal listeners would otherwise hang the proc
  }
  // start() returns once listeners are wired up; the signal handlers + BLE
  // stream subscriptions keep the process alive until a signal arrives.
}
