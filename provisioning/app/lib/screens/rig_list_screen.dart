import 'dart:async';

import 'package:butane/butane.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:whiteboard_provisioning/whiteboard_provisioning.dart';

import 'device_screen.dart';

/// Scans for nearby whiteboard rigs (peripherals advertising the provisioning
/// service) and lets the user pick one to set up.
class RigListScreen extends StatefulWidget {
  const RigListScreen({super.key, required this.manager});

  final CentralManager manager;

  @override
  State<RigListScreen> createState() => _RigListScreenState();
}

class _RigListScreenState extends State<RigListScreen> {
  final Map<Identifier, ScanResult> _results = {};
  StreamSubscription<PeerManagerState>? _stateSub;
  StreamSubscription<ScanResult>? _scanSub;
  PeerManagerState _state = PeerManagerState.unknown;

  bool get _scanning => _scanSub != null;

  @override
  void initState() {
    super.initState();
    _stateSub = widget.manager.stateStream.listen(_onState);
  }

  void _onState(PeerManagerState state) {
    setState(() => _state = state);
    if (state == PeerManagerState.poweredOn) {
      if (!_scanning) _startScan();
    } else {
      _stopScan();
    }
  }

  void _startScan() {
    _scanSub?.cancel();
    _results.clear();
    _scanSub = widget.manager
        .scan(forServices: [UuidIdentifier(WhiteboardGatt.service)])
        .listen((r) => setState(() => _results[r.peripheral.identifier] = r));
    setState(() {});
  }

  void _stopScan() {
    _scanSub?.cancel();
    _scanSub = null;
    if (mounted) setState(() {});
  }

  Future<void> _openRig(ScanResult result) async {
    _stopScan();
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => DeviceScreen(scanResult: result)),
    );
    if (mounted && _state == PeerManagerState.poweredOn) _startScan();
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    _stateSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Whiteboard Setup'),
        actions: [
          if (_state == PeerManagerState.poweredOn)
            IconButton(
              tooltip: _scanning ? 'Stop' : 'Scan',
              icon: Icon(_scanning ? Icons.stop_rounded : Icons.refresh_rounded),
              onPressed: _scanning ? _stopScan : _startScan,
            ),
        ],
      ),
      body: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    if (_state != PeerManagerState.poweredOn) {
      return _AdapterMessage(state: _state);
    }
    final rigs = _results.values.toList()
      ..sort((a, b) =>
          (b.peripheral.initialRssi ?? -999)
              .compareTo(a.peripheral.initialRssi ?? -999));
    if (rigs.isEmpty) {
      return const _Searching();
    }
    return ListView.separated(
      itemCount: rigs.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) => _RigTile(
        result: rigs[i],
        onTap: () => _openRig(rigs[i]),
      ),
    );
  }
}

class _RigTile extends StatelessWidget {
  const _RigTile({required this.result, required this.onTap});

  final ScanResult result;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final name = result.advertisementData.localName ??
        result.peripheral.name ??
        WhiteboardGatt.advertisedName;
    final rssi = result.peripheral.initialRssi;
    return ListTile(
      leading: const CircleAvatar(child: Icon(Icons.cast_rounded)),
      title: Text(name),
      subtitle: Text(result.peripheral.identifier.toString(),
          maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (rssi != null) ...[
            Icon(_rssiIcon(rssi), size: 20),
            const SizedBox(width: 4),
          ],
          const Icon(Icons.chevron_right_rounded),
        ],
      ),
      onTap: onTap,
    );
  }

  IconData _rssiIcon(int rssi) {
    if (rssi > -60) return Icons.signal_cellular_alt_rounded;
    if (rssi > -75) return Icons.signal_cellular_alt_2_bar_rounded;
    return Icons.signal_cellular_alt_1_bar_rounded;
  }
}

class _Searching extends StatelessWidget {
  const _Searching();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
              width: 28, height: 28, child: CircularProgressIndicator()),
          const SizedBox(height: 16),
          Text('Searching for whiteboard rigs…',
              style: Theme.of(context).textTheme.bodyLarge),
          const SizedBox(height: 4),
          Text('Make sure the rig is powered on and nearby.',
              style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _AdapterMessage extends StatelessWidget {
  const _AdapterMessage({required this.state});

  final PeerManagerState state;

  @override
  Widget build(BuildContext context) {
    final (icon, message) = switch (state) {
      PeerManagerState.poweredOff => (
          Icons.bluetooth_disabled_rounded,
          'Bluetooth is off. Turn it on to find your rig.'
        ),
      PeerManagerState.unauthorized => (
          Icons.lock_rounded,
          'Bluetooth permission is needed. Enable it in Settings.'
        ),
      PeerManagerState.unsupported => (
          Icons.error_outline_rounded,
          'Bluetooth LE isn\'t supported on this device.'
        ),
      _ => (Icons.bluetooth_searching_rounded, 'Starting Bluetooth…'),
    };
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
