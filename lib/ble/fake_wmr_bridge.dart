import 'dart:async';
import 'dart:typed_data';

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
      characteristicUuids: [wmrBridgeStreamCharUuid],
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

/// Drives a [FakeTransport] like the ESP32 does: both hands at [rateHz],
/// each frame fragmented for [attMtu]. Sequence numbers advance even when
/// nobody is subscribed, as on the firmware.
class FakeWmrBridge {
  FakeWmrBridge(
    this.transport, {
    this.deviceId = fakeBridgeDeviceId,
    this.rateHz = 100,
    this.attMtu = wmrRequestedMtu,
  });

  final FakeTransport transport;
  final String deviceId;
  final int rateHz;
  final int attMtu;

  final List<int> _sequence = List.filled(wmrNumControllers, 0);
  Timer? _timer;

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

  /// Sends one frame per hand.
  void tick() {
    final capacity = notificationCapacity(attMtu);
    for (var hand = 0; hand < wmrNumControllers; hand++) {
      _sequence[hand] = (_sequence[hand] + 1) & 0xffffffff;
      final frame = syntheticFrame(hand, _sequence[hand]);
      for (final fragment in encodeFrame(frame, capacity)) {
        transport.emit(deviceId, wmrBridgeStreamCharUuid, fragment);
      }
    }
  }
}
