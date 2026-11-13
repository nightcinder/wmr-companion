import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:vector_math/vector_math_64.dart' as vm;
import 'package:wmr_core/domain/droiddeck_xr_sink.dart';
import 'package:wmr_core/domain/gamepad.dart';
import 'package:wmr_core/domain/hand_pipeline.dart';
import 'package:wmr_core/domain/tick_timer.dart';
import 'package:wmr_core/protocol/decoded_record.dart';
import 'package:wmr_core/services/droiddeck_xr_transport.dart';

const _timeNs = 5000000000;

DecodedSample sample({
  required int hand,
  int buttons = 0,
  int trigger = 0,
  int battery = 0,
  List<int> stick = const [0, 0],
  List<int> trackpad = const [0, 0],
  vm.Quaternion? orientation,
}) => DecodedSample(
  record: DecodedRecord(
    hand: hand,
    sequence: 1,
    rxTimeUs: 0,
    deviceTicks: 0,
    gyro: const [0, 0, 0],
    accel: const [0, 0, 9.8],
    buttons: buttons,
    stick: stick,
    trackpad: trackpad,
    trigger: trigger,
    battery: battery,
  ),
  receivedAtUs: 0,
  step: const TickStep(TickStepKind.step, dtTicks: 1000, dtSeconds: 0.0001),
  orientation: orientation ?? vm.Quaternion.identity(),
  fused: true,
  stick: const [0, 0],
);

class FakeTransport implements DroidDeckXrTransport {
  final sent = <Uint8List>[];
  bool closed = false;

  @override
  Future<void> send(Uint8List packet) async => sent.add(packet);

  @override
  Future<void> close() async => closed = true;
}

class FakePeripheral implements DroidDeckXrHidPeripheral {
  final calls = <String>[];

  @override
  Future<void> disable() async => calls.add('disable');

  @override
  Future<void> restore() async => calls.add('restore');
}

double _f32(Uint8List bytes, int offset) =>
    ByteData.sublistView(bytes).getFloat32(offset, Endian.little);

void main() {
  test('an idle packet has the v0 header and two disconnected hands', () {
    final packet = encodeDroidDeckXrInput(
      sequence: 7,
      timeNs: _timeNs,
      sourceId: 3,
    );
    final d = ByteData.sublistView(packet);

    expect(packet, hasLength(DroidDeckXrProtocol.packetBytes));
    expect(d.getUint32(0, Endian.little), DroidDeckXrProtocol.magic);
    expect(d.getUint32(4, Endian.little), DroidDeckXrProtocol.version);
    expect(d.getUint32(8, Endian.little), 7);
    expect(d.getUint32(12, Endian.little), DroidDeckXrProtocol.headerBytes);
    expect(d.getUint32(16, Endian.little), DroidDeckXrProtocol.flagFocused);
    expect(d.getUint32(20, Endian.little), 3);
    expect(d.getInt64(24, Endian.little), _timeNs);
    expect(d.getUint32(32, Endian.little), 0);
    expect(d.getUint32(40, Endian.little), 0);
    expect(d.getUint32(40 + DroidDeckXrProtocol.handBytes, Endian.little), 0);
  });

  test('a claim carries the device matcher and the token', () {
    final packet = encodeDroidDeckXrClaim(
      claim: const DroidDeckXrClaim(
        vendorId: 0x045e,
        productId: 0x02ea,
        descriptor: 'abc',
        name: 'My Controller',
      ),
      sequence: 2,
      timeNs: _timeNs,
      token: 0x1234,
    );
    final d = ByteData.sublistView(packet);

    expect(packet, hasLength(DroidDeckXrProtocol.claimBytes));
    expect(
      d.getUint32(16, Endian.little),
      DroidDeckXrProtocol.flagPacketClaim | DroidDeckXrProtocol.flagFocused,
    );
    expect(d.getUint32(32, Endian.little), 0x1234);
    expect(d.getUint32(40, Endian.little), 0x045e);
    expect(d.getUint32(44, Endian.little), 0x02ea);
    expect(packet.sublist(56, 60), [0x61, 0x62, 0x63, 0]);
    expect(packet.sublist(120, 124), [0x4d, 0x79, 0x20, 0x43]);
    expect(packet[183], 0);
  });

  test('pipeline and gamepad map to the host hand layout', () {
    final left = sample(
      hand: 0,
      buttons:
          wmrBtnSqueeze |
          wmrBtnThumbstickClick |
          wmrBtnHome |
          wmrBtnTrackpadClick |
          wmrBtnTrackpadTouch,
      battery: 153,
      trackpad: const [16384, -16384],
      orientation: vm.Quaternion.axisAngle(vm.Vector3(0, 1, 0), math.pi / 2),
    );
    final right = sample(hand: 1);
    final gamepad = GamepadState(
      buttons: const {
        GamepadButton.b,
        GamepadButton.l2,
        GamepadButton.r2,
        GamepadButton.r3,
        GamepadButton.guide,
      },
      leftStick: const [0.5, -0.25],
      rightStick: const [0, 0],
      leftTrigger: 0.75,
      rightTrigger: 1,
      leftConnected: true,
      rightConnected: true,
    );

    final packet = encodeDroidDeckXrInput(
      sequence: 0,
      timeNs: _timeNs,
      left: DroidDeckXrHand.fromPipeline(left, gamepad),
      right: DroidDeckXrHand.fromPipeline(
        right,
        gamepad,
        position: const [1, 2, 3],
      ),
    );
    final d = ByteData.sublistView(packet);
    const l = DroidDeckXrProtocol.headerBytes;
    const r = l + DroidDeckXrProtocol.handBytes;

    expect(
      d.getUint32(l, Endian.little),
      DroidDeckXrProtocol.handConnected |
          DroidDeckXrProtocol.handPoseValid |
          DroidDeckXrProtocol.handTrackpad,
    );
    expect(
      d.getUint32(l + 4, Endian.little),
      DroidDeckXrProtocol.buttonTrigger |
          DroidDeckXrProtocol.buttonSqueeze |
          DroidDeckXrProtocol.buttonStick |
          DroidDeckXrProtocol.buttonSystem,
    );
    expect(
      d.getUint32(l + 8, Endian.little),
      DroidDeckXrProtocol.touchTrackpad |
          DroidDeckXrProtocol.touchPrimary |
          DroidDeckXrProtocol.touchTrackpadClick,
    );
    expect(_f32(packet, l + 68), 0.75);
    expect(_f32(packet, l + 72), 1);
    expect(_f32(packet, l + 76), closeTo(0.5, 1e-4));
    expect(_f32(packet, l + 80), closeTo(-0.25, 1e-4));
    expect(_f32(packet, l + 84), closeTo(0.5, 1e-4));
    expect(_f32(packet, l + 88), closeTo(-0.5, 1e-4));
    expect(_f32(packet, l + 92), closeTo(0.6, 1e-4));
    expect(d.getInt64(l + 96, Endian.little), _timeNs);

    expect(
      d.getUint32(r, Endian.little),
      DroidDeckXrProtocol.handConnected |
          DroidDeckXrProtocol.handPoseValid |
          DroidDeckXrProtocol.handStick,
    );
    expect(
      d.getUint32(r + 4, Endian.little),
      DroidDeckXrProtocol.buttonTrigger |
          DroidDeckXrProtocol.buttonStick |
          DroidDeckXrProtocol.buttonSecondary |
          DroidDeckXrProtocol.buttonSystem,
    );
    expect(_f32(packet, r + 16), 1);
    expect(_f32(packet, r + 20), 2);
    expect(_f32(packet, r + 24), 3);
    expect(_f32(packet, r + 68), 1);
  });

  test('the sink claims, disables HID and sends frames while active', () async {
    final transport = FakeTransport();
    final peripheral = FakePeripheral();
    final sink = DroidDeckXrSink(
      transport: transport,
      claim: const DroidDeckXrClaim(
        vendorId: 0x045e,
        productId: 0x02ea,
        descriptor: 'abc',
      ),
      sourceId: 4,
      token: 0x1234,
      clockNs: () => _timeNs,
      hidPeripheral: peripheral,
      claimInterval: Duration.zero,
    );

    await sink.submit(
      left: sample(hand: 0),
      right: null,
      gamepad: const GamepadState(),
    );
    expect(transport.sent, isEmpty, reason: 'nothing before start');

    await sink.start();
    expect(peripheral.calls, ['disable']);
    expect(transport.sent, hasLength(1));
    final claim = ByteData.sublistView(transport.sent.single);
    expect(
      claim.getUint32(16, Endian.little),
      DroidDeckXrProtocol.flagPacketClaim | DroidDeckXrProtocol.flagFocused,
    );
    expect(claim.getInt64(24, Endian.little), _timeNs);

    await sink.submit(
      left: sample(hand: 0),
      right: sample(hand: 1),
      gamepad: const GamepadState(leftConnected: true, rightConnected: true),
    );
    expect(transport.sent, hasLength(2));
    final input = ByteData.sublistView(transport.sent.last);
    expect(input.getUint32(8, Endian.little), 1);
    expect(input.getUint32(20, Endian.little), 4);
    expect(input.getInt64(24, Endian.little), _timeNs);
    expect(input.getUint32(32, Endian.little), 0x1234);
    expect(
      input.getUint32(40, Endian.little),
      DroidDeckXrProtocol.handConnected |
          DroidDeckXrProtocol.handPoseValid |
          DroidDeckXrProtocol.handStick,
    );

    await sink.stop();
    expect(transport.closed, isTrue);
    expect(peripheral.calls, ['disable', 'restore']);
    expect(sink.active, isFalse);
  });

  test('a claim must name at least one matcher', () {
    expect(
      () => encodeDroidDeckXrClaim(
        claim: const DroidDeckXrClaim(),
        sequence: 0,
        timeNs: _timeNs,
      ),
      throwsArgumentError,
    );
  });

  test('the UDP fallback sends the same packet to loopback', () async {
    final server = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(server.close);
    final received = Completer<Uint8List>();
    final subscription = server.listen((event) {
      if (event != RawSocketEvent.read || received.isCompleted) return;
      final datagram = server.receive();
      if (datagram != null) received.complete(datagram.data);
    });
    addTearDown(subscription.cancel);

    final transport = DroidDeckXrUdpTransport(token: 0x1234, port: server.port);
    addTearDown(transport.close);
    final packet = encodeDroidDeckXrInput(
      sequence: 1,
      timeNs: _timeNs,
      token: 0x1234,
    );

    await transport.send(packet);
    final datagram = await received.future.timeout(const Duration(seconds: 2));
    expect(datagram, packet);
  });

  test('the opener falls back to UDP only with a token', () async {
    const name = 'ony-1336-no-such-droiddeck-socket';
    await expectLater(
      openDroidDeckXrTransport(unixSocketName: name),
      throwsA(isA<DroidDeckXrTransportException>()),
    );
    final transport = await openDroidDeckXrTransport(
      udpToken: 0x1234,
      unixSocketName: name,
    );
    expect(transport, isA<DroidDeckXrUdpTransport>());
    await transport.close();
  });
}
