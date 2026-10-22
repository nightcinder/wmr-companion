import 'dart:async';
import 'dart:typed_data';

import 'package:vector_math/vector_math_64.dart' as vm;

import '../domain/orientation.dart';
import '../domain/synthetic_motion.dart';
import '../protocol/decoded_record.dart';
import '../protocol/gatt.dart';
import '../protocol/wmr_fragment.dart';
import 'ble_transport.dart';
import 'fake_transport.dart';

const String fakeBridgeDeviceId = 'fake-wmr-bridge';

/// A [FakeDevice] exposing the bridge's GATT layout.
const FakeDevice fakeBridgeDevice = FakeDevice(
  id: fakeBridgeDeviceId,
  name: wmrBridgeDeviceName,
  services: [
    BleServiceInfo(
      uuid: wmrBridgeServiceUuid,
      characteristicUuids: [wmrBridgeStreamCharUuid, wmrBridgeDecodedCharUuid],
    ),
  ],
);

/// Same filler as the firmware tests' `make_frame`: `A1`, report ID 1, then a
/// position-dependent payload. Not a decodable controller report.
WmrFrame syntheticFrame(int hand, int sequence, {int length = 46}) {
  final data = Uint8List(length);
  for (var i = 0; i < length; i++) {
    data[i] = i == 0 ? 0xA1 : (i == 1 ? 0x01 : (i * 7 + hand) & 0xff);
  }
  return WmrFrame(hand: hand, sequence: sequence, data: data);
}

/// Sensor-axis gyro (rad/s) and accel (m/s^2) of a body that follows
/// [motion], expressed for the **default axis table** (sensor X = view Y,
/// sensor Y = -view X, sensor Z = view Z), so the app's default mapping
/// reproduces the motion. Built from the same quaternion the synthetic
/// debug view uses.
({List<double> gyro, List<double> accel}) syntheticImu(
  SyntheticMotion motion,
  double tSeconds, {
  double gravity = 10.0,
}) {
  const h = 1e-3;
  final q0 = motion.at(Duration(microseconds: (tSeconds * 1e6).round()));
  final q1 = motion.at(Duration(microseconds: ((tSeconds + h) * 1e6).round()));
  // Body-frame rate: 2 * vec(q0^-1 q1) / h, with the short-arc sign.
  final d = q0.conjugated() * q1;
  final s = d.w < 0 ? -2.0 / h : 2.0 / h;
  final wBody = vm.Vector3(d.x * s, d.y * s, d.z * s);
  final up = rotateVector(q0.conjugated(), vm.Vector3(0, gravity, 0));
  List<double> toSensor(vm.Vector3 v) => [v.y, -v.x, v.z];
  return (gyro: toSensor(wBody), accel: toSensor(up));
}

/// Drives a [FakeTransport] like the ESP32 does: both hands at [rateHz],
/// each frame fragmented for [attMtu] on FF11, and one 56-byte record per
/// report on FF12. The transport only delivers to whichever characteristic
/// is subscribed, as the firmware sends only the active stream. Sequence
/// numbers advance even when nobody is subscribed, as on the firmware.
///
/// FF12 content is deterministic: simulated time advances by one period per
/// [tick], device ticks follow at 100 ns, and the IMU values come from
/// [motion]. [dropRecord] simulates reports lost before the ESP32 (sequence
/// and ticks still advance, nothing is emitted on either stream).
class FakeWmrBridge {
  FakeWmrBridge(
    this.transport, {
    this.deviceId = fakeBridgeDeviceId,
    this.rateHz = 100,
    this.attMtu = wmrRequestedMtu,
    this.motion = const SyntheticMotion(),
    this.dropRecord,
    List<int>? startTicks,
    this.espBootUs = 1000000,
  }) : _ticks = List.of(startTicks ?? const [1000, 1000]);

  final FakeTransport transport;
  final String deviceId;
  final int rateHz;
  final int attMtu;
  final SyntheticMotion motion;

  /// Return true to lose the report of [hand] with this sequence number.
  final bool Function(int hand, int sequence)? dropRecord;

  /// `rx_time_us` of the first report: ESP32 microseconds since boot.
  final int espBootUs;

  final List<int> _sequence = List.filled(wmrNumControllers, 0);
  final List<int> _ticks;
  int _elapsedUs = 0;
  Timer? _timer;

  /// Controller ticks (100 ns) per report.
  int get periodTicks => 10000000 ~/ rateHz;

  void start() {
    _timer ??= Timer.periodic(
      Duration(microseconds: 1000000 ~/ rateHz),
      (_) => tick(),
    );
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Sends one report per hand, on whichever stream is subscribed.
  void tick() {
    final capacity = notificationCapacity(attMtu);
    final t = _elapsedUs / 1e6;
    for (var hand = 0; hand < wmrNumControllers; hand++) {
      _sequence[hand] = (_sequence[hand] + 1) & 0xffffffff;
      final ticks = _ticks[hand];
      _ticks[hand] = (ticks + periodTicks) & 0xffffffff;
      if (dropRecord?.call(hand, _sequence[hand]) ?? false) continue;

      final frame = syntheticFrame(hand, _sequence[hand]);
      for (final fragment in encodeFrame(frame, capacity)) {
        transport.emit(deviceId, wmrBridgeStreamCharUuid, fragment);
      }

      final imu = syntheticImu(motion, t);
      transport.emit(
        deviceId,
        wmrBridgeDecodedCharUuid,
        encodeDecodedRecord(
          DecodedRecord(
            hand: hand,
            sequence: _sequence[hand],
            rxTimeUs: espBootUs + _elapsedUs,
            deviceTicks: ticks,
            gyro: imu.gyro,
            accel: imu.accel,
          ),
        ),
      );
    }
    _elapsedUs += 1000000 ~/ rateHz;
  }
}
