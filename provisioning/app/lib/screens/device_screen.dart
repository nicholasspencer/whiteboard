import 'package:butane/butane.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:whiteboard_provisioning/whiteboard_provisioning.dart';

import '../device_controller.dart';
import '../framing/framing_screen.dart';

/// The setup screen for one rig: connection status, device info, a Wi-Fi
/// network picker, and live provisioning progress.
class DeviceScreen extends StatefulWidget {
  const DeviceScreen({super.key, required this.scanResult});

  final ScanResult scanResult;

  @override
  State<DeviceScreen> createState() => _DeviceScreenState();
}

class _DeviceScreenState extends State<DeviceScreen> {
  late final DeviceController _controller =
      DeviceController(widget.scanResult.peripheral);

  @override
  void initState() {
    super.initState();
    _controller.open();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String get _fallbackName =>
      widget.scanResult.advertisementData.localName ??
      widget.scanResult.peripheral.name ??
      WhiteboardGatt.advertisedName;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final currentSsid = _controller.info?.currentSsid ?? '';
        return Scaffold(
          appBar: AppBar(
            title: Text(_controller.info?.label ?? _fallbackName),
            actions: [
              if (currentSsid.isNotEmpty)
                PopupMenuButton<String>(
                  onSelected: (_) => _confirmForget(currentSsid),
                  itemBuilder: (_) => [
                    PopupMenuItem<String>(
                      value: 'forget',
                      child: Text('Forget "$currentSsid"'),
                    ),
                  ],
                ),
            ],
          ),
          body: _body(context),
        );
      },
    );
  }

  Widget _body(BuildContext context) {
    if (_controller.fault != null) return _Fault(message: _controller.fault!);
    if (!_controller.isReady) return const _Connecting();

    final status = _controller.status;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (status != null) _StatusBanner(status: status),
        if (status != null) const SizedBox(height: 16),
        _InfoCard(info: _controller.info),
        const SizedBox(height: 12),
        _CameraCard(
          ip: _controller.info?.ip,
          onFrame: _openFraming,
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            Text('Wi-Fi networks',
                style: Theme.of(context).textTheme.titleMedium),
            const Spacer(),
            FilledButton.tonalIcon(
              onPressed: _controller.scanningNetworks
                  ? null
                  : _controller.scanNetworks,
              icon: const Icon(Icons.wifi_find_rounded, size: 18),
              label: const Text('Scan'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (_controller.scanningNetworks) const LinearProgressIndicator(),
        for (final network in _controller.networks)
          _NetworkTile(network: network, onTap: () => _promptPassword(network)),
        if (!_controller.scanningNetworks && _controller.networks.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 28),
            child: Center(
                child: Text('Tap Scan to list nearby Wi-Fi networks.')),
          ),
      ],
    );
  }

  Future<void> _promptPassword(WifiNetwork network) async {
    final result = await showModalBottomSheet<({String psk})>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _PasswordSheet(network: network),
    );
    if (result != null) {
      await _controller.provision(network.ssid, result.psk);
    }
  }

  Future<void> _confirmForget(String ssid) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Forget "$ssid"?'),
        content: const Text('The rig will stop auto-joining this network.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Forget')),
        ],
      ),
    );
    if (ok == true) await _controller.forget(ssid);
  }

  void _openFraming() {
    final info = _controller.info;
    final ip = info?.ip;
    if (ip == null || ip.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FramingScreen(
          host: ip,
          title: info?.label ?? _fallbackName,
        ),
      ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.status});

  final StatusReport status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (Color color, IconData icon, String text) = switch (status.state) {
      ProvisionState.idle => (
          scheme.surfaceContainerHighest,
          Icons.info_outline_rounded,
          'Idle'
        ),
      ProvisionState.scanning => (
          scheme.secondaryContainer,
          Icons.wifi_find_rounded,
          'Scanning Wi-Fi…'
        ),
      ProvisionState.applying => (
          scheme.secondaryContainer,
          Icons.sync_rounded,
          'Applying credentials…'
        ),
      ProvisionState.connecting => (
          scheme.secondaryContainer,
          Icons.wifi_tethering_rounded,
          'Joining ${status.ssid ?? "network"}…'
        ),
      ProvisionState.connected => (
          Colors.green.withValues(alpha: 0.18),
          Icons.check_circle_rounded,
          'Connected to ${status.ssid ?? "Wi-Fi"}'
              '${status.ip != null ? " (${status.ip})" : ""}'
        ),
      ProvisionState.failed => (
          scheme.errorContainer,
          Icons.error_rounded,
          'Failed: ${status.error ?? "unknown error"}'
        ),
    };
    final busy = status.state == ProvisionState.scanning ||
        status.state == ProvisionState.applying ||
        status.state == ProvisionState.connecting;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          busy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : Icon(icon),
          const SizedBox(width: 12),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.info});

  final DeviceInfo? info;

  @override
  Widget build(BuildContext context) {
    final i = info;
    final connected = (i?.currentSsid ?? '').isNotEmpty;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _row(context, Icons.cast_rounded, 'Rig', i?.label ?? '—'),
            _row(context, Icons.memory_rounded, 'Model', i?.model ?? '—'),
            _row(
              context,
              Icons.wifi_rounded,
              'Network',
              connected
                  ? '${i!.currentSsid}${i.ip != null ? "  •  ${i.ip}" : ""}'
                  : 'Not connected',
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(
      BuildContext context, IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 10),
          SizedBox(
            width: 72,
            child:
                Text(label, style: Theme.of(context).textTheme.labelMedium),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}

class _CameraCard extends StatelessWidget {
  const _CameraCard({required this.ip, required this.onFrame});

  final String? ip;
  final VoidCallback onFrame;

  @override
  Widget build(BuildContext context) {
    final online = (ip ?? '').isNotEmpty;
    return Card(
      child: ListTile(
        leading: const Icon(Icons.videocam_rounded),
        title: const Text('Frame camera'),
        subtitle: Text(online
            ? 'Live preview to aim and rotate the camera'
            : 'Connect the rig to Wi-Fi first'),
        trailing: const Icon(Icons.chevron_right_rounded),
        enabled: online,
        onTap: online ? onFrame : null,
      ),
    );
  }
}

class _NetworkTile extends StatelessWidget {
  const _NetworkTile({required this.network, required this.onTap});

  final WifiNetwork network;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(_signalIcon(network.signal)),
      title: Text(network.ssid.isEmpty ? '(hidden)' : network.ssid),
      subtitle: Text(network.isOpen ? 'Open' : network.security),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (network.active)
            const Icon(Icons.check_circle_rounded,
                color: Colors.green, size: 18),
          if (network.active) const SizedBox(width: 6),
          if (!network.isOpen) const Icon(Icons.lock_rounded, size: 16),
        ],
      ),
      onTap: onTap,
    );
  }

  IconData _signalIcon(int signal) {
    if (signal >= 75) return Icons.network_wifi_rounded;
    if (signal >= 50) return Icons.network_wifi_3_bar_rounded;
    if (signal >= 25) return Icons.network_wifi_2_bar_rounded;
    return Icons.network_wifi_1_bar_rounded;
  }
}

class _PasswordSheet extends StatefulWidget {
  const _PasswordSheet({required this.network});

  final WifiNetwork network;

  @override
  State<_PasswordSheet> createState() => _PasswordSheetState();
}

class _PasswordSheetState extends State<_PasswordSheet> {
  final TextEditingController _password = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, (psk: _password.text));

  @override
  Widget build(BuildContext context) {
    final open = widget.network.isOpen;
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Join "${widget.network.ssid}"',
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          if (!open)
            TextField(
              controller: _password,
              autofocus: true,
              obscureText: _obscure,
              decoration: InputDecoration(
                labelText: 'Password',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(_obscure
                      ? Icons.visibility_rounded
                      : Icons.visibility_off_rounded),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
              onSubmitted: (_) => _submit(),
            )
          else
            const Text('This is an open network — no password needed.'),
          const SizedBox(height: 16),
          FilledButton(onPressed: _submit, child: const Text('Connect')),
        ],
      ),
    );
  }
}

class _Connecting extends StatelessWidget {
  const _Connecting();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(width: 28, height: 28, child: CircularProgressIndicator()),
          SizedBox(height: 16),
          Text('Connecting to rig…'),
        ],
      ),
    );
  }
}

class _Fault extends StatelessWidget {
  const _Fault({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline_rounded,
                size: 48, color: Theme.of(context).colorScheme.error),
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
