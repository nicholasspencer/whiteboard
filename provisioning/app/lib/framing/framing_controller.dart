import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'camera_client.dart';
import 'whep_client.dart';

enum FramingPhase { connecting, live, reconnecting, error }

/// Orchestrates the live framing session for one rig:
///   info → config → framing-mode ON → WHEP live preview,
/// and on exit tears the WHEP session down and turns framing OFF so the rig
/// resumes normal capture. Rotation/config edits go straight to the server and
/// the preview reflects rotation client-side (the value also drives the still's
/// jpegtran rotation, so the live view matches what `/capture` saves).
class FramingController extends ChangeNotifier {
  FramingController({required this.client});

  final CameraClient client;
  final RTCVideoRenderer renderer = RTCVideoRenderer();

  FramingPhase phase = FramingPhase.connecting;
  String? error;
  CameraInfo? info;
  CameraConfig? config; // server truth (last loaded/saved)
  bool savingConfig = false;
  bool testShotBusy = false;

  WebrtcInfo? _webrtc;
  WhepSession? _whep;
  StreamSubscription<MediaStream>? _streamSub;
  StreamSubscription<RTCPeerConnectionState>? _stateSub;
  bool _framingOn = false;
  bool _disposed = false;

  int get rotation => config?.rotateDegrees ?? 0;
  bool get hasVideo => renderer.srcObject != null;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Connect, verify the rig has a camera + MediaMTX, enter framing, go live.
  Future<void> start() async {
    phase = FramingPhase.connecting;
    error = null;
    _notify();
    try {
      await renderer.initialize();
      info = await client.info();
      if (!info!.hasCamera) {
        throw CameraException('This rig reports no camera attached.');
      }
      if (!info!.webrtc.enabled) {
        throw CameraException(
            'The live preview (MediaMTX) is not installed on this rig. '
            'Re-run install.sh without --no-webrtc.');
      }
      config = (await client.getConfig()).config;
      await _enterFraming();
      await _connectWithRetry();
      phase = FramingPhase.live;
      _notify();
    } catch (e) {
      _setError(e);
    }
  }

  /// MediaMTX takes a moment to reclaim the camera after a (re)start, so the
  /// first WHEP offer can race it. Retry a few times before giving up.
  Future<void> _connectWithRetry({int attempts = 3}) async {
    Object? lastErr;
    for (var i = 0; i < attempts; i++) {
      if (_disposed) return;
      if (i > 0) {
        await _teardownWhep();
        await Future<void>.delayed(const Duration(milliseconds: 1200));
      }
      try {
        await _connectWhep();
        return;
      } catch (e) {
        lastErr = e;
      }
    }
    throw lastErr ?? WhepException('Could not reach the live preview.');
  }

  Future<void> _enterFraming() async {
    _webrtc = await client.setFraming(true);
    _framingOn = true;
  }

  Future<void> _connectWhep() async {
    final webrtc = _webrtc!;
    final whep = WhepSession(endpoint: client.whepUrl(webrtc), headers: _headers);
    _whep = whep;
    _streamSub = whep.remoteStream.listen((stream) {
      renderer.srcObject = stream;
      _notify();
    });
    _stateSub = whep.connectionState.listen((s) {
      if (phase == FramingPhase.live &&
          (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
              s == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected)) {
        phase = FramingPhase.error;
        error = 'Live preview disconnected.';
        _notify();
      }
    });
    await whep.connect();
  }

  Map<String, String> get _headers => {
        if (client.token != null && client.token!.isNotEmpty)
          'X-Whiteboard-Token': client.token!,
      };

  Future<void> _teardownWhep() async {
    await _streamSub?.cancel();
    _streamSub = null;
    await _stateSub?.cancel();
    _stateSub = null;
    renderer.srcObject = null;
    await _whep?.close();
    _whep = null;
  }

  /// Re-establish the live view (e.g. after a test shot blipped MediaMTX, or a
  /// transient ICE failure).
  Future<void> reconnect() async {
    if (_disposed) return;
    phase = FramingPhase.reconnecting;
    error = null;
    _notify();
    try {
      await _teardownWhep();
      if (!_framingOn) await _enterFraming();
      await _connectWhep();
      phase = FramingPhase.live;
      _notify();
    } catch (e) {
      _setError(e);
    }
  }

  /// Quick rotation (0/90/180/270). Empty string for 0 to match the server.
  Future<void> setRotation(int degrees) async {
    final r = (degrees % 360);
    await applyPatch({'rotate': r == 0 ? '' : '$r'});
  }

  /// Save a full-editor draft — only the changed keys are sent.
  Future<void> saveConfig(CameraConfig draft) async {
    final base = config;
    if (base == null) return;
    final patch = draft.diff(base);
    if (patch.isEmpty) return;
    await applyPatch(patch);
  }

  Future<void> applyPatch(Map<String, dynamic> patch) async {
    savingConfig = true;
    error = null;
    _notify();
    try {
      config = (await client.patchConfig(patch)).config;
    } catch (e) {
      error = '$e';
    } finally {
      savingConfig = false;
      _notify();
    }
  }

  /// Take a real still (ground truth for framing). Returns JPEG bytes, then
  /// brings the live preview back (the capture restarts MediaMTX server-side).
  Future<Uint8List?> takeTestShot() async {
    testShotBusy = true;
    error = null;
    _notify();
    Uint8List? bytes;
    try {
      bytes = await client.capture();
    } catch (e) {
      error = 'Test shot failed: $e';
    } finally {
      testShotBusy = false;
      _notify();
    }
    // The capture restarted MediaMTX server-side; give it a beat to reclaim the
    // camera, then bring the live preview back.
    if (_framingOn && !_disposed) {
      Future<void>.delayed(const Duration(milliseconds: 1200), () {
        if (!_disposed) unawaited(reconnect());
      });
    }
    return bytes;
  }

  void _setError(Object e) {
    phase = FramingPhase.error;
    error = '$e';
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    // Detached best-effort cleanup: stop the stream and leave framing mode so
    // the rig hands the camera back to the capture service.
    () async {
      await _teardownWhep();
      if (_framingOn) {
        try {
          await client.setFraming(false);
        } catch (_) {}
      }
      try {
        await renderer.dispose();
      } catch (_) {}
    }();
    super.dispose();
  }
}
