import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../ble/ble_transport.dart';
import '../../domain/hand_pipeline.dart';
import '../../services/controller_service.dart';
import '../../services/latency_files.dart';
import '../../services/latency_recorder.dart';
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
    required this.stream,
    required this.linkInfo,
    required this.counters,
    this.priorityRequested,
  });

  final Stream<ReceivedFrame> frames;
  final Stream<DecodedSample> samples;
  final Stream<ModeState> modeChanges;
  final MonotonicClock clock;

  /// Name of the active stream mode.
  final String stream;

  /// Null when the platform cannot say.
  final Future<BleConnectionInfo?> Function() linkInfo;

  /// Service error counters, by name; the run reports how much they grew.
  final Map<String, int> Function() counters;
  final bool? priorityRequested;

  static LatencyInput fromService(
    ControllerService service, {
    bool? priorityRequested,
  }) {
    return LatencyInput(
      frames: service.frames,
      samples: service.decodedSamples,
      modeChanges: service.modeChanges,
      clock: service.transport.clock,
      stream: service.mode.name,
      priorityRequested: priorityRequested,
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

/// Resolved when a run starts. Null when there is no stream to measure.
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

/// Opens the system share sheet for a run's CSV and JSON.
final shareLatencyProvider =
    Provider<Future<void> Function(SavedLatencyRun run)>((ref) {
      return (run) async {
        await SharePlus.instance.share(
          ShareParams(
            files: [
              XFile(run.csvPath, mimeType: 'text/csv'),
              XFile(run.jsonPath, mimeType: 'application/json'),
            ],
          ),
        );
      };
    });

/// How often the live figures refresh while a run goes.
final latencyTickProvider = Provider<Duration>(
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

  LatencyState copyWith({
    LatencyStage? stage,
    int? Function()? durationSeconds,
    int? elapsedSeconds,
    LatencyReport? report,
    SavedLatencyRun? saved,
    List<SavedLatencyRun>? runs,
    String? error,
    bool clearError = false,
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

  @override
  LatencyState build() {
    ref.onDispose(() {
      _timer?.cancel();
      for (final s in _subs) {
        s.cancel();
      }
    });
    Future(refreshRuns);
    return const LatencyState();
  }

  Future<void> refreshRuns() async {
    final store = await ref.read(latencyStoreProvider.future);
    state = state.copyWith(runs: store.list());
  }

  void selectDuration(int? seconds) {
    if (state.stage == LatencyStage.running) return;
    state = state.copyWith(durationSeconds: () => seconds);
  }

  Future<void> start(DebugSource source) async {
    if (state.stage == LatencyStage.running) return;
    final input = await ref.read(latencyInputProvider)(source);
    if (input == null) {
      state = state.copyWith(error: 'Not connected to the bridge.');
      return;
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
      stream: input.stream,
    );
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
          if (m.mode.name != input.stream) recorder.markModeChanged();
        }),
      );
    state = LatencyState(
      stage: LatencyStage.running,
      durationSeconds: state.durationSeconds,
      report: _report(),
      runs: state.runs,
    );
    _timer?.cancel();
    _timer = Timer.periodic(ref.read(latencyTickProvider), (_) => _tick());
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

  LatencyReport _report() => _recorder!.report(
    nowUs: _input!.clock.nowUs,
    link: _link,
    counters: _counterGrowth(),
  );

  /// Ends the run and saves the CSV and JSON.
  Future<void> stop() async {
    if (state.stage != LatencyStage.running) return;
    _timer?.cancel();
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    final recorder = _recorder!;
    final input = _input!;
    final info = await input.linkInfo();
    _link = _link.withEnd(rssiEnd: info?.rssi);
    final report = _report();
    final elapsed = report.durationUs ~/ Duration.microsecondsPerSecond;
    _recorder = null;
    _input = null;
    try {
      final store = await ref.read(latencyStoreProvider.future);
      final saved = await store.save(recorder, report);
      state = state.copyWith(
        stage: LatencyStage.finished,
        elapsedSeconds: elapsed,
        report: report,
        saved: saved,
        clearError: true,
      );
      await refreshRuns();
    } on FileSystemException catch (e) {
      state = state.copyWith(
        stage: LatencyStage.finished,
        elapsedSeconds: elapsed,
        report: report,
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
    );
  }

  Future<void> share(SavedLatencyRun run) =>
      ref.read(shareLatencyProvider)(run);
}
