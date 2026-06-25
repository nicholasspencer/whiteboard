import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:whiteboard_provisioning/whiteboard_provisioning.dart';

void main() {
  group('command codec', () {
    test('scan round-trips', () {
      final decoded = Command.decode(const ScanCommand().encode());
      expect(decoded, isA<ScanCommand>());
    });

    test('provision round-trips with all fields', () {
      const cmd = ProvisionWifiCommand(
          ssid: 'office-5G', psk: 'hunter2', hidden: true);
      final decoded = Command.decode(cmd.encode()) as ProvisionWifiCommand;
      expect(decoded.ssid, 'office-5G');
      expect(decoded.psk, 'hunter2');
      expect(decoded.hidden, isTrue);
    });

    test('provision defaults hidden to false and allows empty psk (open net)',
        () {
      final decoded = Command.decode(
              const ProvisionWifiCommand(ssid: 'guest', psk: '').encode())
          as ProvisionWifiCommand;
      expect(decoded.psk, isEmpty);
      expect(decoded.hidden, isFalse);
    });

    test('forget round-trips', () {
      final decoded =
          Command.decode(const ForgetCommand('home-wifi').encode())
              as ForgetCommand;
      expect(decoded.ssid, 'home-wifi');
    });

    test('unknown command throws', () {
      expect(() => Command.fromJson({'cmd': 'nope'}),
          throwsA(isA<FormatException>()));
    });

    test('provision without ssid throws', () {
      expect(() => Command.fromJson({'cmd': 'provision', 'psk': 'x'}),
          throwsA(isA<FormatException>()));
    });
  });

  group('status + info codec', () {
    test('status round-trips', () {
      const s = StatusReport(
          state: ProvisionState.connected,
          ssid: 'office-5G',
          ip: '192.168.1.42',
          ts: 1719000000000);
      final d = StatusReport.decode(s.encode());
      expect(d.state, ProvisionState.connected);
      expect(d.ssid, 'office-5G');
      expect(d.ip, '192.168.1.42');
      expect(d.ts, 1719000000000);
    });

    test('failed status carries an error', () {
      const s = StatusReport(state: ProvisionState.failed, error: 'bad psk');
      final d = StatusReport.decode(s.encode());
      expect(d.state, ProvisionState.failed);
      expect(d.error, 'bad psk');
    });

    test('unknown state name decodes to idle', () {
      final d = StatusReport.fromJson({'state': 'wat'});
      expect(d.state, ProvisionState.idle);
    });

    test('device info round-trips', () {
      const info = DeviceInfo(
        label: 'Conference Room A',
        hostname: 'raspberrypi',
        model: 'Raspberry Pi 4 Model B',
        fwVersion: '0.1.0',
        currentSsid: 'home-wifi',
        ip: '192.168.4.51',
        state: ProvisionState.connected,
      );
      final d = DeviceInfo.decode(info.encode());
      expect(d.label, 'Conference Room A');
      expect(d.currentSsid, 'home-wifi');
      expect(d.state, ProvisionState.connected);
    });
  });

  group('chunking', () {
    Uint8List bytes(int n) =>
        Uint8List.fromList(List<int>.generate(n, (i) => i % 256));

    test('round-trips a payload that spans many frames', () {
      final payload = bytes(1000);
      final assembler = ChunkAssembler();
      Uint8List? out;
      for (final frame in Chunking.frames(payload)) {
        expect(frame.length, lessThanOrEqualTo(Chunking.defaultMaxFrameBytes));
        out = assembler.addFrame(frame) ?? out;
      }
      expect(out, isNotNull);
      expect(out, equals(payload));
    });

    test('empty payload still completes', () {
      final frames = Chunking.frames(Uint8List(0));
      expect(frames, hasLength(1));
      final out = ChunkAssembler().addFrame(frames.single);
      expect(out, isEmpty);
    });

    test('reassembles out-of-order frames', () {
      final payload = bytes(100);
      final frames = Chunking.frames(payload).reversed.toList();
      final assembler = ChunkAssembler();
      Uint8List? out;
      for (final frame in frames) {
        out = assembler.addFrame(frame) ?? out;
      }
      expect(out, equals(payload));
    });

    test('a new message (different total) resets the assembler', () {
      final assembler = ChunkAssembler();
      // First frame of a stale 3-frame message, then a fresh complete message.
      assembler.addFrame(Chunking.frames(bytes(50)).first);
      final fresh = bytes(10);
      Uint8List? out;
      for (final frame in Chunking.frames(fresh)) {
        out = assembler.addFrame(frame) ?? out;
      }
      expect(out, equals(fresh));
    });

    test('rejects payloads needing more than 255 frames', () {
      expect(() => Chunking.frames(bytes(255 * 18 + 1)),
          throwsA(isA<ArgumentError>()));
    });

    test('network list encode/decode round-trips through chunks', () {
      final nets = [
        const WifiNetwork(ssid: 'office-5G', signal: 88, security: 'WPA2'),
        const WifiNetwork(
            ssid: 'office-guest', signal: 60, security: 'WPA2', active: true),
        const WifiNetwork(ssid: 'open-cafe', signal: 30, security: ''),
      ];
      final assembler = ChunkAssembler();
      Uint8List? payload;
      for (final frame in encodeNetworkList(nets)) {
        payload = assembler.addFrame(frame) ?? payload;
      }
      final decoded = decodeNetworkList(payload!);
      expect(decoded, hasLength(3));
      expect(decoded[1].active, isTrue);
      expect(decoded[2].isOpen, isTrue);
    });
  });
}
