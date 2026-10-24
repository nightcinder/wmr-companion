import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wmr_core/ble/fake_transport.dart';
import 'package:wmr_core/ble/fake_wmr_bridge.dart';
import 'package:wmr_core/protocol/controller_control.dart';
import 'package:wmr_core/services/controller_control_client.dart';

Uint8List statusBytes({
  int leftFlags = 0,
  int leftSource = 0,
  int leftModel = 0,
  List<int> leftTail = const [0, 0, 0],
  int rightFlags = 0,
  int rightSource = 0,
  int rightModel = 0,
  List<int> rightTail = const [0, 0, 0],
  int discoveryState = 0,
  int discoveryRound = 0,
  int lastCommand = 0,
  int lastResult = 0,
}) => Uint8List.fromList([
  1,
  leftFlags,
  leftSource,
  leftModel,
  ...leftTail,
  0,
  rightFlags,
  rightSource,
  rightModel,
  ...rightTail,
  0,
  discoveryState,
  discoveryRound,
  lastCommand,
  lastResult,
  0,
]);

void main() {
  group('encodeControllerCommand', () {
    test('one-byte commands carry only the opcode', () {
      expect(encodeControllerCommand(ControllerCommand.discover), [0x01]);
      expect(encodeControllerCommand(ControllerCommand.forgetAddresses), [
        0x04,
      ]);
    });

    test('hand commands carry the hand', () {
      expect(encodeControllerCommand(ControllerCommand.connect, hand: 1), [
        0x02,
        0x01,
      ]);
      expect(encodeControllerCommand(ControllerCommand.forgetBond, hand: 0), [
        0x05,
        0x00,
      ]);
    });

    test('refuses a missing or out-of-range hand', () {
      expect(
        () => encodeControllerCommand(ControllerCommand.connect),
        throwsArgumentError,
      );
      expect(
        () => encodeControllerCommand(ControllerCommand.disconnect, hand: 2),
        throwsArgumentError,
      );
    });
  });

  group('ControllerStatusV2.parse', () {
    test('decodes both hands, discovery and the last command', () {
      final status = ControllerStatusV2.parse(
        statusBytes(
          leftFlags: 0x05,
          leftSource: 2,
          leftTail: const [0x11, 0x22, 0x33],
          rightFlags: 0x02,
          rightModel: 1,
          discoveryState: 1,
          discoveryRound: 3,
          lastCommand: 0x02,
          lastResult: 0x01,
        ),
      );
      expect(status, isNotNull);
      expect(status!.version, 1);
      expect(status.hands[0].connected, isTrue);
      expect(status.hands[0].descriptorReceived, isTrue);
      expect(status.hands[0].connecting, isFalse);
      expect(status.hands[0].addressSource, ControllerAddressSource.stored);
      expect(status.hands[0].addressTail, [0x11, 0x22, 0x33]);
      expect(status.hands[0].hasAddress, isTrue);
      expect(status.hands[1].connected, isFalse);
      expect(status.hands[1].connecting, isTrue);
      expect(status.hands[1].model, ControllerModel.psvr2);
      expect(status.discoveryState, ControllerDiscoveryState.inquiry);
      expect(status.discoveryRound, 3);
      expect(status.lastCommand, ControllerCommand.connect);
      expect(status.lastResult, ControllerResult.busy);
    });

    test('a short value is rejected, not guessed', () {
      expect(ControllerStatusV2.parse(Uint8List(19)), isNull);
    });
  });

  group('ControllerControlClient', () {
    late FakeTransport transport;
    late ControllerControlClient client;

    setUp(() async {
      transport = FakeTransport(devices: const [fakeBridgeDevice]);
      FakeWmrBridge(transport, discoveryDuration: Duration.zero);
      await transport.connect(fakeBridgeDeviceId);
      client = ControllerControlClient(transport, fakeBridgeDeviceId);
    });

    tearDown(() => transport.dispose());

    test('finds FF17 and reads the initial status', () async {
      expect(await client.isSupported(), isTrue);
      final status = await client.readStatus();
      expect(status.discoveryState, ControllerDiscoveryState.idle);
      expect(status.hands.every((h) => h.connected), isFalse);
    });

    test('connect and disconnect a hand', () async {
      expect(
        (await client.send(ControllerCommand.connect, hand: 0)).isOk,
        isTrue,
      );
      var status = await client.readStatus();
      expect(status.hands[0].connected, isTrue);
      expect(status.lastCommand, ControllerCommand.connect);

      expect(
        (await client.send(ControllerCommand.disconnect, hand: 0)).isOk,
        isTrue,
      );
      status = await client.readStatus();
      expect(status.hands[0].connected, isFalse);
    });

    test('forget addresses is refused while a hand is connected', () async {
      await client.send(ControllerCommand.connect, hand: 1);
      final outcome = await client.send(ControllerCommand.forgetAddresses);
      expect(outcome.isOk, isFalse);
      expect(outcome.result, ControllerResult.busy);
      expect(outcome.error, isNotNull);
    });

    test('forget addresses clears stored tails once both are idle', () async {
      final outcome = await client.send(ControllerCommand.forgetAddresses);
      expect(outcome.isOk, isTrue);
      final status = await client.readStatus();
      expect(status.hands[0].hasAddress, isFalse);
      expect(status.hands[1].hasAddress, isFalse);
      expect(status.hands[0].addressSource, ControllerAddressSource.none);
    });

    test('discovery runs and finishes with stored addresses', () async {
      expect((await client.send(ControllerCommand.discover)).isOk, isTrue);
      expect(
        (await client.readStatus()).discoveryState,
        ControllerDiscoveryState.idle,
      );
    });

    test('status notifications reach a subscriber', () async {
      final values = <ControllerStatusV2>[];
      final sub = client.statusStream().listen(values.add);
      await Future<void>.delayed(Duration.zero);
      await client.send(ControllerCommand.connect, hand: 0);
      await Future<void>.delayed(Duration.zero);
      expect(values, isNotEmpty);
      expect(values.last.hands[0].connected, isTrue);
      await sub.cancel();
    });

    test('a link drop is not reported as the previous ok result', () async {
      final failing = _WriteFailingTransport(devices: const [fakeBridgeDevice]);
      FakeWmrBridge(failing, discoveryDuration: Duration.zero);
      await failing.connect(fakeBridgeDeviceId);
      addTearDown(failing.dispose);
      final outcome = await ControllerControlClient(
        failing,
        fakeBridgeDeviceId,
      ).send(ControllerCommand.discover);
      expect(outcome.isOk, isFalse);
      expect(outcome.result, isNull);
      expect(outcome.error, isNotNull);
    });
  });
}

/// Accepts reads but refuses every write, like a link that dropped between
/// the status read and the command write.
class _WriteFailingTransport extends FakeTransport {
  _WriteFailingTransport({required super.devices});

  @override
  Future<void> write(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
    Uint8List value, {
    bool withoutResponse = false,
  }) async {
    throw StateError('link dropped');
  }
}
