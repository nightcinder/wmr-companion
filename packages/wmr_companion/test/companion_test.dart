import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wmr_companion/testing.dart';
import 'package:wmr_companion/wmr_companion.dart';
import 'package:wmr_core/ble/ble_transport.dart' show BleConnectionState;

Future<void> _settle([int millis = 20]) =>
    Future<void>.delayed(Duration(milliseconds: millis));

const _bridge = WmrBridgeDevice(id: fakeBridgeDeviceId, name: 'WMR Bridge');

/// A fake transport whose [connect] can fail a set number of times, to
/// exercise the reconnect schedule without a radio.
class _FlakyTransport extends FakeTransport {
  _FlakyTransport({super.devices});

  int failuresRemaining = 0;
  int connectCalls = 0;
  int ioCalls = 0;

  @override
  Future<void> connect(String deviceId) async {
    connectCalls++;
    if (failuresRemaining > 0) {
      failuresRemaining--;
      throw StateError('radio busy');
    }
    await super.connect(deviceId);
  }

  @override
  Future<Uint8List> read(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
  ) {
    ioCalls++;
    return super.read(deviceId, serviceUuid, characteristicUuid);
  }

  @override
  Future<void> write(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
    Uint8List value, {
    bool withoutResponse = false,
  }) {
    ioCalls++;
    return super.write(
      deviceId,
      serviceUuid,
      characteristicUuid,
      value,
      withoutResponse: withoutResponse,
    );
  }
}

void main() {
  late FakeTransport transport;
  late FakeWmrBridge fakeBridge;
  late WmrCompanion companion;
  final subs = <StreamSubscription<Object?>>[];

  void track(Stream<Object?> stream) => subs.add(stream.listen((_) {}));

  setUp(() {
    transport = FakeTransport(devices: const [fakeBridgeDevice]);
    fakeBridge = FakeWmrBridge(transport);
  });

  tearDown(() async {
    for (final sub in subs) {
      await sub.cancel();
    }
    subs.clear();
    await companion.dispose();
    await transport.dispose();
    fakeBridge.stop();
  });

  test('scan publishes de-duplicated devices, strongest first', () async {
    await transport.dispose();
    transport = FakeTransport(
      devices: const [
        FakeDevice(id: 'weak', name: 'WMR Bridge', rssi: -80),
        FakeDevice(id: 'strong', name: 'WMR Bridge', rssi: -40),
      ],
    );
    companion = WmrCompanion(ble: transport);

    final scans = <List<WmrBridgeDevice>>[];
    companion.bridges.listen(scans.add);
    await companion.startScan();
    await _settle();

    expect(companion.state, WmrConnectionState.idle);
    expect(scans, isNotEmpty);
    expect(scans.last.map((d) => d.id), ['strong', 'weak']);
    expect(scans.last.first.name, 'WMR Bridge');
    expect(scans.last.first.rssi, -40);
  });

  test('connect on FF14 emits controller updates, gamepad and link', () async {
    companion = WmrCompanion(ble: transport);
    final updates = <WmrControllerUpdate>[];
    final pads = <GamepadState>[];
    final links = <WmrLinkSnapshot>[];
    track(companion.controllers);
    companion.controllers.listen(updates.add);
    companion.gamepad.listen(pads.add);
    companion.link.listen(links.add);

    await companion.connect(_bridge);
    expect(companion.state, WmrConnectionState.ready);
    expect(companion.deviceId, fakeBridgeDeviceId);

    for (var i = 0; i < 20; i++) {
      fakeBridge.tick();
    }
    await _settle();

    expect(updates, isNotEmpty);
    final decoded = updates.where((u) => u.decoded != null).toList();
    expect(decoded, isNotEmpty);
    expect(decoded.first.hand, Hand.left);
    expect(decoded.first.stats.records, greaterThan(0));
    expect(decoded.any((u) => u.orientation != null), isTrue);
    expect(decoded.any((u) => u.input != null), isTrue);
    expect(pads, isNotEmpty);
    expect(pads.last.leftConnected, isTrue);
    expect(pads.last.rightConnected, isTrue);

    final snapshot = links.last;
    expect(snapshot.state, WmrConnectionState.ready);
    expect(snapshot.mode, StreamMode.batched);
    expect(snapshot.mtu, 247);
    expect(snapshot.fault, isNull);
  });

  test('raw mode emits frames without parsed input', () async {
    companion = WmrCompanion(
      ble: transport,
      config: const WmrCompanionConfig(streamMode: StreamMode.raw),
    );
    final updates = <WmrControllerUpdate>[];
    companion.controllers.listen(updates.add);

    await companion.connect(_bridge);
    for (var i = 0; i < 5; i++) {
      fakeBridge.tick();
    }
    await _settle();

    expect(updates, isNotEmpty);
    expect(updates.every((u) => u.frame != null), isTrue);
    expect(updates.every((u) => u.decoded == null), isTrue);
    expect(updates.every((u) => u.input == null), isTrue);
    expect(updates.first.stats.frames, greaterThan(0));
  });

  test('a too-small MTU is a typed stream-mode fault', () async {
    await transport.dispose();
    transport = FakeTransport(
      devices: [
        FakeDevice(
          id: fakeBridgeDeviceId,
          name: 'WMR Bridge',
          mtu: 23,
          services: fakeBridgeDevice.services,
        ),
      ],
    );
    fakeBridge = FakeWmrBridge(transport);
    companion = WmrCompanion(ble: transport);
    final failures = <WmrException>[];
    companion.failures.listen(failures.add);

    await expectLater(
      companion.connect(_bridge),
      throwsA(
        isA<WmrStreamModeException>().having(
          (e) => e.kind,
          'kind',
          WmrStreamModeFaultKind.mtuTooSmall,
        ),
      ),
    );
    await _settle();

    expect(companion.state, WmrConnectionState.ready);
    expect(failures, isNotEmpty);
    expect(
      failures.single,
      isA<WmrStreamModeException>().having(
        (e) => e.kind,
        'kind',
        WmrStreamModeFaultKind.mtuTooSmall,
      ),
    );
  });

  test('setStreamMode reports a fault, and none is an accepted mode', () async {
    await transport.dispose();
    transport = FakeTransport(
      devices: [
        FakeDevice(
          id: fakeBridgeDeviceId,
          name: 'WMR Bridge',
          mtu: 30,
          services: fakeBridgeDevice.services,
        ),
      ],
    );
    fakeBridge = FakeWmrBridge(transport);
    companion = WmrCompanion(
      ble: transport,
      config: const WmrCompanionConfig(streamMode: StreamMode.raw),
    );

    await companion.connect(_bridge);
    await expectLater(
      companion.setStreamMode(StreamMode.batched),
      throwsA(isA<WmrStreamModeException>()),
    );
    // FF11 does not need the decoded MTU, so it still enables.
    await companion.setStreamMode(StreamMode.raw);
    await companion.setStreamMode(StreamMode.none);
    expect(companion.config.streamMode, StreamMode.none);
  });

  test('an unexpected disconnect reconnects after the first delay', () async {
    companion = WmrCompanion(ble: transport);
    await companion.connect(_bridge);
    companion.setStickCentre(Hand.left, 0.12, -0.34);
    final states = <WmrConnectionState>[];
    companion.connection.listen(states.add);

    await transport.disconnect(fakeBridgeDeviceId);
    await _settle(700);

    expect(states, contains(WmrConnectionState.reconnecting));
    expect(companion.state, WmrConnectionState.ready);
    expect(companion.deviceId, fakeBridgeDeviceId);
    // The in-session centre survives the new connection, not only the value
    // captured by the first connect() call.
    expect(
      companion.debugControllerService!.decodedStats.hands[0].stickCentre,
      [0.12, -0.34],
    );
  });

  test('a recentred stick is restored after a reconnect', () async {
    companion = WmrCompanion(ble: transport);
    await companion.connect(_bridge);
    for (var i = 0; i < 3; i++) {
      fakeBridge.tick();
    }
    await _settle();

    companion.recentreStick(Hand.left);
    expect(
      companion.debugControllerService!.decodedStats.hands[0].stickLearned,
      isTrue,
    );

    await transport.disconnect(fakeBridgeDeviceId);
    await _settle(700);

    expect(companion.state, WmrConnectionState.ready);
    // The new service starts empty; the facade must restore the centre it
    // recorded from the recentre callback, even without a host listener.
    final stats = companion.debugControllerService!.decodedStats.hands[0];
    expect(stats.stickLearned, isTrue);
  });

  test('dispose closes the link, the facade and is idempotent', () async {
    companion = WmrCompanion(ble: transport);
    await companion.connect(_bridge);
    var closed = false;
    final sub = companion.gamepad.listen((_) {}, onDone: () => closed = true);
    await companion.dispose();
    await _settle();
    expect(closed, isTrue);
    expect(companion.state, WmrConnectionState.idle);
    expect(companion.deviceId, isNull);
    expect(
      await transport.connectionState(fakeBridgeDeviceId).first,
      BleConnectionState.disconnected,
    );
    await companion.dispose();
    await sub.cancel();
  });

  test('FF17 status, read and commands go through the facade', () async {
    companion = WmrCompanion(ble: transport);
    await companion.connect(_bridge);
    final statuses = <ControllerStatusV2>[];
    companion.controllerStatus.listen(statuses.add);

    final initial = await companion.readControllerStatus();
    expect(initial.version, ControllerStatusV2.version1);
    expect(initial.hands.first.connected, isFalse);

    final outcome = await companion.sendControllerCommand(
      ControllerCommand.connect,
      hand: Hand.left,
    );
    expect(outcome.isOk, isTrue);
    await _settle();

    expect(statuses, isNotEmpty);
    expect(statuses.last.lastCommand, ControllerCommand.connect);
    expect(statuses.last.lastResult, ControllerResult.ok);
    final after = await companion.readControllerStatus();
    expect(after.hands.first.connected, isTrue);
  });

  test('readConfig reads a hand block over FF13', () async {
    final blob = Uint8List.fromList([for (var i = 0; i < 64; i++) i]);
    await transport.dispose();
    transport = FakeTransport(devices: const [fakeBridgeDevice]);
    fakeBridge = FakeWmrBridge(transport, configBlobs: [blob, null]);
    companion = WmrCompanion(ble: transport);
    await companion.connect(_bridge);

    final result = await companion.readConfig(Hand.left);
    expect(result.failure, isNull);
    expect(result.blob, blob);
    expect(result.crc, isNotNull);
  });

  test('ping round-trips over FF15 and reuses the subscription', () async {
    companion = WmrCompanion(ble: transport);
    await companion.connect(_bridge);

    final first = await companion.ping();
    expect(first.failure, isNull);
    expect(first.sample, isNotNull);
    expect(first.sample!.answer.pingId, isPositive);

    final second = await companion.ping();
    expect(second.failure, isNull);
  });

  test('default reconnect backoff is 500 ms to 8 s', () {
    expect(const WmrCompanionConfig().reconnectBackoff, const [
      Duration(milliseconds: 500),
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 8),
    ]);
  });

  test(
    'reconnect retries with the configured backoff until it succeeds',
    () async {
      final flaky = _FlakyTransport(devices: const [fakeBridgeDevice]);
      transport = flaky;
      fakeBridge = FakeWmrBridge(flaky);
      companion = WmrCompanion(
        ble: flaky,
        config: const WmrCompanionConfig(
          reconnectBackoff: [
            Duration(milliseconds: 10),
            Duration(milliseconds: 20),
            Duration(milliseconds: 30),
          ],
        ),
      );
      await companion.connect(_bridge);
      expect(flaky.connectCalls, 1);

      final states = <WmrConnectionState>[];
      companion.connection.listen(states.add);
      flaky.failuresRemaining = 2;
      await flaky.disconnect(fakeBridgeDeviceId);
      await _settle(200);

      expect(flaky.connectCalls, 4);
      expect(states, contains(WmrConnectionState.reconnecting));
      expect(companion.state, WmrConnectionState.ready);
      expect(companion.deviceId, fakeBridgeDeviceId);
    },
  );

  test('reconnect reports failed once every backoff attempt is used', () async {
    final flaky = _FlakyTransport(devices: const [fakeBridgeDevice]);
    transport = flaky;
    fakeBridge = FakeWmrBridge(flaky);
    companion = WmrCompanion(
      ble: flaky,
      config: const WmrCompanionConfig(
        reconnectBackoff: [
          Duration(milliseconds: 10),
          Duration(milliseconds: 20),
          Duration(milliseconds: 30),
        ],
      ),
    );
    await companion.connect(_bridge);
    expect(flaky.connectCalls, 1);

    final states = <WmrConnectionState>[];
    companion.connection.listen(states.add);
    flaky.failuresRemaining = 3;
    await flaky.disconnect(fakeBridgeDeviceId);
    await _settle(200);

    expect(flaky.connectCalls, 4);
    expect(
      states.where((state) => state == WmrConnectionState.reconnecting),
      hasLength(3),
    );
    expect(states.last, WmrConnectionState.failed);
    expect(companion.state, WmrConnectionState.failed);
  });

  test('an empty backoff fails without retrying', () async {
    final flaky = _FlakyTransport(devices: const [fakeBridgeDevice]);
    transport = flaky;
    fakeBridge = FakeWmrBridge(flaky);
    companion = WmrCompanion(
      ble: flaky,
      config: const WmrCompanionConfig(reconnectBackoff: []),
    );
    await companion.connect(_bridge);
    final states = <WmrConnectionState>[];
    companion.connection.listen(states.add);

    await flaky.disconnect(fakeBridgeDeviceId);
    await _settle(50);

    expect(flaky.connectCalls, 1);
    expect(states, isNot(contains(WmrConnectionState.reconnecting)));
    expect(companion.state, WmrConnectionState.failed);
  });

  test(
    'controllerStatus is re-subscribed after an automatic reconnect',
    () async {
      companion = WmrCompanion(ble: transport);
      await companion.connect(_bridge);
      final statuses = <ControllerStatusV2>[];
      companion.controllerStatus.listen(statuses.add);
      await _settle();

      await transport.disconnect(fakeBridgeDeviceId);
      await _settle(700);
      expect(companion.state, WmrConnectionState.ready);

      statuses.clear();
      final outcome = await companion.sendControllerCommand(
        ControllerCommand.connect,
        hand: Hand.left,
      );
      expect(outcome.isOk, isTrue);
      await _settle();

      expect(statuses, isNotEmpty);
      expect(statuses.last.lastCommand, ControllerCommand.connect);
    },
  );

  test('an unexpected disconnect discards the session clients', () async {
    final flaky = _FlakyTransport(devices: const [fakeBridgeDevice]);
    transport = flaky;
    fakeBridge = FakeWmrBridge(flaky);
    companion = WmrCompanion(
      ble: flaky,
      config: const WmrCompanionConfig(autoReconnect: false),
    );
    await companion.connect(_bridge);
    await flaky.disconnect(fakeBridgeDeviceId);
    await _settle();
    flaky.ioCalls = 0;

    expect(companion.state, WmrConnectionState.failed);
    expect(() => companion.readConfig(Hand.left), throwsStateError);
    expect(
      () => companion.sendControllerCommand(ControllerCommand.discover),
      throwsStateError,
    );
    await expectLater(companion.readControllerStatus(), throwsStateError);
    await expectLater(companion.ping(), throwsStateError);
    expect(flaky.ioCalls, 0);
  });
}
