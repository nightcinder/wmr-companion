import 'dart:async';

import 'package:test/test.dart';
import 'package:vector_math/vector_math_64.dart';
import 'package:wmr_core/ble/fake_transport.dart';
import 'package:wmr_core/ble/fake_wmr_bridge.dart';
import 'package:wmr_core/domain/hand_pipeline.dart';
import 'package:wmr_core/protocol/gatt.dart';
import 'package:wmr_core/protocol/wmr_fragment.dart';
import 'package:wmr_core/services/controller_service.dart';

void main() {
  late FakeTransport transport;
  late FakeWmrBridge bridgeLeft;
  late FakeWmrBridge bridgeRight;
  late ControllerService service;

  setUp(() {
    transport = FakeTransport(
      devices: [fakeBridgeLeftDevice, fakeBridgeRightDevice],
    );
    bridgeLeft = FakeWmrBridge(
      transport,
      deviceId: fakeBridgeLeftDeviceId,
      hands: [wmrHandLeft],
    );
    bridgeRight = FakeWmrBridge(
      transport,
      deviceId: fakeBridgeRightDeviceId,
      hands: [wmrHandRight],
    );
  });

  tearDown(() async {
    bridgeLeft.stop();
    bridgeRight.stop();
    await service.dispose();
    await transport.dispose();
  });

  group('dual-bridge raw streaming (FF11)', () {
    test(
      'subscribes to both bridges and merges frames into shared hand pipelines',
      () async {
        service = ControllerService(transport, [
          fakeBridgeLeftDeviceId,
          fakeBridgeRightDeviceId,
        ], mode: StreamMode.raw);
        await service.start();

        expect(service.deviceIds, [
          fakeBridgeLeftDeviceId,
          fakeBridgeRightDeviceId,
        ]);
        expect(
          transport.isSubscribed(
            fakeBridgeLeftDeviceId,
            wmrBridgeStreamCharUuid,
          ),
          isTrue,
        );
        expect(
          transport.isSubscribed(
            fakeBridgeRightDeviceId,
            wmrBridgeStreamCharUuid,
          ),
          isTrue,
        );

        final receivedFrames = <ReceivedFrame>[];
        final sub = service.frames.listen(receivedFrames.add);

        // Tick each bridge
        bridgeLeft.tick();
        bridgeRight.tick();
        bridgeLeft.tick();
        bridgeRight.tick();

        await Future<void>.delayed(Duration.zero);

        expect(receivedFrames.length, 4);
        expect(
          receivedFrames.where((f) => f.frame.hand == wmrHandLeft).length,
          2,
        );
        expect(
          receivedFrames.where((f) => f.frame.hand == wmrHandRight).length,
          2,
        );

        final stats = service.stats;
        expect(stats.hands[wmrHandLeft].frames, 2);
        expect(stats.hands[wmrHandRight].frames, 2);
        expect(stats.hands[wmrHandLeft].gaps, 0);
        expect(stats.hands[wmrHandRight].gaps, 0);

        await sub.cancel();
      },
    );
  });

  group('dual-bridge decoded streaming (FF12)', () {
    test(
      'fuses orientation for both hands concurrently from separate bridges',
      () async {
        service = ControllerService(transport, [
          fakeBridgeLeftDeviceId,
          fakeBridgeRightDeviceId,
        ], mode: StreamMode.decoded);
        await service.start();

        expect(
          transport.isSubscribed(
            fakeBridgeLeftDeviceId,
            wmrBridgeDecodedCharUuid,
          ),
          isTrue,
        );
        expect(
          transport.isSubscribed(
            fakeBridgeRightDeviceId,
            wmrBridgeDecodedCharUuid,
          ),
          isTrue,
        );

        final leftSamples = <DecodedSample>[];
        final rightSamples = <DecodedSample>[];
        final subLeft = service.samplesFor(wmrHandLeft).listen(leftSamples.add);
        final subRight = service
            .samplesFor(wmrHandRight)
            .listen(rightSamples.add);

        for (var i = 0; i < 50; i++) {
          bridgeLeft.tick();
          bridgeRight.tick();
        }

        await Future<void>.delayed(Duration.zero);

        expect(leftSamples.length, 50);
        expect(rightSamples.length, 50);

        // Verify orientation updated on both pipelines
        final qLeft = service.pipeline(wmrHandLeft).orientation;
        final qRight = service.pipeline(wmrHandRight).orientation;
        expect(qLeft, isNot(equals(Quaternion.identity())));
        expect(qRight, isNot(equals(Quaternion.identity())));

        // Stats track each hand independently
        final dStats = service.decodedStats;
        expect(dStats.hands[wmrHandLeft].records, 50);
        expect(dStats.hands[wmrHandRight].records, 50);
        expect(dStats.hands[wmrHandLeft].sequenceGaps, 0);
        expect(dStats.hands[wmrHandRight].sequenceGaps, 0);

        await subLeft.cancel();
        await subRight.cancel();
      },
    );
  });

  group('dual-bridge batched streaming (FF14)', () {
    test(
      'unpacks batches from both bridges and merges into hand pipelines',
      () async {
        service = ControllerService(transport, [
          fakeBridgeLeftDeviceId,
          fakeBridgeRightDeviceId,
        ], mode: StreamMode.batched);
        await service.start();

        expect(
          transport.isSubscribed(
            fakeBridgeLeftDeviceId,
            wmrBridgeBatchedCharUuid,
          ),
          isTrue,
        );
        expect(
          transport.isSubscribed(
            fakeBridgeRightDeviceId,
            wmrBridgeBatchedCharUuid,
          ),
          isTrue,
        );

        final samples = <DecodedSample>[];
        final sub = service.decodedSamples.listen(samples.add);

        // At MTU 517, a batch holds up to 9 records. Tick 10 times to flush.
        for (var i = 0; i < 10; i++) {
          bridgeLeft.tick();
          bridgeRight.tick();
        }

        await Future<void>.delayed(Duration.zero);

        expect(samples.length, greaterThanOrEqualTo(18));
        expect(samples.any((s) => s.record.hand == wmrHandLeft), isTrue);
        expect(samples.any((s) => s.record.hand == wmrHandRight), isTrue);

        final dStats = service.decodedStats;
        expect(dStats.batches, greaterThanOrEqualTo(2));
        expect(dStats.hands[wmrHandLeft].records, 10);
        expect(dStats.hands[wmrHandRight].records, 10);

        await sub.cancel();
      },
    );
  });

  group('dual-bridge mode switching', () {
    test(
      'switches stream mode across all connected bridges synchronously',
      () async {
        service = ControllerService(transport, [
          fakeBridgeLeftDeviceId,
          fakeBridgeRightDeviceId,
        ], mode: StreamMode.raw);
        await service.start();

        expect(
          transport.isSubscribed(
            fakeBridgeLeftDeviceId,
            wmrBridgeStreamCharUuid,
          ),
          isTrue,
        );
        expect(
          transport.isSubscribed(
            fakeBridgeRightDeviceId,
            wmrBridgeStreamCharUuid,
          ),
          isTrue,
        );

        // Switch to decoded
        await service.setMode(StreamMode.decoded);

        expect(
          transport.isSubscribed(
            fakeBridgeLeftDeviceId,
            wmrBridgeStreamCharUuid,
          ),
          isFalse,
        );
        expect(
          transport.isSubscribed(
            fakeBridgeRightDeviceId,
            wmrBridgeStreamCharUuid,
          ),
          isFalse,
        );
        expect(
          transport.isSubscribed(
            fakeBridgeLeftDeviceId,
            wmrBridgeDecodedCharUuid,
          ),
          isTrue,
        );
        expect(
          transport.isSubscribed(
            fakeBridgeRightDeviceId,
            wmrBridgeDecodedCharUuid,
          ),
          isTrue,
        );

        // Switch to batched
        await service.setMode(StreamMode.batched);

        expect(
          transport.isSubscribed(
            fakeBridgeLeftDeviceId,
            wmrBridgeDecodedCharUuid,
          ),
          isFalse,
        );
        expect(
          transport.isSubscribed(
            fakeBridgeRightDeviceId,
            wmrBridgeDecodedCharUuid,
          ),
          isFalse,
        );
        expect(
          transport.isSubscribed(
            fakeBridgeLeftDeviceId,
            wmrBridgeBatchedCharUuid,
          ),
          isTrue,
        );
        expect(
          transport.isSubscribed(
            fakeBridgeRightDeviceId,
            wmrBridgeBatchedCharUuid,
          ),
          isTrue,
        );

        // Switch to none
        await service.setMode(StreamMode.none);

        expect(
          transport.isSubscribed(
            fakeBridgeLeftDeviceId,
            wmrBridgeBatchedCharUuid,
          ),
          isFalse,
        );
        expect(
          transport.isSubscribed(
            fakeBridgeRightDeviceId,
            wmrBridgeBatchedCharUuid,
          ),
          isFalse,
        );
      },
    );
  });

  group('dynamic bridge join and leave', () {
    test('adding a second bridge connects it and merges into stream; removing cleanly disconnects', () async {
      // Start with only Left bridge
      service = ControllerService(
        transport,
        fakeBridgeLeftDeviceId,
        mode: StreamMode.decoded,
      );
      await service.start();

      expect(service.deviceIds, [fakeBridgeLeftDeviceId]);
      expect(
        transport.isSubscribed(
          fakeBridgeLeftDeviceId,
          wmrBridgeDecodedCharUuid,
        ),
        isTrue,
      );
      expect(
        transport.isSubscribed(
          fakeBridgeRightDeviceId,
          wmrBridgeDecodedCharUuid,
        ),
        isFalse,
      );

      final samples = <DecodedSample>[];
      final sub = service.decodedSamples.listen(samples.add);

      bridgeLeft.tick();
      await Future<void>.delayed(Duration.zero);
      expect(samples.length, 1);
      expect(samples.last.record.hand, wmrHandLeft);

      // Dynamically add Right bridge
      await service.addDevice(fakeBridgeRightDeviceId);

      expect(service.deviceIds, [
        fakeBridgeLeftDeviceId,
        fakeBridgeRightDeviceId,
      ]);
      expect(
        transport.isSubscribed(
          fakeBridgeRightDeviceId,
          wmrBridgeDecodedCharUuid,
        ),
        isTrue,
      );

      bridgeRight.tick();
      await Future<void>.delayed(Duration.zero);
      expect(samples.length, 2);
      expect(samples.last.record.hand, wmrHandRight);

      // Dynamically remove Left bridge
      await service.removeDevice(fakeBridgeLeftDeviceId);

      expect(service.deviceIds, [fakeBridgeRightDeviceId]);
      expect(
        transport.isSubscribed(
          fakeBridgeLeftDeviceId,
          wmrBridgeDecodedCharUuid,
        ),
        isFalse,
      );
      expect(
        transport.isSubscribed(
          fakeBridgeRightDeviceId,
          wmrBridgeDecodedCharUuid,
        ),
        isTrue,
      );

      // Right bridge continues streaming
      bridgeRight.tick();
      await Future<void>.delayed(Duration.zero);
      expect(samples.length, 3);
      expect(samples.last.record.hand, wmrHandRight);

      await sub.cancel();
    });

    test('failed addDevice rolls back deviceId and does not poison service state', () async {
      service = ControllerService(
        transport,
        fakeBridgeLeftDeviceId,
        mode: StreamMode.decoded,
      );
      await service.start();

      expect(service.deviceIds, [fakeBridgeLeftDeviceId]);

      // Attempting to add a device not recognized by the transport throws StateError.
      await expectLater(
        service.addDevice('non-existent-bridge'),
        throwsA(isA<StateError>()),
      );

      // The poisoned ID must be rolled back from ControllerService._deviceIds.
      expect(service.deviceIds, [fakeBridgeLeftDeviceId]);

      // A subsequent mode switch must succeed cleanly without throwing on the failed device.
      await service.setMode(StreamMode.raw);
      expect(service.mode, StreamMode.raw);
      expect(
        transport.isSubscribed(fakeBridgeLeftDeviceId, wmrBridgeStreamCharUuid),
        isTrue,
      );
    });

    test('addDevice validates MTU for carriesRecords mode and raises mtuTooSmall fault if below minimum', () async {
      transport.addDevice(
        FakeDevice(
          id: 'bridge-low-mtu',
          mtu: 23,
          services: fakeBridgeDevice.services,
        ),
      );

      service = ControllerService(
        transport,
        fakeBridgeLeftDeviceId,
        mode: StreamMode.decoded,
      );
      await service.start();
      expect(service.fault, isNull);

      // Dynamically add a second bridge whose MTU is below wmrDecodedMinMtu (64)
      await service.addDevice('bridge-low-mtu');

      expect(service.fault, isNotNull);
      expect(service.fault!.kind, ModeFaultKind.mtuTooSmall);
      expect(service.modeState.fault?.kind, ModeFaultKind.mtuTooSmall);
    });

    test('re-adding a bridge for an already-seen hand resets baselines and does not report false gaps or dt spikes', () async {
      service = ControllerService(
        transport,
        fakeBridgeLeftDeviceId,
        mode: StreamMode.decoded,
      );
      await service.start();

      // Left bridge streams 5 records (sequences 1 to 5)
      for (var i = 0; i < 5; i++) {
        bridgeLeft.tick();
      }
      await Future<void>.delayed(Duration.zero);

      final initialStats = service.decodedStats.hands[wmrHandLeft];
      expect(initialStats.records, 5);
      expect(initialStats.sequenceGaps, 0);
      expect(initialStats.outOfOrder, 0);
      expect(service.pipeline(wmrHandLeft).largeDtSkips, 0);

      // Disconnect and remove Left bridge
      await service.removeDevice(fakeBridgeLeftDeviceId);

      // Add a replacement Left bridge with sequence 1 and a new clock
      const replacementLeftId = 'bridge-left-replacement';
      transport.addDevice(
        FakeDevice(
          id: replacementLeftId,
          mtu: 247,
          services: fakeBridgeDevice.services,
        ),
      );
      final bridgeLeft2 = FakeWmrBridge(
        transport,
        deviceId: replacementLeftId,
        hands: [wmrHandLeft],
      );

      await service.addDevice(replacementLeftId);

      // Replacement bridge sends records starting at sequence 1
      for (var i = 0; i < 5; i++) {
        bridgeLeft2.tick();
      }
      await Future<void>.delayed(Duration.zero);

      final updatedStats = service.decodedStats.hands[wmrHandLeft];
      expect(updatedStats.records, 10);
      // Baselines were reset, so sequence 1 does NOT count as a gap or out-of-order:
      expect(updatedStats.sequenceGaps, 0);
      expect(updatedStats.outOfOrder, 0);
      // Nor does it cause large dt skips:
      expect(service.pipeline(wmrHandLeft).largeDtSkips, 0);

      bridgeLeft2.stop();
    });

    test(
      'one bridge dropping leaves other bridge streaming without interruption',
      () async {
        service = ControllerService(transport, [
          fakeBridgeLeftDeviceId,
          fakeBridgeRightDeviceId,
        ], mode: StreamMode.decoded);
        await service.start();

        final samples = <DecodedSample>[];
        final sub = service.decodedSamples.listen(samples.add);

        bridgeLeft.tick();
        bridgeRight.tick();
        await Future<void>.delayed(Duration.zero);

        expect(samples.length, 2);

        // Left bridge drops
        await transport.disconnect(fakeBridgeLeftDeviceId);

        // Right bridge continues streaming
        bridgeRight.tick();
        bridgeRight.tick();
        await Future<void>.delayed(Duration.zero);

        expect(samples.length, 4);
        expect(samples[2].record.hand, wmrHandRight);
        expect(samples[3].record.hand, wmrHandRight);
        expect(service.decodedStats.hands[wmrHandRight].records, 3);

        // Mode switch while one bridge is dropped: must succeed and subscribe remaining bridge
        await service.setMode(StreamMode.raw);
        expect(service.mode, StreamMode.raw);
        expect(
          transport.isSubscribed(
            fakeBridgeRightDeviceId,
            wmrBridgeStreamCharUuid,
          ),
          isTrue,
        );

        // Switch back to decoded mode
        await service.setMode(StreamMode.decoded);
        expect(service.mode, StreamMode.decoded);

        // Reconnecting the dropped bridge: must reconnect, resubscribe and merge streams
        await service.addDevice(fakeBridgeLeftDeviceId);
        expect(
          transport.isSubscribed(
            fakeBridgeLeftDeviceId,
            wmrBridgeDecodedCharUuid,
          ),
          isTrue,
        );

        bridgeLeft.tick();
        bridgeRight.tick();
        await Future<void>.delayed(Duration.zero);

        expect(samples.length, 6);
        expect(samples[4].record.hand, wmrHandLeft);
        expect(samples[5].record.hand, wmrHandRight);

        await sub.cancel();
      },
    );
  });
}
