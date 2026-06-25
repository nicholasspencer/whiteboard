import 'dart:convert';
import 'dart:typed_data';

import 'models.dart';

/// Frame-based chunking for values that exceed the BLE notification MTU.
///
/// butane exposes no MTU getter and BLE notifications truncate to the negotiated
/// ATT MTU (as low as 20 payload bytes), so the Wi-Fi scan list is split into
/// frames `[index:u8][total:u8][payload…]` and reassembled by [ChunkAssembler]
/// on the receiving side. A `u8` count caps a message at 255 frames.
class Chunking {
  Chunking._();

  /// 2-byte header + up to 18 payload bytes = 20, safe at the 23-byte minimum
  /// ATT MTU (3 bytes of ATT overhead).
  static const int defaultMaxFrameBytes = 20;
  static const int _headerBytes = 2;

  /// Split [payload] into wire frames. An empty payload yields a single
  /// `[0, 1]` frame so the receiver still completes.
  static List<Uint8List> frames(
    Uint8List payload, {
    int maxFrameBytes = defaultMaxFrameBytes,
  }) {
    final perFrame = maxFrameBytes - _headerBytes;
    if (perFrame <= 0) {
      throw ArgumentError.value(
          maxFrameBytes, 'maxFrameBytes', 'must exceed the 2-byte header');
    }
    if (payload.isEmpty) {
      return [Uint8List.fromList(const [0, 1])];
    }
    final total = (payload.length + perFrame - 1) ~/ perFrame;
    if (total > 255) {
      throw ArgumentError('payload of ${payload.length} bytes needs $total '
          'frames; the u8 frame count maxes at 255');
    }
    final out = <Uint8List>[];
    for (var i = 0; i < total; i++) {
      final start = i * perFrame;
      final end =
          (start + perFrame > payload.length) ? payload.length : start + perFrame;
      final frame = Uint8List(_headerBytes + (end - start))
        ..[0] = i
        ..[1] = total
        ..setRange(_headerBytes, _headerBytes + (end - start), payload, start);
      out.add(frame);
    }
    return out;
  }
}

/// Reassembles [Chunking.frames] back into the original payload. Feed each
/// received frame to [addFrame]; it returns the full payload once the final
/// missing frame arrives, otherwise `null`. A change in the advertised `total`
/// is treated as the start of a new message and resets the buffer.
class ChunkAssembler {
  int? _total;
  final Map<int, Uint8List> _parts = {};

  Uint8List? addFrame(Uint8List frame) {
    if (frame.length < 2) {
      throw const FormatException('chunk frame shorter than its 2-byte header');
    }
    final index = frame[0];
    final total = frame[1];
    if (_total != null && total != _total) reset();
    _total = total;
    _parts[index] = Uint8List.sublistView(frame, 2);

    if (_parts.length != _total) return null;
    final builder = BytesBuilder(copy: false);
    for (var i = 0; i < _total!; i++) {
      final part = _parts[i];
      if (part == null) return null; // out-of-order gap; wait for the rest
      builder.add(part);
    }
    final result = builder.toBytes();
    reset();
    return result;
  }

  void reset() {
    _total = null;
    _parts.clear();
  }
}

/// Encode a Wi-Fi scan list into chunk frames ready for notify writes.
List<Uint8List> encodeNetworkList(
  List<WifiNetwork> networks, {
  int maxFrameBytes = Chunking.defaultMaxFrameBytes,
}) =>
    Chunking.frames(
      utf8JsonEncode(networks.map((n) => n.toJson()).toList()),
      maxFrameBytes: maxFrameBytes,
    );

/// Decode a reassembled scan-list payload back into [WifiNetwork]s.
List<WifiNetwork> decodeNetworkList(Uint8List payload) =>
    (jsonDecode(utf8.decode(payload)) as List)
        .map((e) => WifiNetwork.fromJson((e as Map).cast<String, Object?>()))
        .toList();
