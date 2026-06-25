import 'dart:typed_data';

import 'models.dart';

/// An app→Pi instruction written to the Command characteristic. Encoded as a
/// `{"cmd": "...", ...}` JSON object so it's easy to extend and to wrap in an
/// encryption envelope later without changing the transport.
sealed class Command {
  const Command();

  Map<String, Object?> toJson();

  Uint8List encode() => utf8JsonEncode(toJson());

  /// Parse a Command from characteristic bytes. Throws [FormatException] on an
  /// unknown or malformed command so the peripheral can reject it cleanly.
  static Command decode(Uint8List bytes) => fromJson(utf8JsonDecode(bytes));

  static Command fromJson(Map<String, Object?> j) {
    switch (j['cmd']) {
      case 'scan':
        return const ScanCommand();
      case 'provision':
        final ssid = j['ssid'] as String?;
        if (ssid == null || ssid.isEmpty) {
          throw const FormatException('provision command missing ssid');
        }
        return ProvisionWifiCommand(
          ssid: ssid,
          psk: (j['psk'] as String?) ?? '',
          hidden: (j['hidden'] as bool?) ?? false,
        );
      case 'forget':
        final ssid = j['ssid'] as String?;
        if (ssid == null || ssid.isEmpty) {
          throw const FormatException('forget command missing ssid');
        }
        return ForgetCommand(ssid);
      default:
        throw FormatException('unknown command: ${j['cmd']}');
    }
  }
}

/// Ask the Pi to (re)scan for nearby Wi-Fi networks and stream the result on
/// the Networks characteristic.
final class ScanCommand extends Command {
  const ScanCommand();

  @override
  Map<String, Object?> toJson() => {'cmd': 'scan'};
}

/// Join the given network. An open network has an empty [psk].
final class ProvisionWifiCommand extends Command {
  const ProvisionWifiCommand({
    required this.ssid,
    required this.psk,
    this.hidden = false,
  });

  final String ssid;
  final String psk;
  final bool hidden;

  @override
  Map<String, Object?> toJson() => {
        'cmd': 'provision',
        'ssid': ssid,
        'psk': psk,
        if (hidden) 'hidden': true,
      };
}

/// Delete a saved connection so the Pi stops auto-joining it.
final class ForgetCommand extends Command {
  const ForgetCommand(this.ssid);

  final String ssid;

  @override
  Map<String, Object?> toJson() => {'cmd': 'forget', 'ssid': ssid};
}
