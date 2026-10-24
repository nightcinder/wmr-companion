import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:vector_math/vector_math_64.dart' as vm;

import '../domain/orientation.dart';
import '../domain/synthetic_motion.dart';
import '../protocol/config_block.dart';
import '../protocol/controller_control.dart';
import '../protocol/decoded_batch.dart';
import '../protocol/decoded_record.dart';
import '../protocol/echo.dart';
import '../protocol/gatt.dart';
import '../protocol/wmr_fragment.dart';
import 'ble_transport.dart';
import 'fake_transport.dart';

const String fakeBridgeDeviceId = 'fake-wmr-bridge';
const String fakeBridgeLeftDeviceId = 'fake-wmr-bridge-left';
const String fakeBridgeRightDeviceId = 'fake-wmr-bridge-right';

const List<BleServiceInfo> fakeBridgeDeviceServices = [
  BleServiceInfo(
    uuid: wmrBridgeServiceUuid,
    characteristicUuids: [
      wmrBridgeStreamCharUuid,
      wmrBridgeDecodedCharUuid,
      wmrBridgeBatchedCharUuid,
      wmrBridgeEchoCharUuid,
      wmrBridgeConfigCharUuid,
      wmrBridgeVersionCharUuid,
      wmrBridgeControllerCharUuid,
    ],
  ),
];

/// A [FakeDevice] exposing the bridge's GATT layout.
const FakeDevice fakeBridgeDevice = FakeDevice(
  id: fakeBridgeDeviceId,
  name: wmrBridgeDeviceName,
  services: fakeBridgeDeviceServices,
);

const FakeDevice fakeBridgeLeftDevice = FakeDevice(
  id: fakeBridgeLeftDeviceId,
  name: 'WMR Bridge Left',
  services: fakeBridgeDeviceServices,
);

const FakeDevice fakeBridgeRightDevice = FakeDevice(
  id: fakeBridgeRightDeviceId,
  name: 'WMR Bridge Right',
  services: fakeBridgeDeviceServices,
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
/// report on FF12, and on FF14 the same records in batches. The transport
/// only delivers to whichever characteristic
/// is subscribed, as the firmware sends only the active stream. Sequence
/// numbers advance even when nobody is subscribed, as on the firmware.
///
/// FF12 content is deterministic: simulated time advances by one period per
/// [tick], device ticks follow at 100 ns, and the IMU values come from
/// [motion]. [dropRecord] simulates reports lost before the ESP32 (sequence
/// and ticks still advance, nothing is emitted on any stream).
///
/// FF14 follows the firmware's flush rule: a batch goes out as soon as
/// [batchMaxCount] records for [attMtu] are queued, or when the oldest queued
/// record has waited [batchHold] (one connection interval on the bridge).
/// Records of both hands share a batch, oldest first.
///
/// FF15: a valid 4-byte write while FF15 is subscribed is answered with a
/// 20-byte answer after [echoDelay] (zero: inside the write call, so a test
/// that moves its clock in a wrapped `onWrite` controls the round trip).
/// [echoTurnaround] is what the answer reports; [echoEnabled] false makes
/// the bridge ignore pings, like a bridge without the answer.
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
    this.batchHold = const Duration(milliseconds: 15),
    this.echoDelay = Duration.zero,
    this.echoTurnaround = const Duration(microseconds: 300),
    this.echoEnabled = true,
    List<Uint8List?> configBlobs = const [null, null],
    List<ConfigState>? configStates,
    this.discoveryDuration = const Duration(milliseconds: 1500),
    this.hands = const [wmrHandLeft, wmrHandRight],
    this.firmwareVersion = 'fake-1.0.0',
    this.firmwareVersionBytes,
  }) : _ticks = List.of(startTicks ?? const [1000, 1000]),
       configBlobs = List.of(configBlobs),
       configStates = List.of(
         configStates ??
             [
               for (final b in configBlobs)
                 b == null ? ConfigState.notRead : ConfigState.ready,
             ],
       ) {
    if (transport.onWrite == null) {
      transport.onWrite = _onWrite;
    } else {
      transport.addWriteHandler(_onWrite);
    }
    if (transport.onRead == null) {
      transport.onRead = _onRead;
    } else {
      transport.addReadHandler((id, uuid) {
        final lower = uuid.toLowerCase();
        if (id == deviceId &&
            (lower == wmrBridgeConfigCharUuid ||
                lower == wmrBridgeVersionCharUuid ||
                lower == wmrBridgeControllerCharUuid)) {
          return _onRead(id, uuid);
        }
        return null;
      });
    }
  }

  /// Hands this bridge serves. Defaults to both [wmrHandLeft, wmrHandRight].
  final List<int> hands;

  /// FF16: what the bridge reports as its firmware version. Null makes the
  /// read fail, like a bridge that advertises the characteristic but cannot
  /// serve it.
  final String? firmwareVersion;

  /// FF16 raw bytes, used instead of [firmwareVersion] to model a malformed
  /// value. Takes precedence when non-null.
  final List<int>? firmwareVersionBytes;

  /// FF13: the block served per hand and the state reported for it. Change
  /// them between reads to model a block that finishes reading.
  final List<Uint8List?> configBlobs;
  final List<ConfigState> configStates;
  int _cfgHand = 0;
  int _cfgOffset = 0;

  /// How long FF17 discovery reports `inquiry` before it stores an address and
  /// returns to idle. [Duration.zero] finishes inside the write, for tests.
  final Duration discoveryDuration;

  /// FF17 state: per hand flags (bit0 connected, bit1 connecting, bit2
  /// descriptor), address source, model and address tail.
  final List<int> _ctrlFlags = [0, 0];
  final List<int> _ctrlAddrSource = [2, 2];
  final List<int> _ctrlModel = [0, 0];
  final List<List<int>> _ctrlAddrTail = [
    [0x11, 0x22, 0x33],
    [0x44, 0x55, 0x66],
  ];
  int _discoveryState = 0;
  int _discoveryRound = 0;
  int _lastCommand = 0;
  int _lastResult = 0;
  Timer? _discoveryTimer;

  Uint8List _encodeControllerStatus() => Uint8List.fromList([
    1,
    _ctrlFlags[0],
    _ctrlAddrSource[0],
    _ctrlModel[0],
    ..._ctrlAddrTail[0],
    0,
    _ctrlFlags[1],
    _ctrlAddrSource[1],
    _ctrlModel[1],
    ..._ctrlAddrTail[1],
    0,
    _discoveryState,
    _discoveryRound,
    _lastCommand,
    _lastResult,
    0,
  ]);

  void _emitControllerStatus() => transport.emit(
    deviceId,
    wmrBridgeControllerCharUuid,
    _encodeControllerStatus(),
  );

  Never _refuseControllerCommand(
    ControllerCommand? command,
    ControllerResult result,
  ) {
    _lastCommand = command?.opcode ?? 0;
    _lastResult = result.code;
    _emitControllerStatus();
    throw ControllerCommandException(command, result);
  }

  void _onControllerWrite(Uint8List value) {
    if (value.isEmpty || value.length > 2) {
      _refuseControllerCommand(null, ControllerResult.invalidParam);
    }
    ControllerCommand? command;
    for (final c in ControllerCommand.values) {
      if (c.opcode == value[0]) command = c;
    }
    if (command == null) {
      _refuseControllerCommand(null, ControllerResult.invalidParam);
    }
    final hand = value.length == 2 ? value[1] : null;
    if (hand != null && hand > 1) {
      _refuseControllerCommand(command, ControllerResult.invalidParam);
    }
    if (command.needsHand && hand == null) {
      _refuseControllerCommand(command, ControllerResult.invalidParam);
    }
    switch (command) {
      case ControllerCommand.discover:
        if (_discoveryState != 0 || _ctrlFlags.any((f) => f & 2 != 0)) {
          _refuseControllerCommand(command, ControllerResult.busy);
        }
        _discoveryState = 1;
        _discoveryRound++;
        _lastCommand = command.opcode;
        _lastResult = ControllerResult.ok.code;
        _emitControllerStatus();
        if (discoveryDuration == Duration.zero) {
          _finishDiscovery();
        } else {
          _discoveryTimer = Timer(discoveryDuration, _finishDiscovery);
        }
      case ControllerCommand.connect:
        final h = hand!;
        if (_ctrlFlags[h] & 1 != 0) {
          _refuseControllerCommand(command, ControllerResult.busy);
        }
        _ctrlFlags[h] = 1 | 4;
        _lastCommand = command.opcode;
        _lastResult = ControllerResult.ok.code;
        _emitControllerStatus();
      case ControllerCommand.disconnect:
        final h = hand!;
        if (_ctrlFlags[h] == 0) {
          _refuseControllerCommand(command, ControllerResult.notConnected);
        }
        _ctrlFlags[h] = 0;
        _lastCommand = command.opcode;
        _lastResult = ControllerResult.ok.code;
        _emitControllerStatus();
      case ControllerCommand.forgetAddresses:
        if (_ctrlFlags.any((f) => f & 3 != 0)) {
          _refuseControllerCommand(command, ControllerResult.busy);
        }
        for (var h = 0; h < 2; h++) {
          _ctrlAddrSource[h] = 0;
          _ctrlAddrTail[h] = [0, 0, 0];
        }
        _lastCommand = command.opcode;
        _lastResult = ControllerResult.ok.code;
        _emitControllerStatus();
      case ControllerCommand.forgetBond:
        final h = hand!;
        if (_ctrlFlags[h] & 3 != 0) {
          _refuseControllerCommand(command, ControllerResult.busy);
        }
        _lastCommand = command.opcode;
        _lastResult = ControllerResult.ok.code;
        _emitControllerStatus();
    }
  }

  void _finishDiscovery() {
    _discoveryTimer?.cancel();
    _discoveryTimer = null;
    _discoveryState = 0;
    _discoveryRound = 0;
    for (var h = 0; h < 2; h++) {
      _ctrlAddrSource[h] = 2;
      _ctrlAddrTail[h] = [0x11 + h, 0x22 + h, 0x33 + h];
    }
    _emitControllerStatus();
  }

  Uint8List _onRead(String id, String characteristicUuid) {
    final uuid = characteristicUuid.toLowerCase();
    if (id == deviceId && uuid == wmrBridgeControllerCharUuid) {
      return _encodeControllerStatus();
    }
    if (id == deviceId && uuid == wmrBridgeVersionCharUuid) {
      final bytes =
          firmwareVersionBytes ??
          (firmwareVersion == null
              ? null
              : Uint8List.fromList(utf8.encode(firmwareVersion!)));
      if (bytes == null) {
        throw StateError('FakeWmrBridge: FF16 has no value');
      }
      return Uint8List.fromList(bytes);
    }
    if (id != deviceId || uuid != wmrBridgeConfigCharUuid) {
      throw StateError(
        'FakeWmrBridge: unsupported read of $characteristicUuid',
      );
    }
    return encodeConfigWindow(
      hand: _cfgHand,
      state: configStates[_cfgHand],
      blob: configBlobs[_cfgHand],
      offset: _cfgOffset,
    );
  }

  final FakeTransport transport;
  final String deviceId;
  final int rateHz;
  final int attMtu;
  final SyntheticMotion motion;

  /// Return true to lose the report of [hand] with this sequence number.
  final bool Function(int hand, int sequence)? dropRecord;

  /// `rx_time_us` of the first report: ESP32 microseconds since boot.
  final int espBootUs;

  /// How long the oldest record may wait for its FF14 batch.
  final Duration batchHold;

  final Duration echoDelay;
  final Duration echoTurnaround;
  bool echoEnabled;

  /// FF15 answers sent so far.
  int echoesSent = 0;

  void _onWrite(FakeWrite w) {
    if (w.deviceId == deviceId &&
        w.characteristicUuid.toLowerCase() == wmrBridgeControllerCharUuid) {
      _onControllerWrite(w.value);
      return;
    }
    if (w.deviceId == deviceId &&
        w.characteristicUuid.toLowerCase() == wmrBridgeConfigCharUuid) {
      if (w.value.length != wmrConfigCursorSize || w.value[0] > 1) {
        throw const BleStreamException(
          BleStreamFaultKind.enableFailed,
          wmrBridgeConfigCharUuid,
          'invalid FF13 cursor',
          attError: 0x80,
        );
      }
      _cfgHand = w.value[0];
      _cfgOffset = ByteData.sublistView(w.value).getUint32(1, Endian.little);
      return;
    }
    if (!echoEnabled ||
        w.deviceId != deviceId ||
        w.characteristicUuid.toLowerCase() != wmrBridgeEchoCharUuid ||
        w.value.length != wmrEchoRequestSize ||
        w.value[0] != wmrEchoVersion ||
        !transport.isSubscribed(deviceId, wmrBridgeEchoCharUuid)) {
      return;
    }
    final answer = encodeEchoAnswer(
      EchoAnswer(
        pingId: ByteData.sublistView(w.value).getUint16(2, Endian.little),
        rxTimeUs: espBootUs + _elapsedUs,
        turnaroundUs: echoTurnaround.inMicroseconds,
        queueDepth: 0,
      ),
    );
    void send() {
      if (transport.emit(deviceId, wmrBridgeEchoCharUuid, answer)) {
        echoesSent++;
      }
    }

    if (echoDelay == Duration.zero) {
      send();
    } else {
      Timer(echoDelay, send);
    }
  }

  final List<int> _sequence = List.filled(wmrNumControllers, 0);
  final List<int> _ticks;
  int _elapsedUs = 0;
  Timer? _timer;
  final List<Uint8List> _batch = [];
  int _batchOldestUs = 0;

  /// FF14 notifications sent so far.
  int batchesSent = 0;

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
    _discoveryTimer?.cancel();
    _discoveryTimer = null;
  }

  /// Sends one report per hand, on whichever stream is subscribed.
  void tick() {
    final capacity = notificationCapacity(attMtu);
    final t = _elapsedUs / 1e6;
    for (final hand in hands) {
      _sequence[hand] = (_sequence[hand] + 1) & 0xffffffff;
      final ticks = _ticks[hand];
      _ticks[hand] = (ticks + periodTicks) & 0xffffffff;
      if (dropRecord?.call(hand, _sequence[hand]) ?? false) continue;

      final frame = syntheticFrame(hand, _sequence[hand]);
      for (final fragment in encodeFrame(frame, capacity)) {
        transport.emit(deviceId, wmrBridgeStreamCharUuid, fragment);
      }

      final imu = syntheticImu(motion, t);
      final record = encodeDecodedRecord(
        DecodedRecord(
          hand: hand,
          sequence: _sequence[hand],
          rxTimeUs: espBootUs + _elapsedUs,
          deviceTicks: ticks,
          gyro: imu.gyro,
          accel: imu.accel,
        ),
      );
      transport.emit(deviceId, wmrBridgeDecodedCharUuid, record);
      _queueBatched(record);
    }
    _elapsedUs += 1000000 ~/ rateHz;
    if (_batch.isNotEmpty &&
        _elapsedUs - _batchOldestUs >= batchHold.inMicroseconds) {
      _flushBatch();
    }
  }

  void _queueBatched(Uint8List record) {
    // The firmware only queues for the active stream.
    if (!transport.isSubscribed(deviceId, wmrBridgeBatchedCharUuid)) {
      _batch.clear();
      return;
    }
    final max = batchMaxCount(attMtu);
    if (max == 0) return; // MTU below 61: discarded, as on the bridge.
    if (_batch.isEmpty) _batchOldestUs = _elapsedUs;
    _batch.add(record);
    if (_batch.length >= max) _flushBatch();
  }

  void _flushBatch() {
    if (transport.emit(
      deviceId,
      wmrBridgeBatchedCharUuid,
      encodeDecodedBatch(_batch),
    )) {
      batchesSent++;
    }
    _batch.clear();
  }
}
