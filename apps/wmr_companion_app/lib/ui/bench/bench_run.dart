import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:wmr_core/ble/ble_transport.dart';
import 'package:wmr_core/protocol/wmr_fragment.dart';
import 'package:wmr_core/services/capture_files.dart';
import 'package:wmr_core/services/capture_recorder.dart';
import 'package:wmr_core/services/config_client.dart';
import 'package:wmr_core/services/controller_service.dart';
import 'package:wmr_core/services/latency_files.dart';
import 'package:wmr_core/services/latency_recorder.dart';
import 'package:wmr_tracking/wmr_tracking.dart';

import '../capture/capture_providers.dart';
import '../connect/connect_providers.dart';
import '../debug/debug_providers.dart';
import '../debug/pose_recording_store.dart';
import '../latency/latency_providers.dart';

/// How long each measured step runs. Tests override it to a few milliseconds.
class BenchDurations {
  const BenchDurations({
    this.still = const Duration(seconds: 20),
    this.move = const Duration(seconds: 20),
    this.capture = const Duration(seconds: 60),
    this.latency = const Duration(seconds: 30),
    this.handTimeout = const Duration(seconds: 5),
    this.firmwareTimeout = const Duration(seconds: 3),
    this.poseStill = const Duration(seconds: 10),
    this.poseHeldDrift = const Duration(seconds: 10),
    this.poseSlowPan = const Duration(seconds: 18),
    this.poseMediumPan = const Duration(seconds: 10),
    this.poseFastFlick = const Duration(seconds: 10),
  });

  final Duration still;
  final Duration move;
  final Duration capture;
  final Duration latency;

  /// How long to wait for the first frames of both hands.
  final Duration handTimeout;

  /// How long to wait for the one-time FF16 read.
  final Duration firmwareTimeout;

  final Duration poseStill;
  final Duration poseHeldDrift;
  final Duration poseSlowPan;
  final Duration poseMediumPan;
  final Duration poseFastFlick;

  Duration forPoseSegment(PoseSegment segment) => switch (segment) {
    PoseSegment.still => poseStill,
    PoseSegment.heldDrift => poseHeldDrift,
    PoseSegment.slowPan => poseSlowPan,
    PoseSegment.mediumPan => poseMediumPan,
    PoseSegment.fastFlick => poseFastFlick,
  };
}

/// One capture segment from filter-spec rev 4 section 8.
///
/// The id is part of the capture file name and the manifest, so it stays
/// stable even when the prompt text changes.
enum PoseSegment {
  still(
    'still',
    'Still',
    'Hold the hand still, arm braced, as if it rested on a table.',
  ),
  heldDrift(
    'heldDrift',
    'Held, drifting',
    'Hold the hand as if aiming and let it wander slowly.',
  ),
  slowPan(
    'slowPan',
    'Slow pan',
    'Move 30 cm sideways over 3 s, back and forth, 3 times.',
  ),
  mediumPan(
    'mediumPan',
    'Medium pan',
    'Move 50 cm sideways in 1 s, back and forth, for 10 s.',
  ),
  fastFlick(
    'fastFlick',
    'Fast flick',
    'Flick 45 cm in 0.3 s, pause, then return. 10 times.',
  );

  const PoseSegment(this.id, this.label, this.prompt);

  final String id;
  final String label;
  final String prompt;
}

/// The segment the capture step is recording now, for the screen prompt.
class BenchCaptureProgress {
  const BenchCaptureProgress({
    required this.hand,
    required this.segment,
    required this.index,
    required this.total,
  });

  final int hand;
  final PoseSegment segment;

  /// Zero-based index in the whole per-hand sequence, across both hands.
  final int index;
  final int total;

  String get handName => hand == wmrHandLeft ? 'LEFT' : 'RIGHT';
}

/// The wizard variant chosen on the bench page.
enum BenchMode {
  threeDofOnly('3dof_only', '3DoF only'),
  sixDofOnly('6dof_only', '6DoF only'),
  combined('combined', 'Combined');

  const BenchMode(this.id, this.label);

  final String id;
  final String label;

  List<BenchStep> get steps => switch (this) {
    BenchMode.threeDofOnly => const [
      BenchStep.connect,
      BenchStep.bothHands,
      BenchStep.firmwareConfig,
      BenchStep.stillLeft,
      BenchStep.stillRight,
      BenchStep.moveLeft,
      BenchStep.moveRight,
      BenchStep.capture,
      BenchStep.latency,
      BenchStep.photo,
      BenchStep.serialLog,
      BenchStep.export,
    ],
    BenchMode.sixDofOnly => const [
      BenchStep.deviceSummary,
      BenchStep.connect,
      BenchStep.bothHands,
      BenchStep.firmwareConfig,
      BenchStep.stillLeft,
      BenchStep.stillRight,
      BenchStep.moveLeft,
      BenchStep.moveRight,
      BenchStep.capture,
      BenchStep.latency,
      BenchStep.photo,
      BenchStep.serialLog,
      BenchStep.poseCapture,
      BenchStep.export,
    ],
    BenchMode.combined => const [
      BenchStep.connect,
      BenchStep.bothHands,
      BenchStep.firmwareConfig,
      BenchStep.stillLeft,
      BenchStep.stillRight,
      BenchStep.moveLeft,
      BenchStep.moveRight,
      BenchStep.capture,
      BenchStep.latency,
      BenchStep.photo,
      BenchStep.serialLog,
      BenchStep.poseCapture,
      BenchStep.export,
    ],
  };

  /// Steps that need the bridge. In [sixDofOnly] they are recorded as skipped
  /// instead of being removed, so the manifest says why they did not run.
  static const List<BenchStep> bridgeOnlySteps = [
    BenchStep.connect,
    BenchStep.bothHands,
    BenchStep.firmwareConfig,
    BenchStep.stillLeft,
    BenchStep.stillRight,
    BenchStep.moveLeft,
    BenchStep.moveRight,
    BenchStep.capture,
    BenchStep.latency,
    BenchStep.photo,
    BenchStep.serialLog,
  ];
}

final benchDurationsProvider = Provider<BenchDurations>(
  (ref) => const BenchDurations(),
);

/// Every step any bench mode can use. Each [BenchMode] supplies its own order.
/// The id is what the manifest and the tests key on.
enum BenchStep {
  deviceSummary('device_summary'),
  connect('connect'),
  bothHands('both_hands'),
  firmwareConfig('firmware_config'),
  stillLeft('still_left'),
  stillRight('still_right'),
  moveLeft('move_left'),
  moveRight('move_right'),
  capture('capture'),
  latency('latency'),
  photo('photo'),
  serialLog('serial_log'),
  poseCapture('pose_capture'),
  export('export');

  const BenchStep(this.id);

  final String id;

  String get title => switch (this) {
    BenchStep.deviceSummary => 'Device and capability summary',
    BenchStep.connect => 'Connect the bridge',
    BenchStep.bothHands => 'Both hands seen',
    BenchStep.firmwareConfig => 'Firmware and config',
    BenchStep.stillLeft => 'LEFT: hold still',
    BenchStep.stillRight => 'RIGHT: hold still',
    BenchStep.moveLeft => 'LEFT: slow move',
    BenchStep.moveRight => 'RIGHT: slow move',
    BenchStep.capture => 'Record 60 s of FF11',
    BenchStep.latency => 'Measure latency',
    BenchStep.photo => 'LED photo',
    BenchStep.serialLog => 'Serial log',
    BenchStep.poseCapture => 'Pose capture',
    BenchStep.export => 'Write the test bundle',
  };

  String instructions(BenchDurations durations) => switch (this) {
    BenchStep.connect =>
      'Connect one bridge for each hand from the Connect screen. This step '
          'checks that the link is up before the run starts.',
    BenchStep.bothHands =>
      'Turn both controllers on and press any button on each. The run waits '
          'until raw frames from LEFT and RIGHT have arrived.',
    BenchStep.firmwareConfig =>
      'Reads the firmware version (FF16) and both controller config blocks '
          '(FF13). A controller that does not answer is recorded, not fatal.',
    BenchStep.stillLeft =>
      'Put the LEFT controller on a flat surface, ring up, and do not touch '
          'it for ${durations.still.inSeconds} s.',
    BenchStep.stillRight =>
      'Put the RIGHT controller on a flat surface, ring up, and do not touch '
          'it for ${durations.still.inSeconds} s.',
    BenchStep.moveLeft =>
      'Hold the LEFT controller and move it slowly and smoothly for '
          '${durations.move.inSeconds} s. No fast flicks.',
    BenchStep.moveRight =>
      'Hold the RIGHT controller and move it slowly and smoothly for '
          '${durations.move.inSeconds} s. No fast flicks.',
    BenchStep.capture =>
      'Records the FF11 raw stream for ${durations.capture.inSeconds} s and '
          'saves it with the other captures.',
    BenchStep.latency =>
      'Runs the link measurement for ${durations.latency.inSeconds} s and '
          'saves the CSV and JSON with the other latency runs.',
    BenchStep.photo =>
      'Take a photo of the bridge LED with the controller powered on. The '
          'photo is attached outside the app; mark this step done once you '
          'have it.',
    BenchStep.serialLog =>
      'Save the bridge serial log (Pi daemon log or USB console) from this '
          'run. Attach it outside the app; mark this step done once you have '
          'it.',
    BenchStep.deviceSummary =>
      'Reports the attached hand-tracking runtime and the joints and rate it '
          'offers. No bridge is needed for the 6DoF path.',
    BenchStep.poseCapture =>
      'Records five segments with each hand from the attached tracking source. '
          'Follow the prompt on screen; each segment becomes one pose recording '
          'in the bundle.',
    BenchStep.export =>
      'Writes the same zip as Export test bundle, with this run\'s step '
          'results in the manifest, then opens the share sheet.',
  };

  /// Prompts are confirmed by the tester; they do not run a measurement.
  bool get isPrompt => this == BenchStep.photo || this == BenchStep.serialLog;

  bool get isMeasured => !isPrompt && this != BenchStep.export;
}

/// The outcome of one step, before it goes into the manifest.
class BenchStepOutcome {
  const BenchStepOutcome.done(this.summary, {this.data = const {}})
    : ok = true,
      error = null;

  const BenchStepOutcome.failed(this.error, {this.data = const {}})
    : ok = false,
      summary = null;

  final bool ok;
  final String? summary;
  final String? error;
  final Map<String, Object?> data;
}

/// Runs the bench steps against the live service. One instance per run; the
/// wizard creates it when the first step starts.
abstract class BenchSession {
  Future<BenchStepOutcome> deviceSummary();
  Future<BenchStepOutcome> connect();
  Future<BenchStepOutcome> bothHands();
  Future<BenchStepOutcome> firmwareConfig();
  Future<BenchStepOutcome> still(int hand);
  Future<BenchStepOutcome> move(int hand);
  Future<BenchStepOutcome> capture();
  Future<BenchStepOutcome> latency();
  Future<BenchStepOutcome> poseCapture(
    void Function(BenchCaptureProgress progress) onProgress,
  );
}

/// The real session: reads and records through [ControllerService], the same
/// paths the Capture and Latency screens use.
class RealBenchSession implements BenchSession {
  RealBenchSession({
    this.service,
    this.tracking,
    this.poseStore,
    required this.clock,
    required this.captureStore,
    required this.latencyStore,
    required this.durations,
    this.mtu,
  });

  /// Null in the 6DoF-only path, where no bridge is attached.
  final ControllerService? service;

  /// The attached hand-tracking runtime, already started.
  final TrackingSource? tracking;

  /// Where pose captures are written. Null disables the capture step.
  final PoseRecordingStore? poseStore;

  final MonotonicClock clock;
  final CaptureStore captureStore;
  final LatencyStore latencyStore;
  final BenchDurations durations;
  final int? mtu;

  static String handName(int hand) => hand == wmrHandLeft ? 'LEFT' : 'RIGHT';

  ControllerService get _service {
    final service = this.service;
    if (service == null) throw StateError('This step needs a bridge.');
    return service;
  }

  @override
  Future<BenchStepOutcome> deviceSummary() async {
    final source = tracking;
    final caps = source?.capabilities;
    final data = <String, Object?>{
      'runtime': source?.vendor.name,
      'runtime_id': source?.id,
      'hand_joints': caps?.hasHandTracking ?? false,
      'hand_joint_count': caps?.handJointCount,
      'max_hand_rate_hz': caps?.maxHandRateHz,
      'bridges': service?.deviceIds.length ?? 0,
    };
    if (source == null || caps == null || !caps.hasHandTracking) {
      return BenchStepOutcome.failed(
        'No hand-tracking source with hand joints is attached.',
        data: data,
      );
    }
    return BenchStepOutcome.done(
      '${source.vendor.name}: ${caps.handJointCount} hand joints, '
      'up to ${caps.maxHandRateHz} Hz',
      data: data,
    );
  }

  @override
  Future<BenchStepOutcome> connect() async {
    final service = this.service;
    if (service == null || service.deviceIds.isEmpty) {
      return const BenchStepOutcome.failed(
        'No bridge is connected. Connect one on the Connect screen.',
      );
    }
    final links = await service.bridgeLinks();
    final described = [
      for (final link in links)
        '${link.bridgeId} (MTU ${link.mtu ?? '-'}, ${link.mode.name})',
    ];
    return BenchStepOutcome.done(
      '${links.length} bridge(s): ${described.join(', ')}',
      data: {
        'bridges': [
          for (final link in links)
            {
              'id': link.bridgeId,
              'mtu': link.mtu,
              'mode': link.mode.name,
              'firmware': link.protocol?.firmwareVersion,
            },
        ],
      },
    );
  }

  @override
  Future<BenchStepOutcome> bothHands() async {
    await _ensureMode(StreamMode.raw);
    final seen = <int>{};
    final completer = Completer<void>();
    final sub = _service.frames.listen((frame) {
      seen.add(frame.frame.hand);
      if (seen.length >= wmrNumControllers && !completer.isCompleted) {
        completer.complete();
      }
    });
    try {
      await completer.future.timeout(durations.handTimeout, onTimeout: () {});
    } finally {
      await sub.cancel();
    }
    final missing = [
      for (var hand = 0; hand < wmrNumControllers; hand++)
        if (!seen.contains(hand)) handName(hand),
    ];
    if (missing.isNotEmpty) {
      return BenchStepOutcome.failed(
        'No frames from ${missing.join(' and ')}. Press a button on each '
        'controller and try again.',
        data: {
          'hands': [for (final hand in seen) handName(hand)],
          'missing': missing,
        },
      );
    }
    return BenchStepOutcome.done(
      'Frames from LEFT and RIGHT',
      data: {
        'hands': [for (final hand in seen) handName(hand)],
      },
    );
  }

  @override
  Future<BenchStepOutcome> firmwareConfig() async {
    await _waitForProtocols();
    final firmware = <String, Object?>{};
    var firmwareRead = false;
    for (final id in _service.deviceIds) {
      final protocol = _service.protocolFor(id);
      firmware[id] = {
        'version': protocol?.firmwareVersion,
        'malformed': protocol?.firmwareVersionMalformed,
        'feature_present': protocol?.features.firmwareVersion,
        'unavailable': protocol == null,
      };
      if (protocol != null) firmwareRead = true;
    }

    final configs = <Map<String, Object?>>[];
    var configRead = false;
    for (final id in _service.deviceIds) {
      for (var hand = 0; hand < wmrNumControllers; hand++) {
        final result = await ConfigClient(_service.transport, id).read(hand);
        final blob = result.blob;
        configs.add({
          'bridge': id,
          'hand': handName(hand),
          'bytes': blob?.length,
          'crc32': result.crc?.toRadixString(16),
          if (result.failure != null) 'failure': result.failure!.name,
          if (result.state != null) 'state': result.state!.name,
        });
        if (blob != null) configRead = true;
      }
    }

    final data = <String, Object?>{'firmware': firmware, 'config': configs};
    if (!firmwareRead && !configRead) {
      return BenchStepOutcome.failed(
        'Neither FF16 nor FF13 returned a value.',
        data: data,
      );
    }
    final parts = <String>[
      if (firmwareRead) 'firmware read',
      if (configRead) 'config read',
    ];
    return BenchStepOutcome.done(parts.join(', '), data: data);
  }

  @override
  Future<BenchStepOutcome> still(int hand) =>
      _measure(hand, durations.still, moving: false);

  @override
  Future<BenchStepOutcome> move(int hand) =>
      _measure(hand, durations.move, moving: true);

  Future<BenchStepOutcome> _measure(
    int hand,
    Duration duration, {
    required bool moving,
  }) async {
    await _ensureMode(StreamMode.raw);
    final before = _service.stats.hands[hand];
    await Future<void>.delayed(duration);
    final after = _service.stats.hands[hand];
    final frames = after.frames - before.frames;
    final gaps = after.gaps - before.gaps;
    final total = frames + gaps;
    final seconds = duration.inMicroseconds / Duration.microsecondsPerSecond;
    final data = <String, Object?>{
      'hand': handName(hand),
      'motion': moving ? 'slow_move' : 'still',
      'seconds': seconds,
      'frames': frames,
      'gaps': gaps,
      'loss': total == 0 ? null : gaps / total,
      'rate_hz': seconds == 0 ? null : frames / seconds,
    };
    if (frames == 0) {
      return BenchStepOutcome.failed(
        'No ${handName(hand)} frames arrived during the step.',
        data: data,
      );
    }
    return BenchStepOutcome.done(
      '${handName(hand)} ${moving ? 'slow move' : 'still'}: $frames frames, '
      '${(frames / seconds).toStringAsFixed(1)} Hz, '
      '${gaps == 0 ? 'no gaps' : '$gaps gaps'}',
      data: data,
    );
  }

  @override
  Future<BenchStepOutcome> capture() async {
    await _ensureMode(StreamMode.raw);
    final now = DateTime.now();
    final file = captureStore.newFile(wmrHandLeft, now);
    final recorder = CaptureRecorder(
      sink: FileCaptureSink(file),
      hand: wmrHandLeft,
      mtu: mtu,
      started: now,
      originUs: clock.nowUs,
    )..beginPhase('bench', clock.nowUs);
    final sub = _service.frames.listen(recorder.addFrame);
    try {
      await Future<void>.delayed(durations.capture);
    } finally {
      await sub.cancel();
    }
    final summary = recorder.endPhase(clock.nowUs);
    await recorder.close();
    final data = <String, Object?>{
      'path': file.path,
      'seconds': durations.capture.inSeconds,
      'frames': summary.totalFrames,
      'lossy': summary.lossy,
    };
    if (summary.totalFrames == 0) {
      return BenchStepOutcome.failed(
        'The capture recorded no frames; see ${file.path}',
        data: data,
      );
    }
    return BenchStepOutcome.done(
      '${summary.totalFrames} frames in ${durations.capture.inSeconds} s; '
      'saved ${file.path}',
      data: data,
    );
  }

  @override
  Future<BenchStepOutcome> latency() async {
    await _ensureMode(StreamMode.raw);
    final recorder = LatencyRecorder(
      started: DateTime.now(),
      originUs: clock.nowUs,
      stream: _service.mode.name,
    );
    final sub = _service.frames.listen(
      (frame) => recorder.addFrame(
        frame.frame.hand,
        frame.frame.sequence,
        frame.receivedAtUs,
        bridgeId: frame.bridgeId,
      ),
    );
    try {
      await Future<void>.delayed(durations.latency);
    } finally {
      await sub.cancel();
    }
    final links = <String, LatencyLink>{};
    for (final link in await _service.bridgeLinks()) {
      links[link.bridgeId] = LatencyLink(
        mtu: link.mtu,
        rssiStart: link.rssi,
        connectionIntervalUs: link.connectionIntervalUs,
        phy: link.phy,
      );
    }
    final report = recorder.report(
      nowUs: clock.nowUs,
      links: links,
      counters: _counters(),
    );
    final saved = await latencyStore.save(recorder, report);
    final data = <String, Object?>{
      'files': saved.paths,
      'seconds': durations.latency.inSeconds,
      'rows': recorder.rows.length,
    };
    if (recorder.rows.isEmpty) {
      return BenchStepOutcome.failed(
        'The latency run recorded no rows.',
        data: data,
      );
    }
    return BenchStepOutcome.done(
      '${recorder.rows.length} rows in ${durations.latency.inSeconds} s; '
      'saved ${saved.csvPath}',
      data: data,
    );
  }

  @override
  Future<BenchStepOutcome> poseCapture(
    void Function(BenchCaptureProgress progress) onProgress,
  ) async {
    final source = tracking;
    final store = poseStore;
    final data = <String, Object?>{
      'runtime': source?.vendor.name,
      'files': const <Object?>[],
      'empty': const <String>[],
    };
    if (source == null) {
      return BenchStepOutcome.failed(
        'No hand-tracking source is attached.',
        data: data,
      );
    }
    if (store == null) {
      return BenchStepOutcome.failed(
        'The pose recording store is unavailable.',
        data: data,
      );
    }
    final runtime = source.vendor.name;
    final files = <Map<String, Object?>>[];
    final empty = <String>[];
    final total = wmrNumControllers * PoseSegment.values.length;
    var index = 0;
    for (var hand = 0; hand < wmrNumControllers; hand++) {
      final trackedHand = hand == wmrHandLeft
          ? TrackedHand.left
          : TrackedHand.right;
      for (final segment in PoseSegment.values) {
        onProgress(
          BenchCaptureProgress(
            hand: hand,
            segment: segment,
            index: index,
            total: total,
          ),
        );
        index++;
        final builder = PoseRecordingBuilder();
        final sub = source.frames.listen((frame) {
          final anchor = frame.hand(trackedHand)?.controllerAnchor;
          if (anchor == null || !anchor.isTracked) return;
          builder.add(hostTimeNs: frame.fusionTimeNs, tracking: frame);
        });
        try {
          await Future<void>.delayed(durations.forPoseSegment(segment));
        } finally {
          await sub.cancel();
        }
        if (builder.length < 2) {
          empty.add('${handName(hand)} ${segment.id}');
          continue;
        }
        final file = await store.saveCapture(
          builder.build(),
          runtime: runtime,
          hand: handName(hand).toLowerCase(),
          segment: segment.id,
          now: DateTime.now(),
        );
        files.add({
          'path': file.path,
          'runtime': runtime,
          'hand': handName(hand).toLowerCase(),
          'segment': segment.id,
        });
      }
    }
    data
      ..['files'] = files
      ..['empty'] = empty;
    if (files.isEmpty) {
      return BenchStepOutcome.failed(
        'No hand-joint samples arrived during any segment.',
        data: data,
      );
    }
    if (empty.isNotEmpty) {
      return BenchStepOutcome.failed(
        'Saved ${files.length} of $total captures; no hand-joint samples for '
        '${empty.join(', ')}.',
        data: data,
      );
    }
    return BenchStepOutcome.done(
      '${files.length} pose captures saved from $runtime',
      data: data,
    );
  }

  Future<void> _ensureMode(StreamMode mode) async {
    if (_service.mode != mode) await _service.setMode(mode);
  }

  Future<void> _waitForProtocols() async {
    final deadline = DateTime.now().add(durations.firmwareTimeout);
    while (_service.deviceIds.any((id) => _service.protocolFor(id) == null) &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  Map<String, int> _counters() {
    final raw = _service.stats;
    final decoded = _service.decodedStats;
    var incomplete = 0;
    for (final hand in raw.hands) {
      incomplete += hand.incomplete;
    }
    return {
      'incomplete_frames': incomplete,
      'reassembly_errors': raw.errors,
      'decoded_parse_errors': decoded.parseErrors,
    };
  }
}

/// Resolves the session from the live connection or the attached hand-tracking
/// source, or null when neither exists. The wizard calls it again on each step,
/// so a bridge that comes back after a drop is picked up.
final benchSessionProvider = Provider<Future<BenchSession?> Function()>((ref) {
  return () async {
    final device = ref.read(realDeviceProvider);
    final service = ref.read(realDeviceProvider.notifier).service;
    final connected = service != null && device.connected;
    final tracking = ref
        .read(debugTrackingSourceProvider)
        .attachment
        .value
        ?.source;
    if (!connected && tracking == null) return null;
    return RealBenchSession(
      service: connected ? service : null,
      tracking: tracking,
      poseStore: await ref.read(poseRecordingStoreProvider.future),
      clock: service?.transport.clock ?? MonotonicClock(),
      captureStore: await ref.read(captureStoreProvider.future),
      latencyStore: await ref.read(latencyStoreProvider.future),
      durations: ref.read(benchDurationsProvider),
      mtu: device.status.mtu,
    );
  };
});
