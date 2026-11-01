import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/test_bundle_export.dart';
import '../debug/debug_providers.dart';
import '../sbs/stereo_sbs.dart';
import 'bench_controller.dart';
import 'bench_pose.dart';
import 'bench_run.dart';
import 'bench_tracking.dart';

/// One step per screen, every step skippable, ending in the test bundle zip.
/// Entered from the Connect screen with a bridge already connected, or with a
/// hand-tracking source for the 6DoF-only path.
class BenchScreen extends ConsumerStatefulWidget {
  const BenchScreen({super.key});

  @override
  ConsumerState<BenchScreen> createState() => _BenchScreenState();
}

class _BenchScreenState extends ConsumerState<BenchScreen> {
  late final BenchBundleNotifier _bundles;

  /// D-pad state lives above [StereoSbsWrapper]: both eye halves inflate the
  /// screen, and sharing these nodes keeps the focus ring in both eyes.
  final FocusNode _primaryFocus = FocusNode(debugLabel: 'bench-primary');
  final FocusNode _skipFocus = FocusNode(debugLabel: 'bench-skip');
  final FocusNode _skipRemainingFocus = FocusNode(
    debugLabel: 'bench-skip-remaining',
  );
  final FocusNode _trackingFocus = FocusNode(debugLabel: 'bench-tracking');
  final Map<BenchMode, FocusNode> _modeFocus = {
    for (final mode in BenchMode.values)
      mode: FocusNode(debugLabel: 'bench-mode-${mode.id}'),
  };
  final ScrollController _scroll = StereoSbsScrollController();
  Timer? _poseTimer;
  int? _poseTimerSegment;
  int _poseRemaining = 0;

  @override
  void initState() {
    super.initState();
    _bundles = ref.read(benchBundleProvider.notifier);
    // The first step only checks the link, so run it as the screen opens. A
    // 6DoF-only run starts at the capability summary and waits for the tester.
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
    _primaryFocus.dispose();
    _skipFocus.dispose();
    _skipRemainingFocus.dispose();
    _trackingFocus.dispose();
    for (final node in _modeFocus.values) {
      node.dispose();
    }
    _scroll.dispose();
    // A finished run must not attach itself to a later plain export.
    _bundles.clear();
    super.dispose();
  }

  double _poseProgress(
    BenchDurations durations,
    BenchPosePlan plan,
    PoseSegment segment,
  ) {
    final total = durations.poseRunDuration(segment, plan).inSeconds;
    if (total <= 0 || _poseRemaining <= 0) return 1;
    return 1 - _poseRemaining / total;
  }

  /// Counts down only while a pose segment is running. The controller owns the
  /// segment index, so a new index restarts the count.
  void _syncPoseCountdown(
    BenchRunState state,
    BenchDurations durations,
    BenchPosePlan plan,
    List<BenchPoseSpec> sequence,
  ) {
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
    final spec = sequence[state.poseSegment];
    final seconds = durations.poseRunDuration(spec.segment, plan).inSeconds;
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
    final plan = ref.watch(benchPosePlanProvider);
    final sequence = ref.watch(benchPoseSequenceProvider);
    final tracking = ref.watch(benchHandTrackingProvider);
    final selection = ref.watch(debugTrackingSourceProvider);
    // The simulated source is fed by the debug pose viewer; keep that pump
    // alive so a 6DoF capture can run without hardware.
    if (selection.choice == DebugTrackingSource.simulated) {
      ref.watch(debugPosesProvider(DebugSource.real));
    }
    final theme = Theme.of(context);
    final mono = theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace');
    final step = state.step;
    final result = state.current;
    final total = state.steps.length;
    final finished = state.completed + state.skipped + state.failed;
    final poseSpec = step == BenchStep.poseCapture
        ? sequence[state.poseSegment]
        : null;
    _syncPoseCountdown(state, durations, plan, sequence);

    return StereoSbsWrapper(
      child: PopScope(
        canPop: !state.busy,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Guided bench run'),
            actions: const [SbsToggleButton()],
          ),
          body: FocusTraversalGroup(
            key: const Key('bench-focus-order'),
            policy: OrderedTraversalPolicy(),
            child: ListView(
              controller: _scroll,
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
                  focusNode: _trackingFocus,
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
                      DropdownMenuItem(
                        value: choice,
                        child: Text(choice.label),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                LinearProgressIndicator(value: finished / total),
                const SizedBox(height: 12),
                Text(
                  poseSpec == null
                      ? 'Step ${state.index + 1} of $total'
                      : 'Step ${state.index + 1} of $total  ·  '
                            'Pose ${state.poseSegment + 1} of '
                            '${sequence.length}',
                  style: theme.textTheme.labelLarge,
                ),
                Text(
                  poseSpec == null
                      ? step.title
                      : '${poseSpec.segment.title} — ${poseSpec.handName}'
                            '${poseSpec.diagnostic ? ' (diagnostic)' : ' · run ${poseSpec.run}'}',
                  style: theme.textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(
                  poseSpec == null
                      ? step.instructions(durations)
                      : '${RealBenchSession.handName(poseSpec.hand)}: '
                            '${poseSpec.segment.prompt}',
                  key: poseSpec == null
                      ? null
                      : const Key('bench-capture-prompt'),
                ),
                if (poseSpec != null &&
                    result.status == BenchStatus.running) ...[
                  const SizedBox(height: 8),
                  LinearProgressIndicator(
                    value: _poseProgress(durations, plan, poseSpec.segment),
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
                ..._actions(
                  state,
                  controller,
                  durations,
                  plan,
                  sequence,
                  theme,
                  poseSpec,
                ),
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
        ),
      ),
    );
  }

  /// The Start/Continue/Confirm/Export button is first in the D-pad order, so
  /// it takes the initial focus the moment a step needs the tester.
  Widget _primaryAction(Widget button) =>
      FocusTraversalOrder(order: const NumericFocusOrder(1), child: button);

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
      focusNode: _modeFocus[mode],
      onPressed: enabled ? () => controller.selectMode(mode) : null,
      style: selected
          ? OutlinedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
            )
          : null,
      child: Text(mode.label),
    );
  }

  List<Widget> _actions(
    BenchRunState state,
    BenchController controller,
    BenchDurations durations,
    BenchPosePlan plan,
    List<BenchPoseSpec> sequence,
    ThemeData theme,
    BenchPoseSpec? poseSpec,
  ) {
    final step = state.step;
    final result = state.current;
    if (step == BenchStep.export) {
      return [
        _primaryAction(
          FilledButton(
            key: const Key('bench-export'),
            focusNode: _primaryFocus,
            autofocus: true,
            onPressed: state.exporting ? null : controller.exportBundle,
            child: Text(
              state.exporting
                  ? 'Writing...'
                  : state.bundlePath == null
                  ? 'Write test bundle'
                  : 'Write again',
            ),
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
        _primaryAction(
          FilledButton(
            key: const Key('bench-confirm'),
            focusNode: _primaryFocus,
            autofocus: true,
            onPressed: state.busy ? null : controller.confirmCurrent,
            child: Text(
              step == BenchStep.photo ? 'Photo taken' : 'Serial log saved',
            ),
          ),
        ),
        const SizedBox(height: 8),
        TextButton(
          key: const Key('bench-skip'),
          focusNode: _skipFocus,
          onPressed: state.busy ? null : controller.skipCurrent,
          child: const Text('Skip step'),
        ),
      ];
    }
    if (result.status == BenchStatus.failed) {
      return [
        _primaryAction(
          FilledButton(
            key: const Key('bench-start'),
            focusNode: _primaryFocus,
            autofocus: true,
            onPressed: controller.runCurrent,
            child: const Text('Retry'),
          ),
        ),
        const SizedBox(height: 8),
        TextButton(
          key: const Key('bench-skip'),
          focusNode: _skipFocus,
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
          focusNode: _skipFocus,
          onPressed: controller.skipCurrent,
          child: const Text('Skip segment'),
        ),
        if (state.poseSegment + 1 < sequence.length)
          TextButton(
            key: const Key('bench-skip-remaining'),
            focusNode: _skipRemainingFocus,
            onPressed: controller.skipRemainingPose,
            child: const Text('Skip remaining'),
          ),
      ];
    }
    return [
      _primaryAction(
        FilledButton(
          key: const Key('bench-start'),
          focusNode: _primaryFocus,
          autofocus: true,
          onPressed: controller.runCurrent,
          child: Text(
            poseSpec == null
                ? _startLabel(step, durations)
                : 'Start '
                      '${durations.poseRunDuration(poseSpec.segment, plan).inSeconds}'
                      ' s',
          ),
        ),
      ),
      const SizedBox(height: 8),
      TextButton(
        key: const Key('bench-skip'),
        onPressed: controller.skipCurrent,
        child: Text(poseSpec == null ? 'Skip step' : 'Skip segment'),
      ),
      if (poseSpec != null && state.poseSegment + 1 < sequence.length)
        TextButton(
          key: const Key('bench-skip-remaining'),
          focusNode: _skipRemainingFocus,
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

  static String _startLabel(
    BenchStep step,
    BenchDurations durations,
  ) => switch (step) {
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
    BenchStep.handEmpty => 'Start ${durations.handEmpty.inSeconds} s',
    BenchStep.handGrip => 'Start ${durations.handGrip.inSeconds} s',
    BenchStep.carinaLeds =>
      'Start ${carinaLedDistancesM.length * carinaLedOrientations.length} x '
          '${durations.carinaFrame.inSeconds} s',
    BenchStep.carinaCheckerboard =>
      'Start 10 x ${durations.carinaCheckerboardPose.inSeconds} s',
    BenchStep.carinaPose => 'Start ${durations.carinaPoseRun.inSeconds} s',
    BenchStep.poseCapture => 'Start',
    BenchStep.photo || BenchStep.serialLog || BenchStep.export => 'Continue',
  };

  static IconData _icon(BenchStatus status) => switch (status) {
    BenchStatus.done => Icons.check_circle,
    BenchStatus.skipped => Icons.skip_next,
    BenchStatus.failed => Icons.error,
    BenchStatus.running => Icons.play_circle,
    BenchStatus.pending => Icons.radio_button_unchecked,
  };
}
