import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/latency_recorder.dart';
import '../debug/debug_providers.dart';
import 'latency_providers.dart';

/// Link timing test with CSV/JSON export (milestone 4). Measures what the
/// phone can see on its own; no true round trip (WMR_Bridge issue #1). Not
/// verified on hardware.
class LatencyScreen extends ConsumerWidget {
  const LatencyScreen({super.key, this.source = DebugSource.real});

  final DebugSource source;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(latencyControllerProvider);
    final c = ref.read(latencyControllerProvider.notifier);
    final theme = Theme.of(context);
    final mono = theme.textTheme.bodyMedium?.copyWith(fontFamily: 'monospace');
    final running = s.stage == LatencyStage.running;

    return PopScope(
      canPop: !running,
      child: Scaffold(
        appBar: AppBar(title: const Text('Latency')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Not verified on hardware. Measures what the phone sees: '
              'inter-arrival, sequence gaps, tick-based loss and (decoded '
              'streams) one-way delay variation from the ESP32 receive time. '
              'Round trip uses the bridge\'s FF15 echo (WMR_Bridge #13); the '
              'firmware has not been run on hardware either.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            if (s.error != null)
              Text(s.error!, style: TextStyle(color: theme.colorScheme.error)),
            Text('Run length', style: theme.textTheme.labelLarge),
            const SizedBox(height: 4),
            SegmentedButton<int?>(
              segments: [
                for (final d in latencyDurations)
                  ButtonSegment(
                    value: d,
                    label: Text(d == null ? 'Until stop' : '$d s'),
                  ),
              ],
              selected: {s.durationSeconds},
              onSelectionChanged: running
                  ? null
                  : (v) => c.selectDuration(v.first),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Measure round trip (FF15 echo)'),
              subtitle: const Text(
                'A small ping four times a second: about 480 in a 120 s run.',
              ),
              value: s.echoEnabled,
              onChanged: running ? null : c.setEchoEnabled,
            ),
            if (s.echoNote != null)
              Text(
                s.echoNote!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (s.stage == LatencyStage.idle)
                  FilledButton(
                    onPressed: () => c.start(source),
                    child: const Text('Start'),
                  ),
                if (running)
                  FilledButton(onPressed: c.stop, child: const Text('Stop')),
                if (s.stage == LatencyStage.finished) ...[
                  if (s.saved != null)
                    FilledButton.icon(
                      onPressed: () => c.share(s.saved!),
                      icon: const Icon(Icons.share),
                      label: Text(
                        s.saved!.echoCsvPath == null
                            ? 'Export CSV + JSON'
                            : 'Export CSV + JSON + echo',
                      ),
                    ),
                  OutlinedButton(
                    onPressed: c.reset,
                    child: const Text('New run'),
                  ),
                ],
                if (running)
                  Text(
                    s.durationSeconds == null
                        ? '${s.elapsedSeconds} s'
                        : '${s.elapsedSeconds} / ${s.durationSeconds} s',
                    style: theme.textTheme.titleMedium,
                  ),
              ],
            ),
            if (s.report != null) ...[
              const SizedBox(height: 16),
              LatencyReportView(s.report!, style: mono),
            ],
            if (s.saved != null) ...[
              const SizedBox(height: 8),
              Text('Saved', style: theme.textTheme.labelMedium),
              SelectableText(s.saved!.csvPath, style: mono),
            ],
            const SizedBox(height: 16),
            Text('Saved runs', style: theme.textTheme.titleMedium),
            if (s.runs.isEmpty) const Text('None yet.'),
            for (final r in s.runs)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(r.name),
                subtitle: Text(
                  r.echoCsvPath == null
                      ? 'CSV + JSON'
                      : 'CSV + JSON + echo CSV',
                ),
                trailing: IconButton(
                  tooltip: 'Share ${r.name}',
                  icon: const Icon(Icons.share),
                  onPressed: () => c.share(r),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The per-hand figures of a run, as text rows.
class LatencyReportView extends StatelessWidget {
  const LatencyReportView(this.report, {super.key, this.style});

  final LatencyReport report;
  final TextStyle? style;

  static String _ms(int us) => (us / 1000).toStringAsFixed(1);
  static String _pct(double v) => '${(v * 100).toStringAsFixed(1)} %';

  List<Widget> _echo(EchoSummary e, ThemeData theme) {
    return [
      const SizedBox(height: 8),
      Text('Round trip (FF15)', style: theme.textTheme.titleSmall),
      Text(
        '${e.answered} answered of ${e.sent}  timeouts ${e.timeouts}'
        '${e.failedWrites == 0 ? '' : '  failed writes ${e.failedWrites}'}',
        style: style,
      ),
      if (e.answered > 0) ...[
        Text(
          'rtt ms  min ${_ms(e.rtt.min)}  p50 ${_ms(e.rtt.p50)}  '
          'p95 ${_ms(e.rtt.p95)}  p99 ${_ms(e.rtt.p99)}  '
          'max ${_ms(e.rtt.max)}',
          style: style,
        ),
        Text(
          'write to answer ms  p50 ${_ms(e.endToEnd.p50)}  '
          'p99 ${_ms(e.endToEnd.p99)}   ESP32 turnaround ms  '
          'p50 ${_ms(e.turnaround.p50)}  max ${_ms(e.turnaround.max)}   '
          'queue depth max ${e.maxQueueDepth}',
          style: style,
        ),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final link = report.link;
    final growth = report.counters.entries.where((e) => e.value != 0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Stream: ${report.stream}', style: style),
        Text(
          'MTU ${link.mtu ?? '-'}   RSSI ${link.rssiStart ?? '-'}'
          '${link.rssiEnd == null ? '' : ' -> ${link.rssiEnd}'} dBm   '
          'interval ${link.connectionIntervalUs == null ? '-' : _ms(link.connectionIntervalUs!)} ms   '
          'high priority ${switch (link.priorityRequested) {
            true => 'yes',
            false => 'failed',
            null => 'n/a',
          }}',
          style: style,
        ),
        if (report.modeChanged)
          Text(
            'The stream mode changed during the run; the figures mix two '
            'streams.',
            style: TextStyle(color: theme.colorScheme.error),
          ),
        if (report.echo != null) ..._echo(report.echo!, theme),
        for (final h in report.hands)
          if (h.records > 0) ...[
            const SizedBox(height: 8),
            Text(
              LatencyHandSummary.handName(h.hand),
              style: theme.textTheme.titleSmall,
            ),
            Text(
              '${h.records} rx  ${h.ratePerSecond.toStringAsFixed(1)}/s  '
              '${h.arrivals} arrivals',
              style: style,
            ),
            Text(
              'inter-arrival ms  p50 ${_ms(h.interArrival.p50)}  '
              'p90 ${_ms(h.interArrival.p90)}  p99 ${_ms(h.interArrival.p99)}  '
              'max ${_ms(h.interArrival.max)}  stalls ${h.stalls}',
              style: style,
            ),
            Text(
              'seq gaps ${h.sequenceGaps} (${_pct(h.sequenceLoss)})  '
              'out of order ${h.outOfOrder}',
              style: style,
            ),
            if (h.missingFromTicks != null)
              Text(
                'missing (ticks) ${h.missingFromTicks} '
                '(${_pct(h.tickLoss!)})  period '
                '${h.periodUs == null ? '-' : _ms(h.periodUs!)} ms',
                style: style,
              ),
            if (h.delay != null && h.delay!.count > 0)
              Text(
                'delay above min ms  p50 ${_ms(h.delay!.p50)}  '
                'p99 ${_ms(h.delay!.p99)}  max ${_ms(h.delay!.max)}',
                style: style,
              ),
            if (h.delayVariation != null && h.delayVariation!.count > 0)
              Text(
                'delay variation ms  p50 ${_ms(h.delayVariation!.p50)}  '
                'p99 ${_ms(h.delayVariation!.p99)}',
                style: style,
              ),
          ],
        if (growth.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            'During the run: '
            '${growth.map((e) => '${e.key} +${e.value}').join(', ')}',
            style: style,
          ),
        ],
        if (report.rowsDropped > 0)
          Text(
            '${report.rowsDropped} rows over the CSV limit were not kept '
            '(still counted above).',
          ),
      ],
    );
  }
}
