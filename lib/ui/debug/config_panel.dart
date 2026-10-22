import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ble/ble_transport.dart';
import '../../services/config_client.dart';
import '../../services/config_report.dart';

/// Reads a controller's config block (FF13), checks its CRC and shows the
/// decoded inertial calibration. Read-only; the values are not applied.
class ConfigPanel extends ConsumerStatefulWidget {
  const ConfigPanel({
    super.key,
    required this.transport,
    required this.deviceId,
    required this.hand,
  });

  final BleTransport? transport;
  final String? deviceId;
  final int hand;

  @override
  ConsumerState<ConfigPanel> createState() => _ConfigPanelState();
}

class _ConfigPanelState extends ConsumerState<ConfigPanel> {
  List<String>? _lines;
  bool _busy = false;

  Future<void> _read() async {
    final t = widget.transport;
    final id = widget.deviceId;
    if (t == null || id == null) return;
    setState(() => _busy = true);
    final lines = await readConfigReport(ConfigClient(t, id), widget.hand);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _lines = lines;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mono = theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace');
    final ready = widget.transport != null && widget.deviceId != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Controller config', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        OutlinedButton(
          onPressed: ready && !_busy ? _read : null,
          child: Text(
            _busy
                ? 'Reading...'
                : 'Read config (${widget.hand == 0 ? 'LEFT' : 'RIGHT'})',
          ),
        ),
        if (_lines != null)
          for (final l in _lines!) Text(l, style: mono),
      ],
    );
  }
}
