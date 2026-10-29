import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_ble/wmr_ble.dart';
import 'package:wmr_ble/testing.dart';
import 'package:wmr_companion_app/services/test_bundle_export.dart';
import 'package:wmr_companion_app/ui/capture/capture_providers.dart';
import 'package:wmr_companion_app/ui/connect/connect_providers.dart';
import 'package:wmr_companion_app/ui/connect/connect_screen.dart';
import 'package:wmr_companion_app/ui/debug/stream_settings.dart';
import 'package:wmr_companion_app/ui/latency/latency_providers.dart';
import 'package:wmr_core/ble/ble_transport.dart';
import 'package:wmr_core/ble/fake_wmr_bridge.dart';
import 'package:wmr_core/protocol/gatt.dart';
import 'package:wmr_core/services/capture_files.dart';
import 'package:wmr_core/services/latency_files.dart';

import 'raw_mode_notifier.dart';

/// The fake adapter's read returns zeros; FF16 has to say something real for
/// the manifest assertion.
class _FirmwareAdapter extends FakeBleAdapter {
  @override
  Future<Uint8List> read(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
  ) async {
    if (characteristicUuid == wmrBridgeVersionCharUuid) {
      return Uint8List.fromList(utf8.encode('0.3.0'));
    }
    return super.read(deviceId, serviceUuid, characteristicUuid);
  }
}

void main() {
  late Directory dir;
  late _FirmwareAdapter adapter;
  late List<String> shared;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('bundle_export');
    adapter = _FirmwareAdapter();
    shared = [];
  });

  tearDown(() {
    dir.deleteSync(recursive: true);
  });

  testWidgets('one tap exports a zip of the fake bridge artifacts', (
    tester,
  ) async {
    final latencyDir = Directory('${dir.path}/latency')..createSync();
    File('${latencyDir.path}/latency-20261029-101112.json')
        .writeAsStringSync('{"run": true}\n');
    File('${latencyDir.path}/latency-20261029-101112.csv')
        .writeAsStringSync('t_us,left\n');
    final captureDir = Directory('${dir.path}/documents')..createSync();
    File('${captureDir.path}/left-20261029-100000.txt')
        .writeAsStringSync('@begin left-hold\n');

    final transport = UniversalBleTransport(
      adapter: adapter,
      scanTimeout: const Duration(minutes: 5),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          realTransportProvider.overrideWithValue(transport),
          streamModeProvider.overrideWith(RawModeNotifier.new),
          latencyStoreProvider.overrideWith((ref) => LatencyStore(latencyDir)),
          captureStoreProvider.overrideWith((ref) => CaptureStore(captureDir)),
          bundleOutputDirectoryProvider.overrideWith(
            (ref) async => Directory('${dir.path}/out'),
          ),
          bundleClockProvider.overrideWithValue(
            () => DateTime(2026, 10, 29, 12, 30, 0),
          ),
          bundleDeviceInfoProvider.overrideWithValue(
            () async => const BundleDeviceInfo(
              appVersion: '0.2.2+4',
              phone: 'Test Phone',
              androidVersion: 'Android 14 (API 34)',
            ),
          ),
          shareTestBundleProvider.overrideWithValue((path) async {
            shared.add(path);
          }),
        ],
        child: const MaterialApp(home: ConnectScreen()),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Scan'));
    await tester.pump();
    await tester.pump();
    adapter.emitScanResult(
      const BleScanResult(
        deviceId: fakeBridgeDeviceId,
        name: 'WMR Bridge',
        rssi: -48,
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Connect'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    expect(find.text('State: connected, streaming'), findsOneWidget);

    final zip = File('${dir.path}/out/wmr-ext-20261029.zip');
    late List<int> bytes;
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('export-test-bundle')));
      for (var i = 0; i < 200 && shared.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      bytes = await zip.readAsBytes();
    });
    await tester.pump();

    expect(zip.existsSync(), isTrue);
    expect(shared, [zip.path]);
    expect(find.textContaining('Shared wmr-ext-20261029.zip'), findsOneWidget);

    final archive = ZipDecoder().decodeBytes(bytes);
    final names = [for (final file in archive.files) file.name];
    expect(
      names,
      containsAll([
        'manifest.md',
        'README.md',
        'diagnostics.json',
        'latency/latency-20261029-101112.json',
        'latency/latency-20261029-101112.csv',
        'captures/left-20261029-100000.txt',
      ]),
    );

    String text(String name) => utf8.decode(
      archive.files.firstWhere((file) => file.name == name).content,
    );

    final manifest = text('manifest.md');
    expect(manifest, contains('- Date: 2026-10-29T12:30:00.000'));
    expect(manifest, contains('- Phone: Test Phone'));
    expect(manifest, contains('- Android: Android 14 (API 34)'));
    expect(manifest, contains('- Firmware: 0.3.0'));
    expect(manifest, contains('- MTU: 185'));

    final readme = text('README.md');
    expect(readme, contains('## Present'));
    expect(readme, contains('Latest latency run: latency/'));
    expect(readme, contains('FF11 captures: 1 file(s)'));
    expect(readme, contains('- (none)'));

    final diagnostics = jsonDecode(text('diagnostics.json')) as Map;
    expect((diagnostics['app'] as Map)['version'], '0.2.2+4');
    final exportedBridge = (diagnostics['bridges'] as List).single as Map;
    expect((exportedBridge['firmware'] as Map)['version'], '0.3.0');
    expect(exportedBridge['mtu'], 185);
    expect((exportedBridge['link'] as Map)['rssi_dbm'], isNotNull);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
