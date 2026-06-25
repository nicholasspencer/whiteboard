import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;

/// A minimal WHEP (WebRTC-HTTP Egress Protocol) client.
///
/// It POSTs a single SDP offer to the rig's MediaMTX endpoint
/// (`http://<rig>:8889/cam/whep`) and renders the returned video track. The app
/// is **receive-only** — it never publishes media — so the peer connection
/// carries one recvonly video transceiver and nothing else.
///
/// Non-trickle: we wait briefly for ICE gathering to finish so the offer we POST
/// already carries our host candidates. On a LAN that completes in well under a
/// second and avoids the PATCH-based trickle dance entirely.
class WhepSession {
  WhepSession({required this.endpoint, this.headers = const {}});

  /// The WHEP endpoint, e.g. `http://<rig-ip>:8889/cam/whep`.
  final Uri endpoint;

  /// Extra request headers (e.g. an auth token), applied to every call.
  final Map<String, String> headers;

  RTCPeerConnection? _pc;
  Uri? _resource; // WHEP resource Location, for teardown
  bool _closed = false;

  final _stream = StreamController<MediaStream>.broadcast();
  final _state = StreamController<RTCPeerConnectionState>.broadcast();

  /// Emits the remote video stream once the track arrives.
  Stream<MediaStream> get remoteStream => _stream.stream;

  /// Emits peer-connection state changes (connecting → connected → failed…).
  Stream<RTCPeerConnectionState> get connectionState => _state.stream;

  /// Negotiate and start receiving. Throws [WhepException] on a rejected offer.
  Future<void> connect() async {
    final pc = await createPeerConnection(<String, dynamic>{
      // LAN only: host ICE candidates, no public STUN/TURN round-trip.
      'iceServers': <Map<String, dynamic>>[],
      'sdpSemantics': 'unified-plan',
    });
    _pc = pc;

    pc.onTrack = (RTCTrackEvent event) {
      if (event.streams.isNotEmpty && !_stream.isClosed) {
        _stream.add(event.streams.first);
      }
    };
    pc.onConnectionState = (RTCPeerConnectionState s) {
      if (!_state.isClosed) _state.add(s);
    };

    await pc.addTransceiver(
      kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
      init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
    );

    final offer = await pc.createOffer(<String, dynamic>{});
    await pc.setLocalDescription(offer);
    final localSdp = await _gatheredSdp(pc);
    if (_closed) return;

    final res = await http
        .post(
          endpoint,
          headers: {'Content-Type': 'application/sdp', ...headers},
          body: localSdp,
        )
        .timeout(const Duration(seconds: 10));
    if (_closed) return;
    if (res.statusCode != 201 && res.statusCode != 200) {
      throw WhepException(
          'Live preview was refused by the rig (${res.statusCode}). '
          'Is framing mode on and MediaMTX running?');
    }

    final loc = res.headers['location'];
    if (loc != null && loc.isNotEmpty) _resource = endpoint.resolve(loc);

    await pc.setRemoteDescription(RTCSessionDescription(res.body, 'answer'));
  }

  /// Resolve once ICE gathering is complete (or after a short cap), then return
  /// the local SDP including the gathered host candidates.
  Future<String> _gatheredSdp(RTCPeerConnection pc) async {
    Future<String> current() async => (await pc.getLocalDescription())!.sdp!;
    if (pc.iceGatheringState ==
        RTCIceGatheringState.RTCIceGatheringStateComplete) {
      return current();
    }
    final done = Completer<void>();
    void finish() => done.isCompleted ? null : done.complete();
    pc.onIceGatheringState = (RTCIceGatheringState s) {
      if (s == RTCIceGatheringState.RTCIceGatheringStateComplete) finish();
    };
    final timer = Timer(const Duration(milliseconds: 1500), finish);
    await done.future;
    timer.cancel();
    return current();
  }

  /// Tear down: DELETE the WHEP resource (best effort) and close the connection.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final resource = _resource;
    if (resource != null) {
      try {
        await http
            .delete(resource, headers: headers)
            .timeout(const Duration(seconds: 3));
      } catch (_) {/* the rig drops the session on its own anyway */}
    }
    try {
      await _pc?.close();
    } catch (_) {}
    if (!_stream.isClosed) await _stream.close();
    if (!_state.isClosed) await _state.close();
  }
}

class WhepException implements Exception {
  WhepException(this.message);
  final String message;
  @override
  String toString() => message;
}
