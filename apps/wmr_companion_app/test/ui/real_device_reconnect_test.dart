import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_companion_app/hid/hid_output.dart';
import 'package:wmr_companion_app/services/known_bridge_store.dart';
import 'package:wmr_companion_app/ui/connect/connect_providers.dart';
import 'package:wmr_companion_app/ui/debug/debug_providers.dart';
import 'package:wmr_companion_app/ui/debug/stream_settings.dart';
import 'package:wmr_companion_hid_android/wmr_companion_hid_android.dart';
import 'package:wmr_core/ble/fake_transport.dart';
import 'package:wmr_core/ble/fake_wmr_bridge.dart';
import 'package:wmr_core/protocol/decoded_record.dart';
import 'package:wmr_core/protocol/gatt.dart';
import 'package:wmr_core/protocol/wmr_fragment.dart';
import 'package:wmr_core/services/controller_service.dart';
import 'package:wmr_ws/wmr_ws.dart';

import 'package:wmr_ble/wmr_ble.dart';
import 'package:wmr_ble/testing.dart';

import '../hid/fake_hid.dart';
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

  test(
    'resuming with no dropped link retries remembered-bridge discovery',
    () async {
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
      var discoveryFails = true;
      final container = ProviderContainer(
        overrides: [
          realTransportProvider.overrideWithValue(transport),
          wifiTransportFactoryProvider.overrideWithValue((_) => wifi),
          knownBridgeStoreProvider.overrideWithValue(store),
          lanDiscoveryProvider.overrideWithValue(() async {
            if (discoveryFails) throw Exception('network down');
            return [
              WmrWsEndpoint(
                host: 'pi.local',
                port: 8765,
                bridgeId: 'pi-bridge',
              ),
            ];
          }),
          streamModeProvider.overrideWith(
            () => TestModeNotifier(StreamMode.raw),
          ),
        ],
      );
      addTearDown(container.dispose);

      final controller = container.read(realDeviceProvider.notifier);
      await controller.launchAutoConnect();
      expect(container.read(realDeviceProvider).connected, isFalse);

      // Discovery recovers while the app is in the background; the resume must
      // look the remembered bridge up again rather than waiting for a tap.
      discoveryFails = false;
      backgroundApp();
      await pump();
      resumeApp();
      await wait(300);

      expect(container.read(realDeviceProvider).connected, isTrue);
      expect(wifi.connectCalls, 1);
    },
  );
}
