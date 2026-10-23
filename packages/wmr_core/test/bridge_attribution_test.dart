import 'dart:convert';

import 'package:test/test.dart';
import 'package:wmr_core/ble/ble_transport.dart';
import 'package:wmr_core/ble/fake_transport.dart';
import 'package:wmr_core/ble/fake_wmr_bridge.dart';
import 'package:wmr_core/domain/hand_pipeline.dart';
import 'package:wmr_core/protocol/wmr_fragment.dart';
import 'package:wmr_core/services/controller_service.dart';
import 'package:wmr_core/services/latency_recorder.dart';

class _Clock implements MonotonicClock {
  int now = 1000000;

  @override
  int get nowUs => now;
}

void main() {
  late _Clock clock;
  late FakeTransport transport;
  late FakeWmrBridge left;
  late FakeWmrBridge right;
  late ControllerService service;

  setUp(() {
    clock = _Clock();
    transport = FakeTransport(
      devices: const [fakeBridgeLeftDevice, fakeBridgeRightDevice],
      clock: clock,
    );
    left = FakeWmrBridge(
      transport,
      deviceId: fakeBridgeLeftDeviceId,
      hands: const [wmrHandLeft],
    );
    right = FakeWmrBridge(
      transport,
      deviceId: fakeBridgeRightDeviceId,
      hands: const [wmrHandRight],
    );
  });

  tearDown(() async {
    left.stop();
    right.stop();
    await service.dispose();
    await transport.dispose();
  });

  Future<void> tickBoth(int count) async {
    for (var i = 0; i < count; i++) {
      clock.now += 10000;
      left.tick();
      right.tick();
    }
    await Future<void>.delayed(Duration.zero);
  }

  test('raw frames carry the bridge id and stats split per bridge', () async {
    service = ControllerService(transport, [
      fakeBridgeLeftDeviceId,
      fakeBridgeRightDeviceId,
    ], mode: StreamMode.raw);
    await service.start();

    final frames = <ReceivedFrame>[];
    final sub = service.frames.listen(frames.add);
    await tickBoth(3);

    expect(frames, hasLength(6));
    expect(
      frames
          .where((f) => f.frame.hand == wmrHandLeft)
          .map((f) => f.bridgeId)
          .toSet(),
      {fakeBridgeLeftDeviceId},
    );
    expect(
      frames
          .where((f) => f.frame.hand == wmrHandRight)
          .map((f) => f.bridgeId)
          .toSet(),
      {fakeBridgeRightDeviceId},
    );

    final stats = service.stats;
    expect(stats.byBridge.keys, {
      fakeBridgeLeftDeviceId,
      fakeBridgeRightDeviceId,
    });
    expect(
      stats.byBridge[fakeBridgeLeftDeviceId]!.hands[wmrHandLeft].frames,
      3,
    );
    expect(
      stats.byBridge[fakeBridgeLeftDeviceId]!.hands[wmrHandRight].frames,
      0,
    );
    expect(
      stats.byBridge[fakeBridgeRightDeviceId]!.hands[wmrHandRight].frames,
      3,
    );
    expect(
      stats.byBridge[fakeBridgeLeftDeviceId]!.hands[wmrHandLeft].bridgeId,
      fakeBridgeLeftDeviceId,
    );
    // The merged view still counts both hands.
    expect(stats.hands[wmrHandLeft].frames, 3);
    expect(stats.hands[wmrHandRight].frames, 3);
    expect(stats.hands[wmrHandLeft].bridgeId, isNull);
    expect(stats.errors, 0);

    await sub.cancel();
  });

  test(
    'decoded samples carry the bridge id and loss stays per bridge',
    () async {
      service = ControllerService(transport, [
        fakeBridgeLeftDeviceId,
        fakeBridgeRightDeviceId,
      ], mode: StreamMode.decoded);
      await service.start();

      final samples = <DecodedSample>[];
      final sub = service.decodedSamples.listen(samples.add);
      await tickBoth(120);

      expect(samples, hasLength(240));
      expect(
        samples
            .where((s) => s.record.hand == wmrHandLeft)
            .map((s) => s.bridgeId)
            .toSet(),
        {fakeBridgeLeftDeviceId},
      );

      final stats = service.decodedStats;
      final leftStats = stats.byBridge[fakeBridgeLeftDeviceId]!;
      final rightStats = stats.byBridge[fakeBridgeRightDeviceId]!;
      expect(leftStats.hands[wmrHandLeft].records, 120);
      expect(leftStats.hands[wmrHandLeft].sequenceGaps, 0);
      expect(leftStats.hands[wmrHandRight].records, 0);
      expect(rightStats.hands[wmrHandRight].records, 120);
      expect(rightStats.hands[wmrHandLeft].records, 0);

      final links = await service.bridgeLinks();
      expect(links.map((l) => l.bridgeId), [
        fakeBridgeLeftDeviceId,
        fakeBridgeRightDeviceId,
      ]);
      final leftLink = links.first;
      final rightLink = links.last;
      expect(leftLink.mtu, fakeBridgeLeftDevice.mtu);
      expect(leftLink.rssi, fakeBridgeLeftDevice.rssi);
      expect(leftLink.rateHz[wmrHandLeft], greaterThan(0));
      expect(leftLink.loss[wmrHandLeft], 0);
      expect(leftLink.loss[wmrHandRight], isNull);
      expect(rightLink.rateHz[wmrHandRight], greaterThan(0));
      expect(rightLink.loss[wmrHandRight], 0);
      expect(rightLink.loss[wmrHandLeft], isNull);

      await sub.cancel();
    },
  );

  test(
    'one bridge losing a report does not move the other bridge loss',
    () async {
      service = ControllerService(transport, [
        fakeBridgeLeftDeviceId,
        fakeBridgeRightDeviceId,
      ], mode: StreamMode.decoded);
      await service.start();

      // Replace the LEFT bridge with one dropping report 30.
      left.stop();
      await service.removeDevice(fakeBridgeLeftDeviceId);
      final droppingLeft = FakeWmrBridge(
        transport,
        deviceId: fakeBridgeLeftDeviceId,
        hands: const [wmrHandLeft],
        dropRecord: (hand, seq) => seq == 30,
      );
      addTearDown(droppingLeft.stop);
      await service.addDevice(fakeBridgeLeftDeviceId);

      for (var i = 0; i < 60; i++) {
        clock.now += 10000;
        droppingLeft.tick();
        right.tick();
      }
      await Future<void>.delayed(Duration.zero);

      final stats = service.decodedStats;
      final leftStats = stats.byBridge[fakeBridgeLeftDeviceId]!;
      final rightStats = stats.byBridge[fakeBridgeRightDeviceId]!;
      expect(leftStats.hands[wmrHandLeft].records, 59);
      expect(leftStats.hands[wmrHandLeft].sequenceGaps, 1);
      expect(leftStats.hands[wmrHandLeft].missingFromTicks, 1);
      expect(rightStats.hands[wmrHandRight].records, 60);
      expect(rightStats.hands[wmrHandRight].missingFromTicks, 0);

      final links = await service.bridgeLinks();
      final leftLink = links.firstWhere(
        (l) => l.bridgeId == fakeBridgeLeftDeviceId,
      );
      final rightLink = links.firstWhere(
        (l) => l.bridgeId == fakeBridgeRightDeviceId,
      );
      expect(leftLink.loss[wmrHandLeft], closeTo(1 / 60, 1e-9));
      expect(rightLink.loss[wmrHandRight], 0);
    },
  );

  test('latency rows and hand summaries record the bridge', () {
    final recorder = LatencyRecorder(
      started: DateTime(2026, 10, 23, 12),
      originUs: 1000000,
      stream: 'decoded',
    );
    recorder.addRecord(
      wmrHandLeft,
      1,
      1000000,
      deviceTicks: 0,
      espRxUs: 0,
      bridgeId: fakeBridgeLeftDeviceId,
    );
    recorder.addRecord(
      wmrHandLeft,
      2,
      1005000,
      deviceTicks: 50000,
      espRxUs: 5000,
      bridgeId: fakeBridgeLeftDeviceId,
    );
    recorder.addRecord(
      wmrHandRight,
      1,
      1000000,
      deviceTicks: 0,
      espRxUs: 0,
      bridgeId: fakeBridgeRightDeviceId,
    );
    final report = recorder.report(
      nowUs: 2000000,
      links: const {
        fakeBridgeLeftDeviceId: LatencyLink(mtu: 247, rssiStart: -40),
        fakeBridgeRightDeviceId: LatencyLink(mtu: 247, rssiStart: -55),
      },
    );

    expect(report.hands[wmrHandLeft].bridgeId, fakeBridgeLeftDeviceId);
    expect(report.hands[wmrHandLeft].bridgeRecords, {
      fakeBridgeLeftDeviceId: 2,
    });
    expect(report.hands[wmrHandRight].bridgeId, fakeBridgeRightDeviceId);
    expect(report.links.keys, {
      fakeBridgeLeftDeviceId,
      fakeBridgeRightDeviceId,
    });

    final json = jsonDecode(report.toJsonString()) as Map<String, Object?>;
    expect(json['version'], 3);
    expect(json['link'], {
      fakeBridgeLeftDeviceId: {
        'mtu': 247,
        'rssi_start_dbm': -40,
        'rssi_end_dbm': null,
        'connection_interval_us': null,
        'phy': null,
        'high_priority_requested': null,
      },
      fakeBridgeRightDeviceId: {
        'mtu': 247,
        'rssi_start_dbm': -55,
        'rssi_end_dbm': null,
        'connection_interval_us': null,
        'phy': null,
        'high_priority_requested': null,
      },
    });
    final hands = json['hands'] as List<Object?>;
    expect((hands.first as Map)['bridge_id'], fakeBridgeLeftDeviceId);
    expect((hands.last as Map)['bridge_id'], fakeBridgeRightDeviceId);
    expect(recorder.rows.first.bridgeId, fakeBridgeLeftDeviceId);
  });
}
