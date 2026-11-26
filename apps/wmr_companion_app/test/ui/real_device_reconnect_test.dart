import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_companion_app/hid/hid_output.dart';
import 'package:wmr_companion_app/services/bridge_token_store.dart';
import 'package:wmr_companion_app/services/known_bridge_store.dart';
import 'package:wmr_companion_app/ui/connect/connect_providers.dart';
import 'package:wmr_companion_app/ui/debug/debug_providers.dart';
import 'package:wmr_companion_app/ui/debug/stream_settings.dart';
import 'package:wmr_companion_hid_android/wmr_companion_hid_android.dart';
import 'package:wmr_core/ble/fake_transport.dart';
import 'package:wmr_core/ble/fake_wmr_bridge.dart';
import 'package:wmr_core/protocol/decoded_batch.dart';
import 'package:wmr_core/protocol/decoded_record.dart';
import 'package:wmr_core/protocol/gatt.dart';
import 'package:wmr_core/protocol/wmr_fragment.dart';
import 'package:wmr_ws/wmr_ws.dart';

import 'package:wmr_ble/wmr_ble.dart';
import 'package:wmr_ble/testing.dart';
import 'package:wmr_companion/wmr_companion.dart';
import 'package:wmr_core/ble/ble_transport.dart';

import '../hid/fake_hid.dart';
import '../services/memory_secure_token_backend.dart';
import 'memory_known_bridge_store.dart';

class _DroppableWifiTransport extends FakeTransport {
  _DroppableWifiTransport({required super.devices});

  int connectCalls = 0;
  int failNextConnects = 0;
  Object? connectError;

  @override
  Future<void> connect(String deviceId) async {
    connectCalls++;
    final error = connectError;
    if (failNextConnects > 0 && error != null) {
      failNextConnects--;
      throw error;
    }
    await super.connect(deviceId);
  }
}

/// Counts transport preflights: every dial reads the radio's availability
/// before it touches the stack, so a read that arrives while the radio is
/// off is a dial against a dead stack.
class _CountingAdapter extends FakeBleAdapter {
  int availabilityReads = 0;

  @override
  Future<BleAvailability> availability() async {
    availabilityReads++;
    return super.availability();
  }
}

/// A TCP leg that refuses every dial, so a composite built on it falls back
/// to its BLE leg and stays there.
class _RefusedTcp extends WmrWsTransport {
  _RefusedTcp(WmrWsEndpoint endpoint) : super(endpoints: [endpoint]);

  @override
  Future<void> connect(String deviceId) async =>
      throw StateError('tcp refused');
}

/// A [WmrWsTransport] over a [FakeTransport] that can drop and refuse TCP
/// on demand so a test can hold a TCP->BLE failover open without sockets.
class _SwitchableTcp extends WmrWsTransport {
  _SwitchableTcp(this.inner, {WmrWsEndpoint? endpoint})
    : super(endpoints: const []) {
    if (endpoint != null) registerEndpoint(endpoint);
  }

  final FakeTransport inner;
  bool failConnect = false;
  final Map<String, WmrWsEndpoint> endpoints = {};
  final Map<String, WmrWsHello> hellos = {};

  @override
  Stream<BleScanResult> scan({List<String> withServices = const []}) =>
      inner.scan(withServices: withServices);

  @override
  Future<void> stopScan() => inner.stopScan();

  @override
  Future<void> connect(String deviceId) {
    if (failConnect) return Future.error(StateError('tcp down'));
    return inner.connect(deviceId);
  }

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

class _EndpointAdapter extends _CountingAdapter {
  _EndpointAdapter({required this.bridgeId, required this.hosts});

  final String bridgeId;
  final List<String> hosts;

  @override
  Future<Uint8List> read(
    String deviceId,
    String serviceUuid,
    String characteristicUuid, {
    Duration? timeout,
  }) async {
    if (characteristicUuid.toLowerCase() == wmrBridgeVersionCharUuid) {
      return Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'type': 'wmr_ble_endpoint',
            'protocol': 1,
            'bridge_id': bridgeId,
            'name': 'WMR Bridge',
            'version': '0.2.4',
            'hosts': hosts,
            'port': 8765,
            'path': '/wmr',
            'authRequired': false,
          }),
        ),
      );
    }
    return super.read(
      deviceId,
      serviceUuid,
      characteristicUuid,
      timeout: timeout,
    );
  }
}

class TestModeNotifier extends StreamModeNotifier {
  TestModeNotifier(this.mode);

  final StreamMode mode;

  @override
  StreamMode build() => mode;
}

/// Drives the app's real-device controller over the fake adapter. These are
/// regression tests for the facade hand-over: after an automatic reconnect
/// both the published counters and the in-session stick centre must come from
/// the new service, not from the one that was disposed. The HID tests cover
/// the other half of a reconnect: forwarding must re-point at the new service
/// by itself, two bridges must survive one link dropping, and an explicit
/// disconnect must still stop HID and stop re-dialling.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeBleAdapter adapter;
  late UniversalBleTransport transport;

  setUp(() {
    adapter = FakeBleAdapter();
    transport = UniversalBleTransport(
      adapter: adapter,
      scanTimeout: const Duration(minutes: 5),
    );
    addTearDown(transport.dispose);
  });

  ProviderContainer makeContainer({
    StreamMode mode = StreamMode.raw,
    FakeHid? hid,
    ReconnectPolicy policy = const ReconnectPolicy(),
  }) {
    final container = ProviderContainer(
      overrides: [
        realTransportProvider.overrideWithValue(transport),
        streamModeProvider.overrideWith(() => TestModeNotifier(mode)),
        reconnectPolicyProvider.overrideWithValue(policy),
        if (hid != null) hidTransportProvider.overrideWithValue(hid),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  void sendFrames(int from, int count) {
    for (var i = 0; i < count; i++) {
      final fragments = encodeFrame(
        syntheticFrame(0, from + i),
        notificationCapacity(185),
      );
      for (final fragment in fragments) {
        adapter.emitNotification(wmrBridgeStreamCharUuid, fragment);
      }
    }
  }

  DecodedRecord decoded(
    int seq, {
    int hand = 1,
    int trigger = 0,
    int buttons = 0,
  }) => DecodedRecord(
    hand: hand,
    sequence: seq,
    rxTimeUs: seq * 5000,
    deviceTicks: seq * 50000,
    gyro: const [0, 0, 0],
    accel: const [0, 0, 9.8],
    buttons: buttons,
    trigger: trigger,
  );

  void feed(DecodedRecord record, {String deviceId = fakeBridgeDeviceId}) =>
      adapter.emitNotification(
        wmrBridgeDecodedCharUuid,
        encodeDecodedRecord(record),
        deviceId: deviceId,
      );

  Future<void> wait([int millis = 300]) =>
      Future<void>.delayed(Duration(milliseconds: millis));

  Future<void> pump() => Future<void>.delayed(Duration.zero);

  void setAppLifecycle(AppLifecycleState state) {
    // The test binding forwards this to every AppLifecycleListener.
    // ignore: invalid_use_of_protected_member
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(state);
  }

  // The listener asserts on illegal transitions, so walk the real sequence.
  void backgroundApp() {
    for (final state in const [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      setAppLifecycle(state);
    }
  }

  void resumeApp() {
    for (final state in const [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      setAppLifecycle(state);
    }
  }

  test('published stats follow the service created by a reconnect', () async {
    final container = makeContainer();
    final controller = container.read(realDeviceProvider.notifier);
    await controller.connect(fakeBridgeDeviceId);
    expect(container.read(realDeviceProvider).connected, isTrue);

    sendFrames(0, 2);
    await wait();
    expect(container.read(realDeviceProvider).stats?.hands[0].frames, 2);

    adapter.dropLink();
    await wait(800);
    expect(container.read(realDeviceProvider).connected, isTrue);

    sendFrames(0, 5);
    await wait();
    expect(container.read(realDeviceProvider).stats?.hands[0].frames, 5);
  });

  test('a stick centre set after connect survives a reconnect', () async {
    final container = makeContainer();
    final controller = container.read(realDeviceProvider.notifier);
    await controller.connect(fakeBridgeDeviceId);
    expect(container.read(realDeviceProvider).connected, isTrue);

    container.read(stickSettingsProvider.notifier).setCentre(0, 0.2, 0.1);
    await wait();

    adapter.dropLink();
    await wait(800);
    expect(container.read(realDeviceProvider).connected, isTrue);

    expect(controller.service!.decodedStats.hands[0].stickCentre, [0.2, 0.1]);
  });

  test('HID forwarding follows the service created by a reconnect', () async {
    final hid = FakeHid();
    final container = makeContainer(mode: StreamMode.decoded, hid: hid);
    final controller = container.read(realDeviceProvider.notifier);
    await controller.connect(fakeBridgeDeviceId);

    final out = container.read(hidOutputProvider.notifier);
    await out.start(DebugSource.real);
    hid.emit(const HidStatus(HidState.connected, deviceName: 'PC'));
    await pump();
    feed(decoded(1, trigger: 200));
    await pump();
    final held = hid.reports.last[8];
    expect(held, greaterThan(0));

    adapter.dropLink();
    await wait(100); // still inside the 500 ms reconnect delay
    // The host is still connected, so the pad must go neutral instead of
    // holding the last state from the bridge that vanished.
    expect(hid.reports.last[0], 0); // buttons
    expect(hid.reports.last[1], 0);
    expect(hid.reports.last[7], 0); // LEFT trigger
    expect(hid.reports.last[8], 0); // RIGHT trigger
    await wait(700);
    expect(container.read(realDeviceProvider).connected, isTrue);
    expect(container.read(hidOutputProvider).running, isTrue);

    // Before the fix this sample reached the new service only, while the HID
    // subscription still pointed at the disposed one: no report was sent.
    feed(decoded(2, trigger: 60));
    await wait(50);
    expect(hid.reports.last[8], greaterThan(0));
    expect(hid.reports.last[8], isNot(held));
    expect(container.read(hidOutputProvider).reportsSent, greaterThan(0));
  });

  test('the production re-dial schedule is bounded as documented', () {
    const policy = ReconnectPolicy();
    expect(policy.maxAttempts, 6);
    expect(
      [
        for (var attempt = 0; attempt < policy.maxAttempts; attempt++)
          policy.delayFor(attempt).inMilliseconds,
      ],
      [500, 1000, 2000, 4000, 8000, 8000],
    );
  });

  test('a failed automatic re-dial is retried with backoff', () async {
    final container = makeContainer();
    final controller = container.read(realDeviceProvider.notifier);
    await controller.connect(fakeBridgeDeviceId);
    expect(container.read(realDeviceProvider).connected, isTrue);

    final connectsBefore = adapter.calls.where((c) => c == 'connect').length;
    // The first automatic attempt fails; the next one, one second later,
    // succeeds. Before the fix the bridge stayed un-dialled for good.
    adapter.connectFailureCount = 1;
    adapter.dropLink();
    await wait(2200);

    expect(container.read(realDeviceProvider).connected, isTrue);
    expect(
      adapter.calls.where((c) => c == 'connect').length,
      connectsBefore + 2,
    );
  });

  test('automatic re-dial stops at the attempt cap', () async {
    const policy = ReconnectPolicy(
      baseDelay: Duration(milliseconds: 5),
      maxDelay: Duration(milliseconds: 10),
      maxAttempts: 3,
    );
    final container = makeContainer(policy: policy);
    final controller = container.read(realDeviceProvider.notifier);
    await controller.connect(fakeBridgeDeviceId);
    final connectsBefore = adapter.calls.where((c) => c == 'connect').length;

    // Every attempt fails: the loop must stop after maxAttempts rather than
    // re-dialling forever.
    adapter.connectError = Exception('radio unavailable');
    adapter.dropLink();
    await wait(600);
    final attempts = adapter.calls.where((c) => c == 'connect').length;
    expect(attempts, connectsBefore + policy.maxAttempts);

    await wait(300);
    expect(adapter.calls.where((c) => c == 'connect').length, attempts);
    expect(container.read(realDeviceProvider).connected, isFalse);
  });

  test('with two bridges, one drop releases that hand only', () async {
    final hid = FakeHid();
    final container = makeContainer(mode: StreamMode.decoded, hid: hid);
    final controller = container.read(realDeviceProvider.notifier);
    await controller.connect(fakeBridgeLeftDeviceId);
    await controller.connect(fakeBridgeRightDeviceId);
    expect(
      container.read(realDeviceProvider).connectedDeviceIds,
      containsAll([fakeBridgeLeftDeviceId, fakeBridgeRightDeviceId]),
    );

    final out = container.read(hidOutputProvider.notifier);
    await out.start(DebugSource.real);
    hid.emit(const HidStatus(HidState.connected, deviceName: 'PC'));
    await pump();
    feed(decoded(1, hand: 0, trigger: 200), deviceId: fakeBridgeLeftDeviceId);
    feed(decoded(1, hand: 1, trigger: 200), deviceId: fakeBridgeRightDeviceId);
    await pump();
    final heldLeft = hid.reports.last[7]; // LEFT trigger
    final heldRight = hid.reports.last[8]; // RIGHT trigger
    expect(heldLeft, greaterThan(0));
    expect(heldRight, greaterThan(0));

    adapter.dropLink(deviceId: fakeBridgeRightDeviceId);
    await wait(100); // still inside the 500 ms reconnect delay
    expect(container.read(hidOutputProvider).running, isTrue);
    expect(hid.reports.last[7], heldLeft); // the remaining hand keeps going
    expect(hid.reports.last[8], 0); // the missing hand is released

    feed(decoded(2, hand: 0, trigger: 240), deviceId: fakeBridgeLeftDeviceId);
    await wait(20);
    expect(hid.reports.last[7], greaterThan(heldLeft));
    expect(hid.reports.last[8], 0);

    await wait(800);
    expect(
      container
          .read(realDeviceProvider)
          .isDeviceConnected(fakeBridgeRightDeviceId),
      isTrue,
    );
    feed(decoded(2, hand: 1, trigger: 60), deviceId: fakeBridgeRightDeviceId);
    await wait(50);
    expect(hid.reports.last[7], greaterThan(heldLeft));
    expect(hid.reports.last[8], greaterThan(0));
  });

  test('a bridge drop keeps the surviving hand trigger hysteresis', () async {
    final hid = FakeHid();
    final container = makeContainer(mode: StreamMode.decoded, hid: hid);
    final controller = container.read(realDeviceProvider.notifier);
    await controller.connect(fakeBridgeLeftDeviceId);
    await controller.connect(fakeBridgeRightDeviceId);

    final out = container.read(hidOutputProvider.notifier);
    await out.start(DebugSource.real);
    hid.emit(const HidStatus(HidState.connected, deviceName: 'PC'));
    await pump();
    // LEFT trigger crosses the 0.55 press point, then sits in the hysteresis
    // band. Both bridges must have fed a hand so removing one is observable.
    feed(decoded(1, hand: 0, trigger: 153), deviceId: fakeBridgeLeftDeviceId);
    feed(decoded(1, hand: 1, trigger: 100), deviceId: fakeBridgeRightDeviceId);
    await pump();
    feed(decoded(2, hand: 0, trigger: 128), deviceId: fakeBridgeLeftDeviceId);
    await pump();
    const l2 = 1 << 0;
    expect(hid.reports.last[1] & l2, isNot(0));

    adapter.dropLink(deviceId: fakeBridgeRightDeviceId);
    await wait(100);
    // Before the fix this cleared the global previous state, so the surviving
    // hand was judged from released and L2 flickered off in the band.
    expect(hid.reports.last[1] & l2, isNot(0));

    feed(decoded(3, hand: 0, trigger: 128), deviceId: fakeBridgeLeftDeviceId);
    await pump();
    expect(hid.reports.last[1] & l2, isNot(0));
  });

  test('an intentional disconnect does not re-dial and stops HID', () async {
    final hid = FakeHid();
    final container = makeContainer(mode: StreamMode.decoded, hid: hid);
    final controller = container.read(realDeviceProvider.notifier);
    await controller.connect(fakeBridgeDeviceId);

    final out = container.read(hidOutputProvider.notifier);
    await out.start(DebugSource.real);
    hid.emit(const HidStatus(HidState.connected, deviceName: 'PC'));
    await pump();

    final connectsBefore = adapter.calls.where((c) => c == 'connect').length;
    await controller.disconnect();
    await wait(1200);

    expect(container.read(realDeviceProvider).connected, isFalse);
    expect(controller.service, isNull);
    expect(adapter.calls.where((c) => c == 'connect').length, connectsBefore);
    expect(container.read(hidOutputProvider).running, isFalse);
    expect(hid.calls, contains('stop'));
  });

  test('a failed automatic Wi-Fi re-dial is retried with backoff', () async {
    final wifi = _DroppableWifiTransport(
      devices: const [FakeDevice(id: 'pi.local:8765', mtu: 4096)],
    );
    addTearDown(wifi.dispose);
    const policy = ReconnectPolicy(
      baseDelay: Duration(milliseconds: 20),
      maxDelay: Duration(milliseconds: 40),
      maxAttempts: 3,
    );
    final container = ProviderContainer(
      overrides: [
        realTransportProvider.overrideWithValue(transport),
        wifiTransportFactoryProvider.overrideWithValue((_) => wifi),
        streamModeProvider.overrideWith(() => TestModeNotifier(StreamMode.raw)),
        reconnectPolicyProvider.overrideWithValue(policy),
      ],
    );
    addTearDown(container.dispose);

    final controller = container.read(realDeviceProvider.notifier);
    await controller.connectWifi(
      host: 'pi.local',
      port: 8765,
      bleFallback: false,
    );
    expect(container.read(realDeviceProvider).connected, isTrue);

    final connectsBefore = wifi.connectCalls;
    wifi.connectError = WmrWsException('daemon restarting');
    wifi.failNextConnects = 1;
    await wifi.disconnect('pi.local:8765');
    for (
      var elapsed = 0;
      elapsed < 1000 &&
          (wifi.connectCalls < connectsBefore + 2 ||
              !container.read(realDeviceProvider).connected);
      elapsed += 20
    ) {
      await wait(20);
    }

    expect(container.read(realDeviceProvider).connected, isTrue);
    expect(wifi.connectCalls, greaterThanOrEqualTo(connectsBefore + 2));
  });

  test(
    'resuming after the retry cap reconnects to the dropped bridge',
    () async {
      const policy = ReconnectPolicy(
        baseDelay: Duration(milliseconds: 5),
        maxDelay: Duration(milliseconds: 10),
        maxAttempts: 3,
      );
      final container = makeContainer(policy: policy);
      final controller = container.read(realDeviceProvider.notifier);
      await controller.connect(fakeBridgeDeviceId);
      final connectsBefore = adapter.calls.where((c) => c == 'connect').length;

      // The link drops while the app is in the background: every retry fails
      // and the campaign exhausts its attempts.
      adapter.connectError = Exception('radio unavailable');
      adapter.dropLink();
      await wait(500);
      final exhausted = adapter.calls.where((c) => c == 'connect').length;
      expect(exhausted, connectsBefore + policy.maxAttempts);
      expect(container.read(realDeviceProvider).connected, isFalse);

      adapter.connectError = null;
      backgroundApp();
      await pump();
      resumeApp();
      await wait(300);

      expect(container.read(realDeviceProvider).connected, isTrue);
      expect(
        adapter.calls.where((c) => c == 'connect').length,
        greaterThan(exhausted),
      );
    },
  );

  test('resuming after an explicit disconnect stays disconnected', () async {
    final container = makeContainer();
    final controller = container.read(realDeviceProvider.notifier);
    await controller.connect(fakeBridgeDeviceId);
    await controller.disconnect();
    expect(container.read(realDeviceProvider).connected, isFalse);
    final connectsBefore = adapter.calls.where((c) => c == 'connect').length;

    backgroundApp();
    await pump();
    resumeApp();
    await wait(300);

    expect(container.read(realDeviceProvider).connected, isFalse);
    expect(adapter.calls.where((c) => c == 'connect').length, connectsBefore);
    expect(controller.service, isNull);

    // The per-bridge Disconnect control takes the other branch.
    await controller.connect(fakeBridgeDeviceId);
    await controller.disconnect(fakeBridgeDeviceId);
    final afterRowDisconnect = adapter.calls
        .where((c) => c == 'connect')
        .length;
    backgroundApp();
    await pump();
    resumeApp();
    await wait(300);

    expect(container.read(realDeviceProvider).connected, isFalse);
    expect(
      adapter.calls.where((c) => c == 'connect').length,
      afterRowDisconnect,
    );
  });

  test(
    'resume redials a dropped bridge but not a user-disconnected one',
    () async {
      const policy = ReconnectPolicy(
        baseDelay: Duration(milliseconds: 5),
        maxDelay: Duration(milliseconds: 10),
        maxAttempts: 3,
      );
      final container = makeContainer(policy: policy);
      final controller = container.read(realDeviceProvider.notifier);
      await controller.connect(fakeBridgeLeftDeviceId);
      await controller.connect(fakeBridgeRightDeviceId);
      await controller.disconnect(fakeBridgeLeftDeviceId);
      expect(
        container
            .read(realDeviceProvider)
            .isDeviceConnected(fakeBridgeRightDeviceId),
        isTrue,
      );

      // The surviving bridge drops while the app is in the background and its
      // retry campaign exhausts. The earlier per-row Disconnect of the other
      // bridge must not stop this one from being redialled on resume.
      adapter.connectError = Exception('radio unavailable');
      adapter.dropLink(deviceId: fakeBridgeRightDeviceId);
      await wait(500);
      expect(container.read(realDeviceProvider).connected, isFalse);

      adapter.connectError = null;
      backgroundApp();
      await pump();
      resumeApp();
      await wait(300);

      expect(
        container
            .read(realDeviceProvider)
            .isDeviceConnected(fakeBridgeRightDeviceId),
        isTrue,
      );
      expect(
        container
            .read(realDeviceProvider)
            .isDeviceConnected(fakeBridgeLeftDeviceId),
        isFalse,
      );
    },
  );

  test('resuming after a manual scan does not auto-dial', () async {
    final wifi = _DroppableWifiTransport(
      devices: const [FakeDevice(id: 'pi.local:8765', mtu: 4096)],
    );
    addTearDown(wifi.dispose);
    final store = MemoryKnownBridgeStore(
      const KnownBridge(
        bridgeId: 'pi-bridge',
        hosts: ['pi.local'],
        port: 8765,
        bleFallback: false,
      ),
    );
    final container = ProviderContainer(
      overrides: [
        realTransportProvider.overrideWithValue(transport),
        wifiTransportFactoryProvider.overrideWithValue((_) => wifi),
        knownBridgeStoreProvider.overrideWithValue(store),
        lanDiscoveryProvider.overrideWithValue(
          () async => [
            WmrWsEndpoint(host: 'pi.local', port: 8765, bridgeId: 'pi-bridge'),
          ],
        ),
        streamModeProvider.overrideWith(() => TestModeNotifier(StreamMode.raw)),
      ],
    );
    addTearDown(container.dispose);

    final controller = container.read(realDeviceProvider.notifier);
    await controller.startScan();
    backgroundApp();
    await pump();
    resumeApp();
    await wait(300);

    // The user was browsing the scan list, not waiting for an automatic dial.
    expect(container.read(realDeviceProvider).connected, isFalse);
    expect(wifi.connectCalls, 0);
    await controller.stopScan();
  });

  test(
    'resume redials both bridges after both backoff campaigns exhaust',
    () async {
      const policy = ReconnectPolicy(
        baseDelay: Duration(milliseconds: 5),
        maxDelay: Duration(milliseconds: 10),
        maxAttempts: 3,
      );
      final container = makeContainer(policy: policy);
      final controller = container.read(realDeviceProvider.notifier);
      await controller.connect(fakeBridgeLeftDeviceId);
      await controller.connect(fakeBridgeRightDeviceId);
      expect(
        container.read(realDeviceProvider).connectedDeviceIds,
        containsAll([fakeBridgeLeftDeviceId, fakeBridgeRightDeviceId]),
      );
      final connectsBefore = adapter.calls.where((c) => c == 'connect').length;

      // Both links drop while the app is in the background and both retry
      // campaigns exhaust. Every automatic attempt must leave its id in the
      // dropped set, otherwise resume only knows about the last one.
      adapter.connectError = Exception('radio unavailable');
      adapter.dropLink(deviceId: fakeBridgeLeftDeviceId);
      adapter.dropLink(deviceId: fakeBridgeRightDeviceId);
      await wait(600);
      expect(container.read(realDeviceProvider).connected, isFalse);
      final exhausted = adapter.calls.where((c) => c == 'connect').length;
      expect(exhausted, connectsBefore + policy.maxAttempts * 2);

      adapter.connectError = null;
      backgroundApp();
      await pump();
      resumeApp();
      await wait(300);

      expect(
        container.read(realDeviceProvider).connectedDeviceIds,
        containsAll([fakeBridgeLeftDeviceId, fakeBridgeRightDeviceId]),
      );
    },
  );

  test('a finished manual scan does not suppress the resume redial', () async {
    const policy = ReconnectPolicy(
      baseDelay: Duration(milliseconds: 5),
      maxDelay: Duration(milliseconds: 10),
      maxAttempts: 3,
    );
    final container = makeContainer(policy: policy);
    final controller = container.read(realDeviceProvider.notifier);
    await controller.connect(fakeBridgeDeviceId);
    expect(container.read(realDeviceProvider).connected, isTrue);

    // Browsing while connected, then leaving the scan: the browse is over.
    await controller.startScan();
    await controller.stopScan();

    adapter.connectError = Exception('radio unavailable');
    adapter.dropLink();
    await wait(500);
    final exhausted = adapter.calls.where((c) => c == 'connect').length;
    expect(container.read(realDeviceProvider).connected, isFalse);

    adapter.connectError = null;
    backgroundApp();
    await pump();
    resumeApp();
    await wait(300);

    expect(container.read(realDeviceProvider).connected, isTrue);
    expect(
      adapter.calls.where((c) => c == 'connect').length,
      greaterThan(exhausted),
    );
  });

  test(
    'a scan that ends on its own does not suppress the resume redial',
    () async {
      // A retry would call stopScan() and clear the browse suppression by
      // itself, hiding a regression in the scan's own completion. A backoff
      // longer than the scan timeout keeps every automatic retry out of the
      // window before the resume, so only the scan's onDone can clear it.
      const policy = ReconnectPolicy(
        baseDelay: Duration(seconds: 5),
        maxDelay: Duration(seconds: 5),
        maxAttempts: 3,
      );
      final scanAdapter = FakeBleAdapter();
      final scanTransport = UniversalBleTransport(
        adapter: scanAdapter,
        scanTimeout: const Duration(milliseconds: 100),
      );
      addTearDown(scanTransport.dispose);
      final container = ProviderContainer(
        overrides: [
          realTransportProvider.overrideWithValue(scanTransport),
          streamModeProvider.overrideWith(
            () => TestModeNotifier(StreamMode.raw),
          ),
          reconnectPolicyProvider.overrideWithValue(policy),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(realDeviceProvider.notifier);
      await controller.connect(fakeBridgeDeviceId);
      expect(container.read(realDeviceProvider).connected, isTrue);

      // The BLE scan stream closes at its own timeout, with no stopScan call.
      await controller.startScan();
      await wait(300);

      scanAdapter.connectError = Exception('radio unavailable');
      scanAdapter.dropLink();
      await wait(50);
      final connectsBeforeResume = scanAdapter.calls
          .where((c) => c == 'connect')
          .length;
      expect(container.read(realDeviceProvider).connected, isFalse);

      scanAdapter.connectError = null;
      backgroundApp();
      await pump();
      resumeApp();
      await wait(300);

      expect(container.read(realDeviceProvider).connected, isTrue);
      expect(
        scanAdapter.calls.where((c) => c == 'connect').length,
        greaterThan(connectsBeforeResume),
      );
    },
  );

  test('resuming with no dropped link retries LAN discovery', () async {
    final wifi = _DroppableWifiTransport(
      devices: const [FakeDevice(id: 'pi.local:8765', mtu: 4096)],
    );
    addTearDown(wifi.dispose);
    var discoveryFails = true;
    final container = ProviderContainer(
      overrides: [
        realTransportProvider.overrideWithValue(transport),
        wifiTransportFactoryProvider.overrideWithValue((_) => wifi),
        compositeWifiTransportFactoryProvider.overrideWithValue(
          (_) => WifiLink(wifi),
        ),
        lanDiscoveryProvider.overrideWithValue(() async {
          if (discoveryFails) throw Exception('network down');
          return [
            WmrWsEndpoint(host: 'pi.local', port: 8765, bridgeId: 'pi-bridge'),
          ];
        }),
        streamModeProvider.overrideWith(() => TestModeNotifier(StreamMode.raw)),
      ],
    );
    addTearDown(container.dispose);

    final controller = container.read(realDeviceProvider.notifier);
    await controller.launchAutoConnect();
    expect(container.read(realDeviceProvider).connected, isFalse);

    // Discovery recovers while the app is in the background; the resume must
    // run it again rather than waiting for a tap.
    discoveryFails = false;
    backgroundApp();
    await pump();
    resumeApp();
    await wait(300);

    expect(container.read(realDeviceProvider).connected, isTrue);
    expect(wifi.connectCalls, 1);
  });

  test(
    'launch auto-connect reuses the saved token while Bluetooth is off',
    () async {
      final wifi = _DroppableWifiTransport(
        devices: const [FakeDevice(id: 'pi.local:8765', mtu: 4096)],
      );
      addTearDown(wifi.dispose);
      final tokenStore = BridgeTokenStore(MemorySecureTokenBackend());
      await tokenStore.save(
        bridgeId: 'pi-bridge',
        hosts: ['pi.local'],
        token: 'secret',
      );
      WmrWsEndpoint? dialled;
      final container = ProviderContainer(
        overrides: [
          realTransportProvider.overrideWithValue(transport),
          wifiTransportFactoryProvider.overrideWithValue((endpoint) {
            dialled = endpoint;
            return wifi;
          }),
          knownBridgeStoreProvider.overrideWithValue(
            MemoryKnownBridgeStore(
              const KnownBridge(
                bridgeId: 'pi-bridge',
                hosts: ['pi.local'],
                port: 8765,
                bleFallback: false,
              ),
            ),
          ),
          bridgeTokenStoreProvider.overrideWithValue(tokenStore),
          lanDiscoveryProvider.overrideWithValue(
            () async => throw Exception('network down'),
          ),
          streamModeProvider.overrideWith(
            () => TestModeNotifier(StreamMode.raw),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container.read(realDeviceProvider.notifier).launchAutoConnect();

      expect(dialled?.host, 'pi.local');
      expect(dialled?.token, 'secret');
      expect(container.read(realDeviceProvider).connected, isTrue);
    },
  );

  group('adapter power cycle', () {
    Future<void> until(
      bool Function() condition, {
      String? reason,
      Duration timeout = const Duration(seconds: 2),
    }) async {
      final deadline = DateTime.now().add(timeout);
      while (!condition()) {
        if (DateTime.now().isAfter(deadline)) {
          fail(reason ?? 'condition not met within $timeout');
        }
        await wait(5);
      }
    }

    int connectCalls() => adapter.calls.where((c) => c == 'connect').length;

    test(
      'the radio going off parks the campaign; its return redials the stream',
      () async {
        final container = makeContainer(mode: StreamMode.batched);
        final controller = container.read(realDeviceProvider.notifier);
        await controller.connect(fakeBridgeDeviceId);
        expect(container.read(realDeviceProvider).connected, isTrue);
        await until(
          () => adapter.ccc.contains('on ff14'),
          reason: 'the stream CCCD was never enabled',
        );
        final connectsBefore = connectCalls();

        adapter.emitAvailability(BleAvailability.poweredOff);
        // Past the campaign's first delay: nothing dials a powered-off radio.
        await wait(800);

        final state = container.read(realDeviceProvider);
        expect(state.connected, isFalse);
        expect(state.status.phase, BleLinkPhase.bluetoothOff);
        expect(
          connectCalls(),
          connectsBefore,
          reason: 'a parked campaign must not dial a dead radio',
        );

        adapter.emitAvailability(BleAvailability.poweredOn);
        await until(() => container.read(realDeviceProvider).connected);

        // One attempt per device: the radio's return dialled it once, and
        // the wanted stream was re-subscribed with it.
        expect(connectCalls(), connectsBefore + 1);
        expect(adapter.ccc.where((c) => c == 'on ff14'), hasLength(2));
      },
    );

    test(
      'the radio going off mid-connect parks the dial for its return',
      () async {
        final container = makeContainer();
        final controller = container.read(realDeviceProvider.notifier);
        adapter.mtuGate = Completer<void>();
        final connecting = controller.connect(fakeBridgeDeviceId);
        await until(() => adapter.calls.contains('requestMtu 517'));

        adapter.emitAvailability(BleAvailability.poweredOff);
        adapter.mtuGate!.complete();
        await connecting;
        await wait(100);

        final state = container.read(realDeviceProvider);
        expect(state.connected, isFalse);
        expect(state.status.phase, BleLinkPhase.bluetoothOff);
        // The dead stack is not called for a teardown either.
        expect(adapter.calls, isNot(contains('disconnect')));
        final connectsBefore = connectCalls();

        adapter.emitAvailability(BleAvailability.poweredOn);
        await until(() => container.read(realDeviceProvider).connected);
        await until(
          () => adapter.ccc.contains('on ff11'),
          reason: 'the redial did not re-subscribe the stream',
        );

        expect(connectCalls(), connectsBefore + 1);
        expect(adapter.ccc.where((c) => c == 'on ff11'), hasLength(1));
      },
    );

    test(
      'a rapid cycle supersedes the stale dial and it never publishes',
      () async {
        final container = makeContainer(mode: StreamMode.batched);
        final controller = container.read(realDeviceProvider.notifier);
        await controller.connect(fakeBridgeDeviceId);
        await until(
          () => adapter.ccc.contains('on ff14'),
          reason: 'the stream CCCD was never enabled',
        );
        final connectsBefore = connectCalls();

        // Cycle one: the return's redial is held at the MTU step.
        adapter.emitAvailability(BleAvailability.poweredOff);
        await wait(100);
        adapter.mtuGate = Completer<void>();
        adapter.emitAvailability(BleAvailability.poweredOn);
        await until(
          () => connectCalls() == connectsBefore + 1,
          reason: 'the radio return did not redial',
        );
        await until(
          () => adapter.calls.where((c) => c == 'requestMtu 517').length == 2,
          reason: 'the first redial never reached its MTU request',
        );

        // Cycle two lands while that dial is still in flight. The composite
        // serializes its leg switches, so the superseding dial queues behind
        // the stale one instead of being swallowed by it.
        adapter.emitAvailability(BleAvailability.poweredOff);
        adapter.emitAvailability(BleAvailability.poweredOn);

        // The stale dial aborts; the dial that owns this cycle finishes.
        adapter.mtuGate!.complete();
        await until(
          () => connectCalls() == connectsBefore + 2,
          reason: 'the second radio return did not redial over the stale one',
        );
        await until(() => container.read(realDeviceProvider).connected);
        await until(
          () => adapter.ccc.where((c) => c == 'on ff14').length == 2,
          reason: 'the redial did not re-subscribe FF14',
        );

        // One attempt per device per cycle, and the stale attempt published
        // nothing over the recovery: the service the redial built survived.
        expect(connectCalls(), connectsBefore + 2);
        expect(adapter.ccc.where((c) => c == 'on ff14'), hasLength(2));
        expect(controller.service, isNotNull);
      },
    );

    test(
      'the adapter staying off burns no attempts; its return redials',
      () async {
        const policy = ReconnectPolicy(
          baseDelay: Duration(milliseconds: 5),
          maxDelay: Duration(milliseconds: 10),
          maxAttempts: 3,
        );
        final container = makeContainer(
          mode: StreamMode.batched,
          policy: policy,
        );
        final controller = container.read(realDeviceProvider.notifier);
        await controller.connect(fakeBridgeDeviceId);
        final connectsBefore = connectCalls();

        adapter.emitAvailability(BleAvailability.poweredOff);
        // Long enough for the whole (fast) campaign to have run out, had one
        // been armed against the dead radio.
        await wait(300);

        expect(container.read(realDeviceProvider).connected, isFalse);
        expect(connectCalls(), connectsBefore);

        adapter.emitAvailability(BleAvailability.poweredOn);
        await until(() => container.read(realDeviceProvider).connected);

        expect(connectCalls(), connectsBefore + 1);
        expect(adapter.ccc.where((c) => c == 'on ff14'), hasLength(2));
      },
    );

    test(
      'a bridge the user disconnected stays down when the radio returns',
      () async {
        final container = makeContainer();
        final controller = container.read(realDeviceProvider.notifier);
        await controller.connect(fakeBridgeDeviceId);
        await controller.disconnect(fakeBridgeDeviceId);
        final connectsBefore = connectCalls();

        adapter.emitAvailability(BleAvailability.poweredOff);
        await wait(50);
        adapter.emitAvailability(BleAvailability.poweredOn);
        await wait(300);

        expect(container.read(realDeviceProvider).connected, isFalse);
        expect(connectCalls(), connectsBefore);
      },
    );

    test('a Wi-Fi loss while the radio is off is not a radio loss and '
        're-dials', () async {
      final wifi = _DroppableWifiTransport(
        devices: const [FakeDevice(id: 'pi.local:8765', mtu: 4096)],
      );
      addTearDown(wifi.dispose);
      const policy = ReconnectPolicy(
        baseDelay: Duration(milliseconds: 150),
        maxDelay: Duration(milliseconds: 300),
        maxAttempts: 3,
      );
      final container = ProviderContainer(
        overrides: [
          realTransportProvider.overrideWithValue(transport),
          wifiTransportFactoryProvider.overrideWithValue((_) => wifi),
          streamModeProvider.overrideWith(
            () => TestModeNotifier(StreamMode.raw),
          ),
          reconnectPolicyProvider.overrideWithValue(policy),
        ],
      );
      addTearDown(container.dispose);

      final controller = container.read(realDeviceProvider.notifier);
      await controller.connectWifi(
        host: 'pi.local',
        port: 8765,
        bleFallback: false,
      );
      expect(container.read(realDeviceProvider).connected, isTrue);

      // The Bluetooth radio dies: the Wi-Fi session it cannot touch must
      // stay up.
      adapter.emitAvailability(BleAvailability.poweredOff);
      await wait(50);
      expect(container.read(realDeviceProvider).connected, isTrue);

      // The Wi-Fi link then drops for its own reasons. That is a Wi-Fi
      // failure, not a radio loss, and the ordinary campaign re-dials it
      // over Wi-Fi while the radio is still off.
      final connectsBefore = wifi.connectCalls;
      await wifi.disconnect('pi.local:8765');
      await until(
        () =>
            container.read(realDeviceProvider).status.phase ==
            BleLinkPhase.connectionLost,
        reason: 'the Wi-Fi drop was not reported as its own loss',
      );

      for (
        var elapsed = 0;
        elapsed < 1500 &&
            (wifi.connectCalls < connectsBefore + 1 ||
                !container.read(realDeviceProvider).connected);
        elapsed += 20
      ) {
        await wait(20);
      }

      expect(container.read(realDeviceProvider).connected, isTrue);
      expect(wifi.connectCalls, greaterThanOrEqualTo(connectsBefore + 1));
    });

    test(
      'the radio taking a composite BLE-carried Wi-Fi session parks it too',
      () async {
        // The default Wi-Fi tab: the composite's TCP leg cannot answer, so
        // its BLE fallback leg carries the session and dies with the radio.
        const bridgeId = 'pi-1';
        const bleDeviceId = 'ble-pi-1';
        final endpoint = WmrWsEndpoint(
          host: '192.168.1.42',
          port: 8765,
          bridgeId: bridgeId,
        );
        final countingAdapter = _CountingAdapter()
          ..readValues[wmrBridgeVersionCharUuid] = Uint8List.fromList(
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
        final bleTab = UniversalBleTransport(
          adapter: countingAdapter,
          scanTimeout: const Duration(minutes: 5),
        );
        addTearDown(bleTab.dispose);
        final composite = CompositeBleTransport(
          tcp: _RefusedTcp(endpoint),
          ble: UniversalBleTransport(
            adapter: countingAdapter,
            scanTimeout: const Duration(minutes: 5),
          ),
          upgradeInterval: Duration.zero,
          bleScanWait: const Duration(seconds: 2),
        );
        addTearDown(composite.dispose);
        final wifiLink = WifiLink(
          composite,
          activeLeg: () =>
              switch (composite.activeLegFor(endpoint.resolvedDeviceId)) {
                CompositeLeg.tcp => WifiLinkLeg.tcp,
                CompositeLeg.ble => WifiLinkLeg.ble,
                null => null,
              },
        );
        final container = ProviderContainer(
          overrides: [
            realTransportProvider.overrideWithValue(bleTab),
            compositeWifiTransportFactoryProvider.overrideWithValue(
              (_) => wifiLink,
            ),
            lanInterfaceProbeProvider.overrideWithValue(() async => true),
            bridgeTokenStoreProvider.overrideWithValue(
              BridgeTokenStore(MemorySecureTokenBackend()),
            ),
            knownBridgeStoreProvider.overrideWithValue(
              MemoryKnownBridgeStore(),
            ),
            streamModeProvider.overrideWith(
              () => TestModeNotifier(StreamMode.batched),
            ),
          ],
        );
        addTearDown(container.dispose);

        final controller = container.read(realDeviceProvider.notifier);
        // The composite waits for the fallback scan to name its BLE
        // candidate after the TCP refusal.
        final dial = controller.connectWifi(
          host: endpoint.host,
          port: endpoint.port,
          bridgeId: bridgeId,
          bleFallback: true,
        );
        await wait(50);
        countingAdapter.emitScanResult(
          BleScanResult(deviceId: bleDeviceId, name: 'WMR Bridge', rssi: -55),
        );
        await dial;

        var state = container.read(realDeviceProvider);
        expect(state.connected, isTrue);
        expect(state.wifiLeg, WifiLinkLeg.ble);
        await until(
          () => countingAdapter.ccc.contains('on ff14'),
          reason: 'the stream CCCD was never enabled',
        );
        int connectCalls() =>
            countingAdapter.calls.where((c) => c == 'connect').length;
        final connectsBefore = connectCalls();
        final readsBefore = countingAdapter.availabilityReads;

        // The radio dies: the composite's BLE-carried session went with it.
        countingAdapter.emitAvailability(BleAvailability.poweredOff);
        await wait(100);

        state = container.read(realDeviceProvider);
        expect(state.status.phase, BleLinkPhase.bluetoothOff);
        expect(state.connected, isFalse);
        expect(
          connectCalls(),
          connectsBefore,
          reason: 'a parked composite session redialled the dead radio',
        );
        expect(
          countingAdapter.availabilityReads,
          readsBefore,
          reason: 'a parked composite session dialled the dead radio',
        );

        // The radio's return redials the parked session once through the
        // ordinary connect path, over the composite's BLE leg again.
        countingAdapter.emitAvailability(BleAvailability.poweredOn);
        await until(() => container.read(realDeviceProvider).connected);

        state = container.read(realDeviceProvider);
        expect(state.wifiLeg, WifiLinkLeg.ble);
        // One availability read for the redial connect preflight; the already
        // bridge-verified candidate avoids a redundant fallback scan.
        expect(countingAdapter.availabilityReads, readsBefore + 1);
        expect(connectCalls(), connectsBefore + 1);
      },
    );

    test(
      'a retry armed before the radio dies is parked, not dialled',
      () async {
        final countingAdapter = _CountingAdapter();
        final ble = UniversalBleTransport(
          adapter: countingAdapter,
          scanTimeout: const Duration(minutes: 5),
        );
        addTearDown(ble.dispose);
        const policy = ReconnectPolicy(
          baseDelay: Duration(milliseconds: 150),
          maxDelay: Duration(milliseconds: 300),
          maxAttempts: 3,
        );
        final container = ProviderContainer(
          overrides: [
            realTransportProvider.overrideWithValue(ble),
            streamModeProvider.overrideWith(
              () => TestModeNotifier(StreamMode.batched),
            ),
            reconnectPolicyProvider.overrideWithValue(policy),
          ],
        );
        addTearDown(container.dispose);

        final controller = container.read(realDeviceProvider.notifier);
        await controller.connect(fakeBridgeDeviceId);
        await until(
          () => countingAdapter.ccc.contains('on ff14'),
          reason: 'the stream CCCD was never enabled',
        );
        int connectCalls() =>
            countingAdapter.calls.where((c) => c == 'connect').length;
        final connectsBefore = connectCalls();
        final readsAfterConnect = countingAdapter.availabilityReads;

        // The link drops while the radio is alive, arming a retry; the
        // radio dies before the retry's delay elapses.
        countingAdapter.dropLink(deviceId: fakeBridgeDeviceId);
        countingAdapter.emitAvailability(BleAvailability.poweredOff);
        // Past the whole retry delay: the armed timer fired inside the
        // radio-off window and must not have dialled the dead stack.
        await wait(500);

        expect(
          countingAdapter.availabilityReads,
          readsAfterConnect,
          reason: 'a retry armed before the radio died dialled the dead radio',
        );
        expect(connectCalls(), connectsBefore);

        countingAdapter.emitAvailability(BleAvailability.poweredOn);
        await until(() => container.read(realDeviceProvider).connected);

        // The radio's return dials the parked bridge exactly once.
        expect(connectCalls(), connectsBefore + 1);
        expect(countingAdapter.availabilityReads, readsAfterConnect + 1);
      },
    );

    test('radio-off during TCP->BLE failover records bridge and redials on power-on (Wi-Fi composite)', () async {
      const bridgeId = 'pi-1';
      const bleDeviceId = 'ble-pi-1';
      final endpoint = WmrWsEndpoint(
        host: '192.168.1.42',
        port: 8765,
        bridgeId: bridgeId,
      );
      final tcpInner = FakeTransport(
        devices: [FakeDevice(id: endpoint.resolvedDeviceId, mtu: 4096)],
      );
      final tcp = _SwitchableTcp(tcpInner, endpoint: endpoint);
      final countingAdapter = _CountingAdapter()
        ..readValues[wmrBridgeVersionCharUuid] = Uint8List.fromList(
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
      final bleTab = UniversalBleTransport(
        adapter: countingAdapter,
        scanTimeout: const Duration(minutes: 5),
      );
      addTearDown(bleTab.dispose);
      final composite = CompositeBleTransport(
        tcp: tcp,
        ble: UniversalBleTransport(
          adapter: countingAdapter,
          scanTimeout: const Duration(minutes: 5),
        ),
        upgradeInterval: Duration.zero,
        bleScanWait: const Duration(seconds: 2),
      );
      addTearDown(composite.dispose);
      final wifiLink = WifiLink(
        composite,
        activeLeg: () =>
            switch (composite.activeLegFor(endpoint.resolvedDeviceId)) {
              CompositeLeg.tcp => WifiLinkLeg.tcp,
              CompositeLeg.ble => WifiLinkLeg.ble,
              null => null,
            },
      );
      final container = ProviderContainer(
        overrides: [
          realTransportProvider.overrideWithValue(bleTab),
          compositeWifiTransportFactoryProvider.overrideWithValue(
            (_) => wifiLink,
          ),
          lanInterfaceProbeProvider.overrideWithValue(() async => true),
          bridgeTokenStoreProvider.overrideWithValue(
            BridgeTokenStore(MemorySecureTokenBackend()),
          ),
          knownBridgeStoreProvider.overrideWithValue(MemoryKnownBridgeStore()),
          streamModeProvider.overrideWith(
            () => TestModeNotifier(StreamMode.batched),
          ),
        ],
      );
      addTearDown(container.dispose);

      final controller = container.read(realDeviceProvider.notifier);
      await controller.connectWifi(
        host: endpoint.host,
        port: endpoint.port,
        bridgeId: bridgeId,
        bleFallback: true,
      );
      countingAdapter.emitScanResult(
        BleScanResult(deviceId: bleDeviceId, name: 'WMR Bridge', rssi: -55),
      );
      await wait(50);

      var state = container.read(realDeviceProvider);
      expect(state.connected, isTrue);
      expect(state.wifiLeg, WifiLinkLeg.tcp);
      expect(
        composite.activeLegFor(endpoint.resolvedDeviceId),
        CompositeLeg.tcp,
      );

      int connectCalls() =>
          countingAdapter.calls.where((c) => c == 'connect').length;
      int discoveryCalls() =>
          countingAdapter.calls.where((c) => c == 'discoverServices').length;

      // TCP drops -> failover begins -> BLE dial is held in flight before
      // BLE activates, so composite still names TCP active.
      countingAdapter.connectGate = Completer<void>();
      tcp.failConnect = true;
      await tcpInner.disconnect(endpoint.resolvedDeviceId);
      await until(
        () => connectCalls() == 1,
        reason: 'TCP drop did not start BLE failover dial',
      );
      expect(
        composite.activeLegFor(endpoint.resolvedDeviceId),
        CompositeLeg.tcp,
      );

      // Radio powers off before BLE activates: setup must settle within 1 s,
      // state must drop connected/TCP honestly, and zero disconnects are sent
      // into the dead stack.
      countingAdapter.emitAvailability(BleAvailability.poweredOff);
      await until(
        () => !container.read(realDeviceProvider).connected,
        timeout: const Duration(seconds: 1),
        reason: 'state still claimed connected while both legs were down',
      );
      await wait(50);

      state = container.read(realDeviceProvider);
      expect(state.connected, isFalse);
      expect(state.status.phase, BleLinkPhase.bluetoothOff);
      expect(state.wifiLeg, isNull);
      expect(countingAdapter.calls, isNot(contains('disconnect')));

      // Radio powers on while TCP stays down: one dial starts within 2 s,
      // runs connect -> discovery -> FF14 CCCD, and activates BLE.
      countingAdapter.connectGate = null;
      countingAdapter.emitAvailability(BleAvailability.poweredOn);
      await until(
        () => connectCalls() == 2,
        timeout: const Duration(seconds: 2),
        reason: 'radio-on did not start a redial within 2 s',
      );
      await until(
        () => container.read(realDeviceProvider).connected,
        timeout: const Duration(seconds: 15),
        reason: 'redial did not finish within 15 s',
      );
      await until(
        () => countingAdapter.ccc.where((c) => c == 'on ff14').length == 1,
        timeout: const Duration(seconds: 15),
        reason: 'FF14 CCCD was not enabled within 15 s',
      );

      state = container.read(realDeviceProvider);
      expect(state.status.phase, BleLinkPhase.ready);
      expect(state.wifiLeg, WifiLinkLeg.ble);
      expect(
        composite.activeLegFor(endpoint.resolvedDeviceId),
        CompositeLeg.ble,
      );
      expect(discoveryCalls(), 1);
      expect(connectCalls(), 2);

      // FF14 notifications arrive on the recovered BLE leg.
      countingAdapter.emitNotification(
        wmrBridgeBatchedCharUuid,
        encodeDecodedBatch([encodeDecodedRecord(decoded(1, hand: 1))]),
        deviceId: bleDeviceId,
      );
      await wait(280);
      expect(
        container.read(realDeviceProvider).decodedStats?.hands[1].records,
        1,
      );

      // Second radio cycle: drops honestly and re-subscribes FF14 on return.
      countingAdapter.emitAvailability(BleAvailability.poweredOff);
      await until(
        () => !container.read(realDeviceProvider).connected,
        timeout: const Duration(seconds: 1),
      );
      expect(
        container.read(realDeviceProvider).status.phase,
        BleLinkPhase.bluetoothOff,
      );
      expect(countingAdapter.calls, isNot(contains('disconnect')));

      countingAdapter.emitAvailability(BleAvailability.poweredOn);
      await until(
        () => container.read(realDeviceProvider).connected,
        timeout: const Duration(seconds: 15),
      );
      await until(
        () => countingAdapter.ccc.where((c) => c == 'on ff14').length == 2,
        timeout: const Duration(seconds: 15),
        reason: 'second cycle did not re-subscribe FF14',
      );
      expect(connectCalls(), 3);
      expect(discoveryCalls(), 2);
      expect(container.read(realDeviceProvider).wifiLeg, WifiLinkLeg.ble);
    });

    test('radio-off during TCP->BLE failover records bridge and redials on power-on (BLE handoff composite)', () async {
      const bridgeId = 'pi-1';
      const bleDeviceId = fakeBridgeDeviceId;
      const lanDeviceId = '192.168.1.42:8765';
      final endpoint = WmrWsEndpoint(
        host: '192.168.1.42',
        port: 8765,
        bridgeId: bridgeId,
      );
      final tcpInner = FakeTransport(
        devices: [FakeDevice(id: lanDeviceId, mtu: 4096)],
      );
      final tcp = _SwitchableTcp(tcpInner, endpoint: endpoint);
      final endpointAdapter = _EndpointAdapter(
        bridgeId: bridgeId,
        hosts: const ['192.168.1.42'],
      );
      final bleTransport = UniversalBleTransport(
        adapter: endpointAdapter,
        scanTimeout: const Duration(minutes: 5),
      );
      addTearDown(bleTransport.dispose);
      late CompositeBleTransport composite;
      final container = ProviderContainer(
        overrides: [
          realTransportProvider.overrideWithValue(bleTransport),
          bleHandoffTransportFactoryProvider.overrideWithValue(
            (ble) => composite = CompositeBleTransport(
              tcp: tcp,
              ble: ble,
              upgradeInterval: const Duration(hours: 1),
              disposeBle: false,
            ),
          ),
          streamModeProvider.overrideWith(
            () => TestModeNotifier(StreamMode.batched),
          ),
        ],
      );
      addTearDown(container.dispose);

      final controller = container.read(realDeviceProvider.notifier);
      // Populate composite's scan hits just as the Connect screen does.
      await controller.startScan();
      await until(
        () => endpointAdapter.calls.any((c) => c.startsWith('startScan')),
        reason: 'scan never subscribed to adapter scanResults',
      );
      endpointAdapter.emitScanResult(
        BleScanResult(deviceId: bleDeviceId, name: 'WMR Bridge', rssi: -55),
      );
      await wait(20);
      await controller.stopScan();

      await controller.connect(bleDeviceId);
      await until(
        () => composite.activeLegFor(bleDeviceId) == CompositeLeg.tcp,
        reason: 'BLE handoff composite never upgraded to TCP',
      );
      expect(container.read(realDeviceProvider).connected, isTrue);

      // Drop the dormant fallback GATT link while TCP keeps streaming, so
      // the TCP drop below must dial GATT fresh.
      endpointAdapter.dropLink(deviceId: bleDeviceId);
      await wait(50);
      expect(container.read(realDeviceProvider).connected, isTrue);

      int connectCalls() =>
          endpointAdapter.calls.where((c) => c == 'connect').length;
      int discoveryCalls() =>
          endpointAdapter.calls.where((c) => c == 'discoverServices').length;
      final connectsBeforeFailover = connectCalls();
      final discoveriesBeforeFailover = discoveryCalls();
      final ff14BeforeFailover = endpointAdapter.ccc
          .where((c) => c == 'on ff14')
          .length;

      // TCP drops -> failover dial starts -> radio off before BLE activates.
      endpointAdapter.connectGate = Completer<void>();
      tcp.failConnect = true;
      await tcpInner.disconnect(lanDeviceId);
      await until(
        () => connectCalls() == connectsBeforeFailover + 1,
        reason: 'TCP drop did not start BLE failover dial',
      );
      expect(composite.activeLegFor(bleDeviceId), CompositeLeg.tcp);

      endpointAdapter.emitAvailability(BleAvailability.poweredOff);
      await until(
        () => !container.read(realDeviceProvider).connected,
        timeout: const Duration(seconds: 1),
      );
      await wait(50);

      var state = container.read(realDeviceProvider);
      expect(state.connected, isFalse);
      expect(state.status.phase, BleLinkPhase.bluetoothOff);
      expect(endpointAdapter.calls, isNot(contains('disconnect')));

      // Radio powers on: one fresh dial starts, discovers, subscribes FF14.
      endpointAdapter.connectGate = null;
      endpointAdapter.emitAvailability(BleAvailability.poweredOn);
      await until(
        () => connectCalls() == connectsBeforeFailover + 2,
        timeout: const Duration(seconds: 2),
      );
      await until(
        () => container.read(realDeviceProvider).connected,
        timeout: const Duration(seconds: 15),
      );
      await until(
        () =>
            endpointAdapter.ccc.where((c) => c == 'on ff14').length ==
            ff14BeforeFailover + 1,
        timeout: const Duration(seconds: 15),
      );

      state = container.read(realDeviceProvider);
      expect(state.status.phase, BleLinkPhase.ready);
      expect(composite.activeLegFor(bleDeviceId), CompositeLeg.ble);
      expect(discoveryCalls(), discoveriesBeforeFailover + 1);

      // Second cycle subscribes FF14 again.
      endpointAdapter.emitAvailability(BleAvailability.poweredOff);
      await until(
        () => !container.read(realDeviceProvider).connected,
        timeout: const Duration(seconds: 1),
      );
      endpointAdapter.emitAvailability(BleAvailability.poweredOn);
      await until(
        () => container.read(realDeviceProvider).connected,
        timeout: const Duration(seconds: 15),
      );
      await until(
        () =>
            endpointAdapter.ccc.where((c) => c == 'on ff14').length ==
            ff14BeforeFailover + 2,
        timeout: const Duration(seconds: 15),
      );
      expect(composite.activeLegFor(bleDeviceId), CompositeLeg.ble);
    });

    test('T9: healthy TCP with inactive BLE survives radio-off/on with zero GATT dials through 15 s', () async {
      const bridgeId = 'pi-1';
      final endpoint = WmrWsEndpoint(
        host: '192.168.1.42',
        port: 8765,
        bridgeId: bridgeId,
      );
      final tcpInner = FakeTransport(
        devices: [FakeDevice(id: endpoint.resolvedDeviceId, mtu: 4096)],
      );
      final tcp = _SwitchableTcp(tcpInner, endpoint: endpoint);
      final countingAdapter = _CountingAdapter()
        ..readValues[wmrBridgeVersionCharUuid] = Uint8List.fromList(
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
      final bleTab = UniversalBleTransport(
        adapter: countingAdapter,
        scanTimeout: const Duration(minutes: 5),
      );
      addTearDown(bleTab.dispose);
      final composite = CompositeBleTransport(
        tcp: tcp,
        ble: UniversalBleTransport(
          adapter: countingAdapter,
          scanTimeout: const Duration(minutes: 5),
        ),
        upgradeInterval: Duration.zero,
        bleScanWait: const Duration(seconds: 2),
      );
      addTearDown(composite.dispose);
      final wifiLink = WifiLink(
        composite,
        activeLeg: () =>
            switch (composite.activeLegFor(endpoint.resolvedDeviceId)) {
              CompositeLeg.tcp => WifiLinkLeg.tcp,
              CompositeLeg.ble => WifiLinkLeg.ble,
              null => null,
            },
      );
      final container = ProviderContainer(
        overrides: [
          realTransportProvider.overrideWithValue(bleTab),
          compositeWifiTransportFactoryProvider.overrideWithValue(
            (_) => wifiLink,
          ),
          lanInterfaceProbeProvider.overrideWithValue(() async => true),
          bridgeTokenStoreProvider.overrideWithValue(
            BridgeTokenStore(MemorySecureTokenBackend()),
          ),
          knownBridgeStoreProvider.overrideWithValue(MemoryKnownBridgeStore()),
          streamModeProvider.overrideWith(
            () => TestModeNotifier(StreamMode.batched),
          ),
        ],
      );
      addTearDown(container.dispose);

      final controller = container.read(realDeviceProvider.notifier);
      await controller.connectWifi(
        host: endpoint.host,
        port: endpoint.port,
        bridgeId: bridgeId,
        bleFallback: true,
      );
      await wait(50);

      expect(container.read(realDeviceProvider).connected, isTrue);
      expect(container.read(realDeviceProvider).wifiLeg, WifiLinkLeg.tcp);

      // Both hands stream over TCP before the radio toggle.
      tcpInner.emit(
        endpoint.resolvedDeviceId,
        wmrBridgeBatchedCharUuid,
        encodeDecodedBatch([
          encodeDecodedRecord(decoded(1, hand: 0)),
          encodeDecodedRecord(decoded(1, hand: 1)),
        ]),
      );
      await wait(280);
      expect(
        container.read(realDeviceProvider).decodedStats?.hands[0].records,
        1,
      );
      expect(
        container.read(realDeviceProvider).decodedStats?.hands[1].records,
        1,
      );

      // Toggle radio off and on while TCP remains healthy and BLE stays
      // inactive.
      countingAdapter.emitAvailability(BleAvailability.poweredOff);
      await wait(200);
      expect(container.read(realDeviceProvider).connected, isTrue);
      expect(container.read(realDeviceProvider).wifiLeg, WifiLinkLeg.tcp);

      countingAdapter.emitAvailability(BleAvailability.poweredOn);
      await wait(15100);

      // Both hands continue streaming over TCP after radio-on.
      tcpInner.emit(
        endpoint.resolvedDeviceId,
        wmrBridgeBatchedCharUuid,
        encodeDecodedBatch([
          encodeDecodedRecord(decoded(2, hand: 0)),
          encodeDecodedRecord(decoded(2, hand: 1)),
        ]),
      );
      await wait(280);

      final state = container.read(realDeviceProvider);
      expect(state.connected, isTrue);
      expect(state.wifiLeg, WifiLinkLeg.tcp);
      expect(
        composite.activeLegFor(endpoint.resolvedDeviceId),
        CompositeLeg.tcp,
      );
      expect(state.decodedStats?.hands[0].records, 2);
      expect(state.decodedStats?.hands[1].records, 2);
      expect(
        countingAdapter.calls.where((c) => c == 'connect'),
        isEmpty,
        reason: 'healthy TCP toggle must issue zero GATT dials',
      );
      expect(
        countingAdapter.ccc.where((c) => c == 'on ff14'),
        isEmpty,
        reason: 'healthy TCP toggle must create zero FF14 subscriptions',
      );
    }, timeout: const Timeout(Duration(seconds: 45)));

    test('T5: throwing redial connect reports failure and retries after existing backoff', () async {
      const bridgeId = 'pi-1';
      const bleDeviceId = 'ble-pi-1';
      final endpoint = WmrWsEndpoint(
        host: '192.168.1.42',
        port: 8765,
        bridgeId: bridgeId,
      );
      final tcpInner = FakeTransport(
        devices: [FakeDevice(id: endpoint.resolvedDeviceId, mtu: 4096)],
      );
      final tcp = _SwitchableTcp(tcpInner, endpoint: endpoint);
      final countingAdapter = _CountingAdapter()
        ..readValues[wmrBridgeVersionCharUuid] = Uint8List.fromList(
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
      final bleTab = UniversalBleTransport(
        adapter: countingAdapter,
        scanTimeout: const Duration(minutes: 5),
      );
      addTearDown(bleTab.dispose);
      var lanUp = true;
      final composite = CompositeBleTransport(
        tcp: tcp,
        ble: UniversalBleTransport(
          adapter: countingAdapter,
          scanTimeout: const Duration(minutes: 5),
        ),
        upgradeInterval: Duration.zero,
        bleScanWait: const Duration(seconds: 2),
        lanAvailable: () async => lanUp,
      );
      addTearDown(composite.dispose);
      final wifiLink = WifiLink(
        composite,
        activeLeg: () =>
            switch (composite.activeLegFor(endpoint.resolvedDeviceId)) {
              CompositeLeg.tcp => WifiLinkLeg.tcp,
              CompositeLeg.ble => WifiLinkLeg.ble,
              null => null,
            },
      );
      final container = ProviderContainer(
        overrides: [
          realTransportProvider.overrideWithValue(bleTab),
          compositeWifiTransportFactoryProvider.overrideWithValue(
            (_) => wifiLink,
          ),
          lanInterfaceProbeProvider.overrideWithValue(() async => true),
          bridgeTokenStoreProvider.overrideWithValue(
            BridgeTokenStore(MemorySecureTokenBackend()),
          ),
          knownBridgeStoreProvider.overrideWithValue(MemoryKnownBridgeStore()),
          streamModeProvider.overrideWith(
            () => TestModeNotifier(StreamMode.batched),
          ),
        ],
      );
      addTearDown(container.dispose);

      final controller = container.read(realDeviceProvider.notifier);
      await controller.connectWifi(
        host: endpoint.host,
        port: endpoint.port,
        bridgeId: bridgeId,
        bleFallback: true,
      );
      countingAdapter.emitScanResult(
        BleScanResult(deviceId: bleDeviceId, name: 'WMR Bridge', rssi: -55),
      );
      await wait(50);

      int connectCalls() =>
          countingAdapter.calls.where((c) => c == 'connect').length;

      // TCP drops and radio cuts the in-flight failover dial.
      countingAdapter.connectGate = Completer<void>();
      tcp.failConnect = true;
      await tcpInner.disconnect(endpoint.resolvedDeviceId);
      await until(() => connectCalls() == 1);
      expect(
        composite.activeLegFor(endpoint.resolvedDeviceId),
        CompositeLeg.tcp,
      );

      countingAdapter.emitAvailability(BleAvailability.poweredOff);
      await until(
        () => !container.read(realDeviceProvider).connected,
        timeout: const Duration(seconds: 1),
      );
      await wait(50);
      expect(
        container.read(realDeviceProvider).status.phase,
        BleLinkPhase.bluetoothOff,
      );

      // Inject a throwing redial connect on radio-on (fails once with
      // BleTransportException, then recovers on the scheduled retry).
      lanUp = false;
      countingAdapter.connectGate = null;
      countingAdapter.connectFailureCount = 1;
      countingAdapter.emitAvailability(BleAvailability.poweredOn);
      await until(() => connectCalls() == 2);
      await wait(80);

      // Status reports the failure and the retry waits for the existing
      // 500 ms backoff instead of dialling immediately or silently stopping.
      expect(connectCalls(), 2);
      var state = container.read(realDeviceProvider);
      expect(state.connected, isFalse);
      expect(state.status.phase, BleLinkPhase.connectFailed);

      // Advance through the existing ReconnectPolicy attempt-0 backoff
      // (500 ms) and assert that the scheduled retry starts and lands.
      final firstBackoff = const ReconnectPolicy().delayFor(0);
      expect(firstBackoff, const Duration(milliseconds: 500));
      await wait(firstBackoff.inMilliseconds + 150);

      await until(() => connectCalls() == 3);
      await until(() => container.read(realDeviceProvider).connected);
      state = container.read(realDeviceProvider);
      expect(state.status.phase, BleLinkPhase.ready);
      expect(state.wifiLeg, WifiLinkLeg.ble);
      expect(countingAdapter.ccc.where((c) => c == 'on ff14'), hasLength(1));
    });

    test('Wi-Fi bleFallback with TCP down parks retry on poweredOff and recovers via re-armed fallback scan on poweredOn', () async {
      const bridgeId = 'pi-1';
      const bleDeviceId = 'ble-pi-1';
      final endpoint = WmrWsEndpoint(
        host: '192.168.1.42',
        port: 8765,
        bridgeId: bridgeId,
      );
      final countingAdapter = _CountingAdapter()
        ..readValues[wmrBridgeVersionCharUuid] = Uint8List.fromList(
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
      final ble = UniversalBleTransport(
        adapter: countingAdapter,
        scanTimeout: const Duration(minutes: 5),
      );
      addTearDown(ble.dispose);
      final tcpInner = FakeTransport(
        devices: [FakeDevice(id: endpoint.resolvedDeviceId)],
      );
      final tcp = _SwitchableTcp(tcpInner, endpoint: endpoint);
      final composite = CompositeBleTransport(
        tcp: tcp,
        ble: ble,
        disposeBle: false,
        lanAvailable: () async => true,
        upgradeInterval: Duration.zero,
        bleScanWait: const Duration(milliseconds: 50),
      );
      addTearDown(composite.dispose);
      final wifiLink = WifiLink(
        composite,
        activeLeg: () =>
            switch (composite.activeLegFor(endpoint.resolvedDeviceId)) {
              CompositeLeg.tcp => WifiLinkLeg.tcp,
              CompositeLeg.ble => WifiLinkLeg.ble,
              null => null,
            },
      );
      const policy = ReconnectPolicy(
        baseDelay: Duration(milliseconds: 120),
        maxDelay: Duration(milliseconds: 120),
        maxAttempts: 4,
      );
      final container = ProviderContainer(
        overrides: [
          realTransportProvider.overrideWithValue(ble),
          compositeWifiTransportFactoryProvider.overrideWithValue(
            (_) => wifiLink,
          ),
          lanInterfaceProbeProvider.overrideWithValue(() async => true),
          bridgeTokenStoreProvider.overrideWithValue(
            BridgeTokenStore(MemorySecureTokenBackend()),
          ),
          knownBridgeStoreProvider.overrideWithValue(MemoryKnownBridgeStore()),
          streamModeProvider.overrideWith(
            () => TestModeNotifier(StreamMode.batched),
          ),
          reconnectPolicyProvider.overrideWithValue(policy),
        ],
      );
      addTearDown(container.dispose);

      final controller = container.read(realDeviceProvider.notifier);
      await controller.connectWifi(
        host: endpoint.host,
        port: endpoint.port,
        bridgeId: bridgeId,
        bleFallback: true,
      );
      expect(container.read(realDeviceProvider).wifiLeg, WifiLinkLeg.tcp);

      // TCP drops with no BLE hit yet -> failover loses -> reconnect timer is
      // armed in backoff.
      tcp.failConnect = true;
      unawaited(tcpInner.disconnect(endpoint.resolvedDeviceId));
      await until(() => !container.read(realDeviceProvider).connected);

      // Radio turns off while TCP is down / redial backoff is armed: must
      // park in _droppedDeviceIds and burn zero attempts while off.
      final readsAtOff = countingAdapter.availabilityReads;
      final scansAtOff = countingAdapter.calls
          .where((c) => c.startsWith('startScan'))
          .length;
      countingAdapter.emitAvailability(BleAvailability.poweredOff);
      await wait(300);

      var state = container.read(realDeviceProvider);
      expect(state.status.phase, BleLinkPhase.bluetoothOff);
      expect(countingAdapter.availabilityReads, readsAtOff);

      // Radio returns: _startFallbackScan is re-armed before recovery dial,
      // so a fresh scan hit lands the BLE leg.
      countingAdapter.emitAvailability(BleAvailability.poweredOn);
      await until(
        () =>
            countingAdapter.calls
                .where((c) => c.startsWith('startScan'))
                .length >
            scansAtOff,
      );
      countingAdapter.emitScanResult(
        BleScanResult(deviceId: bleDeviceId, name: 'WMR Bridge', rssi: -50),
      );
      await until(() => container.read(realDeviceProvider).connected);

      state = container.read(realDeviceProvider);
      expect(state.wifiLeg, WifiLinkLeg.ble);
      expect(state.status.phase, BleLinkPhase.ready);
    });

    test(
      'Wi-Fi bleFallback poweredOn with dead BLE peer surfaces connectFailed',
      () async {
        const bridgeId = 'pi-1';
        const bleDeviceId = 'ble-pi-1';
        final endpoint = WmrWsEndpoint(
          host: '192.168.1.42',
          port: 8765,
          bridgeId: bridgeId,
        );
        final countingAdapter = _CountingAdapter()
          ..readValues[wmrBridgeVersionCharUuid] = Uint8List.fromList(
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
        final ble = UniversalBleTransport(
          adapter: countingAdapter,
          scanTimeout: const Duration(minutes: 5),
        );
        addTearDown(ble.dispose);
        final tcpInner = FakeTransport(
          devices: [FakeDevice(id: endpoint.resolvedDeviceId)],
        );
        final tcp = _SwitchableTcp(tcpInner, endpoint: endpoint)
          ..failConnect = true;
        final composite = CompositeBleTransport(
          tcp: tcp,
          ble: ble,
          disposeBle: false,
          lanAvailable: () async => true,
          upgradeInterval: Duration.zero,
          bleScanWait: const Duration(milliseconds: 50),
        );
        addTearDown(composite.dispose);
        final wifiLink = WifiLink(
          composite,
          activeLeg: () =>
              switch (composite.activeLegFor(endpoint.resolvedDeviceId)) {
                CompositeLeg.tcp => WifiLinkLeg.tcp,
                CompositeLeg.ble => WifiLinkLeg.ble,
                null => null,
              },
        );
        final container = ProviderContainer(
          overrides: [
            realTransportProvider.overrideWithValue(ble),
            compositeWifiTransportFactoryProvider.overrideWithValue(
              (_) => wifiLink,
            ),
            lanInterfaceProbeProvider.overrideWithValue(() async => true),
            bridgeTokenStoreProvider.overrideWithValue(
              BridgeTokenStore(MemorySecureTokenBackend()),
            ),
            knownBridgeStoreProvider.overrideWithValue(
              MemoryKnownBridgeStore(),
            ),
            streamModeProvider.overrideWith(
              () => TestModeNotifier(StreamMode.batched),
            ),
            reconnectPolicyProvider.overrideWithValue(
              const ReconnectPolicy(
                baseDelay: Duration(seconds: 5),
                maxDelay: Duration(seconds: 5),
                maxAttempts: 1,
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        final controller = container.read(realDeviceProvider.notifier);
        final dial = controller.connectWifi(
          host: endpoint.host,
          port: endpoint.port,
          bridgeId: bridgeId,
          bleFallback: true,
        );
        await wait(50);
        countingAdapter.emitScanResult(
          BleScanResult(deviceId: bleDeviceId, name: 'WMR Bridge', rssi: -50),
        );
        await dial;
        expect(container.read(realDeviceProvider).wifiLeg, WifiLinkLeg.ble);

        countingAdapter.emitAvailability(BleAvailability.poweredOff);
        await wait(50);
        expect(
          container.read(realDeviceProvider).status.phase,
          BleLinkPhase.bluetoothOff,
        );

        // BLE peer is now dead: connect throws on poweredOn recovery.
        countingAdapter.connectError = StateError('peer unreachable');
        countingAdapter.emitAvailability(BleAvailability.poweredOn);
        await wait(50);
        countingAdapter.emitScanResult(
          BleScanResult(deviceId: bleDeviceId, name: 'WMR Bridge', rssi: -50),
        );
        await until(
          () =>
              container.read(realDeviceProvider).status.phase ==
              BleLinkPhase.connectFailed,
        );
        expect(container.read(realDeviceProvider).connected, isFalse);
      },
    );
  });
}
