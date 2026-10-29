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

import '../../services/test_bundle_export.dart';
import '../capture/capture_providers.dart';
import '../connect/connect_providers.dart';
import '../debug/debug_providers.dart';
import '../debug/pose_recording_store.dart';
import '../latency/latency_providers.dart';
import 'bench_pose.dart';

/// How long each measured step runs. Tests override it to a few milliseconds.
class BenchDurations {
  const BenchDurations({
    this.still = const Duration(seconds: 20),
    this.move = const Duration(seconds: 20),
    this.capture = const Duration(seconds: 60),
    this.latency = const Duration(seconds: 30),
    this.poseStill = const Duration(seconds: 10),
    this.poseDrifting = const Duration(seconds: 10),
    this.poseSlowPan = const Duration(seconds: 18),
    this.poseMediumPan = const Duration(seconds: 10),
    this.poseFastFlick = const Duration(seconds: 20),
    this.handTimeout = const Duration(seconds: 5),
    this.firmwareTimeout = const Duration(seconds: 3),
  });

  final Duration still;
  final Duration move;
  final Duration capture;
  final Duration latency;
  final Duration poseStill;
  final Duration poseDrifting;
  final Duration poseSlowPan;
  final Duration poseMediumPan;
  final Duration poseFastFlick;

  Duration poseDuration(PoseSegment segment) => switch (segment) {
    PoseSegment.still => poseStill,
    PoseSegment.drifting => poseDrifting,
    PoseSegment.slowPan => poseSlowPan,
    PoseSegment.mediumPan => poseMediumPan,
    PoseSegment.fastFlick => poseFastFlick,
  };

  /// How long to wait for the first frames of both hands.
  final Duration handTimeout;

  /// How long to wait for the one-time FF16 read.
  final Duration firmwareTimeout;
}

final benchDurationsProvider = Provider<BenchDurations>(
  (ref) => const BenchDurations(),
);

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
    BenchStep.poseCapture => 'Capture 6DoF pose',
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
      'Records one pose recording per hand and segment while a VITURE, XREAL '
          'or Android XR source is tracking hands. Each segment has its own '
          'screen and can be skipped.',
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
  Future<BenchStepOutcome> poseSegment(
    int hand,
    PoseSegment segment,
    Duration duration, {
    Future<void>? cancel,
  });
  Future<BenchStepOutcome> capture();
  Future<BenchStepOutcome> latency();
}

/// The real session: reads and records through [ControllerService], the same
/// paths the Capture and Latency screens use.
class RealBenchSession implements BenchSession {
  RealBenchSession({
    this.service,
    this.tracking,
    this.poseRecorder,
    required this.clock,
    required this.captureStore,
    required this.latencyStore,
    required this.durations,
    this.mtu,
    this.appCommit = 'unknown',
    this.firmwareSha,
    this.applyMode,
  });

  /// Null in the 6DoF-only path, where no bridge is attached.
  final ControllerService? service;

  /// The attached hand-tracking runtime, already started.
  final TrackingSource? tracking;

  /// Records one hand/segment. Null when no source reports hand joints.
  final BenchPoseRecorder? poseRecorder;

  final MonotonicClock clock;
  final CaptureStore captureStore;
  final LatencyStore latencyStore;
  final BenchDurations durations;
  final int? mtu;
  final String appCommit;
  final String? firmwareSha;

  /// Applies a stream mode to both the service and the app's mode choice, so
  /// the debug pose path follows the bench.
  final Future<void> Function(StreamMode mode)? applyMode;

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

  @override
  Future<BenchStepOutcome> poseSegment(
    int hand,
    PoseSegment segment,
    Duration duration, {
    Future<void>? cancel,
  }) async {
    final recorder = poseRecorder;
    final handLabel = handName(hand);
    if (recorder == null) {
      return BenchStepOutcome.failed(
        'unavailable: no 6DoF hand-tracking source',
        data: {
          'hand': handLabel,
          'segment': segment.id,
          'app_commit': appCommit,
          'firmware_sha': firmwareSha,
        },
      );
    }
    // The debug pose path follows the app's stream mode; batched or decoded
    // carries the controller records a pose recording needs.
    await _ensureMode(StreamMode.batched);
    try {
      final result = await recorder.record(
        hand: hand,
        segment: segment,
        duration: duration,
        cancel: cancel,
      );
      return BenchStepOutcome.done(
        '$handLabel ${segment.title}: ${result.samples} samples; '
        'saved ${result.path}',
        data: {
          'runtime': result.runtime,
          'hand': handLabel,
          'segment': segment.id,
          'file': result.path,
          'samples': result.samples,
          'seconds': result.seconds,
          'app_commit': appCommit,
          'firmware_sha': firmwareSha,
        },
      );
    } on Object catch (error) {
      return BenchStepOutcome.failed(
        error is PoseSegmentCancelled ? 'skipped by tester' : '$error',
        data: {
          'runtime': recorder.runtime,
          'hand': handLabel,
          'segment': segment.id,
          'app_commit': appCommit,
          'firmware_sha': firmwareSha,
        },
      );
    }
  }

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

  Future<void> _ensureMode(StreamMode mode) async {
    final apply = applyMode;
    if (apply != null) {
      await apply(mode);
      return;
    }
    final service = this.service;
    if (service != null && service.mode != mode) {
      await service.setMode(mode);
    }
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
    final notifier = ref.read(realDeviceProvider.notifier);
    final service = notifier.service;
    final connected = service != null && device.connected;
    final selection = ref.read(debugTrackingSourceProvider);
    final tracking = selection.attachment.value?.source;
    if (!connected && tracking == null) return null;
    final availability = ref.read(benchPoseAvailabilityProvider);
    final poseRecorder = availability.available
        ? RealBenchPoseRecorder(
            ref: ref,
            store: await ref.read(poseRecordingStoreProvider.future),
            runtime: availability.runtime!,
          )
        : null;
    return RealBenchSession(
      service: connected ? service : null,
      tracking: tracking,
      poseRecorder: poseRecorder,
      clock: service?.transport.clock ?? MonotonicClock(),
      captureStore: await ref.read(captureStoreProvider.future),
      latencyStore: await ref.read(latencyStoreProvider.future),
      durations: ref.read(benchDurationsProvider),
      mtu: device.status.mtu,
      appCommit: ref.read(appCommitProvider),
      firmwareSha: connected
          ? firmwareShaFromVersions({
              for (final id in service.deviceIds)
                id: service.protocolFor(id)?.firmwareVersion,
            })
          : null,
      applyMode: notifier.setStreamMode,
    );
  };
});

/// The short SHA in an FF16 git description, or null when FF16 has none.
///
/// Only the `-g<sha>` shape a git-describe version carries counts. A bare hex
/// token is not a SHA: versions and build stamps can look identical.
String? gitShaFromFirmware(String? version) {
  if (version == null) return null;
  final match = RegExp(r'(?:^|-)g([0-9a-f]{7,40})(?:[-\s+]|$)')
      .firstMatch(version.trim());
  return match?.group(1);
}

/// The SHA recorded for a run: one value when every bridge that exposes a git
/// description agrees, a per-bridge list when they differ, else `unknown`.
String firmwareShaFromVersions(Map<String, String?> versions) {
  final found = <String, String>{};
  for (final entry in versions.entries) {
    final sha = gitShaFromFirmware(entry.value);
    if (sha != null) found[entry.key] = sha;
  }
  if (found.isEmpty) return 'unknown';
  if (found.values.toSet().length == 1) return found.values.first;
  return found.entries.map((entry) => '${entry.key}=${entry.value}').join('; ');
}
