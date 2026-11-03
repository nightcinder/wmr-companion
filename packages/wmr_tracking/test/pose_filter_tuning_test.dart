import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:vector_math/vector_math_64.dart';
import 'package:wmr_tracking/wmr_tracking.dart';

import '../tool/src/pose_filter_tuning.dart';

const String _captureDir = 'test/fixtures/pose_filter_captures/synthetic';

List<PoseCapture> _loadCaptures({TrackingVendor? runtime, int? run}) {
  final files =
      Directory(_captureDir)
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  return [for (final file in files) PoseCapture.decode(file.readAsStringSync())]
      .where((capture) {
        if (runtime != null && capture.runtime != runtime) return false;
        if (run != null && capture.run != run) return false;
        return true;
      })
      .toList();
}

void main() {
  group('pose filter captures', () {
    test('the committed fixtures decode with provenance', () {
      final captures = _loadCaptures();

      expect(captures, hasLength(72));
      expect(captures.map((capture) => capture.runtime).toSet(), {
        TrackingVendor.androidXr,
        TrackingVendor.viture,
        TrackingVendor.xreal,
      });
      expect(captures.map((capture) => capture.motion).toSet(), {
        PoseMotion.still,
        PoseMotion.heldDrift,
        PoseMotion.slowPan,
        PoseMotion.mediumPan,
        PoseMotion.fastFlick,
        PoseMotion.occlusion,
      });
      for (final capture in captures) {
        expect(capture.samples.length, greaterThan(100));
        expect(capture.synthetic, isTrue);
        expect(capture.appCommit, isNull);
        expect(capture.provenance['generator'], contains('generate_pose'));
      }
    });

    test('a recording keeps the raw anchor joint, not a grip offset', () {
      final frame = TrackingFrame(
        timeNs: 1000,
        hostTimeNs: 1000,
        rightHand: HandPose(
          hand: TrackedHand.right,
          palm: TrackedPose(
            pose: Pose(
              translation: Vector3(0.2, -0.25, -0.35),
              rotation: Quaternion.axisAngle(Vector3(0, 1, 0), 0.4),
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
      // filter-spec section 3 filters the anchor joint; the grip offset is
      // applied after filtering and must not leak into the capture.
      expect(capture.samples.first.position, Vector3(0.2, -0.25, -0.35));
      expect(capture.appCommit, 'abc1234');
      expect(capture.firmwareSha, 'def5678');
    });

    test('a recording accepts a runtime-tracked controller pose', () {
      final frame = TrackingFrame(
        timeNs: 1000,
        hostTimeNs: 1000,
        rightHand: HandPose(
          hand: TrackedHand.right,
          palm: TrackedPose(
            pose: Pose(
              translation: Vector3(0.1, -0.2, -0.3),
              rotation: Quaternion.identity(),
            ),
          ),
        ),
        controllers: {
          TrackedHand.right: TrackedPose(
            pose: Pose(
              translation: Vector3(0.4, 1.0, -0.5),
              rotation: Quaternion.identity(),
            ),
          ),
        },
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
        runtime: TrackingVendor.androidXr,
        motion: PoseMotion.still,
      );

      expect(capture.samples, hasLength(2));
      // A runtime-tracked controller is the position the filter sees.
      expect(capture.samples.first.position, Vector3(0.4, 1.0, -0.5));
    });
  });

  group('filter-spec rev 4 grid', () {
    test('is 4,264 points at the section 7 steps', () {
      const grid = PoseGrid.standard;

      expect(grid.pointCount, 4264);
      expect(grid.minCutoff.values, hasLength(13));
      expect(grid.minCutoff.values.first, 1.0);
      expect(grid.minCutoff.values.last, 4.0);
      expect(grid.beta.values, hasLength(41));
      expect(grid.beta.values.first, 0.0);
      expect(grid.beta.values.last, 0.40);
      expect(grid.dCutoff.values, hasLength(8));
      expect(grid.dCutoff.values.first, 0.5);
      expect(grid.dCutoff.values.last, 4.0);
    });

    test('extends a bar-limiting boundary by 50 % at the same step', () {
      const point = TuningPoint(minCutoffHz: 1.0, beta: 0.40, dCutoffHz: 0.5);
      final extended = PoseGrid.standard.extendedFor(point)!;

      expect(extended.minCutoff.min, lessThan(1.0));
      expect(extended.minCutoff.step, 0.25);
      expect(extended.beta.max, closeTo(0.60, 1e-9));
      expect(extended.beta.step, 0.01);
      // 0.5 Hz cannot grow downward at a 0.5 Hz step, so dCutoff grows up.
      expect(extended.dCutoff.max, closeTo(6.0, 1e-9));
      expect(extended.dCutoff.step, 0.5);
    });

    test('an interior point is not on a boundary', () {
      const point = TuningPoint(minCutoffHz: 2.0, beta: 0.20, dCutoffHz: 2.0);
      expect(PoseGrid.standard.edgesAt(point), isEmpty);
      expect(PoseGrid.standard.extendedFor(point), isNull);
    });
  });

  group('tuning', () {
    test('the grid chooses the lowest-J_D passing point', () {
      // A narrow grid around the synthetic optimum so the check is fast and
      // the winner is interior. The standard 4,264-point grid is shape-tested
      // above; the command test below runs it.
      const grid = PoseGrid(
        minCutoff: PoseAxis(min: 0.10, max: 1.00, step: 0.10),
        beta: PoseAxis(min: 0.00, max: 0.20, step: 0.02),
        dCutoff: PoseAxis(min: 0.5, max: 2.0, step: 0.5),
      );
      final captures = _loadCaptures(runtime: TrackingVendor.androidXr, run: 1);
      final reports = tunePoseFilter(captures, grid: grid);

      expect(reports, hasLength(1));
      final report = reports.single;
      expect(report.passed, isTrue);
      expect(report.inconclusive, isFalse);
      final chosen = report.chosen!;
      expect(chosen.jitterMm, lessThanOrEqualTo(poseFilterJitterLimitMm));
      expect(
        chosen.jitterDriftMm,
        lessThanOrEqualTo(poseFilterDriftJitterLimitMm),
      );
      expect(chosen.lagMedianMs, lessThanOrEqualTo(poseFilterLagLimitMs));
      expect(
        chosen.slowLagRegressionOk,
        isTrue,
        reason: 'the synthetic fixtures still meet the slow-sweep bound',
      );
      final lowerDrift = report.rows.where(
        (row) => row.passes && row.jitterDriftMm < chosen.jitterDriftMm,
      );
      expect(lowerDrift, isEmpty);
    });

    test('the slow-sweep bound is a regression metric, not a grid gate', () {
      const row = TuningRow(
        point: TuningPoint(minCutoffHz: 2.0, beta: 0.2, dCutoffHz: 2.0),
        jitterMm: 0.1,
        jitterDriftMm: 0.1,
        lagSlowMedianMs: 200,
        lagMedianMs: 5,
        step90Ms: 10,
      );

      expect(row.passes, isTrue);
      expect(row.slowLagRegressionOk, isFalse);
    });

    test('the command writes the whole grid and its evidence', () async {
      final directory = Directory.systemTemp.createTempSync('pose_filter_');
      addTearDown(() => directory.deleteSync(recursive: true));
      final captureDir = Directory('${directory.path}/captures')..createSync();
      for (final capture in _loadCaptures(
        runtime: TrackingVendor.androidXr,
        run: 1,
      )) {
        final name =
            '${capture.runtime.name}-${capture.motion.name}-${capture.run}.json';
        File('${captureDir.path}/$name').writeAsStringSync(capture.encode());
      }
      final output = '${directory.path}/tune.json';
      final markdown = '${directory.path}/grid.md';
      final process = await Process.run(Platform.resolvedExecutable, [
        'run',
        'tool/pose_filter_tune.dart',
        '--captures',
        captureDir.path,
        '--output',
        output,
        '--markdown',
        markdown,
      ], workingDirectory: Directory.current.path);

      expect(
        process.exitCode,
        anyOf(0, 1, 3),
        reason: process.stderr as String?,
      );
      final json = jsonDecode(File(output).readAsStringSync()) as Map;
      expect(json['spec'], 'filter-spec rev 4');
      expect(json['captures'], 6);
      expect(json['per_capture'], hasLength(6));
      expect((json['grid'] as Map)['points'], 4264);
      final runtimes = json['runtimes'] as List;
      expect(runtimes, hasLength(1));
      final runtime = runtimes.single as Map;
      expect(runtime['rows'], hasLength(4264));
      expect(runtime['missing_motions'], isEmpty);
      final grid = File(markdown).readAsStringSync();
      expect(grid, contains('# Pose filter tuning grid (ONY-502)'));
      expect(grid, contains('filter-spec'));
      expect(grid, contains('4264 points per runtime'));
    }, timeout: const Timeout(Duration(minutes: 4)));
  });
}
