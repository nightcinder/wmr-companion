import 'package:test/test.dart';
import 'package:wmr_core/ble/ble_transport.dart';
import 'package:wmr_core/ble/fake_transport.dart';
import 'package:wmr_core/ble/fake_wmr_bridge.dart';
import 'package:wmr_core/protocol/gatt.dart';
import 'package:wmr_core/protocol/wmr_fragment.dart';
import 'package:wmr_core/services/controller_service.dart';

/// The shipped defaults are a 3 s silence threshold checked every 500 ms; the
/// tests scale both down so the suite stays fast.
const _check = Duration(milliseconds: 20);
const _timeout = Duration(milliseconds: 300);

Future<void> waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

void main() {
  late FakeTransport transport;
  late ControllerService service;

  setUp(() {
    transport = FakeTransport(devices: const [fakeBridgeDevice]);
    service = ControllerService(
      transport,
      fakeBridgeDeviceId,
      stallInterval: _check,
      stallTimeout: _timeout,
    );
  });

  tearDown(() async {
    await service.dispose();
    await transport.dispose();
  });

  void sendFrame(int hand, int sequence) {
    for (final fragment in encodeFrame(syntheticFrame(hand, sequence), 244)) {
      transport.emit(fakeBridgeDeviceId, wmrBridgeStreamCharUuid, fragment);
    }
  }

  test('a silent bridge is marked stalled after the threshold', () async {
    final events = <BridgeStallState>[];
    final sub = service.stallChanges.listen(events.add);
    addTearDown(sub.cancel);

    await service.start();
    await waitFor(() => events.any((event) => event.stalled));

    final link = await service.bridgeLink(fakeBridgeDeviceId);
    expect(link.stalled, isTrue);
    expect(link.silentFor, isNotNull);
    expect(
      link.silentFor!.inMilliseconds,
      greaterThanOrEqualTo(_timeout.inMilliseconds),
    );

    // One event per transition: later checks at the same state stay quiet.
    await Future<void>.delayed(_check * 3);
    expect(events.where((event) => event.stalled), hasLength(1));
    expect(events.single.bridgeId, fakeBridgeDeviceId);
  });

  test('a resumed record clears the stall', () async {
    final events = <BridgeStallState>[];
    final sub = service.stallChanges.listen(events.add);
    addTearDown(sub.cancel);

    await service.start();
    await waitFor(() => events.any((event) => event.stalled));
    expect((await service.bridgeLink(fakeBridgeDeviceId)).stalled, isTrue);

    sendFrame(wmrHandLeft, 1);
    await waitFor(() => events.any((event) => !event.stalled));

    final resumed = events.lastWhere((event) => !event.stalled);
    expect(resumed.bridgeId, fakeBridgeDeviceId);
    expect(
      resumed.silentFor!.inMilliseconds,
      lessThan(_timeout.inMilliseconds),
    );

    final link = await service.bridgeLink(fakeBridgeDeviceId);
    expect(link.stalled, isFalse);
    expect(link.silentFor!.inMilliseconds, lessThan(_timeout.inMilliseconds));
  });

  test('a real disconnect is reported disconnected, not stalled', () async {
    final events = <BridgeStallState>[];
    final sub = service.stallChanges.listen(events.add);
    addTearDown(sub.cancel);

    await service.start();
    await waitFor(() => events.any((event) => event.stalled));

    await transport.disconnect(fakeBridgeDeviceId);
    await waitFor(() => events.any((event) => !event.stalled));
    expect(
      await transport.connectionState(fakeBridgeDeviceId).first,
      BleConnectionState.disconnected,
    );

    // Well past the threshold: a link that is down has no silence to call a
    // stall, so the mark must not come back.
    await Future<void>.delayed(_timeout * 2);
    expect(events.where((event) => event.stalled), hasLength(1));

    final link = await service.bridgeLink(fakeBridgeDeviceId);
    expect(link.stalled, isFalse);
    expect(link.silentFor, isNull);
  });

  test('an ordinary slow gap stays below the threshold', () async {
    final events = <BridgeStallState>[];
    final sub = service.stallChanges.listen(events.add);
    addTearDown(sub.cancel);

    await service.start();
    // 200 Hz would be 5 ms per frame; this hands the service one frame per
    // third of the threshold instead.
    for (var sequence = 1; sequence <= 6; sequence++) {
      sendFrame(wmrHandLeft, sequence);
      await Future<void>.delayed(_timeout ~/ 3);
    }

    expect(events.where((event) => event.stalled), isEmpty);
    final link = await service.bridgeLink(fakeBridgeDeviceId);
    expect(link.stalled, isFalse);
    expect(link.silentFor!.inMilliseconds, lessThan(_timeout.inMilliseconds));
  });
}
