import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ble/ble_transport.dart';
import '../../domain/imu_calibration.dart';
import '../../services/config_client.dart';
import '../../services/config_key_store.dart';
import '../../services/config_report.dart';
import 'stream_settings.dart';

/// Reads a controller's config block (FF13), checks its CRC and shows the
/// decoded inertial calibration. The "Apply FF13 calibration" switch turns
/// the decoded calibration on for this hand; it starts off and is enabled
/// only after a successful read.
class ConfigPanel extends ConsumerStatefulWidget {
  const ConfigPanel({
    super.key,
    required this.transport,
    required this.deviceId,
    required this.hand,
    this.keyLoader,
  });

  final BleTransport? transport;
  final String? deviceId;
  final int hand;

  /// For tests; the app uses the bundled key from [loadConfigKey].
  final Future<ConfigKeyResult> Function()? keyLoader;

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
    final report = await readConfigReport(
      ConfigClient(t, id),
      widget.hand,
      keyLoader: widget.keyLoader,
    );
    if (!mounted) return;
    final calibration = report.calibration == null
        ? null
        : ImuCalibration.fromController(report.calibration!);
    ref
        .read(ff13SettingsProvider.notifier)
        .setCalibration(widget.hand, calibration);
    setState(() {
      _busy = false;
      _lines = report.lines;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mono = theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace');
    final ready = widget.transport != null && widget.deviceId != null;
    final handName = widget.hand == 0 ? 'LEFT' : 'RIGHT';
    final settings = ref.watch(ff13SettingsProvider);
    final calibration = settings.calibrations[widget.hand];
    final applying = settings.apply[widget.hand];
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
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Apply FF13 calibration'),
          subtitle: Text(
            calibration == null
                ? 'Read the config first; calibration is not applied.'
                : applying
                ? 'Active for $handName: mix matrix, bias and inverse Rt '
                      'before the axis map.'
                : 'Read and ready; off for $handName.',
          ),
          value: applying,
          onChanged: calibration == null
              ? null
              : (v) => ref
                    .read(ff13SettingsProvider.notifier)
                    .setApply(widget.hand, v),
        ),
        if (_lines != null)
          for (final l in _lines!) Text(l, style: mono),
      ],
    );
  }
}
