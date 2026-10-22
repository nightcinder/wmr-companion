import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../protocol/wmr_fragment.dart';
import '../../services/capture_recorder.dart';
import 'capture_providers.dart';

/// Guided raw capture, same procedure as WMR_Bridge tools/capture_ble.py.
/// Not verified on hardware.
class CaptureScreen extends ConsumerWidget {
  const CaptureScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(captureControllerProvider);
    final c = ref.read(captureControllerProvider.notifier);
    final theme = Theme.of(context);
    final mono = theme.textTheme.bodyMedium?.copyWith(fontFamily: 'monospace');

    return PopScope(
      canPop: s.stage == CaptureStage.setup || s.stage == CaptureStage.finished,
      child: Scaffold(
        appBar: AppBar(title: const Text('Capture')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Not verified on hardware. Records raw controller frames in the '
              'format of WMR_Bridge tools/capture_ble.py.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            if (s.error != null)
              Text(s.error!, style: TextStyle(color: theme.colorScheme.error)),
            if (s.stage == CaptureStage.setup) ..._setup(s, c, theme),
            if (s.stage == CaptureStage.ready ||
                s.stage == CaptureStage.countdown ||
                s.stage == CaptureStage.recording)
              ..._phase(s, c, theme),
            if (s.path != null) ...[
              const SizedBox(height: 12),
              Text('Saving to', style: theme.textTheme.labelMedium),
              SelectableText(s.path!, style: mono),
            ],
            if (s.summaries.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text('Link per phase', style: theme.textTheme.titleMedium),
              for (final summary in s.summaries) _summary(summary, theme, mono),
              if (s.skippedFrames > 0)
                Text(
                  '${s.skippedFrames} frames were not 46 bytes and were not '
                  'written.',
                ),
            ],
            if (s.stage == CaptureStage.finished)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: FilledButton(
                  onPressed: c.abort,
                  child: const Text('New capture'),
                ),
              ),
            const SizedBox(height: 16),
            Text('Saved captures', style: theme.textTheme.titleMedium),
            if (s.saved.isEmpty) const Text('None yet.'),
            for (final f in s.saved)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(f.name),
                subtitle: Text('${f.bytes} bytes\n${f.path}'),
                isThreeLine: true,
                trailing: IconButton(
                  tooltip: 'Share ${f.name}',
                  icon: const Icon(Icons.share),
                  onPressed: () => c.share(f.path),
                ),
              ),
          ],
        ),
      ),
    );
  }

  List<Widget> _setup(CaptureState s, CaptureController c, ThemeData theme) {
    return [
      Text('Which controller will you hold?', style: theme.textTheme.bodyLarge),
      const SizedBox(height: 8),
      SegmentedButton<int>(
        segments: const [
          ButtonSegment(value: wmrHandLeft, label: Text('LEFT')),
          ButtonSegment(value: wmrHandRight, label: Text('RIGHT')),
        ],
        selected: {s.hand},
        onSelectionChanged: (v) => c.selectHand(v.first),
      ),
      const SizedBox(height: 8),
      const Text(
        'Four phases: still, twist_cw, flip_away, lean_right. Make sure no '
        'other phone is connected to the bridge.',
      ),
      const SizedBox(height: 8),
      FilledButton(onPressed: c.start, child: const Text('Start capture')),
    ];
  }

  List<Widget> _phase(CaptureState s, CaptureController c, ThemeData theme) {
    final phase = s.phase;
    return [
      Text(
        'Phase ${s.phaseIndex + 1} of ${capturePhases.length}: ${phase.name}',
        style: theme.textTheme.titleLarge,
      ),
      const SizedBox(height: 8),
      Text(phase.instructions),
      const SizedBox(height: 12),
      switch (s.stage) {
        CaptureStage.ready => FilledButton(
          onPressed: c.beginPhase,
          child: Text('Begin ${phase.name}'),
        ),
        CaptureStage.countdown => Text(
          'Starting in ${s.countdown}',
          style: theme.textTheme.headlineMedium,
        ),
        _ => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Recording ${s.elapsedSeconds} s',
              style: theme.textTheme.headlineMedium,
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: s.canFinish ? c.finishPhase : null,
              child: Text(
                s.canFinish
                    ? 'Finished'
                    : 'Finish (after ${phase.minSeconds} s)',
              ),
            ),
          ],
        ),
      },
    ];
  }

  Widget _summary(PhaseSummary p, ThemeData theme, TextStyle? mono) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(p.name, style: theme.textTheme.titleSmall),
          for (var h = 0; h < wmrNumControllers; h++)
            if (p.hands[h].frames > 0)
              Text(p.hands[h].line(CaptureFormat.handName(h)), style: mono),
          if (p.lossy)
            Text(
              'WARNING: more than ${(captureLossyThreshold * 100).round()}% '
              'of frames lost in this phase; the rotation results from it '
              'will not be valid.',
              style: TextStyle(
                color: theme.colorScheme.error,
                fontWeight: FontWeight.bold,
              ),
            ),
        ],
      ),
    );
  }
}
