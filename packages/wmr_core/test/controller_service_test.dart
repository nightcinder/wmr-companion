import 'package:test/test.dart';
import 'package:wmr_core/ble/fake_transport.dart';
import 'package:wmr_core/ble/fake_wmr_bridge.dart';
import 'package:wmr_core/domain/imu_calibration.dart';
import 'package:wmr_core/protocol/config_decode.dart';
import 'package:wmr_core/protocol/controller_control.dart';
import 'package:wmr_core/protocol/decoded_record.dart';
import 'package:wmr_core/protocol/gatt.dart';
import 'package:wmr_core/protocol/wmr_fragment.dart';
import 'package:wmr_core/services/controller_service.dart';

void main() {
  late FakeTransport t;
  late ControllerService service;

  setUp(() async {
    t = FakeTransport(devices: const [fakeBridgeDevice]);
    service = ControllerService(t, fakeBridgeDeviceId);
    await service.start();
  });

  tearDown(() async {
    await service.dispose();
    await t.dispose();
  });

  for (final mtu in [23, 61, 247]) {
    test('fake bridge frames reassemble at MTU $mtu', () async {
      final frames = <ReceivedFrame>[];
      service.frames.listen(frames.add);
      final bridge = FakeWmrBridge(t, attMtu: mtu);
      for (var i = 0; i < 10; i++) {
        bridge.tick();
      }
      await Future<void>.delayed(Duration.zero);

      expect(frames, hasLength(20));
      expect(frames.first.frame, syntheticFrame(0, 1));
      final stats = service.stats;
      for (final h in stats.hands) {
        expect(h.frames, 10);
        expect(h.lastSequence, 10);
        expect(h.gaps, 0);
        expect(h.incomplete, 0);
      }
      expect(stats.errors, 0);
    });
  }

  void send(int hand, int seq) {
    for (final f in encodeFrame(syntheticFrame(hand, seq), 244)) {
      t.emit(fakeBridgeDeviceId, wmrBridgeStreamCharUuid, f);
    }
  }

  test('counts sequence gaps and out-of-order frames per hand', () async {
    send(0, 1);
    send(0, 2);
    send(0, 6); // 3 missing
    send(0, 6); // duplicate
    send(1, 0xffffffff);
    send(1, 0); // wrap, no gap
    await Future<void>.delayed(Duration.zero);

    final s = service.stats;
    expect(s.hands[0].gaps, 3);
    expect(s.hands[0].outOfOrder, 1);
    expect(s.hands[1].gaps, 0);
    expect(s.hands[1].outOfOrder, 0);
    expect(s.hands[1].lastSequence, 0);
  });

  test('FF13 calibration is applied only when the switch is on', () {
    final cal = _calibration();
    expect(service.pipeline(0).calibration, isNull);

    service.setFf13Calibration(0, cal, apply: false);
    expect(service.pipeline(0).calibration, isNull);

    service.setFf13Calibration(0, cal, apply: true);
    expect(service.pipeline(0).calibration, same(cal));
    expect(service.pipeline(1).calibration, isNull);

    service.setFf13Calibration(0, cal, apply: false);
    expect(service.pipeline(0).calibration, isNull);
  });

  test('none turns the active stream off and enables nothing', () async {
    expect(t.cccLog, ['on $wmrBridgeStreamCharUuid']);
    await service.setMode(StreamMode.none);
    expect(service.mode, StreamMode.none);
    expect(t.cccLog, [
      'on $wmrBridgeStreamCharUuid',
      'off $wmrBridgeStreamCharUuid',
    ]);

    await service.setMode(StreamMode.decoded);
    expect(service.mode, StreamMode.decoded);
    expect(t.cccLog.last, 'on $wmrBridgeDecodedCharUuid');
  });

  test('a Switch hand spaces a 3-sample burst and does not call it out of '
      'order', () async {
    await service.setMode(StreamMode.decoded);
    expect(service.controllerModel(0), ControllerModel.wmr);
    service.setControllerModel(0, ControllerModel.nintendoSwitch);
    expect(service.controllerModel(0), ControllerModel.nintendoSwitch);

    // One 0x30 report: three samples, one sequence, one packet time.
    for (var i = 0; i < 3; i++) {
      t.emit(
        fakeBridgeDeviceId,
        wmrBridgeDecodedCharUuid,
        encodeDecodedRecord(
          DecodedRecord(
            hand: 0,
            sequence: 3,
            rxTimeUs: 1000,
            deviceTicks: 9000,
            gyro: const [0, 0, 0],
            accel: const [0, 0, 9.8],
          ),
        ),
      );
    }
    await Future<void>.delayed(Duration.zero);

    final hand = service.decodedStats.hands[0];
    expect(hand.records, 3);
    expect(hand.outOfOrder, 0);
    expect(hand.sequenceGaps, 0);
    expect(hand.dt.count, 2);
    expect(hand.dt.p50, closeTo(0.005, 1e-9));
  });

  test('a bridge without FF10 is unavailable, not still reading', () async {
    final other = FakeTransport(
      devices: const [FakeDevice(id: 'not-a-bridge', services: [])],
    );
    final otherService = ControllerService(other, 'not-a-bridge');
    await otherService.start();
    await Future<void>.delayed(Duration.zero);

    final link = await otherService.bridgeLink('not-a-bridge');
    expect(link.protocol, isNull);
    expect(link.protocolUnavailable, isTrue);

    await otherService.dispose();
    await other.dispose();
  });
}

ImuCalibration _calibration() {
  InertialSensorCalibration sensor(InertialSensorType type) =>
      InertialSensorCalibration(
        type: type,
        typeName: type == InertialSensorType.gyro
            ? 'CALIBRATION_InertialSensorType_Gyro'
            : 'CALIBRATION_InertialSensorType_Accelerometer',
        rotation: const [1, 0, 0, 0, 1, 0, 0, 0, 1],
        translation: const [0, 0, 0],
        mixMatrix: const [1, 0, 0, 0, 1, 0, 0, 0, 1],
        bias: const [0, 0, 0],
        biasUncertainty: const [0, 0, 0],
        noise: const [0, 0, 0],
      );
  return ImuCalibration.fromSensors(
    accel: sensor(InertialSensorType.accelerometer),
    gyro: sensor(InertialSensorType.gyro),
  );
}
