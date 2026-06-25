import 'dart:convert';
import 'dart:io';

import 'package:whiteboard_provisioning/whiteboard_provisioning.dart';

/// Result of running an `nmcli` command.
class NmcliResult {
  const NmcliResult(this.ok, this.message);
  final bool ok;
  final String message;
}

/// The Pi's current Wi-Fi association, if any.
class CurrentConnection {
  const CurrentConnection({this.ssid, this.ip});
  final String? ssid;
  final String? ip;
}

/// Thin wrapper over the `nmcli` CLI. Every call shells out with an argument
/// list (never a shell string) so SSIDs/passwords can't be misinterpreted.
class NmcliClient {
  NmcliClient({this.nmcliPath = 'nmcli'});

  final String nmcliPath;
  String? _cachedWifiDevice;

  Future<ProcessResult> _run(List<String> args) => Process.run(
        nmcliPath,
        args,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );

  /// The first Wi-Fi interface NetworkManager knows about (e.g. `wlan0`).
  Future<String> wifiDevice() async {
    if (_cachedWifiDevice != null) return _cachedWifiDevice!;
    final r = await _run(['-t', '-f', 'DEVICE,TYPE', 'dev']);
    if (r.exitCode == 0) {
      for (final line in const LineSplitter().convert(r.stdout as String)) {
        final f = _splitTerse(line);
        if (f.length >= 2 && f[1] == 'wifi') return _cachedWifiDevice = f[0];
      }
    }
    return _cachedWifiDevice = 'wlan0';
  }

  /// Scan and return the visible networks: strongest signal per SSID, hidden
  /// (empty-SSID) entries dropped, sorted by signal descending.
  Future<List<WifiNetwork>> scan() async {
    final r = await _run([
      '-t',
      '-f',
      'ACTIVE,SSID,SIGNAL,SECURITY',
      'dev',
      'wifi',
      'list',
      '--rescan',
      'yes',
    ]);
    if (r.exitCode != 0) {
      throw NmcliException('wifi list failed: ${_trim(r.stderr)}');
    }
    final bySsid = <String, WifiNetwork>{};
    for (final line in const LineSplitter().convert(r.stdout as String)) {
      if (line.trim().isEmpty) continue;
      final f = _splitTerse(line);
      if (f.length < 4) continue;
      final ssid = f[1];
      if (ssid.isEmpty) continue; // hidden network — nothing to show
      final net = WifiNetwork(
        ssid: ssid,
        signal: int.tryParse(f[2]) ?? 0,
        security: f[3],
        active: f[0] == 'yes',
      );
      final existing = bySsid[ssid];
      if (existing == null ||
          net.signal > existing.signal ||
          (net.active && !existing.active)) {
        bySsid[ssid] = net;
      }
    }
    final list = bySsid.values.toList()
      ..sort((a, b) => b.signal.compareTo(a.signal));
    return list;
  }

  /// Join [ssid]. Pass an empty [psk] for an open network. Returns the raw
  /// nmcli outcome; the caller verifies association via [currentConnection].
  Future<NmcliResult> connect(
    String ssid,
    String psk, {
    bool hidden = false,
  }) async {
    final args = ['device', 'wifi', 'connect', ssid];
    if (psk.isNotEmpty) args.addAll(['password', psk]);
    if (hidden) args.addAll(['hidden', 'yes']);
    final r = await _run(args);
    final ok = r.exitCode == 0;
    return NmcliResult(
      ok,
      ok ? _trim(r.stdout) : _trim(r.stderr).ifEmpty(_trim(r.stdout)),
    );
  }

  /// Delete the saved connection profile named [ssid] (best effort).
  Future<NmcliResult> forget(String ssid) async {
    final r = await _run(['connection', 'delete', 'id', ssid]);
    final ok = r.exitCode == 0;
    return NmcliResult(ok, ok ? 'forgot $ssid' : _trim(r.stderr));
  }

  /// The Pi's current SSID + IPv4 address, or nulls if not associated.
  Future<CurrentConnection> currentConnection() async {
    final dev = await wifiDevice();

    String? ssid;
    final active = await _run(['-t', '-f', 'ACTIVE,SSID', 'dev', 'wifi']);
    if (active.exitCode == 0) {
      for (final line in const LineSplitter().convert(active.stdout as String)) {
        final f = _splitTerse(line);
        if (f.length >= 2 && f[0] == 'yes' && f[1].isNotEmpty) {
          ssid = f[1];
          break;
        }
      }
    }

    String? ip;
    final show = await _run(['-t', '-f', 'IP4.ADDRESS', 'dev', 'show', dev]);
    if (show.exitCode == 0) {
      for (final line in const LineSplitter().convert(show.stdout as String)) {
        final f = _splitTerse(line);
        // e.g. "IP4.ADDRESS[1]:192.168.1.42/24"
        if (f.length >= 2 && f[0].startsWith('IP4.ADDRESS') && f[1].isNotEmpty) {
          ip = f[1].split('/').first;
          break;
        }
      }
    }
    return CurrentConnection(ssid: ssid, ip: ip);
  }

  /// Split one line of `nmcli -t` terse output into fields. Terse mode escapes
  /// literal `:` and `\` inside values as `\:` and `\\`, so we split on
  /// unescaped colons and then unescape.
  static List<String> _splitTerse(String line) {
    final fields = <String>[];
    final buf = StringBuffer();
    for (var i = 0; i < line.length; i++) {
      final c = line[i];
      if (c == r'\' && i + 1 < line.length) {
        buf.write(line[i + 1]); // unescape the next char
        i++;
      } else if (c == ':') {
        fields.add(buf.toString());
        buf.clear();
      } else {
        buf.write(c);
      }
    }
    fields.add(buf.toString());
    return fields;
  }

  static String _trim(Object? s) => (s as String? ?? '').trim();
}

class NmcliException implements Exception {
  NmcliException(this.message);
  final String message;
  @override
  String toString() => 'NmcliException: $message';
}

extension _Fallback on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}
