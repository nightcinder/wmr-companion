import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/test_bundle_export.dart';
import '../debug/debug_providers.dart';
import 'bench_controller.dart';
import 'bench_run.dart';
import 'bench_tracking.dart';

/// One step per screen, every step skippable, ending in the test bundle zip.
/// Entered from the Connect screen with a bridge already connected.
class BenchScreen extends ConsumerStatefulWidget {
  const BenchScreen({super.key});

  @override
  ConsumerState<BenchScreen> createState() => _BenchScreenState();
}

class _BenchScreenState extends ConsumerState<BenchScreen> {
  late final BenchBundleNotifier _bundles;

  @override
  void initState() {
    super.initState();
    _bundles = ref.read(benchBundleProvider.notifier);
    // The first step only checks the link, so run it as the screen opens.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final state = ref.read(benchControllerProvider);
      if (state.step == BenchStep.connect &&
          state.current.status == BenchStatus.pending) {
        ref.read(benchControllerProvider.notifier).runCurrent();
      }
    });
  }

  @override
  void dispose() {
    // A finished run must not attach itself to a later plain export.
    _bundles.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(benchControllerProvider);
    final controller = ref.read(benchControllerProvider.notifier);
    final durations = ref.watch(benchDurationsProvider);
    final tracking = ref.watch(benchHandTrackingProvider);
    final selection = ref.watch(debugTrackingSourceProvider);
    final theme = Theme.of(context);
    final mono = theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace');
    final step = state.step;
    final result = state.current;
    final total = state.steps.length;
    final finished = state.completed + state.skipped + state.failed;
    final progress = state.captureProgress;

    return PopScope(
      canPop: !state.busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('Guided bench run')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('Bench mode', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final mode in BenchMode.values)
                  _modeButton(mode, state, controller, tracking),
              ],
            ),
            if (!tracking.available) ...[
              const SizedBox(height: 4),
              Text(
                tracking.reason ?? 'No hand-tracking source is attached.',
                key: const Key('bench-6dof-reason'),
                style: theme.textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 8),
            Text('Hand tracking source', style: theme.textTheme.labelLarge),
            DropdownButton<DebugTrackingSource>(
              key: const Key('bench-tracking-source'),
              isExpanded: true,
              value: selection.choice,
              onChanged: state.started || state.busy
                  ? null
                  : (value) {
                      if (value != null) {
                        ref
                            .read(debugTrackingSourceProvider.notifier)
                            .set(value);
                      }
                    },
              items: [
                for (final choice in DebugTrackingSource.values)
                  DropdownMenuItem(value: choice, child: Text(choice.label)),
              ],
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: finished / total),
            const SizedBox(height: 12),
            Text(
              'Step ${state.index + 1} of $total',
              style: theme.textTheme.labelLarge,
            ),
            Text(step.title, style: theme.textTheme.headlineSmall),
            const SizedBox(height: 8),
            if (step == BenchStep.poseCapture)
              _capturePrompt(
                progress ??
                    const BenchCaptureProgress(
                      hand: 0,
                      segment: PoseSegment.still,
                      index: 0,
                      total: 10,
                    ),
                durations,
                theme,
                mono,
              )
            else
              Text(step.instructions(durations)),
            const SizedBox(height: 16),
            _status(result, mono, theme),
            const SizedBox(height: 16),
            ..._actions(state, controller, durations, theme),
            if (step == BenchStep.export && state.bundlePath != null)
              ..._bundle(state, theme, mono),
            const SizedBox(height: 24),
            Text('Steps', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            for (final item in state.steps)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(_icon(state.resultFor(item).status)),
                title: Text(item.title),
                subtitle: state.resultFor(item).summary == null
                    ? null
                    : Text(state.resultFor(item).summary!),
              ),
          ],
        ),
      ),
    );
  }

  Widget _modeButton(
    BenchMode mode,
    BenchRunState state,
    BenchController controller,
    BenchHandTracking tracking,
  ) {
    final selected = state.mode == mode;
    final enabled =
        !state.started &&
        !state.busy &&
        (mode != BenchMode.sixDofOnly || tracking.available);
    return OutlinedButton(
      key: Key('bench-mode-${mode.id}'),
      onPressed: enabled ? () => controller.selectMode(mode) : null,
      style: selected
          ? OutlinedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
            )
          : null,
      child: Text(mode.label),
    );
  }

  Widget _capturePrompt(
    BenchCaptureProgress progress,
    BenchDurations durations,
    ThemeData theme,
    TextStyle? mono,
  ) {
    final segment = progress.segment;
    final seconds = durations.forPoseSegment(segment).inSeconds;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${progress.handName} · ${segment.label} '
          '(${progress.index + 1} of ${progress.total})',
          key: const Key('bench-capture-prompt'),
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 4),
        Text(segment.prompt),
        Text('Record for $seconds s.', style: mono),
      ],
    );
  }

  List<Widget> _actions(
    BenchRunState state,
    BenchController controller,
    BenchDurations durations,
    ThemeData theme,
  ) {
    final step = state.step;
    final result = state.current;
    if (step == BenchStep.export) {
      return [
        FilledButton(
          key: const Key('bench-export'),
          onPressed: state.exporting ? null : controller.exportBundle,
          child: Text(
            state.exporting
                ? 'Writing...'
                : state.bundlePath == null
                ? 'Write test bundle'
                : 'Write again',
          ),
        ),
        if (state.bundleError != null) ...[
          const SizedBox(height: 8),
          Text(
            state.bundleError!,
            style: TextStyle(color: theme.colorScheme.error),
          ),
        ],
      ];
    }
    if (step.isPrompt) {
      return [
        FilledButton(
          key: const Key('bench-confirm'),
          onPressed: state.busy ? null : controller.confirmCurrent,
          child: Text(
            step == BenchStep.photo ? 'Photo taken' : 'Serial log saved',
          ),
        ),
        const SizedBox(height: 8),
        TextButton(
          key: const Key('bench-skip'),
          onPressed: state.busy ? null : controller.skipCurrent,
          child: const Text('Skip step'),
        ),
      ];
    }
    if (result.status == BenchStatus.failed) {
      return [
        FilledButton(
          key: const Key('bench-start'),
          onPressed: controller.runCurrent,
          child: const Text('Retry'),
        ),
        const SizedBox(height: 8),
        TextButton(
          key: const Key('bench-skip'),
          onPressed: controller.skipCurrent,
          child: const Text('Skip step'),
        ),
      ];
    }
    if (result.status == BenchStatus.running || state.exporting) {
      return const [Center(child: CircularProgressIndicator())];
    }
    return [
      FilledButton(
        key: const Key('bench-start'),
        onPressed: controller.runCurrent,
        child: Text(_startLabel(step, durations)),
      ),
      const SizedBox(height: 8),
      TextButton(
        key: const Key('bench-skip'),
        onPressed: controller.skipCurrent,
        child: const Text('Skip step'),
      ),
    ];
  }

  List<Widget> _bundle(BenchRunState state, ThemeData theme, TextStyle? mono) {
    return [
      const SizedBox(height: 12),
      Text(state.fileName ?? '', style: theme.textTheme.titleMedium),
      SelectableText(state.bundlePath!, style: mono),
      if (state.missing.isNotEmpty) ...[
        const SizedBox(height: 8),
        Text('Missing from this bundle', style: theme.textTheme.labelLarge),
        for (final item in state.missing)
          Text('• $item', style: theme.textTheme.bodySmall),
      ],
    ];
  }

  Widget _status(BenchStepResult result, TextStyle? mono, ThemeData theme) {
    return switch (result.status) {
      BenchStatus.pending => Text('Not run yet.', style: mono),
      BenchStatus.running => Text('Running...', style: mono),
      BenchStatus.done => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.check_circle, color: theme.colorScheme.primary, size: 18),
          const SizedBox(width: 6),
          Expanded(child: Text(result.summary ?? 'Done', style: mono)),
        ],
      ),
      BenchStatus.skipped => Text(
        result.summary == null
            ? 'Skipped. The manifest records the step as skipped.'
            : 'Skipped: ${result.summary}',
        style: mono,
      ),
      BenchStatus.failed => Text(
        result.error ?? 'Failed',
        style: mono?.copyWith(color: theme.colorScheme.error),
      ),
    };
  }

  static String _startLabel(BenchStep step, BenchDurations durations) =>
      switch (step) {
        BenchStep.deviceSummary => 'Check capabilities',
        BenchStep.connect => 'Check connection',
        BenchStep.bothHands => 'Wait for both hands',
        BenchStep.firmwareConfig => 'Read firmware and config',
        BenchStep.stillLeft ||
        BenchStep.stillRight => 'Start ${durations.still.inSeconds} s',
        BenchStep.moveLeft ||
        BenchStep.moveRight => 'Start ${durations.move.inSeconds} s',
        BenchStep.capture => 'Start ${durations.capture.inSeconds} s capture',
        BenchStep.latency => 'Start ${durations.latency.inSeconds} s',
        BenchStep.poseCapture => 'Start captures',
        BenchStep.photo ||
        BenchStep.serialLog ||
        BenchStep.export => 'Continue',
      };

  static IconData _icon(BenchStatus status) => switch (status) {
    BenchStatus.done => Icons.check_circle,
    BenchStatus.skipped => Icons.skip_next,
    BenchStatus.failed => Icons.error,
    BenchStatus.running => Icons.play_circle,
    BenchStatus.pending => Icons.radio_button_unchecked,
  };
}
