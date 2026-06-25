import 'dart:async';
import 'dart:typed_data';

import 'package:butane_bluez/butane_bluez.dart';
import 'package:butane_platform_interface/butane_platform_interface.dart';
import 'package:whiteboard_provisioning/whiteboard_provisioning.dart';

import 'device_info.dart';
import 'nmcli.dart';

/// The headless BLE peripheral. Advertises the provisioning GATT service, serves
/// the Info/Status/Networks characteristics, and turns Command writes into
/// `nmcli` actions while streaming progress back over Status notifications.
///
/// One command runs at a time; the work is async and reports exclusively through
/// the Status characteristic, so the app only has to subscribe and watch.
class Provisioner {
  Provisioner({ButaneBluez? ble, NmcliClient? nmcli})
      : _ble = ble ?? ButaneBluez(),
        _nmcli = nmcli ?? NmcliClient();

  final ButaneBluez _ble;
  final NmcliClient _nmcli;
  final _subs = <StreamSubscription<dynamic>>[];

  StatusReport _status = const StatusReport(state: ProvisionState.idle);
  DeviceInfo _info = const DeviceInfo(
      label: '', hostname: '', model: '', fwVersion: provisionerVersion);
  bool _busy = false;

  /// Wait for the adapter, publish the service, and start advertising.
  Future<void> start() async {
    await _awaitPoweredOn();
    final current = await _safeCurrent();
    _info = await gatherDeviceInfo(
        current: current, state: _stateFor(current));
    _status = _restingStatus(current);

    await _ble.addService(service: _buildService());
    _subs.add(_ble.readRequestStream().listen(_onRead));
    _subs.add(_ble.writeRequestsStream().listen(_onWrites));
    // No localName in the advertisement: a 128-bit service UUID already nearly
    // fills the 31-byte BLE adv packet, and adding a name makes BlueZ reject the
    // registration. The app finds the rig by service UUID and reads the friendly
    // label from the Info characteristic after connecting.
    await _ble.startAdvertising(serviceUuids: [WhiteboardGatt.service]);
    _log('advertising service ${WhiteboardGatt.service} as ${_info.label} '
        '(${_info.model}); current: ${current.ssid ?? "—"} ${current.ip ?? ""}');
  }

  /// Stop advertising and tear down the GATT service.
  Future<void> stop() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    try {
      await _ble.stopAdvertising();
    } catch (_) {}
    try {
      await _ble.removeAllServices();
    } catch (_) {}
  }

  MutableService _buildService() => MutableService(
        uuid: WhiteboardGatt.service,
        characteristics: [
          MutableCharacteristic(
            uuid: WhiteboardGatt.info,
            properties: CharacteristicProperty(read: true),
            permissions: CharacteristicPermission(readable: true),
          ),
          MutableCharacteristic(
            uuid: WhiteboardGatt.command,
            properties: CharacteristicProperty(write: true),
            permissions: CharacteristicPermission(writeable: true),
          ),
          MutableCharacteristic(
            uuid: WhiteboardGatt.status,
            properties: CharacteristicProperty(read: true, notify: true),
            permissions: CharacteristicPermission(readable: true),
          ),
          MutableCharacteristic(
            uuid: WhiteboardGatt.networks,
            properties: CharacteristicProperty(read: true, notify: true),
            permissions: CharacteristicPermission(readable: true),
          ),
        ],
      );

  // --- request handlers ----------------------------------------------------

  void _onRead(AttRequest req) {
    final uuid = req.characteristicUuid;
    if (_isUuid(uuid, WhiteboardGatt.info)) {
      _respond(req, _info.encode());
    } else if (_isUuid(uuid, WhiteboardGatt.status)) {
      _respond(req, _status.encode());
    } else if (_isUuid(uuid, WhiteboardGatt.networks)) {
      // The list arrives via notify after a scan; a bare read just completes.
      _respond(req, Uint8List.fromList(const [0, 1]));
    } else {
      _ble.respondToRequest(
          requestId: req.requestId, result: AttResult.readNotPermitted);
    }
  }

  void _respond(AttRequest req, Uint8List value) => _ble.respondToRequest(
      requestId: req.requestId, result: AttResult.success, value: value);

  void _onWrites(List<AttRequest> requests) {
    for (final req in requests) {
      final value = req.value;
      if (!_isUuid(req.characteristicUuid, WhiteboardGatt.command) ||
          value == null) {
        _ble.respondToRequest(
            requestId: req.requestId, result: AttResult.writeNotPermitted);
        continue;
      }
      Command cmd;
      try {
        cmd = Command.decode(value);
      } on FormatException catch (e) {
        _ble.respondToRequest(
            requestId: req.requestId, result: AttResult.unlikelyError);
        unawaited(_fail('rejected command: ${e.message}'));
        continue;
      }
      // Ack the write immediately; the work proceeds async via Status notifies.
      _ble.respondToRequest(
          requestId: req.requestId, result: AttResult.success);
      unawaited(_dispatch(cmd));
    }
  }

  // --- command dispatch ----------------------------------------------------

  Future<void> _dispatch(Command cmd) async {
    if (_busy) {
      _log('busy — ignoring ${cmd.runtimeType}');
      return;
    }
    _busy = true;
    try {
      switch (cmd) {
        case ScanCommand():
          await _doScan();
        case final ProvisionWifiCommand c:
          await _doProvision(c);
        case final ForgetCommand c:
          await _doForget(c);
      }
    } catch (e) {
      await _fail('$e');
    } finally {
      _busy = false;
    }
  }

  Future<void> _doScan() async {
    await _setStatus(_status.copyWith(
        state: ProvisionState.scanning, error: null, ts: _now()));
    final networks = await _nmcli.scan();
    final frames = encodeNetworkList(networks);
    for (final frame in frames) {
      await _ble.updateValue(
        serviceUuid: WhiteboardGatt.service,
        characteristicUuid: WhiteboardGatt.networks,
        value: frame,
      );
      // Pace the notifications so BlueZ's outbound queue doesn't drop frames.
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    _log('scan: ${networks.length} networks in ${frames.length} frames');
    await _setStatus(_restingStatus(await _safeCurrent()));
  }

  Future<void> _doProvision(ProvisionWifiCommand cmd) async {
    await _setStatus(StatusReport(
        state: ProvisionState.applying, ssid: cmd.ssid, ts: _now()));
    final result = await _nmcli.connect(cmd.ssid, cmd.psk, hidden: cmd.hidden);
    if (!result.ok) {
      await _fail('could not join ${cmd.ssid}: ${result.message}',
          ssid: cmd.ssid);
      return;
    }
    await _setStatus(StatusReport(
        state: ProvisionState.connecting, ssid: cmd.ssid, ts: _now()));
    // nmcli usually returns once DHCP is up; poll as a safety net for the IP.
    for (var i = 0; i < 20; i++) {
      final current = await _safeCurrent();
      if (current.ssid == cmd.ssid && current.ip != null) {
        _info = await gatherDeviceInfo(
            current: current, state: ProvisionState.connected);
        await _setStatus(StatusReport(
            state: ProvisionState.connected,
            ssid: current.ssid,
            ip: current.ip,
            ts: _now()));
        _log('connected to ${current.ssid} @ ${current.ip}');
        return;
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    await _fail('joined ${cmd.ssid} but no IP within 20s', ssid: cmd.ssid);
  }

  Future<void> _doForget(ForgetCommand cmd) async {
    final result = await _nmcli.forget(cmd.ssid);
    _log(result.message);
    final current = await _safeCurrent();
    _info =
        await gatherDeviceInfo(current: current, state: _stateFor(current));
    await _setStatus(_restingStatus(current));
  }

  // --- helpers -------------------------------------------------------------

  Future<void> _awaitPoweredOn() async {
    for (var i = 0; i < 60; i++) {
      if (await _ble.clientState() == ClientState.poweredOn) return;
      if (i == 0) _log('waiting for the Bluetooth adapter to power on…');
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    throw StateError('Bluetooth adapter not powered on after 60s');
  }

  Future<CurrentConnection> _safeCurrent() async {
    try {
      return await _nmcli.currentConnection();
    } catch (_) {
      return const CurrentConnection();
    }
  }

  Future<void> _setStatus(StatusReport status) async {
    _status = status;
    await _ble.updateValue(
      serviceUuid: WhiteboardGatt.service,
      characteristicUuid: WhiteboardGatt.status,
      value: status.encode(),
    );
    _log('status: ${status.state.name}'
        '${status.error != null ? " — ${status.error}" : ""}');
  }

  Future<void> _fail(String error, {String? ssid}) => _setStatus(StatusReport(
      state: ProvisionState.failed, ssid: ssid, error: error, ts: _now()));

  StatusReport _restingStatus(CurrentConnection c) => StatusReport(
      state: _stateFor(c), ssid: c.ssid, ip: c.ip, ts: _now());

  ProvisionState _stateFor(CurrentConnection c) =>
      c.ip != null ? ProvisionState.connected : ProvisionState.idle;

  bool _isUuid(String a, String b) => a.toLowerCase() == b.toLowerCase();

  int _now() => DateTime.now().millisecondsSinceEpoch;

  void _log(String message) => print('[provisioner] $message');
}
