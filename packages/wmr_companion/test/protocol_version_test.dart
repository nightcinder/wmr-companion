import 'dart:async';

import 'package:test/test.dart';
import 'package:wmr_companion/testing.dart';
import 'package:wmr_companion/wmr_companion.dart';
import 'package:wmr_core/ble/ble_transport.dart' show BleServiceInfo;
import 'package:wmr_core/protocol/gatt.dart';

const _legacyBridgeId = 'legacy-wmr-bridge';

/// A bridge from before FF13/FF14/FF15/FF16: only the stream characteristics.
const _legacyBridge = FakeDevice(
  id: _legacyBridgeId,
  name: 'WMR Bridge',
  services: [
    BleServiceInfo(
      uuid: wmrBridgeServiceUuid,
      characteristicUuids: [wmrBridgeStreamCharUuid, wmrBridgeDecodedCharUuid],
    ),
  ],
);

Future<void> _settle([int millis = 20]) =>
    Future<void>.delayed(Duration(milliseconds: millis));

void main() {
  late FakeTransport transport;
  late FakeWmrBridge fakeBridge;
  late WmrCompanion companion;
  final subs = <StreamSubscription<Object?>>[];

  void track(Stream<Object?> stream) => subs.add(stream.listen((_) {}));

  setUp(() {
    transport = FakeTransport(devices: const [fakeBridgeDevice]);
    fakeBridge = FakeWmrBridge(transport);
    companion = WmrCompanion(ble: transport);
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

  test('a bridge with FF16 publishes its version and feature matrix', () async {
    final links = <WmrLinkSnapshot>[];
    final updates = <WmrControllerUpdate>[];
    track(companion.controllers);
    companion.link.listen(links.add);
    companion.controllers.listen(updates.add);

    await companion.connect(
      const WmrBridgeDevice(id: fakeBridgeDeviceId, name: 'WMR Bridge'),
    );
    await _settle();

    final protocol = links.last.protocol;
    expect(protocol, isNotNull);
    expect(protocol!.firmwareVersion, 'fake-1.0.0');
    expect(protocol.hasFirmwareVersion, isTrue);
    expect(protocol.firmwareVersionMalformed, isFalse);
    final features = protocol.features;
    expect(features.rawStream, isTrue);
    expect(features.decodedStream, isTrue);
    expect(features.batchedStream, isTrue);
    expect(features.configBlock, isTrue);
    expect(features.echo, isTrue);
    expect(features.firmwareVersion, isTrue);
    expect(
      transport.reads.where((read) => read.endsWith(wmrBridgeVersionCharUuid)),
      hasLength(1),
    );

    // The read is informational: the stream was never gated on it.
    for (var i = 0; i < 20; i++) {
      fakeBridge.tick();
    }
    await _settle();
    expect(updates, isNotEmpty);
    expect(links.last.state, WmrConnectionState.ready);
  });

  test('a bridge without FF16 is an older firmware, not a failure', () async {
    await transport.dispose();
    transport = FakeTransport(devices: const [_legacyBridge]);
    fakeBridge = FakeWmrBridge(transport, deviceId: _legacyBridgeId);
    companion = WmrCompanion(ble: transport);
    final links = <WmrLinkSnapshot>[];
    final failures = <WmrException>[];
    final updates = <WmrControllerUpdate>[];
    companion.link.listen(links.add);
    companion.failures.listen(failures.add);
    companion.controllers.listen(updates.add);

    await companion.connect(
      const WmrBridgeDevice(id: _legacyBridgeId, name: 'WMR Bridge'),
    );
    await _settle();

    final protocol = links.last.protocol;
    expect(protocol, isNotNull);
    expect(protocol!.firmwareVersion, isNull);
    expect(protocol.hasFirmwareVersion, isFalse);
    expect(protocol.firmwareVersionMalformed, isFalse);
    expect(protocol.features.rawStream, isTrue);
    expect(protocol.features.decodedStream, isTrue);
    expect(protocol.features.batchedStream, isFalse);
    expect(protocol.features.firmwareVersion, isFalse);
    expect(
      transport.reads.where((read) => read.endsWith(wmrBridgeVersionCharUuid)),
      isEmpty,
    );
    expect(failures, isEmpty);
    expect(companion.state, WmrConnectionState.ready);

    for (var i = 0; i < 20; i++) {
      fakeBridge.tick();
    }
    await _settle();
    expect(updates, isNotEmpty);
  });

  test('a malformed FF16 value is flagged and never fatal', () async {
    await transport.dispose();
    transport = FakeTransport(devices: const [fakeBridgeDevice]);
    fakeBridge = FakeWmrBridge(
      transport,
      firmwareVersionBytes: const [0xff, 0xfe, 0xfd],
    );
    companion = WmrCompanion(ble: transport);
    final links = <WmrLinkSnapshot>[];
    final failures = <WmrException>[];
    final updates = <WmrControllerUpdate>[];
    companion.link.listen(links.add);
    companion.failures.listen(failures.add);
    companion.controllers.listen(updates.add);

    await companion.connect(
      const WmrBridgeDevice(id: fakeBridgeDeviceId, name: 'WMR Bridge'),
    );
    await _settle();

    final protocol = links.last.protocol;
    expect(protocol, isNotNull);
    expect(protocol!.firmwareVersion, isNull);
    expect(protocol.firmwareVersionMalformed, isTrue);
    expect(protocol.features.firmwareVersion, isTrue);
    expect(failures, isEmpty);
    expect(companion.state, WmrConnectionState.ready);

    for (var i = 0; i < 20; i++) {
      fakeBridge.tick();
    }
    await _settle();
    expect(updates, isNotEmpty);
  });

  test(
    'a failed FF16 read leaves the version unknown and the link up',
    () async {
      await transport.dispose();
      transport = FakeTransport(devices: const [fakeBridgeDevice]);
      fakeBridge = FakeWmrBridge(transport, firmwareVersion: null);
      companion = WmrCompanion(ble: transport);
      final links = <WmrLinkSnapshot>[];
      final failures = <WmrException>[];
      companion.link.listen(links.add);
      companion.failures.listen(failures.add);

      await companion.connect(
        const WmrBridgeDevice(id: fakeBridgeDeviceId, name: 'WMR Bridge'),
      );
      await _settle();

      final protocol = links.last.protocol;
      expect(protocol, isNotNull);
      expect(protocol!.firmwareVersion, isNull);
      expect(protocol.firmwareVersionMalformed, isFalse);
      expect(protocol.features.firmwareVersion, isTrue);
      expect(failures, isEmpty);
      expect(companion.state, WmrConnectionState.ready);
    },
  );

  test('the FF16 read does not delay connect or the stream', () async {
    final onRead = transport.onRead!;
    final readStarted = Completer<void>();
    transport.onRead = (deviceId, characteristicUuid) async {
      if (characteristicUuid.toLowerCase() == wmrBridgeVersionCharUuid) {
        readStarted.complete();
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
      return onRead(deviceId, characteristicUuid);
    };
    final updates = <WmrControllerUpdate>[];
    companion.controllers.listen(updates.add);

    await companion.connect(
      const WmrBridgeDevice(id: fakeBridgeDeviceId, name: 'WMR Bridge'),
    );
    expect(companion.state, WmrConnectionState.ready);
    expect(companion.protocol, isNull);
    await readStarted.future;

    for (var i = 0; i < 20; i++) {
      fakeBridge.tick();
    }
    await _settle(20);
    expect(updates, isNotEmpty);
    expect(companion.protocol, isNull);

    await _settle(160);
    expect(companion.protocol?.firmwareVersion, 'fake-1.0.0');
  });

  test(
    'the version is read once per connect, not on every link tick',
    () async {
      await companion.connect(
        const WmrBridgeDevice(id: fakeBridgeDeviceId, name: 'WMR Bridge'),
      );
      await _settle();
      int ff16Reads() => transport.reads
          .where((read) => read.endsWith(wmrBridgeVersionCharUuid))
          .length;
      expect(ff16Reads(), 1);

      await _settle(1200);
      expect(ff16Reads(), 1);
    },
  );
}
