import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/test_bundle.dart';
import '../../services/test_bundle_export.dart';
import 'bench_run.dart';
import 'bench_tracking.dart';

enum BenchStatus { pending, running, done, skipped, failed }

class BenchStepResult {
  const BenchStepResult({
    this.status = BenchStatus.pending,
    this.summary,
    this.error,
    this.data = const {},
  });

  final BenchStatus status;
  final String? summary;
  final String? error;
  final Map<String, Object?> data;

  bool get finished =>
      status == BenchStatus.done ||
      status == BenchStatus.skipped ||
      status == BenchStatus.failed;
}

class BenchRunState {
  const BenchRunState({
    this.mode = BenchMode.threeDofOnly,
    this.step = BenchStep.connect,
    this.results = const {},
    this.exporting = false,
    this.bundlePath,
    this.fileName,
    this.present = const [],
    this.missing = const [],
    this.bundleError,
    this.captureProgress,
  });

  final BenchMode mode;
  final BenchStep step;
  final Map<BenchStep, BenchStepResult> results;
  final bool exporting;
  final String? bundlePath;
  final String? fileName;
  final List<String> present;
  final List<String> missing;
  final String? bundleError;

  /// The segment the pose capture is recording, while it runs.
  final BenchCaptureProgress? captureProgress;

  BenchStepResult resultFor(BenchStep step) =>
      results[step] ?? const BenchStepResult();

  BenchStepResult get current => resultFor(step);

  List<BenchStep> get steps => mode.steps;

  int get index => steps.indexOf(step);

  /// True once a step past the automatic connect check has a result, so the
  /// mode cannot be changed under a run that is already measuring.
  bool get started => results.entries.any(
    (entry) =>
        entry.key != BenchStep.connect &&
        entry.value.status != BenchStatus.skipped,
  );

  bool get busy => current.status == BenchStatus.running || exporting;

  int get completed =>
      results.values.where((r) => r.status == BenchStatus.done).length;

  int get skipped =>
      results.values.where((r) => r.status == BenchStatus.skipped).length;

  int get failed =>
      results.values.where((r) => r.status == BenchStatus.failed).length;

  BenchRunState copyWith({
    BenchMode? mode,
    BenchStep? step,
    Map<BenchStep, BenchStepResult>? results,
    bool? exporting,
    String? bundlePath,
    String? fileName,
    List<String>? present,
    List<String>? missing,
    String? bundleError,
    BenchCaptureProgress? captureProgress,
    bool clearBundleError = false,
    bool clearCaptureProgress = false,
  }) {
    return BenchRunState(
      mode: mode ?? this.mode,
      step: step ?? this.step,
      results: results ?? this.results,
      exporting: exporting ?? this.exporting,
      bundlePath: bundlePath ?? this.bundlePath,
      fileName: fileName ?? this.fileName,
      present: present ?? this.present,
      missing: missing ?? this.missing,
      bundleError: clearBundleError ? null : (bundleError ?? this.bundleError),
      captureProgress: clearCaptureProgress
          ? null
          : (captureProgress ?? this.captureProgress),
    );
  }
}

final benchControllerProvider =
    NotifierProvider.autoDispose<BenchController, BenchRunState>(
      BenchController.new,
    );

/// Drives one step at a time. Measurements run through [BenchSession] so the
/// machine is testable against the fake bridge without any UI.
class BenchController extends Notifier<BenchRunState> {
  @override
  BenchRunState build() => const BenchRunState();

  /// Switches the wizard to [mode] before it has meaningful results.
  ///
  /// 6DoF only pre-records every bridge step as skipped with its reason, so the
  /// manifest explains why the bridge work did not run. The tester starts at
  /// the device summary instead of at the connect step.
  void selectMode(BenchMode mode) {
    if (state.busy || state.started) return;
    final tracking = ref.read(benchHandTrackingProvider);
    if (mode == BenchMode.sixDofOnly && !tracking.available) return;
    final results = <BenchStep, BenchStepResult>{};
    if (mode == BenchMode.sixDofOnly) {
      for (final step in BenchMode.bridgeOnlySteps) {
        results[step] = const BenchStepResult(
          status: BenchStatus.skipped,
          summary: 'No bridge in 6DoF only mode.',
        );
      }
    }
    state = BenchRunState(mode: mode, step: mode.steps.first, results: results);
    _publish();
  }

  Future<void> runCurrent() async {
    final step = state.step;
    if (state.busy || step == BenchStep.export) return;
    if (step.isPrompt) {
      await confirmCurrent();
      return;
    }
    final tracking = ref.read(benchHandTrackingProvider);
    if (step == BenchStep.poseCapture && !tracking.available) {
      _setResult(
        step,
        const BenchStepResult(
          status: BenchStatus.skipped,
          summary: 'No hand-tracking source with hand joints is attached.',
        ),
      );
      _advance();
      return;
    }
    _setResult(step, const BenchStepResult(status: BenchStatus.running));
    try {
      final session = await ref.read(benchSessionProvider)();
      if (session == null) {
        _setResult(
          step,
          const BenchStepResult(
            status: BenchStatus.failed,
            error: 'Not connected to the bridge.',
          ),
        );
        return;
      }
      final outcome = await _runStep(session, step, (progress) {
        if (!ref.mounted) return;
        state = state.copyWith(captureProgress: progress);
      });
      if (!ref.mounted) return;
      state = state.copyWith(clearCaptureProgress: true);
      _setResult(
        step,
        outcome.ok
            ? BenchStepResult(
                status: BenchStatus.done,
                summary: outcome.summary,
                data: outcome.data,
              )
            : BenchStepResult(
                status: BenchStatus.failed,
                error: outcome.error,
                data: outcome.data,
              ),
      );
      if (outcome.ok) _advance();
    } catch (e) {
      if (!ref.mounted) return;
      _setResult(
        step,
        BenchStepResult(status: BenchStatus.failed, error: '$e'),
      );
    }
  }

  Future<BenchStepOutcome> _runStep(
    BenchSession session,
    BenchStep step,
    void Function(BenchCaptureProgress progress) onProgress,
  ) => switch (step) {
    BenchStep.deviceSummary => session.deviceSummary(),
    BenchStep.connect => session.connect(),
    BenchStep.bothHands => session.bothHands(),
    BenchStep.firmwareConfig => session.firmwareConfig(),
    BenchStep.stillLeft => session.still(0),
    BenchStep.stillRight => session.still(1),
    BenchStep.moveLeft => session.move(0),
    BenchStep.moveRight => session.move(1),
    BenchStep.capture => session.capture(),
    BenchStep.latency => session.latency(),
    BenchStep.poseCapture => session.poseCapture(onProgress),
    BenchStep.photo ||
    BenchStep.serialLog ||
    BenchStep.export => throw StateError('Step $step does not run'),
  };

  /// Marks a prompt step done and moves on.
  Future<void> confirmCurrent() async {
    final step = state.step;
    if (!step.isPrompt || state.busy) return;
    _setResult(
      step,
      BenchStepResult(
        status: BenchStatus.done,
        summary: step == BenchStep.photo ? 'Photo taken' : 'Serial log saved',
      ),
    );
    _advance();
  }

  /// Records the step as skipped and moves on. The export step cannot be
  /// skipped: the run ends in a bundle.
  void skipCurrent() {
    final step = state.step;
    if (state.busy || step == BenchStep.export) return;
    // Keep any partial data (for example the captures a failed segment saved)
    // so the bundle still carries it.
    final previous = state.resultFor(step);
    _setResult(
      step,
      BenchStepResult(
        status: BenchStatus.skipped,
        summary: previous.summary,
        data: previous.data,
      ),
    );
    _advance();
  }

  /// Writes the same zip as Export test bundle, with these results in the
  /// manifest, then shares it.
  Future<void> exportBundle() async {
    if (state.exporting) return;
    state = state.copyWith(exporting: true, clearBundleError: true);
    // Record and publish the export before the writer reads the run, so the
    // manifest does not say `not_run` for a step that is finishing now.
    _setResult(
      BenchStep.export,
      const BenchStepResult(
        status: BenchStatus.done,
        summary: 'Bundle written',
      ),
    );
    final run = ref.read(benchBundleProvider);
    try {
      final bundle = await ref.read(exportTestBundleProvider)(benchRun: run);
      if (!ref.mounted) return;
      _setResult(
        BenchStep.export,
        BenchStepResult(
          status: BenchStatus.done,
          summary: 'Shared ${bundle.fileName}',
          data: {'file': bundle.fileName, 'present': bundle.present},
        ),
      );
      state = state.copyWith(
        exporting: false,
        bundlePath: bundle.path,
        fileName: bundle.fileName,
        present: bundle.present,
        missing: bundle.missing,
      );
    } catch (e) {
      if (!ref.mounted) return;
      _setResult(
        BenchStep.export,
        BenchStepResult(status: BenchStatus.failed, error: '$e'),
      );
      state = state.copyWith(exporting: false, bundleError: '$e');
    }
  }

  void _advance() {
    final steps = state.steps;
    var next = state.index + 1;
    while (next < steps.length) {
      final step = steps[next];
      if (state.resultFor(step).finished) {
        next++;
        continue;
      }
      // Combined runs with no hand-joint source skip the capture visibly and
      // still reach the export.
      if (step == BenchStep.poseCapture &&
          !ref.read(benchHandTrackingProvider).available) {
        _setResult(
          step,
          const BenchStepResult(
            status: BenchStatus.skipped,
            summary: 'No hand-tracking source with hand joints is attached.',
          ),
        );
        next++;
        continue;
      }
      break;
    }
    if (next >= steps.length) return;
    state = state.copyWith(step: steps[next], clearCaptureProgress: true);
    _publish();
  }

  void _setResult(BenchStep step, BenchStepResult result) {
    state = state.copyWith(results: {...state.results, step: result});
    _publish();
  }

  /// Keeps the manifest copy in step with the screen.
  void _publish() {
    ref
        .read(benchBundleProvider.notifier)
        .publish(
          BenchBundleRun([
            for (final step in state.steps)
              BenchBundleStep(
                id: step.id,
                status: _statusName(state.resultFor(step).status),
                summary: state.resultFor(step).summary,
                detail: state.resultFor(step).error,
                data: state.resultFor(step).data,
              ),
          ], mode: state.mode.id),
        );
  }

  static String _statusName(BenchStatus status) => switch (status) {
    BenchStatus.pending => 'not_run',
    BenchStatus.running => 'running',
    BenchStatus.done => 'done',
    BenchStatus.skipped => 'skipped',
    BenchStatus.failed => 'failed',
  };
}
