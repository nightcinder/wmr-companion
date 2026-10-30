import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/test_bundle.dart';
import '../../services/test_bundle_export.dart';
import '../debug/pose_recording_store.dart';
import 'bench_pose.dart';
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
    this.poseSegment = 0,
  });

  final BenchMode mode;
  final BenchStep step;
  final Map<BenchStep, BenchStepResult> results;

  /// Index into [benchPoseSequence] while [step] is [BenchStep.poseCapture].
  final int poseSegment;
  final bool exporting;
  final String? bundlePath;
  final String? fileName;
  final List<String> present;
  final List<String> missing;
  final String? bundleError;

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
    bool clearBundleError = false,
    int? poseSegment,
  }) {
    return BenchRunState(
      mode: mode ?? this.mode,
      step: step ?? this.step,
      results: results ?? this.results,
      poseSegment: poseSegment ?? this.poseSegment,
      exporting: exporting ?? this.exporting,
      bundlePath: bundlePath ?? this.bundlePath,
      fileName: fileName ?? this.fileName,
      present: present ?? this.present,
      missing: missing ?? this.missing,
      bundleError: clearBundleError ? null : (bundleError ?? this.bundleError),
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
  final List<Map<String, Object?>> _poseEntries = [];
  Completer<void>? _poseCancel;
  bool _poseSkipRest = false;
  bool _posePrepared = false;
  Future<void> _poseProgressWrite = Future<void>.value();

  List<BenchPoseSpec> get _sequence => ref.read(benchPoseSequenceProvider);

  /// Completes when the queued resume write has reached the store. The wizard
  /// does not wait for disk; a simulated restart in a test does.
  Future<void> get poseProgressWritten => _poseProgressWrite;

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
    _poseEntries.clear();
    _poseCancel = null;
    _poseSkipRest = false;
    _posePrepared = false;
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
      if (step == BenchStep.poseCapture) {
        await _preparePoseStep();
        if (!ref.mounted) return;
        if (state.poseSegment >= _sequence.length) {
          _finishPose();
          return;
        }
        await _runPoseSegment(session);
        return;
      }
      final outcome = await _runStep(session, step);
      if (!ref.mounted) return;
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

  Future<BenchStepOutcome> _runStep(BenchSession session, BenchStep step) =>
      switch (step) {
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
        BenchStep.poseCapture ||
        BenchStep.photo ||
        BenchStep.serialLog ||
        BenchStep.export => throw StateError('Step $step does not run'),
      };

  /// Runs one segment of the 6DoF step. Each segment keeps the step current so
  /// the screen can show its own prompt and countdown; the step ends after the
  /// last segment, or on skip.
  Future<void> _runPoseSegment(BenchSession session) async {
    final sequence = _sequence;
    final index = state.poseSegment;
    if (index >= sequence.length) return;
    final spec = sequence[index];
    final durations = ref.read(benchDurationsProvider);
    final plan = ref.read(benchPosePlanProvider);
    _setResult(
      BenchStep.poseCapture,
      BenchStepResult(
        status: BenchStatus.running,
        data: {
          'segments': [..._poseEntries],
        },
      ),
    );
    final cancel = Completer<void>();
    _poseCancel = cancel;
    final outcome = await session.poseSegment(
      spec.hand,
      spec.segment,
      durations.poseRunDuration(spec.segment, plan),
      run: spec.run,
      cancel: cancel.future,
    );
    _poseCancel = null;
    if (!ref.mounted) return;
    _poseEntries.add({
      ...outcome.data,
      'runtime':
          outcome.data['runtime'] ??
          ref.read(benchPoseAvailabilityProvider).runtime,
      'hand': RealBenchSession.handName(spec.hand),
      'segment': spec.segment.id,
      'run': spec.run,
      'status': outcome.ok ? 'done' : 'skipped',
      if (!outcome.ok) 'reason': outcome.error ?? 'failed',
    });
    _queuePoseProgress();
    if (!ref.mounted) return;
    final skipRest = _poseSkipRest;
    _poseSkipRest = false;
    if (index + 1 >= sequence.length) {
      _finishPose();
      return;
    }
    if (skipRest) {
      _skipRemainingPose(index + 1);
      return;
    }
    state = state.copyWith(poseSegment: index + 1);
    _publishPoseProgress();
  }

  /// Loads a saved corpus after an interruption and skips every run whose file
  /// is still on disk. A completed corpus, a different runtime, app commit or
  /// plan starts fresh.
  Future<void> _preparePoseStep() async {
    if (_posePrepared) return;
    _posePrepared = true;
    if (_poseEntries.isNotEmpty || state.poseSegment != 0) return;
    final runtime = ref.read(benchPoseAvailabilityProvider).runtime;
    final plan = ref.read(benchPosePlanProvider);
    final sequence = _sequence;
    try {
      final store = await ref.read(poseRecordingStoreProvider.future);
      final saved = await store.loadBenchProgress();
      if (saved == null ||
          saved['runtime'] != runtime ||
          saved['plan'] != plan.signature ||
          saved['app_commit'] != ref.read(appCommitProvider) ||
          saved['completed'] == true) {
        await store.clearBenchProgress();
        return;
      }
      final rawEntries = saved['entries'];
      if (rawEntries is! List) return;
      final keys = <String>{};
      for (final raw in rawEntries) {
        if (raw is! Map) continue;
        final entry = {
          for (final field in raw.entries) '${field.key}': field.value,
        };
        final hand = entry['hand'];
        final segment = entry['segment'];
        final run = entry['run'];
        if (hand is! String || segment is! String || run is! int) continue;
        final file = entry['file'];
        if (entry['status'] == 'done' &&
            (file is! String || !store.hasRecording(file))) {
          continue;
        }
        final handIndex = hand == 'LEFT' ? 0 : 1;
        if (!keys.add('$handIndex:$segment:$run')) continue;
        _poseEntries.add(entry);
      }
      var next = 0;
      while (next < sequence.length && keys.contains(sequence[next].key)) {
        next++;
      }
      state = state.copyWith(poseSegment: next);
      _publishPoseProgress();
    } catch (_) {
      // No document directory in a test or a fresh install: start at run 1.
    }
  }

  /// Queues a progress write. Writes are chained so a later snapshot cannot be
  /// overtaken by an earlier one; the wizard never waits for the disk.
  void _queuePoseProgress({bool completed = false}) {
    final data = <String, Object?>{
      'version': 1,
      'runtime': ref.read(benchPoseAvailabilityProvider).runtime,
      'app_commit': ref.read(appCommitProvider),
      'plan': ref.read(benchPosePlanProvider).signature,
      'completed': completed,
      'entries': [..._poseEntries],
    };
    _poseProgressWrite = _poseProgressWrite.then((_) async {
      try {
        final store = await ref.read(poseRecordingStoreProvider.future);
        await store.saveBenchProgress(data);
      } catch (_) {
        // Progress is advisory; a failed write must not stop the corpus.
      }
    });
  }

  void _finishPose() {
    _poseCancel = null;
    _poseSkipRest = false;
    final plan = ref.read(benchPosePlanProvider);
    final done = _poseEntries.where((e) => e['status'] == 'done').length;
    final total = _sequence.length;
    final status = done == 0 ? BenchStatus.skipped : BenchStatus.done;
    _setResult(
      BenchStep.poseCapture,
      BenchStepResult(
        status: status,
        summary: done == 0
            ? 'No pose runs recorded'
            : '$done of $total pose runs recorded',
        error: done == 0 ? 'all runs skipped' : null,
        data: {
          'segments': [..._poseEntries],
          'plan': plan.signature,
          'runs_per_class': plan.runsPerClass,
          'min_run_seconds': plan.minRunDuration.inSeconds,
        },
      ),
    );
    _queuePoseProgress(completed: true);
    _advance();
  }

  void _skipRemainingPose(int from) {
    final sequence = _sequence;
    for (var index = from; index < sequence.length; index++) {
      _recordSkippedSegment(index);
    }
    _finishPose();
  }

  /// Republishes the segments captured so far while the step is still current.
  void _publishPoseProgress() {
    final plan = ref.read(benchPosePlanProvider);
    state = state.copyWith(
      results: {
        ...state.results,
        BenchStep.poseCapture: BenchStepResult(
          data: {
            'segments': [..._poseEntries],
            'plan': plan.signature,
            'runs_per_class': plan.runsPerClass,
            'min_run_seconds': plan.minRunDuration.inSeconds,
          },
        ),
      },
    );
    _publish();
  }

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

  /// Skips the step on screen and moves on. For the 6DoF step this skips only
  /// the segment shown, aborting its recording when one is in progress; use
  /// [skipRemainingPose] to abandon the rest. The export step cannot be
  /// skipped: the run ends in a bundle.
  void skipCurrent() {
    final step = state.step;
    if (step == BenchStep.export || state.exporting) return;
    if (step == BenchStep.poseCapture) {
      _skipPoseSegment();
      return;
    }
    if (state.busy) return;
    // Keep any partial data so the bundle still carries it.
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

  /// Skips the segment on screen: aborts it when it is recording, otherwise
  /// records it skipped, then moves to the next segment.
  void _skipPoseSegment() {
    final sequence = _sequence;
    final index = state.poseSegment;
    if (index >= sequence.length) return;
    if (state.current.status == BenchStatus.running) {
      final cancel = _poseCancel;
      if (cancel != null && !cancel.isCompleted) cancel.complete();
      return;
    }
    _recordSkippedSegment(index);
    if (index + 1 >= sequence.length) {
      _finishPose();
      return;
    }
    state = state.copyWith(poseSegment: index + 1);
    _publishPoseProgress();
  }

  /// Skips the segment on screen and every segment after it.
  void skipRemainingPose() {
    if (state.step != BenchStep.poseCapture) return;
    if (state.current.status == BenchStatus.running) {
      _poseSkipRest = true;
      final cancel = _poseCancel;
      if (cancel != null && !cancel.isCompleted) cancel.complete();
      return;
    }
    _skipRemainingPose(state.poseSegment);
  }

  void _recordSkippedSegment(int index) {
    final spec = _sequence[index];
    _poseEntries.add({
      'runtime': ref.read(benchPoseAvailabilityProvider).runtime,
      'hand': RealBenchSession.handName(spec.hand),
      'segment': spec.segment.id,
      'run': spec.run,
      'status': 'skipped',
      'reason': 'skipped by tester',
    });
    _queuePoseProgress();
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
      // still reach the export. In 6DoF only the mode cannot be selected
      // without hand joints, so this is the combined path.
      if (step == BenchStep.poseCapture) {
        final availability = ref.read(benchPoseAvailabilityProvider);
        if (!availability.available) {
          _setResult(
            step,
            BenchStepResult(
              status: BenchStatus.skipped,
              summary: availability.reason,
              error: availability.reason,
              data: const {'segments': []},
            ),
          );
          next++;
          continue;
        }
        _poseEntries.clear();
        _poseCancel = null;
        _poseSkipRest = false;
        _posePrepared = false;
      }
      break;
    }
    if (next >= steps.length) return;
    state = state.copyWith(step: steps[next], poseSegment: 0);
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
