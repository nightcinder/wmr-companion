import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vector_math/vector_math_64.dart' as vm;

import '../../domain/hand_pipeline.dart';
import '../../domain/orientation.dart';
import '../../services/controller_service.dart';
import '../connect/connect_providers.dart';
import '../gamepad/gamepad_screen.dart';
import '../../ble/fake_wmr_bridge.dart';
import 'config_panel.dart';
import 'debug_providers.dart';
import 'orientation_painter.dart';
import 'stream_settings.dart';

const _handNames = ['LEFT', 'RIGHT'];

/// The ModeState of [source]'s service, current value first.
final modeStateProvider = StreamProvider.family<ModeState, DebugSource>((
  ref,
  source,
) {
  final service = ref.watch(controllerServiceProvider(source));
  if (service == null) return const Stream.empty();
  // Subscribe before reading the current value, so a change in between is
  // not lost.
  final out = StreamController<ModeState>();
  final sub = service.modeChanges.listen(out.add);
  out.add(service.modeState);
  ref.onDispose(() {
    sub.cancel();
    out.close();
  });
  return out.stream;
});

class DebugScreen extends ConsumerWidget {
  const DebugScreen({super.key, this.source = DebugSource.fake});

  final DebugSource source;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(streamModeProvider);
    final decoded = mode.carriesRecords;
    final synthetic = !decoded && source == DebugSource.fake;
    final hand = ref.watch(selectedHandProvider);
    final view = decoded ? ref.watch(decodedViewProvider(source)).value : null;
    final modeState = decoded || source == DebugSource.real
        ? ref.watch(modeStateProvider(source)).value
        : null;
    final link = ref.watch(linkStatusProvider(source)).value;

    final vm.Quaternion raw = decoded
        ? view?.orientation ?? vm.Quaternion.identity()
        : synthetic
        ? ref.watch(orientationProvider).value ?? vm.Quaternion.identity()
        : vm.Quaternion.identity();
    final yawOffset = ref.watch(yawOffsetProvider);
    final q = synthetic ? removeYaw(raw, yawOffset) : raw;
    final euler = eulerFromQuaternion(q);
    final theme = Theme.of(context);
    final mono = theme.textTheme.bodyMedium?.copyWith(
      fontFamily: 'monospace',
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Debug: 3DoF'),
        actions: [
          IconButton(
            tooltip: 'Gamepad mapping',
            icon: const Icon(Icons.sports_esports),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => GamepadScreen(source: source),
              ),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(_note(mode), style: theme.textTheme.bodySmall),
          const SizedBox(height: 8),
          StreamModeSelector(mode: mode, onChanged: (m) => _setMode(ref, m)),
          if (modeState?.fault != null) ...[
            const SizedBox(height: 8),
            ModeFaultBanner(modeState!.fault!),
          ],
          if (decoded) ...[
            const SizedBox(height: 8),
            SegmentedButton<int>(
              segments: [
                for (var h = 0; h < _handNames.length; h++)
                  ButtonSegment(value: h, label: Text(_handNames[h])),
              ],
              selected: {hand},
              onSelectionChanged: (s) =>
                  ref.read(selectedHandProvider.notifier).set(s.first),
            ),
          ],
          const SizedBox(height: 8),
          SizedBox(
            height: 320,
            child: CustomPaint(
              painter: OrientationPainter(
                q,
                edgeColor: theme.colorScheme.onSurface,
              ),
            ),
          ),
          Text(
            'q  w ${_f(q.w)}  x ${_f(q.x)}  y ${_f(q.y)}  z ${_f(q.z)}',
            style: mono,
          ),
          Text(
            'yaw ${_deg(euler.yawDeg)}  pitch ${_deg(euler.pitchDeg)}  '
            'roll ${_deg(euler.rollDeg)}',
            style: mono,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonal(
                onPressed: () {
                  if (synthetic) {
                    ref.read(yawOffsetProvider.notifier).zeroAt(raw);
                  } else if (decoded) {
                    ref.read(controllerServiceProvider(source))?.resetYaw(hand);
                  }
                },
                child: const Text('Reset orientation'),
              ),
              if (decoded)
                FilledButton.tonal(
                  onPressed: () => ref
                      .read(controllerServiceProvider(source))
                      ?.recalibrate(hand),
                  child: const Text('Recalibrate gyro bias'),
                ),
              if (decoded)
                FilledButton.tonal(
                  onPressed: () => ref
                      .read(controllerServiceProvider(source))
                      ?.recentreStick(hand),
                  child: const Text('Re-centre stick'),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Text('Stream', style: theme.textTheme.titleMedium),
          if (decoded)
            if (view == null)
              const Text('Waiting for the decoded stream...')
            else
              DecodedStatsView(
                view.stats,
                selectedHand: hand,
                style: mono,
                link: link,
              )
          else
            _rawStats(ref, mono),
          const SizedBox(height: 16),
          ConfigPanel(
            key: ValueKey('${source.name}$hand'),
            transport: source == DebugSource.fake
                ? ref.watch(transportProvider)
                : ref.watch(realTransportProvider),
            deviceId: source == DebugSource.fake
                ? fakeBridgeDeviceId
                : ref.watch(realDeviceProvider).deviceId,
            hand: hand,
          ),
          const SizedBox(height: 8),
          const AxisSettingsPanel(),
        ],
      ),
    );
  }

  Widget _rawStats(WidgetRef ref, TextStyle? mono) {
    if (source == DebugSource.real) {
      final stats = ref.watch(realDeviceProvider).stats;
      return stats == null
          ? const Text('Not connected.')
          : StatsTable(stats, style: mono);
    }
    return switch (ref.watch(streamStatsProvider)) {
      AsyncData(:final value) => StatsTable(value, style: mono),
      AsyncError(:final error) => Text('Error: $error'),
      _ => const Text('Connecting...'),
    };
  }

  Future<void> _setMode(WidgetRef ref, StreamMode m) async {
    if (source == DebugSource.real) {
      await ref.read(realDeviceProvider.notifier).setStreamMode(m);
      return;
    }
    ref.read(streamModeProvider.notifier).set(m);
    await ref.read(controllerServiceProvider(source))?.setMode(m);
  }

  String _note(StreamMode mode) {
    final where = source == DebugSource.fake
        ? 'the fake bridge'
        : 'the real bridge';
    if (mode.carriesRecords) {
      final from = mode == StreamMode.batched
          ? 'FF12 records batched on FF14'
          : 'FF12 decoded records';
      return 'Fused orientation from the $from of $where '
          '(gyro + accelerometer only). Yaw drifts: there is no '
          'magnetometer, use Reset orientation to re-zero it. The gyro bias '
          'is taken from the first stationary second, so hold the '
          'controller still after connecting. Not verified on hardware.';
    }
    return source == DebugSource.fake
        ? 'Synthetic orientation: the raw FF11 stream carries no IMU values '
              'the app decodes. Select Decoded FF12 to fuse the fake '
              "bridge's FF12 records instead."
        : 'Raw FF11 mode: no orientation. Select Decoded FF12.';
  }

  static String _f(double v) => v.toStringAsFixed(3).padLeft(6);
  static String _deg(double v) => '${v.toStringAsFixed(1).padLeft(6)}°';
}

/// Raw FF11, decoded FF12 or batched FF14. The app listens to one at a
/// time.
class StreamModeSelector extends StatelessWidget {
  const StreamModeSelector({
    super.key,
    required this.mode,
    required this.onChanged,
    this.enabled = true,
  });

  final StreamMode mode;
  final ValueChanged<StreamMode> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<StreamMode>(
      segments: [
        ButtonSegment(
          value: StreamMode.raw,
          label: const Text('Raw FF11'),
          enabled: enabled,
        ),
        ButtonSegment(
          value: StreamMode.decoded,
          label: const Text('Decoded FF12'),
          enabled: enabled,
        ),
        ButtonSegment(
          value: StreamMode.batched,
          label: const Text('Batched FF14'),
          enabled: enabled,
        ),
      ],
      selected: {mode},
      onSelectionChanged: (s) => onChanged(s.first),
    );
  }
}

/// A stream-mode failure, in words. Never hidden.
class ModeFaultBanner extends StatelessWidget {
  const ModeFaultBanner(this.fault, {super.key});

  final ModeFault fault;

  static String title(ModeFaultKind kind) => switch (kind) {
    ModeFaultKind.otherStreamActive =>
      'The bridge refused: another stream is still enabled (ATT 0x80)',
    ModeFaultKind.enableFailed => 'Could not enable the stream',
    ModeFaultKind.disableFailed =>
      'Could not turn the previous stream off, so nothing was switched',
    ModeFaultKind.mtuTooSmall => 'ATT MTU too small for this stream',
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(8),
      color: scheme.errorContainer,
      child: Text(
        '${title(fault.kind)}\n${fault.message}',
        style: TextStyle(color: scheme.onErrorContainer),
      ),
    );
  }
}

class DecodedStatsView extends StatelessWidget {
  const DecodedStatsView(
    this.stats, {
    super.key,
    required this.selectedHand,
    this.style,
    this.link,
  });

  final DecodedStats stats;
  final int selectedHand;
  final TextStyle? style;

  /// BLE link state and parameters, when the debug screen has a transport.
  final LinkStatus? link;

  static String _ms(double s) => (s * 1000).toStringAsFixed(2);
  static String _sgn(double v) => '${v >= 0 ? '+' : ''}${v.toStringAsFixed(4)}';
  static String _pct(double v) => '${(v * 100).toStringAsFixed(1)}%';

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _link(),
        for (var h = 0; h < stats.hands.length; h++)
          ..._hand(h, stats.hands[h]),
        Text(
          'parse errors  length ${stats.wrongLength}  '
          'version ${stats.unknownVersion}  hand ${stats.badHand}',
          style: style,
        ),
        if (stats.batches > 0 || stats.batchErrors > 0)
          Text(
            'FF14 batches ${stats.batches}  '
            'mean ${stats.batchMean?.toStringAsFixed(2) ?? '-'}  '
            'max ${stats.batchMax}  rejected ${stats.batchErrors}',
            style: style,
          ),
      ],
    );
  }

  Widget _link() {
    final l = link;
    if (l == null) return Text('link n/a', style: style);
    final parts = <String>[
      'link ${l.state?.name ?? 'n/a'}',
      'RSSI ${l.info?.rssi == null ? 'n/a' : '${l.info!.rssi} dBm'}',
    ];
    final mtu = l.info?.mtu;
    if (mtu != null) parts.add('MTU $mtu');
    final interval = l.info?.connectionIntervalUs;
    if (interval != null) {
      parts.add('${(interval / 1000).toStringAsFixed(1)} ms');
    }
    final phy = l.info?.phy;
    if (phy != null) parts.add('PHY $phy');
    return Text(parts.join('  '), style: style);
  }

  List<Widget> _hand(int h, DecodedHandStats s) {
    final mark = h == selectedHand ? '*' : ' ';
    final bias = s.biasCalibrated
        ? 'calibrated'
        : 'calibrating ${(s.biasProgress * 100).round()}%';
    final ratio = s.tickClockRatio;
    return [
      Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(
          '$mark${_handNames[h].padRight(5)} records ${s.records}  '
          'rate ${s.rateHz.toStringAsFixed(1)} Hz  '
          'seq ${s.lastSequence ?? '-'}',
          style: style,
        ),
      ),
      Text(
        '  seq gaps ${s.sequenceGaps}  missing (ticks) ${s.missingFromTicks}  '
        'out of order ${s.outOfOrder}',
        style: style,
      ),
      Text(
        '  loss ${_pct(s.cumulativeLoss)} cumulative  '
        '${s.windowLoss == null ? '-' : _pct(s.windowLoss!.loss)} last 5 s',
        style: style,
      ),
      Text(
        '  nominal period ${s.periodTicks == null ? '-' : '${(s.periodTicks! * 1e-4).toStringAsFixed(2)} ms (${s.periodTicks} ticks)'}',
        style: style,
      ),
      Text(
        '  dt p50 ${_ms(s.dt.p50)} ms  p95 ${_ms(s.dt.p95)} ms  '
        'max ${_ms(s.dt.max)} ms',
        style: style,
      ),
      Text(
        '  gyro bias x ${_sgn(s.bias[0])} y ${_sgn(s.bias[1])} '
        'z ${_sgn(s.bias[2])} rad/s ($bias)',
        style: style,
      ),
      Text(
        '  stick centre x ${_sgn(s.stickCentre[0])} y ${_sgn(s.stickCentre[1])} '
        '(${s.stickLearned ? 'learned/set ${s.stickCentreUpdates}x' : 'not set'})  '
        'out x ${_sgn(s.stick[0])} y ${_sgn(s.stick[1])}',
        style: style,
      ),
      Text(
        '  tick discontinuities ${s.discontinuities}  '
        'dt > 100 ms skipped ${s.largeDtSkips}  '
        'tick/clock ${ratio == null ? '-' : ratio.toStringAsFixed(3)}',
        style: style,
      ),
    ];
  }
}

/// Filter choice and the axis table with per-axis flips. A backwards axis is
/// one toggle, no rebuild.
class AxisSettingsPanel extends ConsumerWidget {
  const AxisSettingsPanel({super.key});

  static const _axes = ['X', 'Y', 'Z'];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mapping = ref.watch(axisMappingProvider);
    final notifier = ref.read(axisMappingProvider.notifier);
    final filter = ref.watch(filterKindProvider);
    final stickConfig = ref.watch(stickConfigProvider);
    final stickNotifier = ref.read(stickSettingsProvider.notifier);
    final theme = Theme.of(context);
    return ExpansionTile(
      title: const Text('Debug settings'),
      tilePadding: EdgeInsets.zero,
      childrenPadding: EdgeInsets.zero,
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SegmentedButton<FilterKind>(
          segments: const [
            ButtonSegment(value: FilterKind.madgwick, label: Text('Madgwick')),
            ButtonSegment(value: FilterKind.mahony, label: Text('Mahony')),
          ],
          selected: {filter},
          onSelectionChanged: (s) =>
              ref.read(filterKindProvider.notifier).set(s.first),
        ),
        const SizedBox(height: 8),
        Text(
          'Sensor to view axes: ${mapping.toString()}',
          style: theme.textTheme.bodyMedium?.copyWith(fontFamily: 'monospace'),
        ),
        Text(
          'Default from raw captures (X right, Y up, Z toward you); the sign '
          'of the vertical axis is unverified.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        const Text('Flip view axis (gyro and accel)'),
        Wrap(
          spacing: 8,
          children: [
            for (var i = 0; i < 3; i++)
              FilterChip(
                label: Text('Flip ${_axes[i]}'),
                selected: mapping.flip[i],
                onSelected: (v) => notifier.setFlip(i, v),
              ),
          ],
        ),
        const SizedBox(height: 8),
        const Text('Flip rotation sense (gyro only)'),
        Wrap(
          spacing: 8,
          children: [
            for (var i = 0; i < 3; i++)
              FilterChip(
                label: Text('Gyro ${_axes[i]}'),
                selected: mapping.gyroFlip[i],
                onSelected: (v) => notifier.setGyroFlip(i, v),
              ),
          ],
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: notifier.reset,
            child: const Text('Reset to default table'),
          ),
        ),
        const SizedBox(height: 8),
        Text('Stick dead zone ${stickConfig.deadZone.toStringAsFixed(2)}'),
        Slider(
          value: stickConfig.deadZone,
          max: 0.3,
          divisions: 30,
          onChanged: stickNotifier.setDeadZone,
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Learn stick rest centre'),
          subtitle: const Text(
            'Takes the stick position as centre after about 1 s still, inside '
            'a quarter of full scale, with the controller otherwise untouched.',
          ),
          value: stickConfig.learn,
          onChanged: stickNotifier.setLearn,
        ),
      ],
    );
  }
}

class StatsTable extends StatelessWidget {
  const StatsTable(this.stats, {super.key, this.style});

  final StreamStats stats;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var h = 0; h < stats.hands.length; h++)
          Text(
            '${_handNames[h].padRight(5)}  frames ${stats.hands[h].frames}  '
            'seq ${stats.hands[h].lastSequence ?? '-'}  '
            'gaps ${stats.hands[h].gaps}  '
            'incomplete ${stats.hands[h].incomplete}',
            style: style,
          ),
        Text('fragment errors ${stats.errors}', style: style),
      ],
    );
  }
}
