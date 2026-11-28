import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math_64.dart' show Quaternion, Vector3;
import 'package:wmr_core/ble/ble_transport.dart';
import 'package:wmr_core/ble/fake_transport.dart';
import 'package:wmr_core/ble/fake_wmr_bridge.dart';
import 'package:wmr_core/domain/droiddeck_xr_sink.dart';
import 'package:wmr_core/protocol/decoded_batch.dart';
import 'package:wmr_core/protocol/decoded_record.dart';
import 'package:wmr_core/protocol/gatt.dart';
import 'package:wmr_core/services/controller_service.dart';
import 'package:wmr_core/services/droiddeck_xr_queued_transport.dart';
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

class _StepClock implements MonotonicClock {
  _StepClock(this.nowUs);

  @override
  int nowUs;
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

  test(
    'the real factory with no token refuses and names the untaken fallback',
    () async {
      final plain = ProviderContainer();
      addTearDown(plain.dispose);
      await expectLater(
        plain.read(droidDeckTransportFactoryProvider)(),
        throwsA(
          isA<DroidDeckXrTransportException>().having(
            (e) => e.message,
            'message',
            contains('was not tried because no pairing token is set'),
          ),
        ),
      );
      expect(plain.read(droidDeckTokenProvider), isNull);
    },
  );

  test(
    'the real factory reads the token when invoked, not when built',
    () async {
      final plain = ProviderContainer();
      addTearDown(plain.dispose);
      // Build the factory before any token exists: a build-time read would
      // refuse exactly like the no-token test above.
      final open = plain.read(droidDeckTransportFactoryProvider);
      plain.read(droidDeckTokenProvider.notifier).state = 12648430;
      final transport = await open();
      addTearDown(transport.close);
      // The abstract socket has no listener here, so the token is what makes
      // the open succeed through the loopback UDP fallback.
      expect(transport, isA<DroidDeckXrQueuedTransport>());
    },
  );

  test('a token edit while streaming reaches only the next start', () async {
    final opened = <int?>[];
    final stream = StreamController<DebugPoses>.broadcast();
    final tokenContainer = ProviderContainer(
      overrides: [
        hidTransportProvider.overrideWithValue(hid),
        controllerServiceProvider(DebugSource.fake).overrideWithValue(service),
        droidDeckTransportFactoryProvider.overrideWith((ref) {
          return () async {
            opened.add(ref.read(droidDeckTokenProvider));
            return droidDeck;
          };
        }),
        debugPosesProvider(DebugSource.fake)
            .overrideWith((ref) => stream.stream),
      ],
    );
    addTearDown(() async {
      tokenContainer.dispose();
      await stream.close();
    });

    tokenContainer.read(droidDeckTokenProvider.notifier).state = 1;
    final output = tokenContainer.read(droidDeckOutputProvider.notifier);
    await output.start(DebugSource.fake);
    expect(opened, [1]);

    // Mid-stream, the edit is visible only to the factory; start() is the
    // only reader, and nothing restarts the transport for it.
    tokenContainer.read(droidDeckTokenProvider.notifier).state = 2;
    feed(record(1));
    await pump();
    expect(
      tokenContainer.read(droidDeckOutputProvider).status,
      DroidDeckStatus.streaming,
    );
    expect(opened, [1]);

    await output.stop();
    await output.start(DebugSource.fake);
    expect(opened, [1, 2]);
    await output.stop();
  });

  group('DroidDeckOutput sampleTimeNs monotonicity', () {
    void expectMonotonic(List<Uint8List> packets) {
      var prevLeft = 0;
      var prevRight = 0;
      for (final packet in packets) {
        final d = ByteData.sublistView(packet);
        if ((d.getUint32(16, Endian.little) &
                DroidDeckXrProtocol.flagPacketClaim) !=
            0) {
          continue;
        }
        final headerTimeNs = d.getInt64(24, Endian.little);
        final leftNs = d.getInt64(
          DroidDeckXrProtocol.headerBytes + 96,
          Endian.little,
        );
        final rightNs = d.getInt64(
          DroidDeckXrProtocol.headerBytes + DroidDeckXrProtocol.handBytes + 96,
          Endian.little,
        );
        expect(leftNs, greaterThan(0));
        expect(rightNs, greaterThan(0));
        expect(leftNs, greaterThan(prevLeft));
        expect(rightNs, greaterThan(prevRight));
        expect(
          leftNs,
          greaterThanOrEqualTo(headerTimeNs - droidDeckMaxSampleAgeNs),
        );
        expect(
          rightNs,
          greaterThanOrEqualTo(headerTimeNs - droidDeckMaxSampleAgeNs),
        );
        expect(leftNs, lessThanOrEqualTo(headerTimeNs));
        expect(rightNs, lessThanOrEqualTo(headerTimeNs));
        prevLeft = leftNs;
        prevRight = rightNs;
      }
    }

    test('FF14 batches and idle hand stay strictly monotonic', () async {
      var nowNs = 5000000000;
      final clock = _StepClock(1000000);
      final batchedTransport = FakeTransport(
        devices: const [fakeBridgeDevice],
        clock: clock,
      );
      final batchedService = ControllerService(
        batchedTransport,
        fakeBridgeDeviceId,
        mode: StreamMode.batched,
      );
      await batchedService.start();
      addTearDown(() async {
        await batchedService.dispose();
        await batchedTransport.dispose();
      });

      final c = ProviderContainer(
        overrides: [
          hidTransportProvider.overrideWithValue(hid),
          controllerServiceProvider(DebugSource.fake)
              .overrideWithValue(batchedService),
          droidDeckTransportFactoryProvider.overrideWithValue(
            () async => droidDeck,
          ),
          droidDeckClockNsProvider.overrideWithValue(() => nowNs += 1000),
          debugPosesProvider(DebugSource.fake)
              .overrideWith((ref) => poses.stream),
        ],
      );
      addTearDown(c.dispose);
      c.read(hidOutputProvider);

      await c.read(droidDeckOutputProvider.notifier).start(DebugSource.fake);

      // Emit an FF14 batch of 4 left records sharing one arrival time, then
      // another batch with an idle right hand.
      final batch1 = encodeDecodedBatch([
        encodeDecodedRecord(record(1, hand: 0)),
        encodeDecodedRecord(record(1, hand: 1)),
        encodeDecodedRecord(record(2, hand: 0)),
        encodeDecodedRecord(record(3, hand: 0)),
      ]);
      nowNs += 5000000;
      clock.nowUs += 5000;
      batchedTransport.emit(
        fakeBridgeDeviceId,
        wmrBridgeBatchedCharUuid,
        batch1,
      );
      await pump();

      final batch2 = encodeDecodedBatch([
        encodeDecodedRecord(record(4, hand: 0)),
        encodeDecodedRecord(record(5, hand: 0)),
      ]);
      nowNs += 10000000;
      clock.nowUs += 10000;
      batchedTransport.emit(
        fakeBridgeDeviceId,
        wmrBridgeBatchedCharUuid,
        batch2,
      );
      await pump();

      expect(droidDeck.sent, hasLength(6));
      expectMonotonic(droidDeck.sent);
      await c.read(droidDeckOutputProvider.notifier).stop();
    });

    test('transport switch (WebSocket -> BLE -> WebSocket) and stop/restart stay strictly monotonic', () async {
      var nowNs = 5000000000;
      final wsClock = _StepClock(100000000);
      final bleClock = _StepClock(1000000);
      final wsTransport = FakeTransport(
        devices: const [fakeBridgeDevice],
        clock: wsClock,
      );
      final bleTransport = FakeTransport(
        devices: const [fakeBridgeDevice],
        clock: bleClock,
      );
      final wsService = ControllerService(
        wsTransport,
        fakeBridgeDeviceId,
        mode: StreamMode.decoded,
      );
      final bleService = ControllerService(
        bleTransport,
        fakeBridgeDeviceId,
        mode: StreamMode.decoded,
      );
      await wsService.start();
      await bleService.start();
      addTearDown(() async {
        await wsService.dispose();
        await bleService.dispose();
        await wsTransport.dispose();
        await bleTransport.dispose();
      });

      final activeServiceProvider = StateProvider<ControllerService?>(
        (ref) => wsService,
      );
      final c = ProviderContainer(
        overrides: [
          hidTransportProvider.overrideWithValue(hid),
          controllerServiceProvider(DebugSource.fake)
              .overrideWith((ref) => ref.watch(activeServiceProvider)),
          droidDeckTransportFactoryProvider.overrideWithValue(
            () async => droidDeck,
          ),
          droidDeckClockNsProvider.overrideWithValue(() => nowNs += 1000),
          debugPosesProvider(DebugSource.fake)
              .overrideWith((ref) => poses.stream),
        ],
      );
      addTearDown(c.dispose);
      c.read(hidOutputProvider);

      final output = c.read(droidDeckOutputProvider.notifier);
      await output.start(DebugSource.fake);

      // Phase 1: WebSocket clock (~100 s).
      nowNs += 5000000;
      wsClock.nowUs += 5000;
      wsTransport.emit(
        fakeBridgeDeviceId,
        wmrBridgeDecodedCharUuid,
        encodeDecodedRecord(record(1, hand: 0)),
      );
      await pump();

      // Phase 2: Switch to BLE clock (~1 s).
      nowNs += 50000000;
      bleClock.nowUs += 50000;
      c.read(activeServiceProvider.notifier).state = bleService;
      await pump();
      nowNs += 5000000;
      bleClock.nowUs += 5000;
      bleTransport.emit(
        fakeBridgeDeviceId,
        wmrBridgeDecodedCharUuid,
        encodeDecodedRecord(record(2, hand: 0)),
      );
      await pump();

      // Phase 3: Switch back to WebSocket clock (~100.1 s).
      nowNs += 50000000;
      wsClock.nowUs += 105000;
      c.read(activeServiceProvider.notifier).state = wsService;
      await pump();
      nowNs += 5000000;
      wsClock.nowUs += 5000;
      wsTransport.emit(
        fakeBridgeDeviceId,
        wmrBridgeDecodedCharUuid,
        encodeDecodedRecord(record(3, hand: 0)),
      );
      await pump();

      // Phase 4: Stop and restart DroidDeckOutput.
      await output.stop();
      nowNs += 50000000;
      wsClock.nowUs += 50000;
      await output.start(DebugSource.fake);
      nowNs += 5000000;
      wsClock.nowUs += 5000;
      wsTransport.emit(
        fakeBridgeDeviceId,
        wmrBridgeDecodedCharUuid,
        encodeDecodedRecord(record(4, hand: 0)),
      );
      await pump();

      expect(droidDeck.sent.length, greaterThanOrEqualTo(4));
      expectMonotonic(droidDeck.sent);
      await output.stop();
    });
  });
}
