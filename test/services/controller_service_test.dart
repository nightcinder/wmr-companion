import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_companion/ble/fake_transport.dart';
import 'package:wmr_companion/ble/fake_wmr_bridge.dart';
import 'package:wmr_companion/domain/imu_calibration.dart';
import 'package:wmr_companion/protocol/config_decode.dart';
import 'package:wmr_companion/protocol/gatt.dart';
import 'package:wmr_companion/protocol/wmr_fragment.dart';
import 'package:wmr_companion/services/controller_service.dart';

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
