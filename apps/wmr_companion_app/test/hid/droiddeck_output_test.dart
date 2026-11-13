import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math_64.dart' show Quaternion, Vector3;
import 'package:wmr_core/ble/fake_transport.dart';
import 'package:wmr_core/ble/fake_wmr_bridge.dart';
import 'package:wmr_core/domain/droiddeck_xr_sink.dart';
import 'package:wmr_core/protocol/decoded_record.dart';
import 'package:wmr_core/protocol/gatt.dart';
import 'package:wmr_core/services/controller_service.dart';
import 'package:wmr_core/services/droiddeck_xr_transport.dart';
import 'package:wmr_tracking/wmr_tracking.dart';
import 'package:wmr_companion_app/hid/droiddeck_output.dart';
import 'package:wmr_companion_app/hid/hid_output.dart';
import 'package:wmr_companion_app/ui/debug/debug_providers.dart';

import 'fake_hid.dart';

Future<void> pump() => Future<void>.delayed(Duration.zero);

DecodedRecord record(int seq, {int hand = 0, int buttons = 0}) => DecodedRecord(
  hand: hand,
  sequence: seq,
  rxTimeUs: seq * 5000,
  deviceTicks: seq * 50000,
  gyro: const [0, 0, 0],
  accel: const [0, 0, 9.8],
  buttons: buttons,
);

class FakeDroidDeckTransport
    implements DroidDeckXrTransport, DroidDeckXrPacketStatsSource {
  final sent = <Uint8List>[];
  bool closed = false;
  bool failSend = false;
  int dropped = 0;

  @override
  DroidDeckXrPacketStats get packetStats => DroidDeckXrPacketStats(
    accepted: sent.length,
    dropped: dropped,
    queued: 0,
  );

  @override
  Future<void> send(Uint8List packet) async {
    if (failSend) {
      throw const DroidDeckXrTransportException('short socket write');
    }
    sent.add(packet);
  }

  @override
  Future<void> close() async => closed = true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeTransport t;
  late ControllerService service;
  late FakeHid hid;
  late FakeDroidDeckTransport droidDeck;
  late StreamController<DebugPoses> poses;
  late ProviderContainer container;

  setUp(() async {
    t = FakeTransport(devices: const [fakeBridgeDevice]);
    service = ControllerService(
      t,
      fakeBridgeDeviceId,
      mode: StreamMode.decoded,
    );
    await service.start();
    hid = FakeHid();
    droidDeck = FakeDroidDeckTransport();
    poses = StreamController<DebugPoses>.broadcast();
    container = ProviderContainer(
      overrides: [
        hidTransportProvider.overrideWithValue(hid),
        controllerServiceProvider(DebugSource.fake).overrideWithValue(service),
        droidDeckTransportFactoryProvider.overrideWithValue(
          () async => droidDeck,
        ),
        debugPosesProvider(DebugSource.fake)
            .overrideWith((ref) => poses.stream),
      ],
    );
    container.read(hidOutputProvider); // build, subscribe to status
    addTearDown(() async {
      container.dispose();
      await poses.close();
      await service.dispose();
      await t.dispose();
    });
  });

  DroidDeckOutput out() => container.read(droidDeckOutputProvider.notifier);
  DroidDeckOutputState state() => container.read(droidDeckOutputProvider);

  void feed(DecodedRecord r) => t.emit(
    fakeBridgeDeviceId,
    wmrBridgeDecodedCharUuid,
    encodeDecodedRecord(r),
  );

  Future<void> startHid() async {
    await container.read(hidOutputProvider.notifier).start(DebugSource.fake);
    hid.calls.clear();
  }

  test('start opens the socket, turns HID off and streams packets', () async {
    await startHid();
    await out().start(DebugSource.fake);
    expect(state().status, DroidDeckStatus.streaming);
    expect(hid.calls, ['stop']);
    expect(droidDeck.sent, isEmpty);

    feed(record(1, buttons: wmrBtnSqueeze));
    await pump();
    expect(state().packetsAccepted, 1);
    expect(state().packetsDropped, 0);
    expect(droidDeck.sent, hasLength(1));
    expect(droidDeck.sent.single, hasLength(DroidDeckXrProtocol.packetBytes));

    await out().stop();
    expect(state().status, DroidDeckStatus.idle);
    expect(droidDeck.closed, isTrue);
    // The flat gamepad comes back because this session turned it off.
    expect(hid.calls, ['stop', 'start']);
    expect(container.read(hidOutputProvider).running, isTrue);
  });

  test('a session that did not touch HID leaves it off', () async {
    await out().start(DebugSource.fake);
    expect(state().status, DroidDeckStatus.streaming);
    await out().stop();
    expect(hid.calls, isEmpty);
    expect(container.read(hidOutputProvider).running, isFalse);
  });

  test('a hand without a tracked position is sent rotation-only', () async {
    await out().start(DebugSource.fake);
    poses.add(
      DebugPoses(
        left: ControllerPose(
          hand: TrackedHand.left,
          hostTimeNs: 1000,
          orientation: Quaternion.identity(),
          position: Vector3(0.25, 1.5, -0.5),
          source: ControllerPoseSource.handAnchor,
        ),
      ),
    );
    await pump();
    feed(record(1));
    feed(record(2, hand: 1));
    await pump();
    expect(state().leftPosition, isTrue);
    expect(state().rightPosition, isFalse);
    final packet = droidDeck.sent.last;
    final data = ByteData.sublistView(packet);
    const e = Endian.little;
    expect(data.getFloat32(56, e), closeTo(0.25, 1e-6));
    expect(data.getFloat32(60, e), closeTo(1.5, 1e-6));
    expect(data.getFloat32(64, e), closeTo(-0.5, 1e-6));
    expect(data.getFloat32(168, e), 0);
    expect(data.getFloat32(172, e), 0);
    expect(data.getFloat32(176, e), 0);
    expect(state().rightPosition, isFalse);
  });

  test(
    'a socket that cannot be opened shows the error and keeps HID',
    () async {
      container.dispose();
      container = ProviderContainer(
        overrides: [
          hidTransportProvider.overrideWithValue(hid),
          controllerServiceProvider(DebugSource.fake)
              .overrideWithValue(service),
          droidDeckTransportFactoryProvider.overrideWithValue(
            () async => throw const DroidDeckXrTransportException(
              'cannot connect to abstract socket "droiddeck-ext-xr"',
            ),
          ),
        ],
      );
      container.read(hidOutputProvider);
      await out().start(DebugSource.fake);
      expect(state().status, DroidDeckStatus.error);
      expect(state().message, contains('droiddeck-ext-xr'));
      expect(hid.calls, isEmpty);
    },
  );

  test('starting the flat gamepad again ends the stream', () async {
    await out().start(DebugSource.fake);
    await container.read(hidOutputProvider.notifier).start(DebugSource.fake);
    await pump();
    expect(state().status, DroidDeckStatus.idle);
    expect(state().message, contains('Bluetooth HID output'));
    expect(droidDeck.closed, isTrue);
  });

  test('a send failure ends the stream and restores HID', () async {
    await startHid();
    await out().start(DebugSource.fake);
    droidDeck.failSend = true;
    feed(record(1));
    await pump();
    await pump();
    expect(state().status, DroidDeckStatus.error);
    expect(state().sendErrors, 1);
    expect(state().message, contains('short socket write'));
    expect(droidDeck.closed, isTrue);
    expect(hid.calls, ['stop', 'start']);
  });

  test('a bridge removal releases that hand', () async {
    await out().start(DebugSource.fake);
    feed(record(1, hand: 1));
    await pump();
    expect(droidDeck.sent, hasLength(1));
    await service.removeDevice(fakeBridgeDeviceId);
    await pump();
    expect(droidDeck.sent, hasLength(2));
    // The released packet reports the right hand as disconnected.
    final data = ByteData.sublistView(droidDeck.sent.last);
    expect(
      data.getUint32(152, Endian.little) & DroidDeckXrProtocol.handConnected,
      0,
    );
  });
}
