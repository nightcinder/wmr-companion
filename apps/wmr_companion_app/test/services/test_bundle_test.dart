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
}
