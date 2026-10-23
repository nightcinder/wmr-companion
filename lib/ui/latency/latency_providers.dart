import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'package:wmr_core/ble/ble_transport.dart';
import 'package:wmr_core/domain/hand_pipeline.dart';
import 'package:wmr_core/services/controller_service.dart';
import 'package:wmr_core/services/echo_client.dart';
import 'package:wmr_core/services/latency_files.dart';
import 'package:wmr_core/services/latency_recorder.dart';

import '../connect/connect_providers.dart';
import '../debug/debug_providers.dart';

/// What a run reads from: the frame and sample streams ControllerService
/// already produces (no second subscription), its clock and the link.
class LatencyInput {
  const LatencyInput({
    required this.frames,
    required this.samples,
    required this.modeChanges,
    required this.clock,
    required this.mode,
    required this.linkInfo,
    required this.counters,
    this.setMode,
    this.priorityRequested,
    this.echoFactory,
  });

  final Stream<ReceivedFrame> frames;
  final Stream<DecodedSample> samples;
  final Stream<ModeState> modeChanges;
  final MonotonicClock clock;

  /// The service mode when the input was resolved. [StreamMode.none] means
  /// the run measures only FF15: no stream figures.
  final StreamMode mode;

  /// Switches the service mode through its normal API. Null in tests that do
  /// not use the selector.
  final Future<void> Function(StreamMode)? setMode;

  /// Null when the platform cannot say.
  final Future<BleConnectionInfo?> Function() linkInfo;

  /// Service error counters, by name; the run reports how much they grew.
  final Map<String, int> Function() counters;
  final bool? priorityRequested;

  /// Makes the FF15 echo client for this connection; null when there is none
  /// (nothing to ping).
  final EchoClient Function(Duration timeout)? echoFactory;

  static LatencyInput fromService(
    ControllerService service, {
    bool? priorityRequested,
  }) {
    return LatencyInput(
      frames: service.frames,
      samples: service.decodedSamples,
      modeChanges: service.modeChanges,
      clock: service.transport.clock,
      mode: service.mode,
      setMode: service.setMode,
      priorityRequested: priorityRequested,
      echoFactory: (timeout) =>
          EchoClient(service.transport, service.deviceId, timeout: timeout),
      linkInfo: () async {
        try {
          return await service.transport.connectionInfo(service.deviceId);
        } catch (_) {
          return null;
        }
      },
      counters: () {
        final raw = service.stats;
        final decoded = service.decodedStats;
        var incomplete = 0;
        for (final h in raw.hands) {
          incomplete += h.incomplete;
        }
        return {
          'incomplete_frames': incomplete,
          'reassembly_errors': raw.errors,
          'decoded_parse_errors': decoded.parseErrors,
        };
      },
    );
  }
}

/// The latency screen's stream choice. [none] is the run mode where FF11,
/// FF12 and FF14 are all off and only FF15 pings.
enum LatencyStream {
  none(StreamMode.none, 'None'),
  raw(StreamMode.raw, 'FF11 raw'),
  decoded(StreamMode.decoded, 'FF12 decoded'),
  batched(StreamMode.batched, 'FF14 batched');

  const LatencyStream(this.mode, this.label);

  final StreamMode mode;
  final String label;

  bool get isNone => this == LatencyStream.none;

  static LatencyStream fromMode(StreamMode mode) => switch (mode) {
    StreamMode.none => LatencyStream.none,
    StreamMode.raw => LatencyStream.raw,
    StreamMode.decoded => LatencyStream.decoded,
    StreamMode.batched => LatencyStream.batched,
  };
}

/// Resolved when a run starts. Null when there is no connection.
final latencyInputProvider =
    Provider<Future<LatencyInput?> Function(DebugSource)>((ref) {
      return (source) async {
        switch (source) {
          case DebugSource.fake:
            final service = await ref.read(fakeServiceProvider.future);
            return LatencyInput.fromService(service);
          case DebugSource.real:
            final device = ref.read(realDeviceProvider);
            final service = ref.read(realDeviceProvider.notifier).service;
            if (service == null || !device.connected) return null;
            return LatencyInput.fromService(
              service,
              priorityRequested: device.status.priorityRequested,
            );
        }
      };
    });

final latencyStoreProvider = FutureProvider<LatencyStore>((ref) async {
  final docs = await getApplicationDocumentsDirectory();
  return LatencyStore(
    Directory('${docs.path}${Platform.pathSeparator}latency'),
  );
});

/// Opens the system share sheet for a run's files (CSV, JSON, echo CSV).
final shareLatencyProvider =
    Provider<Future<void> Function(SavedLatencyRun run)>((ref) {
      return (run) async {
        await SharePlus.instance.share(
          ShareParams(
            files: [
              for (final p in run.paths)
                XFile(
                  p,
                  mimeType: p.endsWith('.json')
                      ? 'application/json'
                      : 'text/csv',
                ),
            ],
          ),
        );
      };
    });

/// How often the live figures refresh while a run goes.
final latencyTickProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 1),
);

/// Time between echo pings. One is outstanding at a time; a tick that finds
/// the previous ping still waiting does nothing.
final echoIntervalProvider = Provider<Duration>(
  (ref) => const Duration(milliseconds: 250),
);

/// Wait for an echo answer before counting the ping as lost.
final echoTimeoutProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 1),
);

/// Run lengths offered; null runs until Stop.
const List<int?> latencyDurations = [30, 60, 120, null];

enum LatencyStage { idle, running, finished }

class LatencyState {
  const LatencyState({
    this.stage = LatencyStage.idle,
    this.durationSeconds = 120,
    this.elapsedSeconds = 0,
    this.report,
    this.saved,
    this.runs = const [],
    this.error,
    this.echoEnabled = true,
    this.echoNote,
    this.streamChoice,
    this.echoInterval = const Duration(milliseconds: 250),
  });

  final LatencyStage stage;

  /// Null: until Stop.
  final int? durationSeconds;
  final int elapsedSeconds;

  /// Live while running, final once finished.
  final LatencyReport? report;

  /// Files of the run that just finished.
  final SavedLatencyRun? saved;
  final List<SavedLatencyRun> runs;
  final String? error;

  /// Whether the next run pings the FF15 echo.
  final bool echoEnabled;

  /// Why a run goes without a round trip, when echo was asked for.
  final String? echoNote;

  /// The stream the user picked on this screen. Null: follow the service's
  /// current mode (the old behaviour: measure whatever stream is active).
  final LatencyStream? streamChoice;

  /// Time between echo pings; one is outstanding at a time.
  final Duration echoInterval;

  LatencyState copyWith({
    LatencyStage? stage,
    int? Function()? durationSeconds,
    int? elapsedSeconds,
    LatencyReport? report,
    SavedLatencyRun? saved,
    List<SavedLatencyRun>? runs,
    String? error,
    bool clearError = false,
    bool? echoEnabled,
    String? Function()? echoNote,
    LatencyStream? streamChoice,
    Duration? echoInterval,
  }) {
    return LatencyState(
      stage: stage ?? this.stage,
      durationSeconds: durationSeconds != null
          ? durationSeconds()
          : this.durationSeconds,
      elapsedSeconds: elapsedSeconds ?? this.elapsedSeconds,
      report: report ?? this.report,
      saved: saved ?? this.saved,
      runs: runs ?? this.runs,
      error: clearError ? null : (error ?? this.error),
      echoEnabled: echoEnabled ?? this.echoEnabled,
      echoNote: echoNote != null ? echoNote() : this.echoNote,
      streamChoice: streamChoice ?? this.streamChoice,
      echoInterval: echoInterval ?? this.echoInterval,
    );
  }
}

final latencyControllerProvider =
    NotifierProvider.autoDispose<LatencyController, LatencyState>(
      LatencyController.new,
    );

/// Runs one measurement at a time and saves it when it ends.
class LatencyController extends Notifier<LatencyState> {
  LatencyRecorder? _recorder;
  LatencyInput? _input;
  LatencyLink _link = const LatencyLink();
  Map<String, int> _countersAtStart = const {};
  final List<StreamSubscription<Object?>> _subs = [];
  Timer? _timer;
  Timer? _echoTimer;
  EchoClient? _echo;

  /// Mode to restore when a no-stream run ends. Set when this screen turns a
  /// stream off; cleared when the user picks a stream explicitly.
  StreamMode? _restoreMode;

  @override
  LatencyState build() {
    ref.onDispose(() {
      _timer?.cancel();
      _echoTimer?.cancel();
      _echo?.dispose();
      for (final s in _subs) {
        s.cancel();
      }
      final input = _input;
      final restore = _restoreMode;
      _restoreMode = null;
      if (input != null && restore != null) {
        // Leaving the screen mid-run must not leave the bridge without the
        // stream the rest of the app expects.
        unawaited(input.setMode?.call(restore) ?? Future<void>.value());
      }
    });
    Future(refreshRuns);
    return LatencyState(echoInterval: ref.read(echoIntervalProvider));
  }

  /// Also runs from [build] a turn later, so the notifier may be gone.
  Future<void> refreshRuns() async {
    if (!ref.mounted) return;
    final store = await ref.read(latencyStoreProvider.future);
    if (!ref.mounted) return;
    state = state.copyWith(runs: store.list());
  }

  void selectDuration(int? seconds) {
    if (state.stage == LatencyStage.running) return;
    state = state.copyWith(durationSeconds: () => seconds);
  }

  void setEchoEnabled(bool on) {
    if (state.stage == LatencyStage.running) return;
    state = state.copyWith(echoEnabled: on, echoNote: () => null);
  }

  /// Chooses the stream and applies it through [ControllerService.setMode]
  /// before the run. [LatencyStream.none] turns the active stream off and
  /// remembers it for [stop]; picking a stream again clears that memory.
  Future<void> selectStream(DebugSource source, LatencyStream choice) async {
    if (state.stage == LatencyStage.running) return;
    final input = await ref.read(latencyInputProvider)(source);
    if (input == null) {
      state = state.copyWith(error: 'Not connected to the bridge.');
      return;
    }
    // Keep it for the dispose restore even when no run starts.
    _input = input;
    final wanted = choice.mode;
    if (choice.isNone) {
      if (input.mode != StreamMode.none && _restoreMode == null) {
        _restoreMode = input.mode;
      }
    } else {
      _restoreMode = null;
    }
    if (input.mode != wanted) {
      final setMode = input.setMode;
      if (setMode == null) {
        state = state.copyWith(error: 'Cannot switch the stream here.');
        return;
      }
      try {
        await setMode(wanted);
      } catch (e) {
        state = state.copyWith(error: 'Cannot switch the stream: $e');
        return;
      }
    }
    state = state.copyWith(streamChoice: choice, clearError: true);
  }

  void selectEchoInterval(Duration interval) {
    if (state.stage == LatencyStage.running) return;
    state = state.copyWith(echoInterval: interval);
  }

  Future<void> start(DebugSource source) async {
    if (state.stage == LatencyStage.running) return;
    final input = await ref.read(latencyInputProvider)(source);
    if (input == null) {
      state = state.copyWith(error: 'Not connected to the bridge.');
      return;
    }
    var activeMode = input.mode;
    final choice = state.streamChoice;
    if (choice != null && choice.mode != activeMode) {
      final setMode = input.setMode;
      if (setMode == null) {
        state = state.copyWith(error: 'Cannot switch the stream here.');
        return;
      }
      if (choice.isNone && _restoreMode == null) _restoreMode = activeMode;
      try {
        await setMode(choice.mode);
      } catch (e) {
        state = state.copyWith(error: 'Cannot switch the stream: $e');
        return;
      }
      activeMode = choice.mode;
    }
    _input = input;
    final info = await input.linkInfo();
    _link = LatencyLink(
      mtu: info?.mtu,
      rssiStart: info?.rssi,
      connectionIntervalUs: info?.connectionIntervalUs,
      phy: info?.phy,
      priorityRequested: input.priorityRequested,
    );
    _countersAtStart = input.counters();
    final recorder = _recorder = LatencyRecorder(
      started: DateTime.now(),
      originUs: input.clock.nowUs,
      stream: activeMode.name,
    );
    String? note;
    final factory = input.echoFactory;
    if (state.echoEnabled && factory != null) {
      final echo = _echo = factory(ref.read(echoTimeoutProvider));
      if (await echo.start()) {
        recorder.useEcho();
        _echoTimer = Timer.periodic(
          state.echoInterval,
          (_) => unawaited(_pingOnce(recorder, echo)),
        );
      } else {
        _echo = null;
        note = echo.support == EchoSupport.unsupported
            ? 'This bridge has no FF15 echo (firmware older than WMR_Bridge '
                  '#13): running without a round trip.'
            : 'Echo setup failed (${echo.lastError}): running without a '
                  'round trip.';
        unawaited(echo.dispose());
      }
    }
    _subs
      ..add(
        input.frames.listen(
          (f) =>
              recorder.addFrame(f.frame.hand, f.frame.sequence, f.receivedAtUs),
        ),
      )
      ..add(
        input.samples.listen(
          (s) => recorder.addRecord(
            s.record.hand,
            s.record.sequence,
            s.receivedAtUs,
            deviceTicks: s.record.deviceTicks,
            espRxUs: s.record.rxTimeUs,
          ),
        ),
      )
      ..add(
        input.modeChanges.listen((m) {
          if (m.mode.name != activeMode.name) recorder.markModeChanged();
        }),
      );
    state = LatencyState(
      stage: LatencyStage.running,
      durationSeconds: state.durationSeconds,
      report: _report(),
      runs: state.runs,
      echoEnabled: state.echoEnabled,
      echoNote: note,
      streamChoice: state.streamChoice,
      echoInterval: state.echoInterval,
    );
    _timer?.cancel();
    _timer = Timer.periodic(ref.read(latencyTickProvider), (_) => _tick());
  }

  Future<void> _pingOnce(LatencyRecorder recorder, EchoClient echo) async {
    if (echo.busy) return;
    final r = await echo.ping();
    // The run may have ended while the ping was out.
    if (!identical(recorder, _recorder)) return;
    final sample = r.sample;
    if (sample != null) {
      recorder.addEcho(sample);
      return;
    }
    switch (r.failure!) {
      case EchoFailure.timeout:
        recorder.addEchoTimeout();
      case EchoFailure.writeFailed:
        recorder.addEchoFailure();
      case EchoFailure.busy:
      case EchoFailure.cancelled:
        break;
    }
  }

  void _tick() {
    final input = _input;
    if (input == null || _recorder == null) return;
    final elapsed =
        (input.clock.nowUs - _recorder!.originUs) ~/
        Duration.microsecondsPerSecond;
    final limit = state.durationSeconds;
    if (limit != null && elapsed >= limit) {
      unawaited(stop());
      return;
    }
    state = state.copyWith(elapsedSeconds: elapsed, report: _report());
  }

  Map<String, int> _counterGrowth() {
    final now = _input!.counters();
    return {
      for (final e in now.entries)
        e.key: e.value - (_countersAtStart[e.key] ?? 0),
    };
  }

  LatencyReport _report() {
    final echo = _echo;
    return _recorder!.report(
      nowUs: _input!.clock.nowUs,
      link: _link,
      counters: _counterGrowth(),
      echoIntervalUs: state.echoInterval.inMicroseconds,
      echoCounters: echo == null
          ? const {}
          : {
              'late_or_duplicate_answers': echo.stale,
              'bad_answers': echo.badAnswers,
              'pings_skipped_busy': echo.skipped,
            },
    );
  }

  /// Ends the run and saves the CSV and JSON. Also the cancel path: a no-stream
  /// run restores the mode the screen turned off.
  Future<void> stop() async {
    if (state.stage != LatencyStage.running) return;
    _timer?.cancel();
    _echoTimer?.cancel();
    _echoTimer = null;
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    final recorder = _recorder!;
    final input = _input!;
    final info = await input.linkInfo();
    _link = _link.withEnd(rssiEnd: info?.rssi);
    final report = _report();
    final echo = _echo;
    _echo = null;
    await echo?.dispose();
    final elapsed = report.durationUs ~/ Duration.microsecondsPerSecond;
    _recorder = null;
    _input = null;
    final restore = _restoreMode;
    _restoreMode = null;
    String? restoreError;
    if (restore != null) {
      final setMode = input.setMode;
      if (setMode == null) {
        restoreError =
            'The stream was not restored: switching is not '
            'available here.';
      } else {
        try {
          await setMode(restore);
        } catch (e) {
          restoreError = 'The stream was not restored: $e';
        }
      }
    }
    final restoredChoice = restore == null
        ? state.streamChoice
        : LatencyStream.fromMode(restore);
    try {
      final store = await ref.read(latencyStoreProvider.future);
      final saved = await store.save(recorder, report);
      state = state.copyWith(
        stage: LatencyStage.finished,
        elapsedSeconds: elapsed,
        report: report,
        saved: saved,
        streamChoice: restoredChoice,
        clearError: true,
      );
      if (restoreError != null) {
        state = state.copyWith(error: restoreError);
      }
      await refreshRuns();
    } on FileSystemException catch (e) {
      state = state.copyWith(
        stage: LatencyStage.finished,
        elapsedSeconds: elapsed,
        report: report,
        streamChoice: restoredChoice,
        error: 'Cannot save the run: ${e.message}',
      );
    }
  }

  /// Back to the start, keeping the saved runs.
  void reset() {
    if (state.stage == LatencyStage.running) return;
    state = LatencyState(
      durationSeconds: state.durationSeconds,
      runs: state.runs,
      echoEnabled: state.echoEnabled,
      echoInterval: state.echoInterval,
    );
  }

  Future<void> share(SavedLatencyRun run) =>
      ref.read(shareLatencyProvider)(run);
}
