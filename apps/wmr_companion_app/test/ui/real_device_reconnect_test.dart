import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_companion_app/hid/hid_output.dart';
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
    await controller.connectWifi(host: 'pi.local', port: 8765);
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
}
