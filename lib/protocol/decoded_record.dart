/// Wire format of the bridge's FF12 decoded notifications.
///
/// Mirrors WMR_Bridge `src/wmr_decoded.{h,c}` (`wmr_decoded_pack` and
/// `wmr_decoded_unpack`). See docs/PROTOCOL.md, "FF12 decoded stream". Pure
/// Dart. Not verified on hardware.
library;

import 'dart:typed_data';

const int wmrDecodedSize = 56;
const int wmrDecodedVersion = 1;

/// `flags` bit 0. Always clear in version 1.
const int wmrDecodedFlagCalibrated = 0x01;

/// Controller timer period: 100 ns per tick (from Monado, not measured).
const int wmrTickNanoseconds = 100;
const double wmrTickSeconds = 1e-7;

/// The counter is 32 bits wide.
const int wmrTickModulus = 0x100000000;

// Button bits, same positions as the controller report.
const int wmrBtnThumbstickClick = 0x01;
const int wmrBtnHome = 0x02;
const int wmrBtnMenu = 0x04;
const int wmrBtnSqueeze = 0x08;
const int wmrBtnTrackpadClick = 0x10;
const int wmrBtnBtPairing = 0x20;
const int wmrBtnTrackpadTouch = 0x40;

enum DecodedParseError { wrongLength, unknownVersion, badHand }

/// One decoded sample. Gyro in rad/s and accel in m/s^2, both in the
/// controller's raw sensor axes (uncalibrated).
class DecodedRecord {
  const DecodedRecord({
    required this.hand,
    required this.sequence,
    required this.rxTimeUs,
    required this.deviceTicks,
    required this.gyro,
    required this.accel,
    this.flags = 0,
    this.buttons = 0,
    this.temperatureRaw = 0,
    this.stick = const [0, 0],
    this.trackpad = const [0, 0],
    this.trigger = 0,
    this.battery = 0,
  });

  final int hand;
  final int flags;
  final int buttons;

  /// Per-hand u32, the same number as the raw FF11 frame it came from.
  final int sequence;

  /// ESP32 `esp_timer_get_time()` at receipt, microseconds since ESP32 boot.
  /// Latency and jitter diagnostics only, never a sensor clock.
  final int rxTimeUs;

  /// Controller timer, 100 ns per tick, wraps at 2^32. The sensor clock.
  final int deviceTicks;

  /// x, y, z in rad/s.
  final List<double> gyro;

  /// x, y, z in m/s^2.
  final List<double> accel;
  final int temperatureRaw;
  final List<int> stick;
  final List<int> trackpad;
  final int trigger;
  final int battery;

  bool get calibrated => flags & wmrDecodedFlagCalibrated != 0;
}

class DecodedParseResult {
  const DecodedParseResult.ok(DecodedRecord this.record) : error = null;
  const DecodedParseResult.error(DecodedParseError this.error) : record = null;

  final DecodedRecord? record;
  final DecodedParseError? error;
}

/// Parses one notification value like `wmr_decoded_unpack`: exactly 56 bytes,
/// version 1, hand 0 or 1. Anything else is an error (a receiver must ignore
/// records with an unknown version). Floats are passed through as received,
/// including NaN; consumers must guard.
DecodedParseResult parseDecodedRecord(Uint8List value) {
  if (value.length != wmrDecodedSize) {
    return const DecodedParseResult.error(DecodedParseError.wrongLength);
  }
  final d = ByteData.sublistView(value);
  if (d.getUint8(0) != wmrDecodedVersion) {
    return const DecodedParseResult.error(DecodedParseError.unknownVersion);
  }
  final hand = d.getUint8(1);
  if (hand >= 2) {
    return const DecodedParseResult.error(DecodedParseError.badHand);
  }
  const e = Endian.little;
  return DecodedParseResult.ok(
    DecodedRecord(
      hand: hand,
      flags: d.getUint8(2),
      buttons: d.getUint8(3),
      sequence: d.getUint32(4, e),
      rxTimeUs: d.getUint64(8, e),
      deviceTicks: d.getUint32(16, e),
      gyro: [for (var i = 0; i < 3; i++) d.getFloat32(20 + 4 * i, e)],
      accel: [for (var i = 0; i < 3; i++) d.getFloat32(32 + 4 * i, e)],
      temperatureRaw: d.getInt16(44, e),
      stick: [d.getInt16(46, e), d.getInt16(48, e)],
      trackpad: [d.getInt16(50, e), d.getInt16(52, e)],
      trigger: d.getUint8(54),
      battery: d.getUint8(55),
    ),
  );
}

/// Serializes [r] like `wmr_decoded_pack`. The app only needs this for the
/// fake bridge and tests.
Uint8List encodeDecodedRecord(DecodedRecord r) {
  final out = Uint8List(wmrDecodedSize);
  final d = ByteData.sublistView(out);
  const e = Endian.little;
  d
    ..setUint8(0, wmrDecodedVersion)
    ..setUint8(1, r.hand)
    ..setUint8(2, r.flags)
    ..setUint8(3, r.buttons)
    ..setUint32(4, r.sequence, e)
    ..setUint64(8, r.rxTimeUs, e)
    ..setUint32(16, r.deviceTicks, e);
  for (var i = 0; i < 3; i++) {
    d
      ..setFloat32(20 + 4 * i, r.gyro[i], e)
      ..setFloat32(32 + 4 * i, r.accel[i], e);
  }
  d
    ..setInt16(44, r.temperatureRaw, e)
    ..setInt16(46, r.stick[0], e)
    ..setInt16(48, r.stick[1], e)
    ..setInt16(50, r.trackpad[0], e)
    ..setInt16(52, r.trackpad[1], e)
    ..setUint8(54, r.trigger)
    ..setUint8(55, r.battery);
  return out;
}

/// `b - a` modulo 2^32, as an unsigned value: the number of ticks from [a]
/// to [b], correct across one wrap.
int tickDelta(int a, int b) => (b - a) & (wmrTickModulus - 1);
