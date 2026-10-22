import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../ble/ble_transport.dart';
import '../../protocol/wmr_fragment.dart';
import '../../services/capture_files.dart';
import '../../services/capture_recorder.dart';
import '../../services/controller_service.dart';
import '../connect/connect_providers.dart';

/// What a capture reads from: the frame stream ControllerService already
/// reassembles (no second subscription), its clock and the negotiated MTU.
class CaptureInput {
  const CaptureInput({
    required this.frames,
    required this.clock,
    required this.mtu,
  });

  final Stream<ReceivedFrame> frames;
  final MonotonicClock clock;
  final int? mtu;
}

/// Resolved when a capture starts. Null when there is no connection.
final captureInputProvider = Provider<CaptureInput? Function()>((ref) {
  return () {
    final device = ref.read(realDeviceProvider);
    final service = ref.read(realDeviceProvider.notifier).service;
    if (service == null || !device.connected) return null;
    return CaptureInput(
      frames: service.frames,
      clock: ref.read(realTransportProvider).clock,
      mtu: device.status.mtu,
    );
  };
});

final captureStoreProvider = FutureProvider<CaptureStore>((ref) async {
  return CaptureStore(await getApplicationDocumentsDirectory());
});

/// Opens the system share sheet for one file.
final shareCaptureProvider = Provider<Future<void> Function(String path)>((
  ref,
) {
  return (path) async {
    await SharePlus.instance.share(
      ShareParams(files: [XFile(path, mimeType: 'text/plain')]),
    );
  };
});

/// Length of one countdown / elapsed-time step.
final captureTickProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 1),
);

const int captureCountdownSeconds = 3;

enum CaptureStage { setup, ready, countdown, recording, finished }

class CaptureState {
  const CaptureState({
    this.stage = CaptureStage.setup,
    this.hand = wmrHandLeft,
    this.phaseIndex = 0,
    this.countdown = 0,
    this.elapsedSeconds = 0,
    this.summaries = const [],
    this.path,
    this.skippedFrames = 0,
    this.error,
    this.saved = const [],
  });

  final CaptureStage stage;
  final int hand;
  final int phaseIndex;
  final int countdown;
  final int elapsedSeconds;
  final List<PhaseSummary> summaries;

  /// Where the file is being written, once a run has started.
  final String? path;
  final int skippedFrames;
  final String? error;
  final List<SavedCapture> saved;

  CapturePhase get phase => capturePhases[phaseIndex];

  bool get canFinish =>
      stage == CaptureStage.recording && elapsedSeconds >= phase.minSeconds;

  CaptureState copyWith({
    CaptureStage? stage,
    int? hand,
    int? phaseIndex,
    int? countdown,
    int? elapsedSeconds,
    List<PhaseSummary>? summaries,
    String? path,
    int? skippedFrames,
    String? error,
    bool clearError = false,
    List<SavedCapture>? saved,
  }) {
    return CaptureState(
      stage: stage ?? this.stage,
      hand: hand ?? this.hand,
      phaseIndex: phaseIndex ?? this.phaseIndex,
      countdown: countdown ?? this.countdown,
      elapsedSeconds: elapsedSeconds ?? this.elapsedSeconds,
      summaries: summaries ?? this.summaries,
      path: path ?? this.path,
      skippedFrames: skippedFrames ?? this.skippedFrames,
      error: clearError ? null : (error ?? this.error),
      saved: saved ?? this.saved,
    );
  }
}

final captureControllerProvider =
    NotifierProvider.autoDispose<CaptureController, CaptureState>(
      CaptureController.new,
    );

/// Drives the guided procedure. Frames are handed to a [CaptureRecorder]
/// whose sink buffers, so the receive path does no I/O waiting.
class CaptureController extends Notifier<CaptureState> {
  CaptureRecorder? _recorder;
  CaptureInput? _input;
  StreamSubscription<ReceivedFrame>? _frameSub;
  Timer? _timer;
  int _phaseStartUs = 0;

  @override
  CaptureState build() {
    ref.onDispose(() {
      _timer?.cancel();
      _frameSub?.cancel();
      _recorder?.close();
    });
    Future(refreshSaved);
    return const CaptureState();
  }

  /// Also runs from [build] a turn later, so the notifier may be gone.
  Future<void> refreshSaved() async {
    if (!ref.mounted) return;
    final store = await ref.read(captureStoreProvider.future);
    if (!ref.mounted) return;
    state = state.copyWith(saved: store.list());
  }

  void selectHand(int hand) {
    if (state.stage == CaptureStage.setup) {
      state = state.copyWith(hand: hand);
    }
  }

  /// Opens the file and starts listening. Does not record until a phase
  /// begins.
  Future<void> start() async {
    final input = ref.read(captureInputProvider)();
    if (input == null) {
      state = state.copyWith(error: 'Not connected to the bridge.');
      return;
    }
    try {
      final store = await ref.read(captureStoreProvider.future);
      final now = DateTime.now();
      final file = store.newFile(state.hand, now);
      _input = input;
      _recorder = CaptureRecorder(
        sink: FileCaptureSink(file),
        hand: state.hand,
        mtu: input.mtu,
        started: now,
        originUs: input.clock.nowUs,
      );
      _frameSub = input.frames.listen(_recorder!.addFrame);
      state = CaptureState(
        stage: CaptureStage.ready,
        hand: state.hand,
        path: file.path,
        saved: state.saved,
      );
    } on FileSystemException catch (e) {
      state = state.copyWith(error: 'Cannot create the file: ${e.message}');
    }
  }

  /// "Start" on a phase: countdown, then the `@begin` marker.
  void beginPhase() {
    if (state.stage != CaptureStage.ready) return;
    final tick = ref.read(captureTickProvider);
    state = state.copyWith(
      stage: CaptureStage.countdown,
      countdown: captureCountdownSeconds,
    );
    _timer?.cancel();
    _timer = Timer.periodic(tick, (t) {
      final left = state.countdown - 1;
      if (left > 0) {
        state = state.copyWith(countdown: left);
        return;
      }
      t.cancel();
      _phaseStartUs = _input!.clock.nowUs;
      _recorder!.beginPhase(state.phase.name, _phaseStartUs);
      state = state.copyWith(
        stage: CaptureStage.recording,
        countdown: 0,
        elapsedSeconds: 0,
      );
      _timer = Timer.periodic(tick, (_) {
        final us = _input!.clock.nowUs - _phaseStartUs;
        state = state.copyWith(
          elapsedSeconds: us ~/ Duration.microsecondsPerSecond,
        );
      });
    });
  }

  /// "Finish": the `@end` marker, then the next phase or the end of the run.
  Future<void> finishPhase() async {
    if (!state.canFinish) return;
    _timer?.cancel();
    final recorder = _recorder!;
    final summary = recorder.endPhase(_input!.clock.nowUs);
    final summaries = [...state.summaries, summary];
    if (state.phaseIndex + 1 < capturePhases.length) {
      state = state.copyWith(
        stage: CaptureStage.ready,
        phaseIndex: state.phaseIndex + 1,
        summaries: summaries,
        skippedFrames: recorder.skippedFrames,
      );
      return;
    }
    await _frameSub?.cancel();
    _frameSub = null;
    await recorder.close();
    _recorder = null;
    state = state.copyWith(
      stage: CaptureStage.finished,
      summaries: summaries,
      skippedFrames: recorder.skippedFrames,
    );
    await refreshSaved();
  }

  /// Stops a run early. The partial file stays on disk, with no `@end` for a
  /// phase that was running.
  Future<void> abort() async {
    _timer?.cancel();
    await _frameSub?.cancel();
    _frameSub = null;
    await _recorder?.close();
    _recorder = null;
    state = CaptureState(hand: state.hand, saved: state.saved);
    await refreshSaved();
  }

  Future<void> share(String path) => ref.read(shareCaptureProvider)(path);
}
