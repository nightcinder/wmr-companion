import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math_64.dart';
import 'package:wmr_core/ble/ble_transport.dart';
import 'package:wmr_core/ble/fake_transport.dart';
import 'package:wmr_core/ble/fake_wmr_bridge.dart';
import 'package:wmr_core/protocol/wmr_fragment.dart';
import 'package:wmr_core/services/capture_files.dart';
import 'package:wmr_core/services/controller_service.dart';
import 'package:wmr_core/services/latency_files.dart';
import 'package:wmr_companion_app/services/test_bundle.dart';
import 'package:wmr_companion_app/services/test_bundle_export.dart';
import 'package:wmr_companion_app/ui/bench/bench_controller.dart';
import 'package:wmr_companion_app/ui/bench/bench_run.dart';
import 'package:wmr_companion_app/ui/debug/pose_recording_store.dart';
import 'package:wmr_tracking/wmr_tracking.dart';

/// A 700-byte block exercises both FF13 windows (496 + 204).
Uint8List _configBlob(int seed) =>
    Uint8List.fromList([for (var i = 0; i < 700; i++) (i + seed) & 0xff]);

void main() {
  late Directory dir;
  late FakeTransport transport;
  late FakeWmrBridge bridge;
  late ControllerService service;

  Future<BenchSession> open({List<int> hands = const [0, 1]}) async {
    transport = FakeTransport(devices: const [fakeBridgeDevice]);
    bridge = FakeWmrBridge(
      transport,
      hands: hands,
      configBlobs: [_configBlob(0), _configBlob(7)],
    )..start();
    service = ControllerService(transport, fakeBridgeDeviceId);
    await service.start();
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
        handTimeout: Duration(seconds: 2),
        firmwareTimeout: Duration(seconds: 2),
      ),
      mtu: 185,
    );
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('bench_run');
  });

  tearDown(() async {
    bridge.stop();
    await service.dispose();
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
    bridge.stop(); // no more frames from either hand

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
        exportTestBundleProvider.overrideWithValue(
          ({BenchBundleRun? benchRun}) => writeTestBundle(
            TestBundleInput(
              now: DateTime(2026, 10, 29, 13),
              appVersion: '0.2.2+4',
              phone: 'Test Phone',
              androidVersion: 'Android 14 (API 34)',
              streamMode: 'raw',
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

    for (var i = 0; i < 9; i++) {
      await controller.runCurrent();
    }
    expect(container.read(benchControllerProvider).step, BenchStep.photo);
    await controller.confirmCurrent();
    await controller.confirmCurrent();
    await controller.exportBundle();

    final state = container.read(benchControllerProvider);
    expect(state.bundleError, isNull);
    final archive = ZipDecoder().decodeBytes(
      File(state.bundlePath!).readAsBytesSync(),
    );
    final file = archive.files.firstWhere((f) => f.name == 'manifest.md');
    final manifest = utf8.decode(file.content as List<int>);
    for (final step in BenchMode.threeDofOnly.steps) {
      expect(manifest, contains('- ${step.id}: done'), reason: step.id);
    }
    expect(manifest, contains('- Bench mode: 3dof_only'));
  });

  test('pose capture writes one recording per hand and segment', () async {
    final source = FakeTrackingSource();
    await source.start();
    addTearDown(source.dispose);
    final session = RealBenchSession(
      tracking: source,
      poseStore: PoseRecordingStore(Directory('${dir.path}/pose')),
      clock: MonotonicClock(),
      captureStore: CaptureStore(Directory('${dir.path}/captures')),
      latencyStore: LatencyStore(Directory('${dir.path}/latency')),
      durations: const BenchDurations(
        poseStill: Duration(milliseconds: 20),
        poseHeldDrift: Duration(milliseconds: 20),
        poseSlowPan: Duration(milliseconds: 20),
        poseMediumPan: Duration(milliseconds: 20),
        poseFastFlick: Duration(milliseconds: 20),
      ),
    );

    var timeNs = 0;
    final timer = Timer.periodic(const Duration(milliseconds: 2), (_) {
      timeNs += 2000000;
      source.addFrame(
        TrackingFrame(
          timeNs: timeNs,
          hostTimeNs: timeNs,
          leftHand: HandPose(
            hand: TrackedHand.left,
            palm: TrackedPose(
              pose: Pose(
                translation: Vector3(-0.2, -0.25, -0.35),
                rotation: Quaternion.identity(),
              ),
            ),
          ),
          rightHand: HandPose(
            hand: TrackedHand.right,
            palm: TrackedPose(
              pose: Pose(
                translation: Vector3(0.2, -0.25, -0.35),
                rotation: Quaternion.identity(),
              ),
            ),
          ),
        ),
      );
    });
    addTearDown(timer.cancel);

    final progress = <BenchCaptureProgress>[];
    final outcome = await session.poseCapture(progress.add);
    timer.cancel();

    expect(outcome.ok, isTrue, reason: outcome.error);
    expect(progress, hasLength(10));
    expect(progress.first.handName, 'LEFT');
    expect(progress.first.segment, PoseSegment.still);
    expect(progress.last.handName, 'RIGHT');
    expect(progress.last.segment, PoseSegment.fastFlick);

    final files = (outcome.data['files']! as List).cast<Map<String, Object?>>();
    expect(files, hasLength(10));
    final namePattern = RegExp(
      r'^pose_capture_fake_(left|right)_'
      r'(still|heldDrift|slowPan|mediumPan|fastFlick)\.json$',
    );
    for (final entry in files) {
      final path = entry['path']! as String;
      expect(path.split(Platform.pathSeparator).last, matches(namePattern));
      final recording = PoseRecording.decode(File(path).readAsStringSync());
      expect(recording.samples.length, greaterThanOrEqualTo(2));
      expect(recording.samples.first.tracking, isNotNull);
    }
  });
}
