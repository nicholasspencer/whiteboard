import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// HTTP client for the whiteboard capture server (`whiteboard-server.ts`).
///
/// Reached once the rig is on Wi-Fi (the IP comes from BLE provisioning). Wraps
/// the camera endpoints the framing screen needs: live config get/patch,
/// framing-mode toggle (which starts/stops the MediaMTX live preview), a real
/// test-shot via `/capture`, and `/info`.
class CameraClient {
  CameraClient({required this.host, this.port = 8080, this.token});

  final String host;
  final int port;
  final String? token;

  Uri _u(String path) => Uri(scheme: 'http', host: host, port: port, path: path);

  Map<String, String> get _authHeaders => {
        if (token != null && token!.isNotEmpty) 'X-Whiteboard-Token': token!,
      };

  static const _timeout = Duration(seconds: 10);

  Future<CameraInfo> info() async {
    final res =
        await http.get(_u('/info'), headers: _authHeaders).timeout(_timeout);
    _check(res);
    return CameraInfo.fromJson(_json(res));
  }

  /// Current camera config + WebRTC endpoint.
  Future<ConfigSnapshot> getConfig() async {
    final res =
        await http.get(_u('/config'), headers: _authHeaders).timeout(_timeout);
    _check(res);
    return ConfigSnapshot.fromJson(_json(res));
  }

  /// Patch one or more config fields. Returns the new effective snapshot.
  Future<ConfigSnapshot> patchConfig(Map<String, dynamic> patch) async {
    final res = await http
        .post(_u('/config'),
            headers: {'Content-Type': 'application/json', ..._authHeaders},
            body: jsonEncode(patch))
        .timeout(_timeout);
    _check(res);
    return ConfigSnapshot.fromJson(_json(res));
  }

  /// Enter/leave framing mode. On => the rig hands the camera to MediaMTX for
  /// the live preview; off => normal capture resumes. Returns the WebRTC info.
  Future<WebrtcInfo> setFraming(bool on) async {
    final res = await http
        .post(_u('/framing'),
            headers: {'Content-Type': 'application/json', ..._authHeaders},
            body: jsonEncode({'on': on}))
        .timeout(const Duration(seconds: 25)); // MediaMTX cold-start headroom
    _check(res);
    return WebrtcInfo.fromJson(
        (_json(res)['webrtc'] as Map?)?.cast<String, dynamic>() ?? const {});
  }

  /// Take a real still (what the board reads will produce). Returns JPEG bytes.
  Future<Uint8List> capture() async {
    final res = await http
        .get(_u('/capture'), headers: _authHeaders)
        .timeout(const Duration(seconds: 40)); // HDR bracket + framing swap
    _check(res, wantBytes: true);
    return res.bodyBytes;
  }

  /// The WHEP URL for a given WebRTC info on this host.
  Uri whepUrl(WebrtcInfo webrtc) => Uri(
      scheme: 'http', host: host, port: webrtc.port, path: webrtc.whepPath);

  Map<String, dynamic> _json(http.Response res) =>
      jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;

  void _check(http.Response res, {bool wantBytes = false}) {
    if (res.statusCode == 200) return;
    String detail;
    try {
      final body = jsonDecode(utf8.decode(res.bodyBytes));
      detail = body is Map && body['error'] != null
          ? '${body['error']}'
          : res.reasonPhrase ?? '';
    } catch (_) {
      detail = res.reasonPhrase ?? '';
    }
    throw CameraException('Rig returned ${res.statusCode}'
        '${detail.isEmpty ? '' : ': $detail'}');
  }
}

/// `/info` response (the bits the app uses).
class CameraInfo {
  const CameraInfo({
    required this.label,
    required this.model,
    required this.camera,
    required this.framing,
    required this.webrtc,
  });

  final String label;
  final String model;
  final String? camera; // capture binary path, or null if no camera
  final bool framing;
  final WebrtcInfo webrtc;

  bool get hasCamera => camera != null && camera!.isNotEmpty;

  factory CameraInfo.fromJson(Map<String, dynamic> j) => CameraInfo(
        label: '${j['label'] ?? ''}',
        model: '${j['model'] ?? ''}',
        camera: j['camera'] as String?,
        framing: j['framing'] == true,
        webrtc: WebrtcInfo.fromJson(
            (j['webrtc'] as Map?)?.cast<String, dynamic>() ?? const {}),
      );
}

/// The WebRTC/WHEP endpoint advertised by the rig.
class WebrtcInfo {
  const WebrtcInfo({
    required this.enabled,
    required this.port,
    required this.whepPath,
    required this.framing,
  });

  final bool enabled;
  final int port;
  final String whepPath;
  final bool framing;

  factory WebrtcInfo.fromJson(Map<String, dynamic> j) => WebrtcInfo(
        enabled: j['enabled'] == true,
        port: (j['port'] as num?)?.toInt() ?? 8889,
        whepPath: '${j['whepPath'] ?? '/cam/whep'}',
        framing: j['framing'] == true,
      );
}

/// `/config` (and `/framing`) wrap a config + a webrtc block.
class ConfigSnapshot {
  const ConfigSnapshot({required this.config, required this.webrtc});

  final CameraConfig config;
  final WebrtcInfo webrtc;

  factory ConfigSnapshot.fromJson(Map<String, dynamic> j) => ConfigSnapshot(
        config: CameraConfig.fromJson(
            (j['config'] as Map?)?.cast<String, dynamic>() ?? const {}),
        webrtc: WebrtcInfo.fromJson(
            (j['webrtc'] as Map?)?.cast<String, dynamic>() ?? const {}),
      );
}

/// Mirrors the server's editable capture config. Every field round-trips
/// through `/config`; [diff] yields the minimal patch to POST back.
class CameraConfig {
  const CameraConfig({
    this.label = '',
    this.token = '',
    this.width = 2304,
    this.height = 1296,
    this.timeoutMs = 1200,
    this.extra = '',
    this.rotate = '',
    this.hdr = 'auto',
    this.hdrBracket = '',
    this.enfuseArgs = '',
    this.watchIntervalMs = 20000,
    this.watchWidth = 160,
    this.watchHeight = 90,
    this.watchThreshold = 0.035,
    this.watchStableEps = 0.012,
  });

  final String label;
  final String token;
  final int width;
  final int height;
  final int timeoutMs;
  final String extra;
  final String rotate; // '', '90', '180', '270'
  final String hdr; // auto | on | off
  final String hdrBracket;
  final String enfuseArgs;
  final int watchIntervalMs;
  final int watchWidth;
  final int watchHeight;
  final double watchThreshold;
  final double watchStableEps;

  /// Rotation as a number of degrees (0/90/180/270) for the preview transform.
  int get rotateDegrees => int.tryParse(rotate) ?? 0;

  static int _int(dynamic v, int d) => (v as num?)?.toInt() ?? d;
  static double _dbl(dynamic v, double d) => (v as num?)?.toDouble() ?? d;

  factory CameraConfig.fromJson(Map<String, dynamic> j) => CameraConfig(
        label: '${j['label'] ?? ''}',
        token: '${j['token'] ?? ''}',
        width: _int(j['width'], 2304),
        height: _int(j['height'], 1296),
        timeoutMs: _int(j['timeoutMs'], 1200),
        extra: '${j['extra'] ?? ''}',
        rotate: '${j['rotate'] ?? ''}',
        hdr: '${j['hdr'] ?? 'auto'}',
        hdrBracket: '${j['hdrBracket'] ?? ''}',
        enfuseArgs: '${j['enfuseArgs'] ?? ''}',
        watchIntervalMs: _int(j['watchIntervalMs'], 20000),
        watchWidth: _int(j['watchWidth'], 160),
        watchHeight: _int(j['watchHeight'], 90),
        watchThreshold: _dbl(j['watchThreshold'], 0.035),
        watchStableEps: _dbl(j['watchStableEps'], 0.012),
      );

  Map<String, dynamic> toJson() => {
        'label': label,
        'token': token,
        'width': width,
        'height': height,
        'timeoutMs': timeoutMs,
        'extra': extra,
        'rotate': rotate,
        'hdr': hdr,
        'hdrBracket': hdrBracket,
        'enfuseArgs': enfuseArgs,
        'watchIntervalMs': watchIntervalMs,
        'watchWidth': watchWidth,
        'watchHeight': watchHeight,
        'watchThreshold': watchThreshold,
        'watchStableEps': watchStableEps,
      };

  /// The minimal patch turning [base] into this config (only changed keys).
  Map<String, dynamic> diff(CameraConfig base) {
    final mine = toJson();
    final theirs = base.toJson();
    return {
      for (final e in mine.entries)
        if (e.value != theirs[e.key]) e.key: e.value,
    };
  }

  CameraConfig copyWith({
    String? label,
    String? token,
    int? width,
    int? height,
    int? timeoutMs,
    String? extra,
    String? rotate,
    String? hdr,
    String? hdrBracket,
    String? enfuseArgs,
    int? watchIntervalMs,
    int? watchWidth,
    int? watchHeight,
    double? watchThreshold,
    double? watchStableEps,
  }) =>
      CameraConfig(
        label: label ?? this.label,
        token: token ?? this.token,
        width: width ?? this.width,
        height: height ?? this.height,
        timeoutMs: timeoutMs ?? this.timeoutMs,
        extra: extra ?? this.extra,
        rotate: rotate ?? this.rotate,
        hdr: hdr ?? this.hdr,
        hdrBracket: hdrBracket ?? this.hdrBracket,
        enfuseArgs: enfuseArgs ?? this.enfuseArgs,
        watchIntervalMs: watchIntervalMs ?? this.watchIntervalMs,
        watchWidth: watchWidth ?? this.watchWidth,
        watchHeight: watchHeight ?? this.watchHeight,
        watchThreshold: watchThreshold ?? this.watchThreshold,
        watchStableEps: watchStableEps ?? this.watchStableEps,
      );
}

class CameraException implements Exception {
  CameraException(this.message);
  final String message;
  @override
  String toString() => message;
}
