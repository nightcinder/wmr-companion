import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_companion/testing.dart';
import 'package:wmr_companion_app/services/test_bundle.dart';
import 'package:wmr_core/domain/stick_centre.dart';
import 'package:wmr_tracking/wmr_tracking.dart';
import 'package:wmr_tracking_dispatch/wmr_tracking_dispatch.dart';

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

  DeviceEnvironmentSnapshot environment() => DeviceEnvironmentSnapshot(
    capturedAt: DateTime.utc(2026, 11, 9, 12),
    usbHostAvailable: true,
    usbDevices: const [
      UsbDeviceSnapshot(
        vendorId: 0xFFFF,
        productId: 0xEEEE,
        productName: 'URXR One',
        interfaces: [
          UsbInterfaceSnapshot(
            interfaceClass: 0xFF,
            interfaceSubclass: 0x42,
            interfaceProtocol: 0x99,
          ),
        ],
      ),
    ],
    displays: const [
      ExternalDisplaySnapshot(
        id: 7,
        type: 'type_99',
        name: 'URXR One',
        width: 2328,
        height: 1728,
        refreshRateHz: 90.0,
      ),
    ],
    xrFeatures: const [
      XrSystemFeatureSnapshot(name: 'vendor.urxr.spatial', present: false),
    ],
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
        '| — | LEFT | drifting | 1 | skipped | — | — | — | — | '
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
          deviceEnvironment: environment(),
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

  test('diagnostics records the composite leg and stick settings', () async {
    final bundle = await writeTestBundle(
      TestBundleInput(
        now: DateTime(2026, 11, 9, 12),
        appVersion: '0.3.20+25',
        phone: 'Test Phone',
        androidVersion: 'Android 14 (API 34)',
        streamMode: 'raw',
        wifiFallback: true,
        activeLeg: 'TCP',
        stickSettings: const StickSettings(
          config: StickConfig(deadZone: 0.2, learn: false),
          centres: [
            [0.03, 0.148],
            null,
          ],
        ),
      ),
      Directory('${dir.path}/out'),
    );

    final archive = ZipDecoder().decodeBytes(
      await File(bundle.path).readAsBytes(),
    );
    final diagnostics =
        jsonDecode(text(archive, 'diagnostics.json')) as Map<String, Object?>;
    expect(diagnostics['ble_fallback'], isTrue);
    expect(diagnostics['active_leg'], 'TCP');
    expect(diagnostics['stick'], {
      'dead_zone': 0.2,
      'learn_centre': false,
      'centres': [
        [0.03, 0.148],
        null,
      ],
    });
  });

  test('diagnostics keeps each episode anchor after an upgrade', () async {
    // Two stalls, each followed by a failover and an upgrade back to TCP.
    // Each episode froze its own pre-stall anchor, while the records the
    // upgrades delivered moved only the top-level mark, which the newest
    // record (9.5 s) now owns; the third episode is the live one.
    const timeline = {
      'last_tcp_record_us': 9500000,
      'stall_detected_us': 9100000,
      'failover_begin_us': 9105000,
      'failover_end_us': 9180000,
      'first_ble_record_us': 9200000,
      'upgrade_dial_start_us': null,
      'upgrade_dial_end_us': null,
      'first_tcp_record_us': null,
      'episodes': [
        {
          'last_tcp_record_us': 1000000,
          'stall_detected_us': 1100000,
          'failover_begin_us': 1105000,
          'failover_end_us': 1180000,
          'first_ble_record_us': 1200000,
          'upgrade_dial_start_us': 5000000,
          'upgrade_dial_end_us': 5105000,
          'first_tcp_record_us': 5120000,
        },
        {
          'last_tcp_record_us': 6000000,
          'stall_detected_us': 6100000,
          'failover_begin_us': 6105000,
          'failover_end_us': 6180000,
          'first_ble_record_us': 6200000,
          'upgrade_dial_start_us': 8000000,
          'upgrade_dial_end_us': 8105000,
          'first_tcp_record_us': 8120000,
        },
      ],
    };

    final bundle = await writeTestBundle(
      TestBundleInput(
        now: DateTime(2026, 11, 19, 12),
        appVersion: '0.3.27+35',
        phone: 'Test Phone',
        androidVersion: 'Android 14 (API 34)',
        streamMode: 'raw',
        linkTimeline: timeline,
      ),
      Directory('${dir.path}/out'),
    );

    final archive = ZipDecoder().decodeBytes(
      await File(bundle.path).readAsBytes(),
    );
    final diagnostics =
        jsonDecode(text(archive, 'diagnostics.json')) as Map<String, Object?>;
    final exported = diagnostics['link_timeline']! as Map<String, Object?>;
    expect(exported['last_tcp_record_us'], 9500000);
    final episodes = exported['episodes']! as List<Object?>;
    expect(episodes, hasLength(2));

    // The anchors the recorder froze survive the export, and each
    // episode's first-BLE takeover stays computable and at least zero.
    final episodeOne = episodes[0]! as Map<String, Object?>;
    expect(episodeOne['last_tcp_record_us'], 1000000);
    final takeoverOne =
        (episodeOne['first_ble_record_us']! as int) -
        (episodeOne['last_tcp_record_us']! as int);
    expect(takeoverOne, greaterThanOrEqualTo(0));

    final episodeTwo = episodes[1]! as Map<String, Object?>;
    expect(episodeTwo['last_tcp_record_us'], 6000000);
    final takeoverTwo =
        (episodeTwo['first_ble_record_us']! as int) -
        (episodeTwo['last_tcp_record_us']! as int);
    expect(takeoverTwo, greaterThanOrEqualTo(0));

    // The top-level mark no longer bounds either takeover: from it both
    // would read negative. The frozen anchors are what keep step 4
    // computable after the route has moved on.
    expect(
      episodeOne['first_ble_record_us']! as int,
      lessThan(exported['last_tcp_record_us']! as int),
    );
  });

  test('diagnostics keeps the anchors the recorder froze', () async {
    // Driven through the recorder the composite keeps, not a hand-built
    // map: a stall fails over to BLE, the upgrade dials back to TCP and
    // its records move the top-level mark, and the next stall archives
    // the episode. After two rounds two episodes are finished, and the
    // third is live with its upgrade already past its first BLE record.
    final timeline = LinkTimelineRecorder()
      ..onTcpRecord(1000000)
      ..onTcpRecord(1500000)
      ..onStallDetected(1600000)
      ..onFailoverBegin(1605000)
      ..onFailoverEnd(1680000, candidates: 1)
      ..onBleRecord(1700000)
      ..onUpgradeDialStart(2000000)
      ..onUpgradeDialEnd(2105000)
      ..onTcpRecord(2120000)
      ..onTcpRecord(3000000)
      ..onStallDetected(3100000)
      ..onFailoverBegin(3105000)
      ..onFailoverEnd(3180000, candidates: 1)
      ..onBleRecord(3200000)
      ..onUpgradeDialStart(3500000)
      ..onUpgradeDialEnd(3605000)
      ..onTcpRecord(3620000)
      ..onTcpRecord(6000000)
      ..onStallDetected(6100000)
      ..onFailoverBegin(6105000)
      ..onFailoverEnd(6180000, candidates: 1)
      ..onBleRecord(6200000)
      ..onUpgradeDialStart(6500000)
      ..onUpgradeDialEnd(6605000)
      ..onTcpRecord(6620000)
      ..onTcpRecord(7000000);

    final bundle = await writeTestBundle(
      TestBundleInput(
        now: DateTime(2026, 11, 19, 13),
        appVersion: '0.3.27+35',
        phone: 'Test Phone',
        androidVersion: 'Android 14 (API 34)',
        streamMode: 'raw',
        linkTimeline: timeline.snapshot,
      ),
      Directory('${dir.path}/out'),
    );

    final archive = ZipDecoder().decodeBytes(
      await File(bundle.path).readAsBytes(),
    );
    final diagnostics =
        jsonDecode(text(archive, 'diagnostics.json')) as Map<String, Object?>;
    final exported = diagnostics['link_timeline']! as Map<String, Object?>;

    // The records the live episode's upgrade delivered own the top-level
    // mark, past its own first BLE record: it is not an anchor.
    expect(exported['last_tcp_record_us'], 7000000);
    expect(
      exported['first_ble_record_us']! as int,
      lessThan(exported['last_tcp_record_us']! as int),
    );

    // The live episode's anchor survived that upgrade: the takeover stays
    // computable and at least zero from the frozen mark.
    expect(exported['episode_last_tcp_record_us'], 6000000);
    final liveTakeover =
        (exported['first_ble_record_us']! as int) -
        (exported['episode_last_tcp_record_us']! as int);
    expect(liveTakeover, greaterThanOrEqualTo(0));

    // Two episodes export, each with the anchor the recorder froze at its
    // own stall, and each first-BLE takeover still at least zero from it.
    final episodes = exported['episodes']! as List<Object?>;
    expect(episodes, hasLength(2));
    // The bundle keeps every dial key on each finished episode: the Debug
    // row and the bench sheet read the landing attempt and the retry count
    // from this history, so a dropped key would silently break both.
    const dialKeys = [
      'upgrade_dial_start_us',
      'upgrade_dial_end_us',
      'first_upgrade_dial_start_us',
      'upgrade_dial_attempts',
    ];
    for (final episode in episodes) {
      expect(
        (episode! as Map<String, Object?>).keys,
        containsAll(dialKeys),
        reason: 'an episode lost a dial key from the bundle',
      );
    }
    final episodeOne = episodes[0]! as Map<String, Object?>;
    expect(episodeOne['last_tcp_record_us'], 1500000);
    expect(
      (episodeOne['first_ble_record_us']! as int) -
          (episodeOne['last_tcp_record_us']! as int),
      greaterThanOrEqualTo(0),
    );
    final episodeTwo = episodes[1]! as Map<String, Object?>;
    expect(episodeTwo['last_tcp_record_us'], 3000000);
    expect(
      (episodeTwo['first_ble_record_us']! as int) -
          (episodeTwo['last_tcp_record_us']! as int),
      greaterThanOrEqualTo(0),
    );
  });

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
                  'speed_gate': {
                    'cell': 'still',
                    'status': 'pass',
                    'samples': 30,
                    'gated_samples': 28,
                    'in_band_samples': 28,
                    'in_band_fraction': 1.0,
                    'median_speed_mps': 0.008,
                    'band_min_mps': 0.0,
                    'band_max_mps': 0.02,
                    'reason': '0.8 cm/s is in < 2 cm/s',
                  },
                },
                {
                  'file': '/tmp/pose_capture_fake_right_fastFlick.json',
                  'runtime': 'fake',
                  'hand': 'RIGHT',
                  'segment': 'fastFlick',
                  'status': 'done',
                  'samples': 30,
                  'speed_gate': {
                    'cell': 'fastFlick',
                    'status': 'warning',
                    'samples': 30,
                    'gated_samples': 28,
                    'in_band_samples': 0,
                    'in_band_fraction': 0.0,
                    'median_speed_mps': 0.8,
                    'peak_speed_mps': 1.0,
                    'speed_metric': 'peak',
                    'band_min_mps': 1.125,
                    'band_max_mps': 1.875,
                    'reason': '100.0 cm/s is below 112.5-187.5 cm/s',
                  },
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
    expect(manifest, contains('| Speed gate | Speed cm/s |'));
    expect(manifest, contains('| pass | 0.8 |'));
    expect(manifest, contains('pose_capture_fake_right_fastFlick.json'));
    expect(manifest, contains('| warning | 100.0 |'));
  });

  test(
    'writes device_environment.json for unknown environment fixtures',
    () async {
      final bundle = await writeTestBundle(
        TestBundleInput(
          now: DateTime(2026, 11, 9, 12),
          appVersion: '0.3.19+24',
          phone: 'URXR One',
          androidVersion: 'Android 16 (API 36)',
          streamMode: 'none',
          deviceEnvironment: environment(),
        ),
        Directory('${dir.path}/out'),
      );

      expect(bundle.missing, isNot(contains(contains('Device environment'))));
      expect(bundle.present.join('\n'), contains('device_environment.json'));

      final archive = ZipDecoder().decodeBytes(
        await File(bundle.path).readAsBytes(),
      );
      final names = [for (final file in archive.files) file.name];
      expect(names, contains('device_environment.json'));

      final environmentJson = jsonDecode(
        text(archive, 'device_environment.json'),
      ) as Map<String, Object?>;
      expect(environmentJson['format'], 'wmr-device-environment/1');
      expect(environmentJson['captured_at'], '2026-11-09T12:00:00.000Z');
      final usb = environmentJson['usb']! as Map<String, Object?>;
      expect(usb['host_available'], isTrue);
      final device = (usb['devices']! as List).single as Map<String, Object?>;
      expect(device['vendor_id'], 0xFFFF);
      expect(device['product_id'], 0xEEEE);
      expect(device['product'], 'URXR One');
      final usbInterface =
          (device['interfaces']! as List).single as Map<String, Object?>;
      expect(usbInterface['class'], 0xFF);
      expect(usbInterface['subclass'], 0x42);
      expect(usbInterface['protocol'], 0x99);

      final displays = environmentJson['displays']! as Map<String, Object?>;
      expect(displays['external_count'], 0);
      final display =
          (displays['items']! as List).single as Map<String, Object?>;
      expect(display['type'], 'type_99');
      expect(display['name'], 'URXR One');
      expect(display['width'], 2328);
      expect(display['refresh_rate_hz'], 90.0);

      final feature =
          (environmentJson['xr_features']! as List).single
              as Map<String, Object?>;
      expect(feature['name'], 'vendor.urxr.spatial');
      expect(feature['present'], isFalse);

      final manifest = text(archive, 'manifest.md');
      expect(
        manifest,
        contains(
          '- Device environment: 1 USB device(s), 0 external display(s), '
          '1 XR feature(s)',
        ),
      );
    },
  );

  test('names a failed environment probe as a missing artifact', () async {
    final bundle = await writeTestBundle(
      TestBundleInput(
        now: DateTime(2026, 11, 9, 12),
        appVersion: '0.3.19+24',
        phone: 'URXR One',
        androidVersion: 'Android 16 (API 36)',
        streamMode: 'none',
        deviceEnvironment: DeviceEnvironmentSnapshot(
          capturedAt: DateTime.utc(2026, 11, 9, 12),
          status: DeviceEnvironmentProbeStatus.failed,
          reason: DeviceEnvironmentReason.probeFailed,
          detail: 'channel exploded',
        ),
      ),
      Directory('${dir.path}/out'),
    );

    expect(
      bundle.missing.join('\n'),
      contains(
        'Device environment — probe failed (probeFailed): channel exploded',
      ),
    );
    expect(
      bundle.present.join('\n'),
      isNot(contains('device_environment.json')),
    );

    final archive = ZipDecoder().decodeBytes(
      await File(bundle.path).readAsBytes(),
    );
    final environmentJson = jsonDecode(
      text(archive, 'device_environment.json'),
    ) as Map<String, Object?>;
    expect(environmentJson['status'], 'failed');
    expect(environmentJson['reason'], 'probeFailed');
    expect(environmentJson['detail'], 'channel exploded');

    final manifest = text(archive, 'manifest.md');
    expect(
      manifest,
      contains(
        '- Device environment: probe failed (probeFailed): channel exploded',
      ),
    );
  });

  test(
    'diagnostics record relay timing, hand presence and pose sources',
    () async {
      TrackingFrame frame(
        int timeNs, {
        bool left = false,
        bool right = false,
      }) => TrackingFrame(
        timeNs: timeNs,
        leftHand: left ? HandPose(hand: TrackedHand.left) : null,
        rightHand: right ? HandPose(hand: TrackedHand.right) : null,
      );

      final accumulator = HandTrackingAccumulator()
        ..addFrame(frame(0, left: true))
        ..addFrame(frame(10000000, left: true, right: true))
        ..addFrame(frame(20000000, right: true))
        ..addFrame(frame(50000000, right: true))
        ..addPose(ControllerPoseSource.handAnchor)
        ..addPose(ControllerPoseSource.handAnchor)
        ..addPose(ControllerPoseSource.runtimeController);

      final bundle = await writeTestBundle(
        TestBundleInput(
          now: DateTime(2026, 11, 11, 12),
          appVersion: '0.3.23+28',
          phone: 'Test Phone',
          androidVersion: 'Android 14 (API 34)',
          streamMode: 'decoded',
          handTrackingDiagnostics: accumulator.diagnostics,
        ),
        Directory('${dir.path}/out'),
      );

      final archive = ZipDecoder().decodeBytes(
        await File(bundle.path).readAsBytes(),
      );
      final diagnostics =
          jsonDecode(text(archive, 'diagnostics.json')) as Map<String, Object?>;
      expect(diagnostics['hand_tracking_diagnostics'], {
        'relay_frame_count': 4,
        'effective_hz': 60.0,
        'max_gap_ms': 30.0,
        'left_hand_presence_ratio': 0.5,
        'right_hand_presence_ratio': 0.75,
        'pose_source_counts': {'handAnchor': 2, 'runtimeController': 1},
      });
    },
  );
}
