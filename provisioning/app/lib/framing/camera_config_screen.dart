import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'camera_client.dart';

/// Full camera config editor. Mirrors every editable field the server exposes
/// (`whiteboard-server.ts`). Returns an edited [CameraConfig] on save; the
/// caller diffs it against the live config and POSTs only what changed.
class CameraConfigScreen extends StatefulWidget {
  const CameraConfigScreen({super.key, required this.initial});

  final CameraConfig initial;

  @override
  State<CameraConfigScreen> createState() => _CameraConfigScreenState();
}

class _CameraConfigScreenState extends State<CameraConfigScreen> {
  late final _label = TextEditingController(text: widget.initial.label);
  late final _token = TextEditingController(text: widget.initial.token);
  late final _width = TextEditingController(text: '${widget.initial.width}');
  late final _height = TextEditingController(text: '${widget.initial.height}');
  late final _timeout =
      TextEditingController(text: '${widget.initial.timeoutMs}');
  late final _extra = TextEditingController(text: widget.initial.extra);
  late final _hdrBracket =
      TextEditingController(text: widget.initial.hdrBracket);
  late final _enfuseArgs =
      TextEditingController(text: widget.initial.enfuseArgs);
  late final _watchInterval =
      TextEditingController(text: '${widget.initial.watchIntervalMs}');
  late final _watchThreshold =
      TextEditingController(text: '${widget.initial.watchThreshold}');
  late final _watchStableEps =
      TextEditingController(text: '${widget.initial.watchStableEps}');
  late final _watchWidth =
      TextEditingController(text: '${widget.initial.watchWidth}');
  late final _watchHeight =
      TextEditingController(text: '${widget.initial.watchHeight}');

  late int _rotate = widget.initial.rotateDegrees;
  late String _hdr = widget.initial.hdr;
  bool _obscureToken = true;

  @override
  void dispose() {
    for (final c in [
      _label, _token, _width, _height, _timeout, _extra, _hdrBracket,
      _enfuseArgs, _watchInterval, _watchThreshold, _watchStableEps,
      _watchWidth, _watchHeight,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    final i = widget.initial;
    final draft = CameraConfig(
      label: _label.text.trim(),
      token: _token.text,
      width: int.tryParse(_width.text.trim()) ?? i.width,
      height: int.tryParse(_height.text.trim()) ?? i.height,
      timeoutMs: int.tryParse(_timeout.text.trim()) ?? i.timeoutMs,
      extra: _extra.text.trim(),
      rotate: _rotate == 0 ? '' : '$_rotate',
      hdr: _hdr,
      hdrBracket: _hdrBracket.text.trim(),
      enfuseArgs: _enfuseArgs.text.trim(),
      watchIntervalMs: int.tryParse(_watchInterval.text.trim()) ?? i.watchIntervalMs,
      watchWidth: int.tryParse(_watchWidth.text.trim()) ?? i.watchWidth,
      watchHeight: int.tryParse(_watchHeight.text.trim()) ?? i.watchHeight,
      watchThreshold: double.tryParse(_watchThreshold.text.trim()) ?? i.watchThreshold,
      watchStableEps: double.tryParse(_watchStableEps.text.trim()) ?? i.watchStableEps,
    );
    Navigator.of(context).pop(draft);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Camera settings'),
        actions: [
          TextButton(onPressed: _save, child: const Text('Save')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _section('Identity'),
          _text(_label, 'Label', hint: 'Conference Room A'),
          _text(_token, 'Access token',
              hint: 'leave empty for an open rig',
              obscure: _obscureToken,
              suffix: IconButton(
                icon: Icon(_obscureToken
                    ? Icons.visibility_rounded
                    : Icons.visibility_off_rounded),
                onPressed: () => setState(() => _obscureToken = !_obscureToken),
              )),

          _section('Image'),
          Row(
            children: [
              Expanded(child: _number(_width, 'Width')),
              const SizedBox(width: 12),
              Expanded(child: _number(_height, 'Height')),
            ],
          ),
          const SizedBox(height: 12),
          _presetRow(),
          const SizedBox(height: 16),
          _label2('Rotation'),
          SegmentedButton<int>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 0, label: Text('0°')),
              ButtonSegment(value: 90, label: Text('90°')),
              ButtonSegment(value: 180, label: Text('180°')),
              ButtonSegment(value: 270, label: Text('270°')),
            ],
            selected: {_rotate},
            onSelectionChanged: (s) => setState(() => _rotate = s.first),
          ),

          _section('Exposure & focus'),
          _text(_extra, 'Extra rpicam args',
              hint: '--autofocus-mode manual --lens-position 1.0 --awb auto',
              maxLines: 2,
              help:
                  'libcamera flags for focus / white-balance / exposure. With HDR '
                  'on, leave --shutter/--gain out — the bracket drives them.'),
          const SizedBox(height: 16),
          _label2('HDR'),
          SegmentedButton<String>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 'auto', label: Text('Auto')),
              ButtonSegment(value: 'on', label: Text('On')),
              ButtonSegment(value: 'off', label: Text('Off')),
            ],
            selected: {_hdr},
            onSelectionChanged: (s) => setState(() => _hdr = s.first),
          ),
          const SizedBox(height: 12),
          _text(_hdrBracket, 'HDR bracket',
              hint: '15000:1.0,150000:1.0,1000000:2.0',
              help: 'shutterMicros:gain stops, fused with enfuse.'),
          _text(_enfuseArgs, 'enfuse args',
              hint: '--saturation-weight=0 --compression=90'),
          const SizedBox(height: 12),
          _number(_timeout, 'Capture warmup (ms)',
              help: 'rpicam settle time before the frame; ≥ the shutter time.'),

          _section('Change watcher'),
          _number(_watchInterval, 'Interval (ms, 0 = off)'),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: _number(_watchThreshold, 'Change threshold')),
              const SizedBox(width: 12),
              Expanded(child: _number(_watchStableEps, 'Stable epsilon')),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: _number(_watchWidth, 'Thumb width')),
              const SizedBox(width: 12),
              Expanded(child: _number(_watchHeight, 'Thumb height')),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Threshold = board-vs-committed diff that counts as a change. '
            'Stable epsilon = frame-to-frame diff below which the scene is "still". '
            'Watch /state to read the live noise floor.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _presetRow() {
    Widget chip(String label, int w, int h) => ActionChip(
          label: Text(label),
          onPressed: () => setState(() {
            _width.text = '$w';
            _height.text = '$h';
          }),
        );
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        chip('1536×864', 1536, 864),
        chip('2304×1296', 2304, 1296),
        chip('4608×2592', 4608, 2592),
      ],
    );
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(0, 24, 0, 8),
        child: Text(title,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(color: Theme.of(context).colorScheme.primary)),
      );

  Widget _label2(String title) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(title, style: Theme.of(context).textTheme.labelLarge),
      );

  Widget _text(
    TextEditingController c,
    String label, {
    String? hint,
    String? help,
    bool obscure = false,
    int maxLines = 1,
    Widget? suffix,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: c,
        obscureText: obscure,
        maxLines: obscure ? 1 : maxLines,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          helperText: help,
          helperMaxLines: 3,
          border: const OutlineInputBorder(),
          suffixIcon: suffix,
        ),
      ),
    );
  }

  Widget _number(TextEditingController c, String label, {String? help}) {
    return TextField(
      controller: c,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
      decoration: InputDecoration(
        labelText: label,
        helperText: help,
        helperMaxLines: 2,
        border: const OutlineInputBorder(),
      ),
    );
  }
}
