import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:vector_math/vector_math_64.dart';
import 'package:wmr_tracking/wmr_tracking.dart';

import '../tool/src/pose_filter_tuning.dart';

const String _captureDir = 'test/fixtures/pose_filter_captures/synthetic';

List<PoseCapture> _loadCaptures() {
  final files =
      Directory(_captureDir)
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  return [
    for (final file in files) PoseCapture.decode(file.readAsStringSync()),
  ];
}

void main() {
  group('pose filter captures', () {
    test('the committed fixtures decode with provenance', () {
      final captures = _loadCaptures();

      expect(captures, hasLength(60));
      expect(captures.map((capture) => capture.runtime).toSet(), {
        TrackingVendor.androidXr,
        TrackingVendor.viture,
        TrackingVendor.xreal,
      });
      for (final capture in captures) {
        expect(capture.samples.length, greaterThan(100));
        expect(capture.synthetic, isTrue);
        expect(capture.appCommit, isNull);
        expect(capture.provenance['generator'], contains('generate_pose'));
      }
    });

    test('a recording with hand anchors converts to a capture', () {
      final frame = TrackingFrame(
        timeNs: 1000,
        hostTimeNs: 1000,
        rightHand: HandPose(
          hand: TrackedHand.right,
          palm: TrackedPose(
            pose: Pose(
              translation: Vector3(0.2, -0.25, -0.35),
              rotation: Quaternion.identity(),
            ),
          ),
        ),
      );
      final recording = PoseRecording(
        samples: [
          PoseRecordingSample(hostTimeNs: 1000, tracking: frame),
          PoseRecordingSample(
            hostTimeNs: 2000,
            tracking: frame.withHostTime(2000),
          ),
        ],
      );

      final capture = PoseCapture.fromRecording(
        recording,
        runtime: TrackingVendor.viture,
        motion: PoseMotion.still,
        provenance: const {
          'kind': 'hardware',
          'app_commit': 'abc1234',
          'firmware_sha': 'def5678',
        },
      );

      expect(capture.samples, hasLength(2));
      expect(capture.samples.first.position, Vector3(0.2, -0.27, -0.41));
      expect(capture.appCommit, 'abc1234');
      expect(capture.firmwareSha, 'def5678');
    });
  });

  group('tuning', () {
    test('the grid finds a passing point on the harness fixtures', () {
      final reports = tunePoseFilter(_loadCaptures());

      expect(reports, hasLength(3));
      for (final report in reports) {
        expect(report.passed, isTrue, reason: report.runtime.name);
        final chosen = report.chosen!;
        expect(chosen.jitterMm, lessThanOrEqualTo(poseFilterJitterLimitMm));
        expect(chosen.lagMedianMs, lessThanOrEqualTo(poseFilterLagLimitMs));
      }
    });

    test('the grid distinguishes a passing point from the paper defaults', () {
      final captures = _loadCaptures();
      const paper = PoseFilterConfig(
        minCutoffHz: 1,
        beta: 0.02,
        dCutoffHz: 1,
        minDt: Duration(microseconds: 4167),
      );
      final reports = tunePoseFilter(captures);
      for (final report in reports) {
        final chosen = report.chosen!;
        final tuned = chosen.point.config(OneEuroFilter.defaultMinDt);
        for (final capture in captures.where(
          (capture) =>
              capture.runtime == report.runtime &&
              (capture.motion == PoseMotion.mediumPan ||
                  capture.motion == PoseMotion.fastFlick),
        )) {
          final before = analyzeCapture(capture, paper);
          final after = analyzeCapture(capture, tuned);
          expect(
            after.lagMedianMs,
            lessThan(before.lagMedianMs),
            reason: '${capture.runtime.name} ${capture.motion.name}',
          );
        }
      }
    });

    test('the command exits 0 and writes the evidence', () async {
      final directory = Directory.systemTemp.createTempSync('pose_filter_');
      addTearDown(() => directory.deleteSync(recursive: true));
      final output = '${directory.path}/tune.json';
      final markdown = '${directory.path}/grid.md';
      final process = await Process.run(Platform.resolvedExecutable, [
        'run',
        'tool/pose_filter_tune.dart',
        '--output',
        output,
        '--markdown',
        markdown,
      ], workingDirectory: Directory.current.path);

      expect(process.exitCode, 0, reason: process.stderr as String?);
      final json = jsonDecode(File(output).readAsStringSync()) as Map;
      expect(json['captures'], 60);
      expect(json['per_capture'], hasLength(60));
      final runtimes = json['runtimes'] as List;
      expect(runtimes, hasLength(3));
      for (final runtime in runtimes) {
        expect((runtime as Map)['passed'], isTrue);
      }
      final grid = File(markdown).readAsStringSync();
      expect(grid, contains('# Pose filter tuning grid (ONY-502)'));
      expect(grid, contains('| 16.0 | 0.2 | 4.0 |'));
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
