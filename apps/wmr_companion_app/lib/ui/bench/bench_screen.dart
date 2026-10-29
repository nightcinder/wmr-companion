import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/test_bundle_export.dart';
import 'bench_controller.dart';
import 'bench_pose.dart';
import 'bench_run.dart';

/// One step per screen, every step skippable, ending in the test bundle zip.
/// Entered from the Connect screen with a bridge already connected.
class BenchScreen extends ConsumerStatefulWidget {
  const BenchScreen({super.key});

  @override
  ConsumerState<BenchScreen> createState() => _BenchScreenState();
}

class _BenchScreenState extends ConsumerState<BenchScreen> {
  late final BenchBundleNotifier _bundles;
  Timer? _poseTimer;
  int? _poseTimerSegment;
  int _poseRemaining = 0;

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
    _poseTimer?.cancel();
    // A finished run must not attach itself to a later plain export.
    _bundles.clear();
    super.dispose();
  }

  double _poseProgress(BenchDurations durations, PoseSegment segment) {
    final total = durations.poseDuration(segment).inSeconds;
    if (total <= 0 || _poseRemaining <= 0) return 1;
    return 1 - _poseRemaining / total;
  }

  /// Counts down only while a pose segment is running. The controller owns the
  /// segment index, so a new index restarts the count.
  void _syncPoseCountdown(BenchRunState state, BenchDurations durations) {
    final running =
        state.step == BenchStep.poseCapture &&
        state.current.status == BenchStatus.running;
    if (!running) {
      _poseTimer?.cancel();
      _poseTimer = null;
      _poseTimerSegment = null;
      return;
    }
    if (_poseTimer != null && _poseTimerSegment == state.poseSegment) return;
    _poseTimer?.cancel();
    _poseTimerSegment = state.poseSegment;
    final spec = benchPoseSequence[state.poseSegment];
    final seconds = durations.poseDuration(spec.segment).inSeconds;
    _poseRemaining = seconds;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _poseTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() {
          if (_poseRemaining > 0) _poseRemaining--;
        });
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(benchControllerProvider);
    final controller = ref.read(benchControllerProvider.notifier);
    final durations = ref.watch(benchDurationsProvider);
    final theme = Theme.of(context);
    final mono = theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace');
    final step = state.step;
    final result = state.current;
    final total = BenchStep.values.length;
    final finished = state.completed + state.skipped + state.failed;
    final poseSpec = step == BenchStep.poseCapture
        ? benchPoseSequence[state.poseSegment]
        : null;
    _syncPoseCountdown(state, durations);

    return PopScope(
      canPop: !state.busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('Guided bench run')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            LinearProgressIndicator(value: finished / total),
            const SizedBox(height: 12),
            Text(
              poseSpec == null
                  ? 'Step ${state.index + 1} of $total'
                  : 'Step ${state.index + 1} of $total  ·  '
                        'Pose ${state.poseSegment + 1} of '
                        '${benchPoseSequence.length}',
              style: theme.textTheme.labelLarge,
            ),
            Text(
              poseSpec == null
                  ? step.title
                  : '${poseSpec.segment.title} — '
                        '${RealBenchSession.handName(poseSpec.hand)}',
              style: theme.textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              poseSpec == null
                  ? step.instructions(durations)
                  : '${RealBenchSession.handName(poseSpec.hand)}: '
                        '${poseSpec.segment.prompt}',
            ),
            if (poseSpec != null && result.status == BenchStatus.running) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: _poseProgress(durations, poseSpec.segment),
              ),
              Text(
                '$_poseRemaining s left',
                key: const Key('bench-pose-countdown'),
                style: theme.textTheme.titleMedium,
              ),
            ],
            const SizedBox(height: 16),
            _status(result, mono, theme),
            const SizedBox(height: 16),
            ..._actions(state, controller, durations, theme),
            if (step == BenchStep.export && state.bundlePath != null)
              ..._bundle(state, theme, mono),
            const SizedBox(height: 24),
            Text('Steps', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            for (final item in BenchStep.values)
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

  List<Widget> _actions(
    BenchRunState state,
    BenchController controller,
    BenchDurations durations,
    ThemeData theme,
  ) {
    final step = state.step;
    final result = state.current;
    final poseSpec = step == BenchStep.poseCapture
        ? benchPoseSequence[state.poseSegment]
        : null;
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
      if (step != BenchStep.poseCapture) {
        return const [Center(child: CircularProgressIndicator())];
      }
      return [
        TextButton(
          key: const Key('bench-skip'),
          onPressed: controller.skipCurrent,
          child: const Text('Skip segment'),
        ),
        if (state.poseSegment + 1 < benchPoseSequence.length)
          TextButton(
            key: const Key('bench-skip-remaining'),
            onPressed: controller.skipRemainingPose,
            child: const Text('Skip remaining'),
          ),
      ];
    }
    return [
      FilledButton(
        key: const Key('bench-start'),
        onPressed: controller.runCurrent,
        child: Text(
          poseSpec == null
              ? _startLabel(step, durations)
              : 'Start ${durations.poseDuration(poseSpec.segment).inSeconds} s',
        ),
      ),
      const SizedBox(height: 8),
      TextButton(
        key: const Key('bench-skip'),
        onPressed: controller.skipCurrent,
        child: Text(poseSpec == null ? 'Skip step' : 'Skip segment'),
      ),
      if (poseSpec != null && state.poseSegment + 1 < benchPoseSequence.length)
        TextButton(
          key: const Key('bench-skip-remaining'),
          onPressed: controller.skipRemainingPose,
          child: const Text('Skip remaining'),
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
        'Skipped. The manifest records the step as skipped.',
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
        BenchStep.connect => 'Check connection',
        BenchStep.bothHands => 'Wait for both hands',
        BenchStep.firmwareConfig => 'Read firmware and config',
        BenchStep.stillLeft ||
        BenchStep.stillRight => 'Start ${durations.still.inSeconds} s',
        BenchStep.moveLeft ||
        BenchStep.moveRight => 'Start ${durations.move.inSeconds} s',
        BenchStep.poseCapture => 'Start',
        BenchStep.capture => 'Start ${durations.capture.inSeconds} s capture',
        BenchStep.latency => 'Start ${durations.latency.inSeconds} s',
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
