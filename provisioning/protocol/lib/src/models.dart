import 'dart:convert';
import 'dart:typed_data';

/// Where the Pi is in the provisioning lifecycle. Drives the app's status UI.
enum ProvisionState {
  idle,
  scanning,
  applying,
  connecting,
  connected,
  failed;

  static ProvisionState fromName(String? name) => ProvisionState.values
      .firstWhere((s) => s.name == name, orElse: () => ProvisionState.idle);
}

/// One Wi-Fi network seen by the Pi's `nmcli` scan. Streamed to the app so the
/// user picks from a list instead of typing the SSID.
class WifiNetwork {
  const WifiNetwork({
    required this.ssid,
    required this.signal,
    required this.security,
    this.active = false,
  });

  /// Network name. May be empty for a hidden network.
  final String ssid;

  /// Signal strength, 0–100 (as nmcli reports it).
  final int signal;

  /// Security label, e.g. `WPA2`, `WPA3`, or empty for an open network.
  final String security;

  /// True if this is the network the Pi is currently joined to.
  final bool active;

  bool get isOpen => security.isEmpty;

  Map<String, Object?> toJson() => {
        'ssid': ssid,
        'signal': signal,
        'security': security,
        if (active) 'active': true,
      };

  factory WifiNetwork.fromJson(Map<String, Object?> j) => WifiNetwork(
        ssid: (j['ssid'] as String?) ?? '',
        signal: (j['signal'] as num?)?.toInt() ?? 0,
        security: (j['security'] as String?) ?? '',
        active: (j['active'] as bool?) ?? false,
      );
}

/// Identity + current connection state, exposed on the Info characteristic so
/// the app can show which rig it's talking to and whether it's already online.
class DeviceInfo {
  const DeviceInfo({
    required this.label,
    required this.hostname,
    required this.model,
    required this.fwVersion,
    this.currentSsid,
    this.ip,
    this.state = ProvisionState.idle,
  });

  final String label;
  final String hostname;
  final String model;
  final String fwVersion;
  final String? currentSsid;
  final String? ip;
  final ProvisionState state;

  Map<String, Object?> toJson() => {
        'label': label,
        'hostname': hostname,
        'model': model,
        'fwVersion': fwVersion,
        'currentSsid': currentSsid,
        'ip': ip,
        'state': state.name,
      };

  factory DeviceInfo.fromJson(Map<String, Object?> j) => DeviceInfo(
        label: (j['label'] as String?) ?? '',
        hostname: (j['hostname'] as String?) ?? '',
        model: (j['model'] as String?) ?? '',
        fwVersion: (j['fwVersion'] as String?) ?? '',
        currentSsid: j['currentSsid'] as String?,
        ip: j['ip'] as String?,
        state: ProvisionState.fromName(j['state'] as String?),
      );

  Uint8List encode() => utf8JsonEncode(toJson());
  static DeviceInfo decode(Uint8List bytes) =>
      DeviceInfo.fromJson(utf8JsonDecode(bytes));
}

/// A snapshot of provisioning progress, pushed on the Status characteristic
/// (read + notify) every time the Pi's state changes.
class StatusReport {
  const StatusReport({
    required this.state,
    this.ssid,
    this.ip,
    this.error,
    this.ts = 0,
  });

  final ProvisionState state;
  final String? ssid;
  final String? ip;
  final String? error;

  /// Unix epoch millis when the Pi produced this report (0 if unset).
  final int ts;

  StatusReport copyWith({
    ProvisionState? state,
    String? ssid,
    String? ip,
    String? error,
    int? ts,
  }) =>
      StatusReport(
        state: state ?? this.state,
        ssid: ssid ?? this.ssid,
        ip: ip ?? this.ip,
        error: error ?? this.error,
        ts: ts ?? this.ts,
      );

  Map<String, Object?> toJson() => {
        'state': state.name,
        if (ssid != null) 'ssid': ssid,
        if (ip != null) 'ip': ip,
        if (error != null) 'error': error,
        'ts': ts,
      };

  factory StatusReport.fromJson(Map<String, Object?> j) => StatusReport(
        state: ProvisionState.fromName(j['state'] as String?),
        ssid: j['ssid'] as String?,
        ip: j['ip'] as String?,
        error: j['error'] as String?,
        ts: (j['ts'] as num?)?.toInt() ?? 0,
      );

  Uint8List encode() => utf8JsonEncode(toJson());
  static StatusReport decode(Uint8List bytes) =>
      StatusReport.fromJson(utf8JsonDecode(bytes));
}

/// Encode a JSON-able map as UTF-8 bytes for a characteristic value.
Uint8List utf8JsonEncode(Object? value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(value)));

/// Decode UTF-8 characteristic bytes into a JSON map.
Map<String, Object?> utf8JsonDecode(Uint8List bytes) =>
    (jsonDecode(utf8.decode(bytes)) as Map).cast<String, Object?>();
