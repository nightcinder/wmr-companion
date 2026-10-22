import 'dart:typed_data';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_companion/ble/ble_adapter.dart';
import 'package:wmr_companion/ble/ble_transport.dart';
import 'package:wmr_companion/ble/fake_transport.dart';
import 'package:wmr_companion/ble/fake_wmr_bridge.dart';
import 'package:wmr_companion/ble/universal_ble_transport.dart';
import 'package:wmr_companion/domain/axis_mapping.dart';
import 'package:wmr_companion/domain/hand_pipeline.dart';
import 'package:wmr_companion/domain/synthetic_motion.dart';
import 'package:wmr_companion/protocol/decoded_batch.dart';
import 'package:wmr_companion/protocol/gatt.dart';
import 'package:wmr_companion/services/controller_service.dart';

import '../ble/fake_adapter.dart';

Future<void> pump() => Future<void>.delayed(Duration.zero);

double angleDeg(dynamic a, dynamic b) {
  final d = (a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w).abs();
  return 2 * math.acos(d.clamp(0.0, 1.0)) * 180 / math.pi;
}

void main() {
  late FakeTransport t;
  late ControllerService service;

  Future<void> setUpService({
    StreamMode mode = StreamMode.decoded,
    FakeDevice device = fakeBridgeDevice,
  }) async {
    t = FakeTransport(devices: [device]);
    service = ControllerService(t, fakeBridgeDeviceId, mode: mode);
    await service.start();
  }

  tearDown(() async {
    await service.dispose();
    await t.dispose();
  });

  group('batched stream (FF14) from the fake bridge', () {
    test(
      'subscribes to FF14 only and every record reaches the pipeline',
      () async {
        await setUpService(mode: StreamMode.batched);
        expect(t.cccLog, ['on $wmrBridgeBatchedCharUuid']);

        final left = <DecodedSample>[];
        final right = <DecodedSample>[];
        service.samplesFor(0).listen(left.add);
        service.samplesFor(1).listen(right.add);
        // 100 Hz and a 15 ms hold: a batch every 2 ticks, 4 records each,
        // which is also the most MTU 247 allows.
        final bridge = FakeWmrBridge(t);
        for (var i = 0; i < 100; i++) {
          bridge.tick();
        }
        await pump();

        expect(left, hasLength(100));
        expect(right, hasLength(100));
        final stats = service.decodedStats;
        expect(stats.batches, bridge.batchesSent);
        expect(stats.batches, 50);
        expect(stats.batchRecords, 200);
        expect(stats.batchMax, 4);
        expect(stats.batchMean, 4);
        expect(stats.batchErrors, 0);
        expect(stats.parseErrors, 0);
        for (final h in stats.hands) {
          expect(h.records, 100);
          expect(h.sequenceGaps, 0);
          expect(h.outOfOrder, 0);
          expect(h.missingFromTicks, 0);
          // dt from device ticks, not from the batch arrival time.
          expect(h.dt.p50, closeTo(0.01, 1e-9));
          expect(h.dt.max, closeTo(0.01, 1e-9));
        }
      },
    );

    test('a short hold sends partial batches', () async {
      await setUpService(mode: StreamMode.batched);
      final bridge = FakeWmrBridge(t, batchHold: Duration.zero);
      for (var i = 0; i < 10; i++) {
        bridge.tick();
      }
      await pump();
      final stats = service.decodedStats;
      expect(stats.batches, 10);
      expect(stats.batchMax, 2);
      expect(stats.hands[0].records, 10);
    });

    test('at MTU 517 a batch holds up to 9 records', () async {
      await setUpService(
        mode: StreamMode.batched,
        device: const FakeDevice(
          id: fakeBridgeDeviceId,
          mtu: 517,
          services: [
            BleServiceInfo(
              uuid: wmrBridgeServiceUuid,
              characteristicUuids: [wmrBridgeBatchedCharUuid],
            ),
          ],
        ),
      );
      final bridge = FakeWmrBridge(
        t,
        attMtu: 517,
        batchHold: const Duration(seconds: 1),
      );
      for (var i = 0; i < 45; i++) {
        bridge.tick();
      }
      await pump();
      final stats = service.decodedStats;
      expect(stats.batchMax, 9);
      expect(stats.batches, 10);
      expect(stats.hands[1].records, 45);
    });

    test('lost reports still show as gaps, batching adds none', () async {
      await setUpService(mode: StreamMode.batched);
      final bridge = FakeWmrBridge(
        t,
        dropRecord: (hand, seq) => hand == 1 && seq % 5 == 0,
      );
      for (var i = 0; i < 100; i++) {
        bridge.tick();
      }
      await pump();
      final stats = service.decodedStats;
      expect(stats.hands[0].sequenceGaps, 0);
      // Sequences 5, 10, ..., 100 lost; the last one is not a gap yet.
      expect(stats.hands[1].sequenceGaps, 19);
      expect(stats.hands[1].missingFromTicks, 19);
    });

    test('a malformed batch is counted and nothing is fused', () async {
      await setUpService(mode: StreamMode.batched);
      final got = <DecodedSample>[];
      service.decodedSamples.listen(got.add);
      final good = encodeDecodedBatch([Uint8List(56)..[0] = 1]);
      t.emit(fakeBridgeDeviceId, wmrBridgeBatchedCharUuid, good.sublist(0, 57));
      t.emit(fakeBridgeDeviceId, wmrBridgeBatchedCharUuid, [...good]..[0] = 1);
      // A single FF12 record sent where a batch is expected.
      t.emit(fakeBridgeDeviceId, wmrBridgeBatchedCharUuid, good.sublist(2));
      await pump();
      expect(got, isEmpty);
      expect(service.decodedStats.batchErrors, 3);
      expect(service.decodedStats.batches, 0);
    });

    test('MTU 60 is enough for FF12 but not FF14', () async {
      const device = FakeDevice(
        id: fakeBridgeDeviceId,
        mtu: 60,
        services: [
          BleServiceInfo(
            uuid: wmrBridgeServiceUuid,
            characteristicUuids: [
              wmrBridgeDecodedCharUuid,
              wmrBridgeBatchedCharUuid,
            ],
          ),
        ],
      );
      await setUpService(device: device);
      expect(service.fault, isNull);
      await service.setMode(StreamMode.batched);
      expect(service.fault?.kind, ModeFaultKind.mtuTooSmall);
      expect(service.fault?.message, contains('FF14 needs at least 61'));
    });

    test('switching FF12 to FF14 starts a fresh baseline', () async {
      await setUpService();
      final bridge = FakeWmrBridge(t);
      for (var i = 0; i < 10; i++) {
        bridge.tick();
      }
      await service.setMode(StreamMode.batched);
      for (var i = 0; i < 10; i++) {
        bridge.tick();
      }
      await pump();
      final h = service.decodedStats.hands[0];
      expect(h.sequenceGaps, 0);
      expect(h.outOfOrder, 0);
      expect(t.cccLog.last, 'on $wmrBridgeBatchedCharUuid');
    });
  });

  group('decoded stream from the fake bridge', () {
    test(
      'subscribes to FF12 only and fuses a sample stream per hand',
      () async {
        await setUpService();
        expect(t.cccLog, ['on $wmrBridgeDecodedCharUuid']);

        final left = <DecodedSample>[];
        final right = <DecodedSample>[];
        service.samplesFor(0).listen(left.add);
        service.samplesFor(1).listen(right.add);
        final bridge = FakeWmrBridge(t);
        for (var i = 0; i < 100; i++) {
          bridge.tick();
        }
        await pump();

        expect(left, hasLength(100));
        expect(right, hasLength(100));
        expect(left.first.record.hand, 0);
        expect(right.first.record.hand, 1);
        final stats = service.decodedStats;
        expect(stats.hands[0].records, 100);
        expect(stats.hands[0].sequenceGaps, 0);
        expect(stats.hands[0].missingFromTicks, 0);
        expect(stats.hands[0].discontinuities, 0);
        expect(stats.hands[0].dt.p50, closeTo(0.01, 1e-9));
        expect(stats.hands[0].dt.max, closeTo(0.01, 1e-9));
        expect(stats.hands[0].periodTicks, 100000);
        expect(stats.hands[0].tickClockRatio, closeTo(1.0, 0.01));
        expect(stats.parseErrors, 0);
      },
    );

    test('the fused orientation follows the synthetic motion', () async {
      await setUpService();
      const motion = SyntheticMotion();
      final bridge = FakeWmrBridge(t, motion: motion);
      DecodedSample? last;
      service.samplesFor(0).listen((s) => last = s);
      for (var i = 0; i < 400; i++) {
        bridge.tick();
        await pump();
      }
      // 400 ticks at 100 Hz: the last sample was made at t = 3.99 s.
      final want = motion.at(const Duration(milliseconds: 3990));
      expect(angleDeg(last!.orientation, want), lessThan(4));
    });

    test('flipping an axis in the table changes the result', () async {
      await setUpService();
      service.setMapping(AxisMapping.defaultMapping.withGyroFlip(axisY, true));
      const motion = SyntheticMotion();
      final bridge = FakeWmrBridge(t, motion: motion);
      DecodedSample? last;
      service.samplesFor(0).listen((s) => last = s);
      for (var i = 0; i < 400; i++) {
        bridge.tick();
        await pump();
      }
      final want = motion.at(const Duration(milliseconds: 3990));
      expect(angleDeg(last!.orientation, want), greaterThan(10));
    });

    test('lost reports are counted from sequence and from ticks', () async {
      await setUpService();
      // About half of LEFT's reports are lost, in an irregular pattern (a
      // strictly alternating pattern would make 2 periods look normal).
      bool lost(int seq) => ((seq * 2654435761) >> 9) & 1 == 0;
      final bridge = FakeWmrBridge(
        t,
        dropRecord: (hand, seq) => hand == 0 && lost(seq),
      );
      for (var i = 0; i < 400; i++) {
        bridge.tick();
      }
      await pump();
      final left = service.decodedStats.hands[0];
      final dropped = [
        for (var s = 1; s <= 400; s++)
          if (lost(s)) s,
      ];
      expect(left.records, 400 - dropped.length);
      expect(dropped.length, inInclusiveRange(150, 250));
      // Every number skipped between two received ones is a sequence gap;
      // the ticks must agree because the fake loses nothing else.
      expect(left.sequenceGaps, greaterThan(100));
      expect(left.missingFromTicks, left.sequenceGaps);
      expect(left.periodTicks, 100000);
      // dt carries the real elapsed time: the largest step is several periods.
      expect(left.dt.max, greaterThan(0.02));
      expect(left.dt.p50, greaterThanOrEqualTo(0.01));
      // The right hand lost nothing.
      expect(service.decodedStats.hands[1].missingFromTicks, 0);
    });

    test(
      'device ticks wrapping at 2^32 do not disturb dt or the counts',
      () async {
        await setUpService();
        final bridge = FakeWmrBridge(
          t,
          startTicks: [0xffffffff - 20 * 100000, 0xffffffff - 3 * 100000],
        );
        for (var i = 0; i < 60; i++) {
          bridge.tick();
        }
        await pump();
        for (final h in service.decodedStats.hands) {
          expect(h.discontinuities, 0);
          expect(h.missingFromTicks, 0);
          expect(h.dt.max, closeTo(0.01, 1e-9));
          expect(h.largeDtSkips, 0);
        }
      },
    );

    test('malformed records are counted, not fused', () async {
      await setUpService();
      void emit(List<int> v) =>
          t.emit(fakeBridgeDeviceId, wmrBridgeDecodedCharUuid, v);
      emit(List.filled(55, 0));
      emit(List.filled(57, 0));
      emit([2, ...List.filled(55, 0)]);
      emit([1, 3, ...List.filled(54, 0)]);
      await pump();
      final s = service.decodedStats;
      expect(s.wrongLength, 2);
      expect(s.unknownVersion, 1);
      expect(s.badHand, 1);
      expect(s.hands[0].records + s.hands[1].records, 0);
    });

    test('restarting the service is a new baseline, not a gap', () async {
      await setUpService();
      var away = false;
      final bridge = FakeWmrBridge(t, dropRecord: (_, _) => away);
      for (var i = 0; i < 20; i++) {
        bridge.tick();
      }
      await pump();
      away = true; // numbers and ticks advance, nothing arrives
      for (var i = 0; i < 500; i++) {
        bridge.tick();
      }
      away = false;
      await service.start();
      for (var i = 0; i < 20; i++) {
        bridge.tick();
      }
      await pump();
      final left = service.decodedStats.hands[0];
      expect(left.records, 40);
      expect(left.sequenceGaps, 0);
      expect(left.missingFromTicks, 0);
      expect(left.discontinuities, 0);
    });

    test('packet rate over arrival time', () async {
      final clock = _StepClock();
      t = FakeTransport(devices: [fakeBridgeDevice], clock: clock);
      service = ControllerService(
        t,
        fakeBridgeDeviceId,
        mode: StreamMode.decoded,
      );
      await service.start();
      final bridge = FakeWmrBridge(t);
      for (var i = 0; i < 250; i++) {
        clock.now += 10000; // 100 Hz
        bridge.tick();
      }
      await pump();
      expect(service.decodedStats.hands[0].rateHz, closeTo(100, 2));
      clock.now += 5000000; // silence
      expect(service.decodedStats.hands[0].rateHz, 0);
    });

    test('a small MTU is reported as a fault', () async {
      await setUpService(
        device: const FakeDevice(
          id: fakeBridgeDeviceId,
          name: wmrBridgeDeviceName,
          mtu: 23,
          services: [
            BleServiceInfo(
              uuid: wmrBridgeServiceUuid,
              characteristicUuids: [
                wmrBridgeStreamCharUuid,
                wmrBridgeDecodedCharUuid,
              ],
            ),
          ],
        ),
      );
      expect(service.fault?.kind, ModeFaultKind.mtuTooSmall);
    });

    test('recalibrate and reset yaw reach the hand pipeline', () async {
      await setUpService();
      final bridge = FakeWmrBridge(
        t,
        motion: const SyntheticMotion(yawDriftRadPerS: 0),
      );
      for (var i = 0; i < 10; i++) {
        bridge.tick();
      }
      await pump();
      service.recalibrate(0);
      expect(service.pipeline(0).bias.calibrated, isFalse);
      service.resetYaw(0);
      service.setFilterKind(FilterKind.mahony);
      expect(service.pipeline(1).kind, FilterKind.mahony);
    });
  });

  group('raw stream is unchanged', () {
    test('raw mode subscribes to FF11 and ignores FF12', () async {
      await setUpService(mode: StreamMode.raw);
      expect(t.cccLog, ['on $wmrBridgeStreamCharUuid']);
      final frames = <ReceivedFrame>[];
      service.frames.listen(frames.add);
      FakeWmrBridge(t).tick();
      await pump();
      expect(frames, hasLength(2));
      expect(service.decodedStats.hands[0].records, 0);
    });
  });

  group('mode switch on the real transport', () {
    late FakeAdapter adapter;
    late UniversalBleTransport real;
    late ControllerService svc;

    setUp(() async {
      adapter = FakeAdapter();
      real = UniversalBleTransport(adapter: adapter);
      svc = ControllerService(real, fakeBridgeDeviceId);
      await svc.start();
      await pump();
    });
    tearDown(() async {
      await svc.dispose();
      await real.dispose();
    });

    test('raw to decoded writes 0x0000 to FF11 first', () async {
      await svc.setMode(StreamMode.decoded);
      await pump();
      expect(adapter.ccc, ['on ff11', 'off ff11', 'on ff12']);
      expect(svc.mode, StreamMode.decoded);
      expect(svc.fault, isNull);

      await svc.setMode(StreamMode.raw);
      await pump();
      expect(adapter.ccc.skip(3), ['off ff12', 'on ff11']);
    });

    test('a failed disable is a visible fault and FF12 stays off', () async {
      adapter.disableErrors[wmrBridgeStreamCharUuid] =
          const BleAdapterException('refused');
      final states = <ModeState>[];
      svc.modeChanges.listen(states.add);
      await svc.setMode(StreamMode.decoded);
      await pump();
      expect(svc.fault?.kind, ModeFaultKind.disableFailed);
      expect(states.last.fault, isNotNull);
    });

    test('0x80 on enable is reported as otherStreamActive', () async {
      final fresh = FakeAdapter();
      final tr = UniversalBleTransport(adapter: fresh);
      final s = ControllerService(
        tr,
        fakeBridgeDeviceId,
        mode: StreamMode.decoded,
      );
      await tr.connect(fakeBridgeDeviceId);
      await fresh.enableNotifications(
        fakeBridgeDeviceId,
        wmrBridgeServiceUuid,
        wmrBridgeStreamCharUuid,
      );
      await s.start();
      await pump();
      expect(s.fault?.kind, ModeFaultKind.otherStreamActive);
      expect(tr.status.phase, BleLinkPhase.ready);
      await s.dispose();
      await tr.dispose();
    });

    test('after a reconnect the chosen mode is enabled again', () async {
      await svc.setMode(StreamMode.decoded);
      await pump();
      adapter.dropLink();
      await pump();
      adapter.ccc.clear();
      await svc.start();
      await pump();
      expect(adapter.ccc, ['on ff12']);
      expect(svc.fault, isNull);
    });
  });
}

class _StepClock extends MonotonicClock {
  int now = 0;

  @override
  int get nowUs => now;
}
