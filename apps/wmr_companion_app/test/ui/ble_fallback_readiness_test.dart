import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_ble/testing.dart';
import 'package:wmr_ble/wmr_ble.dart';
import 'package:wmr_companion/wmr_companion.dart'
    show CompositeBleTransport, CompositeLeg;
import 'package:wmr_companion_app/services/bridge_token_store.dart';
import 'package:wmr_companion_app/services/known_bridge_store.dart';
import 'package:wmr_companion_app/services/test_bundle.dart';
import 'package:wmr_companion_app/services/test_bundle_export.dart';
import 'package:wmr_companion_app/ui/capture/capture_providers.dart';
import 'package:wmr_companion_app/ui/connect/connect_providers.dart';
import 'package:wmr_companion_app/ui/connect/connect_screen.dart';
import 'package:wmr_companion_app/ui/debug/stream_settings.dart';
import 'package:wmr_companion_app/ui/latency/latency_providers.dart';
import 'package:wmr_core/ble/ble_transport.dart';
import 'package:wmr_core/protocol/gatt.dart';
import 'package:wmr_core/services/capture_files.dart';
import 'package:wmr_core/services/latency_files.dart';
import 'package:wmr_ws/wmr_ws.dart';

import 'raw_mode_notifier.dart';

Future<void> _pump([int millis = 20]) =>
    Future<void>.delayed(Duration(milliseconds: millis));

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

void _pauseApp() {
  for (final state in const [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
  ]) {
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(state);
  }
}

void _resumeApp() {
  for (final state in const [
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]) {
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(state);
  }
}

class _MemoryKnownBridgeStore implements KnownBridgeStore {
  KnownBridge? saved;

  @override
  Future<KnownBridge?> load() async => saved;

  @override
  Future<void> save(KnownBridge bridge) async {
    saved = bridge;
  }

  @override
  Future<void> clear() async {
    saved = null;
  }
}

class _MemoryBridgeTokenStore implements BridgeTokenStore {
  final Map<String, String> byBridgeId = {};
  final Map<String, String> byHost = {};

  @override
  Future<String?> load({String? bridgeId, String? host}) async {
    if (bridgeId != null && byBridgeId.containsKey(bridgeId)) {
      return byBridgeId[bridgeId];
    }
    if (host != null && byHost.containsKey(host)) {
      return byHost[host];
    }
    return null;
  }

  @override
  Future<void> save({
    String? bridgeId,
    Iterable<String> hosts = const [],
    required String token,
  }) async {
    if (bridgeId != null && bridgeId.isNotEmpty) {
      byBridgeId[bridgeId] = token;
    }
    for (final h in hosts) {
      byHost[h] = token;
    }
  }

  @override
  Future<void> clear({
    String? bridgeId,
    String? host,
    Iterable<String> hosts = const [],
  }) async {
    byBridgeId.clear();
    byHost.clear();
  }
}

class _ScriptedWsTransport extends WmrWsTransport {
  _ScriptedWsTransport({
    required this.bridgeId,
    required WmrWsEndpoint endpoint,
  }) : super(endpoints: [endpoint]);

  final String bridgeId;
  bool failConnect = false;
  final Map<String, WmrWsHello> _hellos = {};
  final Map<String, BleConnectionState> _states = {};
  final Map<String, StreamController<BleConnectionState>> _stateCtls = {};
  final Map<String, StreamController<BleNotification>> _streams = {};

  @override
  WmrWsHello? helloFor(String deviceId) => _hellos[deviceId];

  @override
  Stream<BleScanResult> scan({List<String> withServices = const []}) =>
      const Stream.empty();

  @override
  Future<void> stopScan() async {}

  @override
  Future<void> connect(String deviceId) async {
    if (failConnect) throw StateError('TCP unreachable');
    _hellos[deviceId] = WmrWsHello(
      protocol: 1,
      transport: 'tcp',
      device: deviceId,
      version: '0.3.27',
      hostname: 'wmrpi',
      bridgeId: bridgeId,
      authRequired: false,
      streams: const {'raw', 'decoded', 'batched'},
      recordSize: 56,
      batchMax: 9,
      fragmentCapacity: 46,
    );
    _setState(deviceId, BleConnectionState.connected);
  }

  @override
  Future<void> disconnect(String deviceId) async {
    _setState(deviceId, BleConnectionState.disconnected);
  }

  void drop(String deviceId) {
    _setState(deviceId, BleConnectionState.disconnected);
  }

  void _setState(String deviceId, BleConnectionState state) {
    _states[deviceId] = state;
    _stateCtls[deviceId]?.add(state);
  }

  @override
  Stream<BleConnectionState> connectionState(String deviceId) async* {
    yield _states[deviceId] ?? BleConnectionState.disconnected;
    yield* _stateCtls
        .putIfAbsent(deviceId, StreamController<BleConnectionState>.broadcast)
        .stream;
  }

  @override
  Future<List<BleServiceInfo>> discoverServices(String deviceId) async =>
      const [
        BleServiceInfo(
          uuid: wmrBridgeServiceUuid,
          characteristicUuids: [
            wmrBridgeStreamCharUuid,
            wmrBridgeDecodedCharUuid,
            wmrBridgeBatchedCharUuid,
            wmrBridgeVersionCharUuid,
          ],
        ),
      ];

  @override
  Stream<BleNotification> subscribe(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
  ) => _streams
      .putIfAbsent(
        '$deviceId|${characteristicUuid.toLowerCase()}',
        StreamController<BleNotification>.broadcast,
      )
      .stream;

  @override
  Future<void> unsubscribe(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
  ) async {}

  @override
  Future<Uint8List> read(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
  ) async => Uint8List(0);

  @override
  Future<void> write(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
    Uint8List value, {
    bool withoutResponse = false,
  }) async {}

  @override
  Future<BleConnectionInfo> connectionInfo(String deviceId) async =>
      const BleConnectionInfo(mtu: 517);

  @override
  Future<void> dispose() async {
    for (final c in _stateCtls.values) {
      await c.close();
    }
    for (final c in _streams.values) {
      await c.close();
    }
    await super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const bridgeId = '1122334455667788';
  const bleDeviceId = 'ble-pi-1';

  Uint8List endpointDoc() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'type': 'wmr_ble_endpoint',
        'protocol': 1,
        'bridge_id': bridgeId,
        'name': 'WMR Bridge',
        'version': '0.3.27',
        'hosts': ['192.168.1.50'],
        'port': 8765,
        'path': '/wmr',
        'authRequired': false,
      }),
    ),
  );

  ProviderContainer makeContainer({
    required FakeBleAdapter adapter,
    required _ScriptedWsTransport Function(WmrWsEndpoint) wsBuilder,
    _MemoryKnownBridgeStore? knownBridgeStore,
    _MemoryBridgeTokenStore? tokenStore,
    DateTime Function()? scanClock,
    Duration scanTimeout = const Duration(seconds: 15),
    Duration scanBackoff = const Duration(milliseconds: 20),
    Duration bleScanWait = const Duration(milliseconds: 300),
  }) {
    final ble = UniversalBleTransport(
      adapter: adapter,
      scanTimeout: scanTimeout,
    );
    final tmpRoot = Directory.systemTemp.createTempSync('wmr_ble_fallback_');
    return ProviderContainer(
      overrides: [
        realTransportProvider.overrideWithValue(ble),
        knownBridgeStoreProvider.overrideWithValue(
          knownBridgeStore ?? _MemoryKnownBridgeStore(),
        ),
        bridgeTokenStoreProvider.overrideWithValue(
          tokenStore ?? _MemoryBridgeTokenStore(),
        ),
        latencyStoreProvider.overrideWith((_) => LatencyStore(tmpRoot)),
        captureStoreProvider.overrideWith((_) => CaptureStore(tmpRoot)),
        bundleDeviceInfoProvider.overrideWithValue(
          () async => const BundleDeviceInfo(
            appVersion: '0.3.28+1',
            phone: 'Test Phone',
            androidVersion: 'Android 15',
          ),
        ),
        lanInterfaceProbeProvider.overrideWithValue(() async => true),
        launchAutoConnectEnabledProvider.overrideWithValue(false),
        streamModeProvider.overrideWith(RawModeNotifier.new),
        if (scanClock != null)
          proactiveScanClockProvider.overrideWithValue(scanClock),
        proactiveScanBackoffProvider.overrideWithValue(scanBackoff),
        compositeWifiTransportFactoryProvider.overrideWithValue((endpoint) {
          final tcp = wsBuilder(endpoint);
          final composite = CompositeBleTransport(
            tcp: tcp,
            ble: ble,
            lanAvailable: () async => true,
            disposeBle: false,
            upgradeInterval: const Duration(milliseconds: 30),
            bleScanWait: bleScanWait,
          );
          return WifiLink(
            composite,
            activeLeg: () =>
                switch (composite.activeLegFor(endpoint.resolvedDeviceId)) {
                  CompositeLeg.tcp => WifiLinkLeg.tcp,
                  CompositeLeg.ble => WifiLinkLeg.ble,
                  null => null,
                },
          );
        }),
      ],
    );
  }

  test('manual-IP connectWifi(bleFallback: true) requests missing permissions, learns hello bridgeId, reaches ready, and stops scanning', () async {
    final adapter = FakeBleAdapter()
      ..permissionsGranted = false
      ..grantOnRequest = true
      ..readValues[wmrBridgeVersionCharUuid] = endpointDoc();
    final knownStore = _MemoryKnownBridgeStore();
    final tokenStore = _MemoryBridgeTokenStore();

    final container = makeContainer(
      adapter: adapter,
      knownBridgeStore: knownStore,
      tokenStore: tokenStore,
      wsBuilder: (ep) => _ScriptedWsTransport(bridgeId: bridgeId, endpoint: ep),
    );
    addTearDown(container.dispose);

    final ctrl = container.read(realDeviceProvider.notifier);
    await ctrl.connectWifi(
      host: '192.168.1.50',
      port: 8765,
      token: 'secret-tok',
      rememberToken: true,
      bleFallback: true,
    );

    expect(adapter.calls, contains('requestPermissions'));
    expect(container.read(realDeviceProvider).connected, isTrue);
    expect(knownStore.saved?.bridgeId, bridgeId);
    expect(tokenStore.byBridgeId[bridgeId], 'secret-tok');

    // Emit a matching WMB1 advertisement -> transitions to ready and stops scan.
    adapter.emitScanResult(
      BleScanResult(
        deviceId: bleDeviceId,
        name: 'WMR Bridge',
        rssi: -42,
        serviceUuids: const [wmrBridgeServiceUuid],
        serviceData: {
          wmrBridgeServiceUuid: Uint8List.fromList(
            utf8.encode('WMB1${bridgeId.substring(0, 8)}'),
          ),
        },
      ),
    );

    await _waitFor(
      () =>
          container.read(realDeviceProvider).bleFallbackState ==
          BleFallbackState.ready,
      reason: 'expected bleFallbackState == ready after matching WMB1 hit',
    );
    final s = container.read(realDeviceProvider);
    expect(s.bleFallbackCandidateCount, 1);
    expect(s.bleFallbackReason, isNull);
    await _waitFor(() => adapter.calls.contains('stopScan'));
  });

  test('permissionDenied, bluetoothOff, and bluetoothUnavailable keep TCP usable, surface in state and diagnostics.json, and recover on resume/poweredOn without looping prompts', () async {
    final adapter = FakeBleAdapter()
      ..permissionsGranted = false
      ..grantOnRequest = false;
    final container = makeContainer(
      adapter: adapter,
      wsBuilder: (ep) => _ScriptedWsTransport(bridgeId: bridgeId, endpoint: ep),
    );
    addTearDown(container.dispose);

    final ctrl = container.read(realDeviceProvider.notifier);
    await ctrl.connectWifi(host: '192.168.1.50', port: 8765, bleFallback: true);

    await _waitFor(
      () =>
          container.read(realDeviceProvider).bleFallbackState ==
          BleFallbackState.permissionDenied,
      reason: 'expected initial permissionDenied',
    );
    expect(container.read(realDeviceProvider).connected, isTrue);
    expect(container.read(realDeviceProvider).wifiLeg, WifiLinkLeg.tcp);

    // Export diagnostics.json and verify additive snake_case keys.
    final input = await container.read(testBundleInputProvider)();
    expect(input.bleFallbackState, 'permission_denied');
    expect(input.bleFallbackCandidateCount, 0);
    expect(input.bleFallbackReason, isNotNull);

    final tmpDir = await Directory.systemTemp.createTemp('wmr_bundle_test_');
    addTearDown(() => tmpDir.delete(recursive: true));
    final bundle = await writeTestBundle(input, tmpDir);
    expect(bundle.fileName, startsWith('wmr-ext-'));

    // AppLifecycleState.resumed while still denied: must NOT re-prompt!
    final requestsBefore = adapter.calls
        .where((c) => c == 'requestPermissions')
        .length;
    _pauseApp();
    _resumeApp();
    await _pump(40);
    expect(
      adapter.calls.where((c) => c == 'requestPermissions').length,
      requestsBefore,
    );
    expect(
      container.read(realDeviceProvider).bleFallbackState,
      BleFallbackState.permissionDenied,
    );

    // Now user grants permission in Settings and returns to app, but BT is off.
    adapter.permissionsGranted = true;
    adapter.availabilityState = BleAvailability.poweredOff;
    _pauseApp();
    _resumeApp();
    await _waitFor(
      () =>
          container.read(realDeviceProvider).bleFallbackState ==
          BleFallbackState.bluetoothOff,
      reason: 'expected bluetoothOff after resume with granted permissions',
    );
    expect(container.read(realDeviceProvider).connected, isTrue);

    // Radio turns poweredOn -> re-arms fallback scan!
    adapter.emitAvailability(BleAvailability.poweredOn);
    await _waitFor(
      () =>
          container.read(realDeviceProvider).bleFallbackState ==
          BleFallbackState.scanning,
      reason: 'expected scanning after poweredOn',
    );
    expect(container.read(realDeviceProvider).connected, isTrue);

    // bluetoothUnavailable surfaces cleanly too.
    adapter.availabilityState = BleAvailability.unsupported;
    await ctrl.retryBleFallback();
    await _waitFor(
      () =>
          container.read(realDeviceProvider).bleFallbackState ==
          BleFallbackState.bluetoothUnavailable,
      reason: 'expected bluetoothUnavailable after retry with unsupported',
    );
    expect(container.read(realDeviceProvider).connected, isTrue);
  });

  test('unverified hit keeps scanning and surfaces candidateUnverified until WMB1 verifies', () async {
    final adapter = FakeBleAdapter()
      ..systemDeviceResults = const [
        BleScanResult(deviceId: 'pi-bonded', name: 'wmrpi', rssi: null),
      ];
    final container = makeContainer(
      adapter: adapter,
      wsBuilder: (ep) => _ScriptedWsTransport(bridgeId: bridgeId, endpoint: ep),
    );
    addTearDown(container.dispose);

    final ctrl = container.read(realDeviceProvider.notifier);
    await ctrl.connectWifi(host: '192.168.1.50', port: 8765, bleFallback: true);

    await _waitFor(
      () =>
          container.read(realDeviceProvider).bleFallbackState ==
          BleFallbackState.candidateUnverified,
    );
    expect(container.read(realDeviceProvider).bleFallbackCandidateCount, 1);
    // Scan was NOT stopped on the unverified hit alone.
    expect(adapter.calls.where((c) => c == 'stopScan'), isEmpty);

    // Now a matching WMB1 advertisement arrives -> becomes ready & stops scan.
    adapter.emitScanResult(
      BleScanResult(
        deviceId: 'pi-bonded',
        name: 'wmrpi',
        rssi: -40,
        serviceUuids: const [wmrBridgeServiceUuid],
        serviceData: {
          wmrBridgeServiceUuid: Uint8List.fromList(
            utf8.encode('WMB1${bridgeId.substring(0, 8)}'),
          ),
        },
      ),
    );
    await _waitFor(
      () =>
          container.read(realDeviceProvider).bleFallbackState ==
          BleFallbackState.ready,
    );
    await _waitFor(() => adapter.calls.contains('stopScan'));
  });

  test('rolling 30 s cap limits proactive startScan calls to <= 3 per window, reserving SafeScanner headroom', () async {
    var now = DateTime.utc(2026, 11, 24, 12, 0, 0);
    final adapter = FakeBleAdapter();
    final container = makeContainer(
      adapter: adapter,
      scanClock: () => now,
      scanTimeout: const Duration(milliseconds: 25),
      scanBackoff: const Duration(milliseconds: 15),
      wsBuilder: (ep) => _ScriptedWsTransport(bridgeId: bridgeId, endpoint: ep),
    );
    addTearDown(container.dispose);

    final ctrl = container.read(realDeviceProvider.notifier);
    await ctrl.connectWifi(host: '192.168.1.50', port: 8765, bleFallback: true);

    // Wait for 3 scanTimeout cycles within the same 30 s window.
    await _waitFor(
      () => adapter.calls.where((c) => c.startsWith('startScan')).length >= 3,
    );
    await _pump(100);
    expect(
      adapter.calls.where((c) => c.startsWith('startScan')).length,
      3,
      reason: 'proactive scans must be capped at 3 per 30 s window',
    );
    expect(
      container.read(realDeviceProvider).bleFallbackState,
      BleFallbackState.noCandidate,
    );
  });

  testWidgets('ConnectScreen surfaces BLE fallback status and Retry button', (
    tester,
  ) async {
    final adapter = FakeBleAdapter()
      ..permissionsGranted = false
      ..grantOnRequest = false;
    final container = makeContainer(
      adapter: adapter,
      wsBuilder: (ep) => _ScriptedWsTransport(bridgeId: bridgeId, endpoint: ep),
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: ConnectScreen()),
      ),
    );

    final ctrl = container.read(realDeviceProvider.notifier);
    unawaited(
      ctrl.connectWifi(host: '192.168.1.50', port: 8765, bleFallback: true),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(
      container.read(realDeviceProvider).bleFallbackState,
      BleFallbackState.permissionDenied,
    );
    expect(find.byKey(const Key('wifi-ble-fallback-status')), findsWidgets);
    expect(find.textContaining('Permission denied'), findsWidgets);
    expect(find.byKey(const Key('wifi-ble-fallback-retry')), findsWidgets);

    unawaited(ctrl.disconnect());
    await tester.pump();
    container.dispose();
    await tester.pump();
  });
}
