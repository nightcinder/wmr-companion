import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_ble/wmr_ble.dart';
import 'package:wmr_ble/testing.dart';
import 'package:wmr_companion/wmr_companion.dart';
import 'package:wmr_companion_app/services/test_bundle.dart';
import 'package:wmr_companion_app/services/test_bundle_export.dart';
import 'package:wmr_companion_app/ui/capture/capture_providers.dart';
import 'package:wmr_companion_app/ui/connect/connect_providers.dart';
import 'package:wmr_companion_app/ui/connect/connect_screen.dart';
import 'package:wmr_companion_app/ui/debug/stream_settings.dart';
import 'package:wmr_companion_app/ui/latency/latency_providers.dart';
import 'package:wmr_core/ble/ble_transport.dart';
import 'package:wmr_core/ble/fake_transport.dart';
import 'package:wmr_core/ble/fake_wmr_bridge.dart';
import 'package:wmr_core/protocol/gatt.dart';
import 'package:wmr_core/services/capture_files.dart';
import 'package:wmr_core/services/latency_files.dart';
import 'package:wmr_tracking_dispatch/wmr_tracking_dispatch.dart';
import 'package:wmr_ws/wmr_ws.dart';

import 'raw_mode_notifier.dart';

class _FakeEnvironmentProbe implements DeviceEnvironmentProbe {
  const _FakeEnvironmentProbe();

  @override
  Future<DeviceEnvironmentSnapshot> probe() async =>
      DeviceEnvironmentSnapshot(capturedAt: DateTime.utc(2026, 10, 29, 12));
}

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

/// Replays the bridge's GATT table and answers FF16 with a valid endpoint
/// document, so a composite reading it learns the LAN host. The
/// `_EndpointAdapter` of `test/connect_providers_test.dart`.
class _EndpointAdapter extends FakeBleAdapter {
  _EndpointAdapter({required this.bridgeId});

  final String bridgeId;

  @override
  Future<Uint8List> read(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
  ) async {
    if (characteristicUuid.toLowerCase() == wmrBridgeVersionCharUuid) {
      return Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'type': 'wmr_ble_endpoint',
            'protocol': 1,
            'bridge_id': bridgeId,
            'name': 'WMR Bridge',
            'version': '0.2.4',
            'hosts': ['192.168.1.42'],
            'port': 8765,
            'path': '/wmr',
            'authRequired': false,
          }),
        ),
      );
    }
    return super.read(deviceId, serviceUuid, characteristicUuid);
  }
}

/// A [WmrWsTransport] whose every operation runs on a [FakeTransport], so a
/// composite's TCP leg can dial and carry records without a socket. The
/// `_ScriptedTcp` pattern of `test/connect_providers_test.dart`, trimmed to
/// the upgrade path.
class _FakeWs extends WmrWsTransport {
  _FakeWs(this.inner) : super(endpoints: const []);

  final FakeTransport inner;
  final Map<String, WmrWsEndpoint> endpoints = {};
  final Map<String, WmrWsHello> hellos = {};

  @override
  Stream<BleScanResult> scan({List<String> withServices = const []}) =>
      inner.scan(withServices: withServices);

  @override
  Future<void> stopScan() => inner.stopScan();

  @override
  Future<void> connect(String deviceId) => inner.connect(deviceId);

  @override
  Future<void> disconnect(String deviceId) => inner.disconnect(deviceId);

  @override
  Stream<BleConnectionState> connectionState(String deviceId) =>
      inner.connectionState(deviceId);

  @override
  Future<List<BleServiceInfo>> discoverServices(String deviceId) =>
      inner.discoverServices(deviceId);

  @override
  Stream<BleNotification> subscribe(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
  ) => inner.subscribe(deviceId, serviceUuid, characteristicUuid);

  @override
  Future<void> unsubscribe(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
  ) => inner.unsubscribe(deviceId, serviceUuid, characteristicUuid);

  @override
  Future<Uint8List> read(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
  ) => inner.read(deviceId, serviceUuid, characteristicUuid);

  @override
  Future<void> write(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
    Uint8List value, {
    bool withoutResponse = false,
  }) => inner.write(
    deviceId,
    serviceUuid,
    characteristicUuid,
    value,
    withoutResponse: withoutResponse,
  );

  @override
  Future<BleConnectionInfo> connectionInfo(String deviceId) =>
      inner.connectionInfo(deviceId);

  @override
  Future<void> dispose() => inner.dispose();

  @override
  WmrWsEndpoint? endpointFor(String deviceId) => endpoints[deviceId];

  @override
  WmrWsHello? helloFor(String deviceId) => hellos[deviceId];

  @override
  void registerEndpoint(WmrWsEndpoint endpoint) {
    endpoints[endpoint.resolvedDeviceId] = endpoint;
    hellos[endpoint.resolvedDeviceId] = WmrWsHello(
      protocol: 1,
      transport: 'wifi',
      device: 'wmr-pi',
      version: '0.2.4',
      hostname: 'pi',
      bridgeId: endpoint.bridgeId ?? '',
      authRequired: false,
      streams: const {'raw', 'decoded', 'batched'},
      recordSize: 56,
      batchMax: 9,
      fragmentCapacity: 244,
    );
  }
}

Future<void> _waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 2),
  String? reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail(reason ?? 'condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
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
          lanDiscoveryProvider.overrideWithValue(
            () async => const <WmrWsEndpoint>[],
          ),
          launchAutoConnectEnabledProvider.overrideWithValue(false),
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
          deviceEnvironmentProbeProvider.overrideWithValue(
            const _FakeEnvironmentProbe(),
          ),
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

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ConnectScreen)),
      listen: false,
    );
    container.read(stickSettingsProvider.notifier)
      ..setDeadZone(0.2)
      ..setLearn(false)
      ..setCentre(1, -0.02, 0.001);

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
    expect(diagnostics['ble_fallback'], isFalse);
    expect(diagnostics['active_leg'], isNull);
    expect(diagnostics['stick'], {
      'dead_zone': 0.2,
      'learn_centre': false,
      'centres': [
        null,
        [-0.02, 0.001],
      ],
    });

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  test(
    'a composite export only reports ble_fallback while Wi-Fi is active',
    () async {
      final latencyDir = Directory('${dir.path}/latency')..createSync();
      final captureDir = Directory('${dir.path}/captures')..createSync();
      final transport = UniversalBleTransport(
        adapter: FakeBleAdapter(),
        scanTimeout: const Duration(minutes: 5),
      );
      final container = ProviderContainer(
        overrides: [
          realTransportProvider.overrideWithValue(transport),
          compositeWifiTransportFactoryProvider.overrideWithValue(
            (_) => WifiLink(
              FakeTransport(
                devices: const [FakeDevice(id: 'pi.local:8765', mtu: 4096)],
              ),
              activeLeg: () => WifiLinkLeg.tcp,
            ),
          ),
          streamModeProvider.overrideWith(RawModeNotifier.new),
          latencyStoreProvider.overrideWith((ref) => LatencyStore(latencyDir)),
          captureStoreProvider.overrideWith((ref) => CaptureStore(captureDir)),
          bundleDeviceInfoProvider.overrideWithValue(
            () async => const BundleDeviceInfo(
              appVersion: '0.2.2+4',
              phone: 'Test Phone',
              androidVersion: 'Android 14 (API 34)',
            ),
          ),
          deviceEnvironmentProbeProvider.overrideWithValue(
            const _FakeEnvironmentProbe(),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(realDeviceProvider.notifier)
          .connectWifi(host: 'pi.local', port: 8765, bleFallback: true);

      final wifi = await container.read(testBundleInputProvider)();
      expect(wifi.wifiFallback, isTrue);
      expect(wifi.activeLeg, 'TCP');

      await container
          .read(realDeviceProvider.notifier)
          .selectTransport(BridgeTransportKind.ble);

      final ble = await container.read(testBundleInputProvider)();
      expect(ble.wifiFallback, isFalse);
      expect(ble.activeLeg, isNull);
    },
  );

  test(
    'an export carries the composite link-switch timeline it recorded',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      const bridgeId = 'pi-1';
      const bleDeviceId = 'ble-pi-1';
      const lanDeviceId = '192.168.1.42:8765';
      final latencyDir = Directory('${dir.path}/latency')..createSync();
      final captureDir = Directory('${dir.path}/captures')..createSync();

      // The Bluetooth tab's handoff: the radio's FF16 read names the LAN
      // host, so the composite upgrades the route to TCP without waiting
      // for the upgrade interval.
      final adapter = _EndpointAdapter(bridgeId: bridgeId);
      final ble = UniversalBleTransport(
        adapter: adapter,
        scanTimeout: const Duration(minutes: 5),
      );
      final tcp = _FakeWs(
        FakeTransport(devices: const [FakeDevice(id: lanDeviceId, mtu: 4096)]),
      );
      late CompositeBleTransport composite;
      final container = ProviderContainer(
        overrides: [
          realTransportProvider.overrideWithValue(ble),
          bleHandoffTransportFactoryProvider.overrideWithValue(
            (bleLeg) => composite = CompositeBleTransport(
              tcp: tcp,
              ble: bleLeg,
              upgradeInterval: const Duration(hours: 1),
            ),
          ),
          streamModeProvider.overrideWith(RawModeNotifier.new),
          latencyStoreProvider.overrideWith((ref) => LatencyStore(latencyDir)),
          captureStoreProvider.overrideWith((ref) => CaptureStore(captureDir)),
          bundleDeviceInfoProvider.overrideWithValue(
            () async => const BundleDeviceInfo(
              appVersion: '0.2.2+4',
              phone: 'Test Phone',
              androidVersion: 'Android 14 (API 34)',
            ),
          ),
          deviceEnvironmentProbeProvider.overrideWithValue(
            const _FakeEnvironmentProbe(),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container.read(realDeviceProvider.notifier).connect(bleDeviceId);
      await _waitFor(
        () => composite.activeLegFor(bleDeviceId) == CompositeLeg.tcp,
        reason: 'the FF16 LAN host was not dialled',
      );

      // One record on the leg that now carries the route opens the upgrade
      // episode's first-TCP mark.
      await _waitFor(
        () => tcp.inner.emit(lanDeviceId, wmrBridgeStreamCharUuid, [1]),
        reason: 'the stream was not subscribed on the TCP leg',
      );
      await _waitFor(
        () =>
            composite.linkTimelineFor(bleDeviceId)!['first_tcp_record_us'] !=
            null,
        reason: 'the first TCP record was not marked on the timeline',
      );

      final input = await container.read(testBundleInputProvider)();
      final timeline = input.linkTimeline;
      expect(timeline, composite.linkTimelineFor(bleDeviceId));
      expect(timeline!['upgrade_dial_start_us'], isA<int>());
      expect(timeline['upgrade_dial_end_us'], isA<int>());
      expect(timeline['first_tcp_record_us'], isA<int>());

      final bundle = await writeTestBundle(input, Directory('${dir.path}/out'));
      final archive = ZipDecoder().decodeBytes(
        await File(bundle.path).readAsBytes(),
      );
      final diagnostics = jsonDecode(
        utf8.decode(
          archive.files.firstWhere((f) => f.name == 'diagnostics.json').content,
        ),
      ) as Map<String, Object?>;
      expect(diagnostics['link_timeline'], timeline);
    },
  );

  test(
    'an export carries the BLE subscribe marks the GATT dial recorded',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final latencyDir = Directory('${dir.path}/latency')..createSync();
      final captureDir = Directory('${dir.path}/captures')..createSync();

      // The Bluetooth tab's handoff with no LAN endpoint in the FF16
      // document, so the route stays on the BLE leg and its GATT marks are
      // the link's own story. The default stream mode is FF14.
      final adapter = _FirmwareAdapter();
      final ble = UniversalBleTransport(
        adapter: adapter,
        scanTimeout: const Duration(minutes: 5),
      );
      final tcp = _FakeWs(FakeTransport(devices: const []));
      late CompositeBleTransport composite;
      final container = ProviderContainer(
        overrides: [
          realTransportProvider.overrideWithValue(ble),
          bleHandoffTransportFactoryProvider.overrideWithValue(
            (bleLeg) => composite = CompositeBleTransport(
              tcp: tcp,
              ble: bleLeg,
              upgradeInterval: const Duration(hours: 1),
            ),
          ),
          latencyStoreProvider.overrideWith((ref) => LatencyStore(latencyDir)),
          captureStoreProvider.overrideWith((ref) => CaptureStore(captureDir)),
          bundleDeviceInfoProvider.overrideWithValue(
            () async => const BundleDeviceInfo(
              appVersion: '0.2.2+4',
              phone: 'Test Phone',
              androidVersion: 'Android 14 (API 34)',
            ),
          ),
          deviceEnvironmentProbeProvider.overrideWithValue(
            const _FakeEnvironmentProbe(),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(realDeviceProvider.notifier)
          .connect(fakeBridgeDeviceId);
      await _waitFor(
        () =>
            ble.subscribeTimelineFor(
              fakeBridgeDeviceId,
            )?['ff14_cccd_write_us'] !=
            null,
        reason: 'the FF14 CCCD write was not marked',
      );
      final discovery =
          ble.subscribeTimelineFor(
                fakeBridgeDeviceId,
              )!['service_discovery_done_us']!
              as int;
      adapter.emitNotification(wmrBridgeBatchedCharUuid, [1]);
      await _waitFor(
        () =>
            ble.subscribeTimelineFor(
              fakeBridgeDeviceId,
            )?['first_ff14_notification_us'] !=
            null,
        reason: 'the first FF14 notification was not marked',
      );

      // The route's timeline carries the BLE leg's marks beside its own,
      // keyed as the bundle exports them.
      final timeline = composite.linkTimelineFor(fakeBridgeDeviceId)!;
      final subscribe = timeline['ble_subscribe']! as Map<String, Object?>;
      final connectStart = subscribe['gatt_connect_start_us']! as int;
      final cccd = subscribe['ff14_cccd_write_us']! as int;
      final firstNotification = subscribe['first_ff14_notification_us']! as int;
      // The dial's steps in order: the write follows discovery (the wait
      // between them can be shorter than a microsecond tick) and the
      // first record follows the write across a real gap.
      expect(discovery, greaterThanOrEqualTo(connectStart));
      expect(cccd, greaterThanOrEqualTo(discovery));
      expect(firstNotification, greaterThan(cccd));
      // Nothing died and the radio never moved during the dial.
      expect(subscribe['disconnect_us'], isNull);
      expect(subscribe['radio_off_us'], isNull);
      expect(subscribe['radio_on_us'], isNull);

      final input = await container.read(testBundleInputProvider)();
      expect(input.linkTimeline, timeline);
      final bundle = await writeTestBundle(input, Directory('${dir.path}/out'));
      final archive = ZipDecoder().decodeBytes(
        await File(bundle.path).readAsBytes(),
      );
      final diagnostics = jsonDecode(
        utf8.decode(
          archive.files.firstWhere((f) => f.name == 'diagnostics.json').content,
        ),
      ) as Map<String, Object?>;
      // The bundle carries the marks verbatim under the timeline's
      // `ble_subscribe` entry.
      expect(diagnostics['link_timeline'], timeline);
      final exported =
          (diagnostics['link_timeline']! as Map)['ble_subscribe'] as Map;
      expect(exported['gatt_connect_start_us'], isA<int>());
      expect(exported['ff14_cccd_write_us'], isA<int>());
      expect(exported['first_ff14_notification_us'], isA<int>());
    },
  );

  testWidgets('a published pose run puts every capture in the zip', (
    tester,
  ) async {
    final poseDir = Directory('${dir.path}/pose')..createSync();
    final left = File('${poseDir.path}/pose_capture_viture_left_still.json')
      ..writeAsStringSync(
        '{"format":"wmr-pose-recording","version":1,'
        '"samples":[]}',
      );
    final right =
        File('${poseDir.path}/pose_capture_viture_right_fast_flick.json')
          ..writeAsStringSync(
            '{"format":"wmr-pose-recording","version":1,'
            '"samples":[]}',
          );

    final transport = UniversalBleTransport(
      adapter: adapter,
      scanTimeout: const Duration(minutes: 5),
    );
    final container = ProviderContainer(
      overrides: [
        realTransportProvider.overrideWithValue(transport),
        lanDiscoveryProvider.overrideWithValue(
          () async => const <WmrWsEndpoint>[],
        ),
        launchAutoConnectEnabledProvider.overrideWithValue(false),
        streamModeProvider.overrideWith(RawModeNotifier.new),
        latencyStoreProvider.overrideWith(
          (ref) => LatencyStore(Directory('${dir.path}/latency')),
        ),
        captureStoreProvider.overrideWith(
          (ref) => CaptureStore(Directory('${dir.path}/captures')),
        ),
        bundleOutputDirectoryProvider.overrideWith(
          (ref) async => Directory('${dir.path}/out'),
        ),
        bundleClockProvider.overrideWithValue(
          () => DateTime(2026, 10, 29, 12, 30, 0),
        ),
        bundleDeviceInfoProvider.overrideWithValue(
          () async => const BundleDeviceInfo(
            appVersion: '0.2.2+4',
            phone: 'Galaxy XR',
            androidVersion: 'Android 16 (API 36)',
          ),
        ),
        shareTestBundleProvider.overrideWithValue((path) async {
          shared.add(path);
        }),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
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

    container
        .read(benchBundleProvider.notifier)
        .publish(
          BenchBundleRun([
            const BenchBundleStep(
              id: 'device_summary',
              status: 'done',
              data: {'runtime': 'viture', 'hand_joints': true},
            ),
            BenchBundleStep(
              id: 'pose_capture',
              status: 'done',
              data: {
                'segments': [
                  {
                    'runtime': 'viture',
                    'hand': 'LEFT',
                    'segment': 'still',
                    'status': 'done',
                    'file': left.path,
                    'samples': 30,
                  },
                  {
                    'runtime': 'viture',
                    'hand': 'RIGHT',
                    'segment': 'fast_flick',
                    'status': 'done',
                    'file': right.path,
                    'samples': 30,
                  },
                ],
              },
            ),
            const BenchBundleStep(id: 'export', status: 'done'),
          ], mode: '6dof_only'),
        );

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

    final archive = ZipDecoder().decodeBytes(bytes);
    final names = [for (final file in archive.files) file.name];
    expect(
      names,
      containsAll([
        'pose_capture_viture_left_still.json',
        'pose_capture_viture_right_fast_flick.json',
      ]),
    );

    String text(String name) => utf8.decode(
      archive.files.firstWhere((file) => file.name == name).content,
    );
    final manifest = text('manifest.md');
    expect(manifest, contains('- Bench mode: 6dof_only'));
    expect(manifest, contains('- Tracking runtime: viture'));
    expect(manifest, contains('## 6DoF pose captures'));
    expect(manifest, contains('| pose_capture_viture_left_still.json | LEFT'));
    expect(
      manifest,
      contains('| pose_capture_viture_right_fast_flick.json | RIGHT'),
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    container.dispose();
  });

  test(
    'Carina PGM and telemetry directories are added to the bundle',
    () async {
      final carina = Directory('${dir.path}/carina-led-0p8m')
        ..createSync(recursive: true);
      File('${carina.path}/carina-diagnostics.json')
          .writeAsStringSync('{"schema":"wmr.carina.diagnostics.v1"}');
      File('${carina.path}/carina-rung0-left0-0.1ms.pgm')
          .writeAsStringSync('P5');
      final bundle = await writeTestBundle(
        TestBundleInput(
          now: DateTime(2026, 11, 1, 12),
          appVersion: '0.3.8+13',
          phone: 'test',
          androidVersion: 'Android 14',
          streamMode: 'raw',
          benchRun: BenchBundleRun([
            BenchBundleStep(
              id: 'carina_leds',
              status: 'done',
              data: {
                'directories': [carina.path],
              },
            ),
          ]),
        ),
        Directory('${dir.path}/out'),
      );
      expect(bundle.present.join('\n'), contains('Carina captures'));
      final archive = ZipDecoder().decodeBytes(
        await File(bundle.path).readAsBytes(),
      );
      final names = [for (final file in archive.files) file.name];
      expect(
        names,
        containsAll([
          'carina/carina-led-0p8m/carina-diagnostics.json',
          'carina/carina-led-0p8m/carina-rung0-left0-0.1ms.pgm',
        ]),
      );
    },
  );
}
