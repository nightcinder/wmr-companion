import 'dart:async';

import 'package:test/test.dart';
import 'package:wmr_companion/testing.dart';
import 'package:wmr_companion/wmr_companion.dart';

Future<void> _settle([int millis = 20]) =>
    Future<void>.delayed(Duration(milliseconds: millis));

const _bridge = WmrBridgeDevice(id: fakeBridgeDeviceId, name: 'WMR Bridge');

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

  test('an unexpected disconnect reconnects once', () async {
    companion = WmrCompanion(ble: transport);
    await companion.connect(_bridge);
    final states = <WmrConnectionState>[];
    companion.connection.listen(states.add);

    await transport.disconnect(fakeBridgeDeviceId);
    await _settle(700);

    expect(states, contains(WmrConnectionState.reconnecting));
    expect(companion.state, WmrConnectionState.ready);
    expect(companion.deviceId, fakeBridgeDeviceId);
  });

  test('dispose closes the facade and is idempotent', () async {
    companion = WmrCompanion(ble: transport);
    await companion.connect(_bridge);
    var closed = false;
    final sub = companion.gamepad.listen((_) {}, onDone: () => closed = true);
    await companion.dispose();
    await _settle();
    expect(closed, isTrue);
    expect(companion.state, WmrConnectionState.idle);
    await companion.dispose();
    await sub.cancel();
  });
}
