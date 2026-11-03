import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_companion_app/services/test_bundle.dart';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('test_bundle');
  });

  tearDown(() {
    dir.deleteSync(recursive: true);
  });

  String text(Archive archive, String name) {
    final file = archive.files.firstWhere((f) => f.name == name);
    return utf8.decode(file.content);
  }

  BundleBridge bridge(String version) => BundleBridge(
    id: 'AA:BB:CC:DD:EE:FF',
    transport: 'BLE',
    firmwareVersion: version,
    firmwareFeaturePresent: true,
    features: const ['rawStream', 'firmwareVersion'],
    mtu: 185,
    rssi: -48,
    connectionIntervalUs: 7500,
    phy: '1M',
    linkState: 'connected',
    mode: 'raw',
    rateHz: const [99.4, 98.8],
    loss: const [0.001, null],
  );

  test('adds pose captures with fixed names and provenance', () async {
    final pose = File('${dir.path}/pose_capture_viture_left_still.json')
      ..writeAsStringSync(
        '{"format":"wmr-pose-recording","version":1,'
        '"samples":[]}',
      );
    final bench = BenchBundleRun([
      BenchBundleStep(
        id: 'pose_capture',
        status: 'done',
        summary: '1 of 1 pose segments recorded',
        data: {
          'segments': [
            {
              'runtime': 'viture',
              'hand': 'LEFT',
              'segment': 'still',
              'status': 'done',
              'file': pose.path,
              'samples': 7,
              'app_commit': 'abc1234',
              'firmware_sha': 'deadbee',
            },
            {
              'runtime': 'viture',
              'hand': 'LEFT',
              'segment': 'drifting',
              'status': 'skipped',
              'reason': 'skipped by tester',
            },
          ],
        },
      ),
    ]);

    final bundle = await writeTestBundle(
      TestBundleInput(
        now: DateTime(2026, 10, 29, 16, 30),
        appVersion: '0.2.2+4',
        appCommit: 'abc1234',
        phone: 'Test Phone',
        androidVersion: 'Android 14 (API 34)',
        streamMode: 'batched',
        bridges: [bridge('0.3.0')],
        poseCaptures: [
          PoseCaptureFile(
            path: pose.path,
            runtime: 'viture',
            hand: 'left',
            segment: 'still',
          ),
        ],
        benchRun: bench,
      ),
      Directory('${dir.path}/out'),
    );

    final archive = ZipDecoder().decodeBytes(
      await File(bundle.path).readAsBytes(),
    );
    final names = [for (final file in archive.files) file.name];
    expect(names, contains('pose_capture_viture_left_still.json'));
    expect(
      bundle.present.join('\n'),
      contains('6DoF pose captures: 1 file(s)'),
    );

    final manifest = text(archive, 'manifest.md');
    expect(manifest, contains('- App commit: abc1234'));
    expect(manifest, contains('## 6DoF pose captures'));
    expect(manifest, contains('- Runtime: viture'));
    expect(manifest, contains('- Firmware SHA: deadbee'));
    expect(
      manifest,
      contains(
        '| pose_capture_viture_left_still.json | LEFT '
        '| still | 1 | done | 7 | — | — |',
      ),
    );
    expect(
      manifest,
      contains(
        '| — | LEFT | drifting | 1 | skipped | — | — | '
        'skipped by tester |',
      ),
    );
  });

  test(
    'zips the manifest, diagnostics, latest latency run and captures',
    () async {
      final latencyJson = File('${dir.path}/latency-20261029-130507.json')
        ..writeAsStringSync('{"run": true}');
      final latencyCsv = File('${dir.path}/latency-20261029-130507.csv')
        ..writeAsStringSync('t,us\n');
      final capture = File('${dir.path}/left-20261029-130000.txt')
        ..writeAsStringSync('@begin\n');

      final bundle = await writeTestBundle(
        TestBundleInput(
          now: DateTime(2026, 10, 29, 13, 5, 7),
          appVersion: '0.2.2+4',
          phone: 'Google Pixel 8',
          androidVersion: 'Android 14 (API 34)',
          streamMode: 'raw',
          rawStats: const {
            'frames': [1200, 1190],
            'reassembly_errors': 0,
          },
          bridges: [bridge('0.3.0')],
          latencyFiles: [latencyJson.path, latencyCsv.path],
          captureFiles: [capture.path],
        ),
        Directory('${dir.path}/out'),
      );

      expect(bundle.fileName, 'wmr-ext-20261029.zip');
      expect(bundle.missing, isEmpty);
      expect(
        bundle.present,
        contains(startsWith('Firmware version (FF16): 0.3.0')),
      );

      final archive = ZipDecoder().decodeBytes(
        await File(bundle.path).readAsBytes(),
      );
      final names = [for (final file in archive.files) file.name];
      expect(
        names,
        containsAll([
          'manifest.md',
          'README.md',
          'diagnostics.json',
          'latency/latency-20261029-130507.json',
          'latency/latency-20261029-130507.csv',
          'captures/left-20261029-130000.txt',
        ]),
      );

      final manifest = text(archive, 'manifest.md');
      expect(manifest, contains('- Date: 2026-10-29T13:05:07.000'));
      expect(manifest, contains('- Phone: Google Pixel 8'));
      expect(manifest, contains('- Android: Android 14 (API 34)'));
      expect(manifest, contains('- Firmware: 0.3.0'));
      expect(manifest, contains('- MTU: 185'));

      final readme = text(archive, 'README.md');
      expect(readme, contains('## Present'));
      expect(readme, contains('Latest latency run: latency/'));
      expect(readme, contains('FF11 captures: 1 file(s)'));
      expect(readme, contains('## Missing'));
      expect(readme, contains('- (none)'));

      final diagnostics =
          jsonDecode(text(archive, 'diagnostics.json')) as Map<String, Object?>;
      expect(diagnostics['app'], {
        'name': 'wmr_companion_app',
        'version': '0.2.2+4',
        'commit': 'unknown',
      });
      expect((diagnostics['stream'] as Map)['mode'], 'raw');
      final bridgeJson = (diagnostics['bridges'] as List).single as Map;
      expect((bridgeJson['firmware'] as Map)['version'], '0.3.0');
      expect((bridgeJson['firmware'] as Map)['source'], 'FF16');
      expect(bridgeJson['mtu'], 185);
      expect((bridgeJson['link'] as Map)['rssi_dbm'], -48);
      expect((bridgeJson['stream'] as Map)['rate_hz'], [99.4, 98.8]);
    },
  );

  test('names every missing artifact in the README and the result', () async {
    final bundle = await writeTestBundle(
      TestBundleInput(
        now: DateTime(2026, 10, 29, 9),
        appVersion: '0.2.2+4',
        phone: 'Google Pixel 8',
        androidVersion: 'Android 14 (API 34)',
        streamMode: 'none',
      ),
      Directory('${dir.path}/out'),
    );

    expect(bundle.missing, contains(contains('Latest latency run')));
    expect(bundle.missing, contains(contains('FF11 captures')));
    expect(bundle.missing, contains(contains('Firmware version (FF16)')));
    expect(bundle.missing, contains(contains('MTU')));

    final archive = ZipDecoder().decodeBytes(
      await File(bundle.path).readAsBytes(),
    );
    final names = [for (final file in archive.files) file.name];
    expect(names, isNot(contains(startsWith('latency/'))));
    expect(names, isNot(contains(startsWith('captures/'))));

    final manifest = text(archive, 'manifest.md');
    expect(manifest, contains('- Firmware: not connected'));
    expect(manifest, contains('- MTU: not reported'));

    final readme = text(archive, 'README.md');
    expect(readme, contains('## Missing'));
    expect(readme, contains('Latest latency run'));
    expect(readme, contains('FF11 captures'));
    expect(readme, contains('Firmware version (FF16)'));
    expect(readme, contains('MTU'));
  });

  test('records every guided bench step in the manifest', () async {
    final bundle = await writeTestBundle(
      TestBundleInput(
        now: DateTime(2026, 10, 29, 14),
        appVersion: '0.2.2+4',
        phone: 'Google Pixel 8',
        androidVersion: 'Android 14 (API 34)',
        streamMode: 'raw',
        benchRun: const BenchBundleRun([
          BenchBundleStep(
            id: 'connect',
            status: 'done',
            summary: '1 bridge(s): AA (MTU 185, raw)',
          ),
          BenchBundleStep(
            id: 'both_hands',
            status: 'done',
            summary: 'Frames from LEFT and RIGHT',
          ),
          BenchBundleStep(id: 'still_left', status: 'skipped'),
          BenchBundleStep(
            id: 'latency',
            status: 'failed',
            detail: 'The latency run recorded no rows.',
          ),
          BenchBundleStep(id: 'export', status: 'not_run'),
        ]),
      ),
      Directory('${dir.path}/out'),
    );

    expect(
      bundle.present,
      contains('Guided bench run: 2 done, 1 skipped, 1 failed (5 steps)'),
    );

    final archive = ZipDecoder().decodeBytes(
      await File(bundle.path).readAsBytes(),
    );
    final manifest = text(archive, 'manifest.md');
    expect(manifest, contains('## Guided bench run'));
    expect(manifest, contains('- connect: done — 1 bridge(s)'));
    expect(manifest, contains('- both_hands: done — Frames from LEFT'));
    expect(manifest, contains('- still_left: skipped'));
    expect(
      manifest,
      contains('- latency: failed — The latency run recorded no rows.'),
    );
    expect(manifest, contains('- export: not_run'));

    final diagnostics =
        jsonDecode(text(archive, 'diagnostics.json')) as Map<String, Object?>;
    final bench = diagnostics['bench']! as Map<String, Object?>;
    final steps = (bench['steps']! as List).cast<Map<String, Object?>>();
    expect(steps, hasLength(5));
    expect(steps[3]['id'], 'latency');
    expect(steps[3]['status'], 'failed');
  });

  test('lists every pose capture file and the bench mode', () async {
    final captures = Directory('${dir.path}/pose')..createSync();
    final left = File('${captures.path}/pose_capture_fake_left_still.json')
      ..writeAsStringSync('{"format":"wmr-pose-recording","version":1}');
    final right = File(
      '${captures.path}/pose_capture_fake_right_fastFlick.json',
    )..writeAsStringSync('{"format":"wmr-pose-recording","version":1}');

    final bundle = await writeTestBundle(
      TestBundleInput(
        now: DateTime(2026, 10, 29, 15),
        appVersion: '0.2.2+4',
        phone: 'Galaxy XR',
        androidVersion: 'Android 16 (API 36)',
        streamMode: 'none',
        benchRun: const BenchBundleRun([
          BenchBundleStep(id: 'device_summary', status: 'done'),
          BenchBundleStep(
            id: 'pose_capture',
            status: 'done',
            data: {
              'segments': [
                {
                  'file': '/tmp/pose_capture_fake_left_still.json',
                  'runtime': 'fake',
                  'hand': 'LEFT',
                  'segment': 'still',
                  'status': 'done',
                  'samples': 30,
                },
                {
                  'file': '/tmp/pose_capture_fake_right_fastFlick.json',
                  'runtime': 'fake',
                  'hand': 'RIGHT',
                  'segment': 'fastFlick',
                  'status': 'done',
                  'samples': 30,
                },
              ],
            },
          ),
          BenchBundleStep(id: 'export', status: 'done'),
        ], mode: '6dof_only'),
        benchRuntime: 'fake',
        appCommit: 'abc1234',
        poseCaptures: [
          PoseCaptureFile(
            path: left.path,
            runtime: 'fake',
            hand: 'left',
            segment: 'still',
          ),
          PoseCaptureFile(
            path: right.path,
            runtime: 'fake',
            hand: 'right',
            segment: 'fastFlick',
          ),
        ],
      ),
      Directory('${dir.path}/out'),
    );

    final archive = ZipDecoder().decodeBytes(
      await File(bundle.path).readAsBytes(),
    );
    final names = archive.files.map((file) => file.name).toSet();
    expect(names, contains('pose_capture_fake_left_still.json'));
    expect(names, contains('pose_capture_fake_right_fastFlick.json'));

    final manifest = text(archive, 'manifest.md');
    expect(manifest, contains('- Bench mode: 6dof_only'));
    expect(manifest, contains('- Tracking runtime: fake'));
    expect(manifest, contains('- App commit: abc1234'));
    expect(manifest, contains('- Firmware SHA: none (no bridge)'));
    expect(manifest, contains('## 6DoF pose captures'));
    expect(manifest, contains('pose_capture_fake_left_still.json'));
    expect(manifest, contains('| LEFT | still | 1 | done | 30 |'));
    expect(manifest, contains('pose_capture_fake_right_fastFlick.json'));
  });
}
