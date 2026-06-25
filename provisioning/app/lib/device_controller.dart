import 'dart:async';

import 'package:butane/butane.dart';
import 'package:flutter/foundation.dart';
import 'package:whiteboard_provisioning/whiteboard_provisioning.dart';

/// Drives a single rig connection: connect, discover the provisioning service,
/// read Info, subscribe to Status + Networks, and send commands. A
/// [ChangeNotifier] so the UI rebuilds as state streams in.
class DeviceController extends ChangeNotifier {
  DeviceController(this.peripheral);

  final Peripheral peripheral;

  ConnectionState connection = ConnectionState.disconnected;
  DeviceInfo? info;
  StatusReport? status;
  List<WifiNetwork> networks = const [];
  bool scanningNetworks = false;

  /// A fatal connect/discover error; when set, the rig can't be used.
  String? fault;

  Characteristic? _info;
  Characteristic? _command;
  Characteristic? _status;
  Characteristic? _networks;

  final ChunkAssembler _assembler = ChunkAssembler();
  final Completer<void> _connected = Completer<void>();
  StreamSubscription<ConnectionState>? _connSub;
  StreamSubscription<Uint8List>? _statusSub;
  StreamSubscription<Uint8List>? _networksSub;
  Timer? _scanTimeout;

  /// True once discovery has wired up the command characteristic.
  bool get isReady => _command != null && _status != null;

  /// Connect, discover, and start listening. Captures any failure in [fault].
  Future<void> open() async {
    try {
      _connSub = peripheral.stateStream.listen(_onConnection);
      await peripheral.connect();
      await _connected.future.timeout(
        const Duration(seconds: 20),
        onTimeout: () => throw TimeoutException('Connection timed out'),
      );
      await _discover();
      await _readInfo();
      _statusSub = _status?.observe().listen(_onStatusBytes);
      _networksSub = _networks?.observe().listen(_onNetworkBytes);
      notifyListeners();
    } catch (e) {
      fault = '$e';
      notifyListeners();
    }
  }

  void _onConnection(ConnectionState state) {
    connection = state;
    if (state == ConnectionState.connected && !_connected.isCompleted) {
      _connected.complete();
    }
    notifyListeners();
  }

  Future<void> _discover() async {
    await peripheral.discoverServices(
        serviceUuids: [UuidIdentifier(WhiteboardGatt.service)]);
    Service? service;
    for (final s in await peripheral.services) {
      if (_sameUuid(s.uuid.toString(), WhiteboardGatt.service)) {
        service = s;
        break;
      }
    }
    if (service == null) {
      throw StateError('This rig is not advertising the provisioning service.');
    }
    await service.discoverCharacteristics();
    for (final c in await service.characteristics) {
      final uuid = c.uuid.toString().toLowerCase();
      if (uuid == WhiteboardGatt.info) {
        _info = c;
      } else if (uuid == WhiteboardGatt.command) {
        _command = c;
      } else if (uuid == WhiteboardGatt.status) {
        _status = c;
      } else if (uuid == WhiteboardGatt.networks) {
        _networks = c;
      }
    }
    if (_command == null || _status == null) {
      throw StateError('This rig is missing the expected characteristics.');
    }
  }

  Future<void> _readInfo() async {
    final bytes = await _info?.read();
    if (bytes != null && bytes.isNotEmpty) {
      info = DeviceInfo.decode(bytes);
      notifyListeners();
    }
  }

  void _onStatusBytes(Uint8List bytes) {
    if (bytes.isEmpty) return;
    try {
      status = StatusReport.decode(bytes);
      notifyListeners();
    } catch (_) {
      // ignore malformed status frames
    }
  }

  void _onNetworkBytes(Uint8List frame) {
    if (frame.isEmpty) return;
    try {
      final payload = _assembler.addFrame(frame);
      if (payload != null && payload.isNotEmpty) {
        networks = decodeNetworkList(payload);
        scanningNetworks = false;
        _scanTimeout?.cancel();
        notifyListeners();
      }
    } catch (_) {
      // a stray/partial frame — wait for a clean message
    }
  }

  /// Ask the rig to scan for Wi-Fi networks. Results arrive over notify.
  Future<void> scanNetworks() async {
    if (_command == null) return;
    scanningNetworks = true;
    networks = const [];
    _assembler.reset();
    notifyListeners();
    _scanTimeout?.cancel();
    _scanTimeout = Timer(const Duration(seconds: 15), () {
      if (scanningNetworks) {
        scanningNetworks = false;
        notifyListeners();
      }
    });
    await _command!.write(value: const ScanCommand().encode());
  }

  /// Join [ssid]; an empty [psk] is treated as an open network. Progress is
  /// reported back through [status].
  Future<void> provision(String ssid, String psk, {bool hidden = false}) async {
    await _command?.write(
        value: ProvisionWifiCommand(ssid: ssid, psk: psk, hidden: hidden)
            .encode());
  }

  /// Forget a saved network so the rig stops auto-joining it.
  Future<void> forget(String ssid) async {
    await _command?.write(value: ForgetCommand(ssid).encode());
  }

  bool _sameUuid(String a, String b) => a.toLowerCase() == b.toLowerCase();

  @override
  void dispose() {
    _scanTimeout?.cancel();
    _connSub?.cancel();
    _statusSub?.cancel();
    _networksSub?.cancel();
    unawaited(_safeDisconnect());
    super.dispose();
  }

  Future<void> _safeDisconnect() async {
    try {
      await peripheral.cancelConnection();
    } catch (_) {}
  }
}
