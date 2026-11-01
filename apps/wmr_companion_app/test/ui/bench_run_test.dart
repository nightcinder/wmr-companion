import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_core/ble/ble_transport.dart';
import 'package:wmr_core/ble/fake_transport.dart';
import 'package:wmr_core/ble/fake_wmr_bridge.dart';
import 'package:wmr_core/protocol/wmr_fragment.dart';
import 'package:wmr_core/services/capture_files.dart';
import 'package:wmr_core/services/controller_service.dart';
import 'package:wmr_core/services/latency_files.dart';
import 'package:wmr_companion_app/services/firmware_identity.dart';
import 'package:wmr_companion_app/ui/capture/capture_providers.dart';
import 'package:wmr_companion_app/ui/connect/connect_providers.dart';
import 'package:wmr_companion_app/ui/latency/latency_providers.dart';
import 'package:wmr_ble/wmr_ble.dart';
import 'package:wmr_ble/testing.dart';
import 'package:wmr_companion_app/services/test_bundle.dart';
import 'package:wmr_companion_app/services/test_bundle_export.dart';
import 'package:wmr_companion_app/ui/bench/bench_controller.dart';
import 'package:wmr_companion_app/ui/bench/bench_pose.dart';
import 'package:wmr_companion_app/ui/bench/bench_run.dart';
import 'package:wmr_companion_app/ui/debug/debug_providers.dart';
import 'package:wmr_companion_app/ui/debug/pose_recording_store.dart';
import 'package:wmr_tracking/wmr_tracking.dart';

/// A 700-byte block exercises both FF13 windows (496 + 204).
Uint8List _configBlob(int seed) =>
    Uint8List.fromList([for (var i = 0; i < 700; i++) (i + seed) & 0xff]);

/// Writes a valid pose file with the guided bench's fixed name.
class _FakePoseRecorder implements BenchPoseRecorder {
  _FakePoseRecorder(this.dir) {
    dir.createSync(recursive: true);
  }

  final Directory dir;
  final List<String> recorded = [];

  @override
  String get runtime => 'viture';

  @override
  Future<PoseCaptureResult> record({
    required int hand,
    required PoseSegment segment,
    required Duration duration,
    int run = 1,
    Future<void>? cancel,
  }) async {
    recorded.add('$hand:${segment.id}:$run');
    final name = poseCaptureFileName(
      runtime: runtime,
      hand: hand == 0 ? 'left' : 'right',
      segment: segment.id,
      run: run,
    );
    final file = File('${dir.path}/$name')
      ..writeAsStringSync(
        '{"format":"wmr-pose-recording","version":1,'
        '"samples":[]}',
      );
    return PoseCaptureResult(
      runtime: runtime,
      path: file.path,
      samples: 3,
      seconds: duration.inSeconds,
      run: run,
      anchorRateHz: 90,
      provenance: const {'runtime': 'viture', 'run_index': 1},
    );
  }
}

/// A short corpus session used by the resume tests.
RealBenchSession _resumeSession(Directory dir, BenchPoseRecorder recorder) =>
    RealBenchSession(
      poseRecorder: recorder,
      clock: MonotonicClock(),
      captureStore: CaptureStore(Directory('${dir.path}/captures')),
      latencyStore: LatencyStore(Directory('${dir.path}/latency')),
      durations: const BenchDurations(
        poseStill: Duration(milliseconds: 10),
        poseDrifting: Duration(milliseconds: 10),
        poseSlowPan: Duration(milliseconds: 10),
        poseMediumPan: Duration(milliseconds: 10),
        poseFastFlick: Duration(milliseconds: 10),
        poseOcclusion: Duration(milliseconds: 10),
      ),
      appCommit: 'abc1234',
      firmwareSha: 'deadbee',
    );

ProviderContainer _openResumeContainer(
  Directory dir,
  PoseRecordingStore progress,
  BenchSession session,
) {
  final container = ProviderContainer(
    overrides: [
      benchSessionProvider.overrideWithValue(() async => session),
      benchPoseAvailabilityProvider.overrideWithValue(
        const BenchPoseAvailability.available('viture'),
      ),
      poseRecordingStoreProvider.overrideWith((ref) async => progress),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<BenchController> _startResumeCorpus(ProviderContainer container) async {
  final sub = container.listen(benchControllerProvider, (_, _) {});
  addTearDown(sub.close);
  final controller = container.read(benchControllerProvider.notifier);
  controller.selectMode(BenchMode.sixDofOnly);
  controller.skipCurrent(); // capability summary is not part of the corpus
  return controller;
}

void main() {
  late Directory dir;
  late FakeTransport transport;
  FakeWmrBridge? bridge;
  ControllerService? service;

  Future<BenchSession> open({List<int> hands = const [0, 1]}) async {
    transport = FakeTransport(devices: const [fakeBridgeDevice]);
    bridge = FakeWmrBridge(
      transport,
      hands: hands,
      configBlobs: [_configBlob(0), _configBlob(7)],
    )..start();
    service = ControllerService(transport, fakeBridgeDeviceId);
    await service!.start();
    return RealBenchSession(
      service: service,
      clock: transport.clock,
      captureStore: CaptureStore(Directory('${dir.path}/captures')),
      latencyStore: LatencyStore(Directory('${dir.path}/latency')),
      durations: const BenchDurations(
        still: Duration(milliseconds: 80),
        move: Duration(milliseconds: 80),
        capture: Duration(milliseconds: 250),
        latency: Duration(milliseconds: 250),
        poseStill: Duration(milliseconds: 10),
        poseDrifting: Duration(milliseconds: 10),
        poseSlowPan: Duration(milliseconds: 10),
        poseMediumPan: Duration(milliseconds: 10),
        poseFastFlick: Duration(milliseconds: 10),
        handTimeout: Duration(seconds: 2),
        firmwareTimeout: Duration(seconds: 2),
      ),
      mtu: 185,
      poseRecorder: _FakePoseRecorder(dir),
      appCommit: 'abc1234',
      firmwareSha: 'deadbee',
    );
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('bench_run');
  });

  tearDown(() async {
    bridge?.stop();
    await service?.dispose();
    dir.deleteSync(recursive: true);
  });

  test('runs every measured step against the fake bridge', () async {
    final session = await open();

    final connect = await session.connect();
    expect(connect.ok, isTrue, reason: connect.error);
    expect(connect.summary, contains(fakeBridgeDeviceId));

    final both = await session.bothHands();
    expect(both.ok, isTrue, reason: both.error);
    expect(both.data['hands'], ['LEFT', 'RIGHT']);

    final protocol = await session.firmwareConfig();
    expect(protocol.ok, isTrue, reason: protocol.error);
    final config = protocol.data['config']! as List;
    expect(config, hasLength(2));
    for (final entry in config.cast<Map<String, Object?>>()) {
      expect(entry['bytes'], 700);
      expect(entry['crc32'], isNotNull);
      expect(entry['failure'], isNull);
    }
    final firmware = protocol.data['firmware']! as Map;
    expect((firmware[fakeBridgeDeviceId]! as Map)['version'], 'fake-1.0.0');

    for (final step in [
      session.still(wmrHandLeft),
      session.still(wmrHandRight),
      session.move(wmrHandLeft),
      session.move(wmrHandRight),
    ]) {
      final outcome = await step;
      expect(outcome.ok, isTrue, reason: outcome.error);
      expect(outcome.data['frames'], greaterThan(0));
      expect(outcome.data['loss'], isNotNull);
    }

    final capture = await session.capture();
    expect(capture.ok, isTrue, reason: capture.error);
    final capturePath = capture.data['path']! as String;
    final captureText = File(capturePath).readAsStringSync();
    expect(captureText, contains('# wmr-capture v1'));
    expect(captureText, contains('@begin bench'));
    expect(captureText, contains('@end bench'));

    final latency = await session.latency();
    expect(latency.ok, isTrue, reason: latency.error);
    final files = (latency.data['files']! as List).cast<String>();
    expect(files, hasLength(2));
    for (final path in files) {
      expect(File(path).existsSync(), isTrue);
    }
  });

  test('both hands fails and names the missing hand', () async {
    final session = await open(hands: const [wmrHandLeft]);

    final outcome = await session.bothHands();

    expect(outcome.ok, isFalse);
    expect(outcome.error, contains('RIGHT'));
    expect(outcome.data['hands'], ['LEFT']);
  });

  test('a step outage is recorded instead of throwing', () async {
    final session = await open();
    await session.connect();
    await session.bothHands();
    bridge!.stop(); // no more frames from either hand

    final still = await session.still(wmrHandLeft);

    expect(still.ok, isFalse);
    expect(still.error, contains('No LEFT frames'));
    expect(still.data['frames'], 0);
  });

  test('the wizard run reaches the manifest, export included', () async {
    final session = await open();
    final container = ProviderContainer(
      overrides: [
        benchSessionProvider.overrideWithValue(() async => session),
        benchPoseAvailabilityProvider.overrideWithValue(
          const BenchPoseAvailability.available('viture'),
        ),
        exportTestBundleProvider.overrideWithValue(
          ({BenchBundleRun? benchRun}) => writeTestBundle(
            TestBundleInput(
              now: DateTime(2026, 10, 29, 13),
              appVersion: '0.2.2+4',
              appCommit: 'abc1234',
              phone: 'Test Phone',
              androidVersion: 'Android 14 (API 34)',
              streamMode: 'raw',
              bridges: const [
                BundleBridge(
                  id: fakeBridgeDeviceId,
                  firmwareVersion: 'v0.2.4-3-gdeadbee',
                ),
              ],
              poseCaptures: poseCapturesFromRun(benchRun),
              benchRun: benchRun,
            ),
            Directory('${dir.path}/out'),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    // Keep the auto-dispose controller alive across the async steps.
    final sub = container.listen(benchControllerProvider, (_, _) {});
    addTearDown(sub.close);
    final controller = container.read(benchControllerProvider.notifier);
    controller.selectMode(BenchMode.combined);

    for (var i = 0; i < 30; i++) {
      if (container.read(benchControllerProvider).step == BenchStep.photo) {
        break;
      }
      await controller.runCurrent();
    }
    expect(container.read(benchControllerProvider).step, BenchStep.photo);
    await controller.confirmCurrent();
    await controller.confirmCurrent();
    for (var i = 0; i < benchPoseSequence.length; i++) {
      if (container.read(benchControllerProvider).step == BenchStep.export) {
        break;
      }
      await controller.runCurrent();
    }
    await controller.exportBundle();

    final state = container.read(benchControllerProvider);
    expect(state.bundleError, isNull);
    final archive = ZipDecoder().decodeBytes(
      File(state.bundlePath!).readAsBytesSync(),
    );
    final file = archive.files.firstWhere((f) => f.name == 'manifest.md');
    final manifest = utf8.decode(file.content as List<int>);
    for (final step in BenchMode.combined.steps) {
      expect(manifest, contains('- ${step.id}: done'), reason: step.id);
    }
    expect(manifest, contains('- Bench mode: combined'));
    expect(manifest, contains('## 6DoF pose captures'));
    expect(manifest, contains('pose_capture_viture_left_still.json'));
    expect(manifest, contains('pose_capture_viture_right_fast_flick.json'));
    // The header commit is the app build, not the per-segment fallback.
    final header = manifest.split('## 6DoF').first;
    expect(header, contains('- App commit: abc1234'));
    expect(manifest, contains('- Firmware SHA: deadbee'));
    // Every recorded segment is in the zip, not just in the manifest table.
    final poseFiles = archive.files
        .map((f) => f.name)
        .where((name) => name.startsWith('pose_capture_'))
        .toList();
    expect(poseFiles, hasLength(benchPoseSequence.length));
    expect(poseFiles, contains('pose_capture_viture_left_still.json'));
  });

  test('3DoF only still runs the old twelve-step wizard', () async {
    final session = await open();
    final container = ProviderContainer(
      overrides: [
        benchSessionProvider.overrideWithValue(() async => session),
        exportTestBundleProvider.overrideWithValue(
          ({BenchBundleRun? benchRun}) => writeTestBundle(
            TestBundleInput(
              now: DateTime(2026, 10, 29, 13),
              appVersion: '0.2.2+4',
              appCommit: 'abc1234',
              phone: 'Test Phone',
              androidVersion: 'Android 14 (API 34)',
              streamMode: 'raw',
              bridges: const [
                BundleBridge(
                  id: fakeBridgeDeviceId,
                  firmwareVersion: 'v0.2.4-3-gdeadbee',
                ),
              ],
              poseCaptures: poseCapturesFromRun(benchRun),
              benchRun: benchRun,
            ),
            Directory('${dir.path}/out'),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    final sub = container.listen(benchControllerProvider, (_, _) {});
    addTearDown(sub.close);
    final controller = container.read(benchControllerProvider.notifier);
    controller.selectMode(BenchMode.threeDofOnly);

    for (var i = 0; i < 30; i++) {
      if (container.read(benchControllerProvider).step == BenchStep.photo) {
        break;
      }
      await controller.runCurrent();
    }
    expect(container.read(benchControllerProvider).step, BenchStep.photo);
    await controller.confirmCurrent();
    await controller.confirmCurrent();
    expect(
      container.read(benchControllerProvider).step,
      BenchStep.export,
      reason: 'the old flow goes straight from the serial log to export',
    );
    await controller.exportBundle();

    final state = container.read(benchControllerProvider);
    expect(state.bundleError, isNull);
    final archive = ZipDecoder().decodeBytes(
      File(state.bundlePath!).readAsBytesSync(),
    );
    final manifest = utf8.decode(
      archive.files.firstWhere((f) => f.name == 'manifest.md').content
          as List<int>,
    );
    final steps = BenchMode.threeDofOnly.steps;
    expect(steps, hasLength(12));
    for (final step in steps) {
      expect(manifest, contains('- ${step.id}: done'), reason: step.id);
    }
    expect(manifest, contains('- Bench mode: 3dof_only'));
    expect(manifest, isNot(contains('## 6DoF pose captures')));
    expect(
      archive.files.where((f) => f.name.startsWith('pose_capture_')),
      isEmpty,
    );
  });

  test('an interrupted corpus resumes from the first missing run', () async {
    final progress = PoseRecordingStore(Directory('${dir.path}/documents'));
    final first = _FakePoseRecorder(Directory('${dir.path}/runs'));
    final second = _FakePoseRecorder(Directory('${dir.path}/runs'));

    final firstContainer = _openResumeContainer(
      dir,
      progress,
      _resumeSession(dir, first),
    );
    final firstController = await _startResumeCorpus(firstContainer);
    for (var i = 0; i < 5; i++) {
      await firstController.runCurrent();
    }
    expect(firstContainer.read(benchControllerProvider).poseSegment, 5);
    expect(first.recorded, hasLength(5));
    await firstController.poseProgressWritten;
    firstContainer.dispose();

    final secondContainer = _openResumeContainer(
      dir,
      progress,
      _resumeSession(dir, second),
    );
    final secondController = await _startResumeCorpus(secondContainer);
    await secondController.runCurrent();
    expect(second.recorded, hasLength(1), reason: 'only the next run records');
    expect(second.recorded.single, '0:drifting:2');
    expect(secondContainer.read(benchControllerProvider).poseSegment, 6);

    for (var i = 6; i < benchPoseSequence.length; i++) {
      await secondController.runCurrent();
    }
    final state = secondContainer.read(benchControllerProvider);
    expect(state.step, BenchStep.export);
    final segments =
        state.resultFor(BenchStep.poseCapture).data['segments']! as List;
    expect(segments, hasLength(benchPoseSequence.length));
    final keys = [
      for (final segment in segments.cast<Map>())
        '${segment['hand']}:${segment['segment']}:${segment['run']}',
    ];
    expect(keys.toSet(), hasLength(benchPoseSequence.length));
  });

  test('resume drops saved runs after a mid-corpus missing file', () async {
    final progress = PoseRecordingStore(Directory('${dir.path}/documents'));
    final first = _FakePoseRecorder(Directory('${dir.path}/runs'));
    final second = _FakePoseRecorder(Directory('${dir.path}/runs'));

    final firstContainer = _openResumeContainer(
      dir,
      progress,
      _resumeSession(dir, first),
    );
    final firstController = await _startResumeCorpus(firstContainer);
    for (var i = 0; i < 8; i++) {
      await firstController.runCurrent();
    }
    expect(first.recorded, hasLength(8));
    await firstController.poseProgressWritten;
    firstContainer.dispose();

    // LEFT still run 4 (sequence index 3) is gone; the later runs are on disk.
    final missing = File(
      '${dir.path}/runs/'
      '${poseCaptureFileName(runtime: 'viture', hand: 'left', segment: 'still', run: 4)}',
    );
    expect(missing.existsSync(), isTrue);
    missing.deleteSync();

    final secondContainer = _openResumeContainer(
      dir,
      progress,
      _resumeSession(dir, second),
    );
    final secondController = await _startResumeCorpus(secondContainer);
    await secondController.runCurrent();
    expect(
      second.recorded,
      hasLength(1),
      reason: 'resume restarts at the missing run, not the first recorded one',
    );
    expect(second.recorded.single, '0:still:4');
    expect(secondContainer.read(benchControllerProvider).poseSegment, 4);

    for (var i = 4; i < benchPoseSequence.length; i++) {
      await secondController.runCurrent();
    }
    final state = secondContainer.read(benchControllerProvider);
    expect(state.step, BenchStep.export);
    final segments =
        state.resultFor(BenchStep.poseCapture).data['segments']! as List;
    expect(segments, hasLength(benchPoseSequence.length));
    final keys = [
      for (final segment in segments.cast<Map>())
        '${segment['hand']}:${segment['segment']}:${segment['run']}',
    ];
    expect(keys.toSet(), hasLength(benchPoseSequence.length));
    expect(second.recorded, hasLength(benchPoseSequence.length - 3));
    expect(second.recorded.first, '0:still:4');
  });

  group('firmware SHA', () {
    test('only a git-describe shape yields a SHA', () {
      expect(gitShaFromFirmware('v0.2.4-3-gdeadbee'), 'deadbee');
      expect(gitShaFromFirmware('0.2.4-g1234567'), '1234567');
      expect(gitShaFromFirmware('2026-10-29 deadbee'), isNull);
      expect(gitShaFromFirmware('deadbee'), isNull);
      expect(gitShaFromFirmware('v0.2.4'), isNull);
      expect(gitShaFromFirmware(null), isNull);
    });

    test('one SHA for agreeing bridges, per-bridge when they differ', () {
      expect(firmwareShaFromVersions({'a': 'v1-gdeadbee'}), 'deadbee');
      expect(
        firmwareShaFromVersions({'a': 'v1-gdeadbee', 'b': 'v1-gdeadbee'}),
        'deadbee',
      );
      expect(
        firmwareShaFromVersions({'a': 'v1-gdeadbee', 'b': 'v1-gc0ffee0'}),
        'a=deadbee; b=c0ffee0',
      );
      expect(
        firmwareShaFromVersions({'a': '2026-10-29', 'b': null}),
        'unknown',
      );
    });
  });

  group('pose gate', () {
    DebugTrackingSelection selection(
      DebugTrackingSource choice, {
      TrackingSource? source,
    }) => DebugTrackingSelection(
      choice: choice,
      attachment: AsyncValue.data(
        DebugTrackingAttachment(choice: choice, source: source),
      ),
    );

    test('no source, simulated and jointless sources are unavailable', () {
      expect(
        BenchPoseAvailability.fromSelection(selection(DebugTrackingSource.none))
            .available,
        isFalse,
      );
      expect(
        BenchPoseAvailability.fromSelection(
          selection(
            DebugTrackingSource.simulated,
            source: FakeTrackingSource(),
          ),
        ).available,
        isFalse,
        reason: 'the simulator is not a real 6DoF runtime',
      );
      final jointless = FakeTrackingSource(
        capabilities: const TrackingCapabilities(
          features: {TrackingFeature.headPose6Dof},
        ),
      );
      expect(
        BenchPoseAvailability.fromSelection(
          selection(DebugTrackingSource.viture, source: jointless),
        ).available,
        isFalse,
      );
    });

    test('a running vendor source with hand joints offers the step', () {
      for (final choice in [
        DebugTrackingSource.viture,
        DebugTrackingSource.xreal,
        DebugTrackingSource.androidXr,
      ]) {
        final availability = BenchPoseAvailability.fromSelection(
          selection(choice, source: FakeTrackingSource()),
        );
        expect(availability.available, isTrue, reason: choice.name);
        expect(availability.runtime, choice.name);
      }
    });
  });

  group('session clock', () {
    test('a tracking-only session keeps one clock across resolves', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final source = FakeTrackingSource();
      await source.start();
      final transport = UniversalBleTransport(adapter: FakeBleAdapter());
      addTearDown(transport.dispose);
      final container = ProviderContainer(
        overrides: [
          realTransportProvider.overrideWithValue(transport),
          debugTrackingSourceProvider.overrideWith(
            () => _FixedTracking(
              DebugTrackingSelection(
                choice: DebugTrackingSource.viture,
                attachment: AsyncValue.data(
                  DebugTrackingAttachment(
                    choice: DebugTrackingSource.viture,
                    source: source,
                  ),
                ),
              ),
            ),
          ),
          benchPoseAvailabilityProvider.overrideWithValue(
            const BenchPoseAvailability.unavailable('no 6DoF source'),
          ),
          captureStoreProvider.overrideWith(
            (ref) async => CaptureStore(Directory('${dir.path}/captures')),
          ),
          latencyStoreProvider.overrideWith(
            (ref) async => LatencyStore(Directory('${dir.path}/latency')),
          ),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(source.dispose);

      final resolve = container.read(benchSessionProvider);
      final first = await resolve() as RealBenchSession;
      final second = await resolve() as RealBenchSession;
      expect(first.service, isNull, reason: 'no controller service');
      expect(
        identical(first.clock, second.clock),
        isTrue,
        reason: 'host_ns must not restart at every pose segment',
      );
    });
  });
}

class _FixedTracking extends DebugTrackingSourceNotifier {
  _FixedTracking(this.selection);

  final DebugTrackingSelection selection;

  @override
  DebugTrackingSelection build() => selection;
}
