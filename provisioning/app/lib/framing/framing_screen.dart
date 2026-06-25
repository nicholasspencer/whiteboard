import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'camera_client.dart';
import 'camera_config_screen.dart';
import 'framing_controller.dart';

/// Live camera framing for a rig that's on Wi-Fi: a WebRTC preview to aim the
/// camera, quick rotation, a real test shot, and the full config editor.
class FramingScreen extends StatefulWidget {
  const FramingScreen({
    super.key,
    required this.host,
    required this.title,
    this.port = 8080,
    this.token,
  });

  final String host;
  final String title;
  final int port;
  final String? token;

  @override
  State<FramingScreen> createState() => _FramingScreenState();
}

class _FramingScreenState extends State<FramingScreen> {
  late final FramingController _controller = FramingController(
    client: CameraClient(
        host: widget.host, port: widget.port, token: widget.token),
  );

  @override
  void initState() {
    super.initState();
    _controller.start();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        return Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            title: Text('Frame ${_controller.config?.label ?? widget.title}'),
            actions: [
              if (_controller.config != null)
                IconButton(
                  tooltip: 'Camera settings',
                  icon: const Icon(Icons.tune_rounded),
                  onPressed: _openSettings,
                ),
            ],
          ),
          body: SafeArea(child: _body(context)),
        );
      },
    );
  }

  Widget _body(BuildContext context) {
    switch (_controller.phase) {
      case FramingPhase.connecting:
        return const _Centered(
            icon: null, text: 'Starting live preview…', spinner: true);
      case FramingPhase.error:
        return _ErrorView(
          message: _controller.error ?? 'Something went wrong.',
          onRetry: () => _controller.start(),
        );
      case FramingPhase.live:
      case FramingPhase.reconnecting:
        return _liveView(context);
    }
  }

  Widget _liveView(BuildContext context) {
    return Column(
      children: [
        Expanded(child: _preview()),
        _controlsBar(context),
      ],
    );
  }

  Widget _preview() {
    final reconnecting = _controller.phase == FramingPhase.reconnecting;
    return Stack(
      fit: StackFit.expand,
      children: [
        Container(color: Colors.black),
        if (_controller.hasVideo)
          RotatedBox(
            quarterTurns: (_controller.rotation ~/ 90) % 4,
            child: RTCVideoView(
              _controller.renderer,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
            ),
          )
        else
          const _Centered(text: 'Waiting for video…', spinner: true),
        // Rule-of-thirds aiming grid.
        if (_controller.hasVideo)
          const Positioned.fill(
            child: IgnorePointer(child: CustomPaint(painter: _GridPainter())),
          ),
        if (reconnecting)
          Container(
            color: Colors.black54,
            child: const _Centered(text: 'Reconnecting…', spinner: true),
          ),
      ],
    );
  }

  Widget _controlsBar(BuildContext context) {
    final rotation = _controller.rotation;
    final busy = _controller.savingConfig || _controller.testShotBusy;
    return Container(
      color: Theme.of(context).colorScheme.surface,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(Icons.screen_rotation_rounded, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: SegmentedButton<int>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: 0, label: Text('0°')),
                    ButtonSegment(value: 90, label: Text('90°')),
                    ButtonSegment(value: 180, label: Text('180°')),
                    ButtonSegment(value: 270, label: Text('270°')),
                  ],
                  selected: {rotation},
                  onSelectionChanged: busy
                      ? null
                      : (s) => _controller.setRotation(s.first),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: _controller.testShotBusy ? null : _takeTestShot,
                  icon: _controller.testShotBusy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.camera_rounded, size: 18),
                  label: const Text('Test photo'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _controller.config == null ? null : _openSettings,
                  icon: const Icon(Icons.tune_rounded, size: 18),
                  label: const Text('Settings'),
                ),
              ),
            ],
          ),
          if (_controller.error != null) ...[
            const SizedBox(height: 10),
            Text(
              _controller.error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _takeTestShot() async {
    final bytes = await _controller.takeTestShot();
    if (!mounted || bytes == null) return;
    await showDialog<void>(
      context: context,
      builder: (_) => _TestShotDialog(bytes: bytes),
    );
  }

  Future<void> _openSettings() async {
    final current = _controller.config;
    if (current == null) return;
    final draft = await Navigator.of(context).push<CameraConfig>(
      MaterialPageRoute(
        builder: (_) => CameraConfigScreen(initial: current),
      ),
    );
    if (draft != null) await _controller.saveConfig(draft);
  }
}

class _TestShotDialog extends StatelessWidget {
  const _TestShotDialog({required this.bytes});

  final Uint8List bytes;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                const Icon(Icons.check_circle_rounded,
                    color: Colors.green, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Actual saved photo',
                      style: Theme.of(context).textTheme.titleMedium),
                ),
              ],
            ),
          ),
          Flexible(child: InteractiveViewer(child: Image.memory(bytes))),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              'This is exactly what /capture produces — rotation and all.',
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(0, 0, 12, 12),
              child: TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Done'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Rule-of-thirds grid to help line up the board.
class _GridPainter extends CustomPainter {
  const _GridPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.25)
      ..strokeWidth = 1;
    for (var i = 1; i < 3; i++) {
      final dx = size.width * i / 3;
      final dy = size.height * i / 3;
      canvas.drawLine(Offset(dx, 0), Offset(dx, size.height), paint);
      canvas.drawLine(Offset(0, dy), Offset(size.width, dy), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _GridPainter oldDelegate) => false;
}

class _Centered extends StatelessWidget {
  const _Centered({this.icon, required this.text, this.spinner = false});

  final IconData? icon;
  final String text;
  final bool spinner;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (spinner)
            const SizedBox(
                width: 28, height: 28, child: CircularProgressIndicator())
          else if (icon != null)
            Icon(icon, size: 40, color: Colors.white70),
          const SizedBox(height: 16),
          Text(text, style: const TextStyle(color: Colors.white70)),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.videocam_off_rounded,
                size: 48, color: Colors.white60),
            const SizedBox(height: 16),
            Text(message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }
}
