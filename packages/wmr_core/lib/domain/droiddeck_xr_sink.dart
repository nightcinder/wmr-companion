import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import '../protocol/decoded_record.dart';
import 'gamepad.dart';
import 'hand_pipeline.dart';
import 'stick_centre.dart';

/// Experimental `v0` external 6DoF input for DroidDeck.
///
/// Mirrors `tools/vr/src/ext_xr_input.h` and
/// `app/src/main/java/com/droiddeck/launcher/input/ExtXrProtocol.kt` in the
/// DroidDeck fork. The wire ABI stays experimental until it is verified on
/// XREAL Aura; only the version field may change meaning, and a producer must
/// reject a version it does not know.
abstract final class DroidDeckXrProtocol {
  /// `"DEXR"`, little-endian on the wire.
  static const int magic = 0x52584544;
  static const int version = 0;

  /// Abstract `SOCK_SEQPACKET` name, without the leading NUL.
  static const String socketName = 'droiddeck-ext-xr';

  /// The host drops a session after this long without a packet.
  static const int sessionTimeoutMs = 1000;

  /// A packet older or newer than this is not republished.
  static const int staleNs = 500000000;

  static const int headerBytes = 40;
  static const int handBytes = 112;
  static const int packetBytes = 264;
  static const int claimBytes = 184;
  static const int descriptorBytes = 64;
  static const int nameBytes = 64;

  static const int flagFocused = 1 << 0;
  static const int flagPacketClaim = 1 << 1;

  static const int handConnected = 1 << 0;
  static const int handPoseValid = 1 << 1;
  static const int handStick = 1 << 2;
  static const int handTrackpad = 1 << 3;

  static const int buttonTrigger = 1 << 0;
  static const int buttonSqueeze = 1 << 1;
  static const int buttonStick = 1 << 2;
  static const int buttonPrimary = 1 << 3;
  static const int buttonSecondary = 1 << 4;
  static const int buttonSystem = 1 << 5;
  static const int buttonThumbrest = 1 << 6;

  static const int touchTrigger = 1 << 0;
  static const int touchStick = 1 << 1;
  static const int touchPrimary = 1 << 2;
  static const int touchSecondary = 1 << 3;
  static const int touchThumbrest = 1 << 4;
  static const int touchTrackpad = 1 << 5;
  static const int touchTrackpadClick = 1 << 6;
}

/// The Android `InputDevice` a producer replaces while its session is live.
///
/// DroidDeck matches [vendorId] and [productId] first; [descriptor] narrows the
/// match when set. [name] is only the explicit user-set fallback, never a
/// hardcoded producer or bridge name. A claim with no vendor/product and no
/// name matches nothing.
class DroidDeckXrClaim {
  const DroidDeckXrClaim({
    this.vendorId = 0,
    this.productId = 0,
    this.descriptor = '',
    this.name = '',
  });

  final int vendorId;
  final int productId;
  final String descriptor;
  final String name;

  bool get isEmpty =>
      vendorId == 0 && productId == 0 && descriptor.isEmpty && name.isEmpty;
}

/// One hand as the host expects it: pose, analog axes and button/touch bits.
class DroidDeckXrHand {
  const DroidDeckXrHand({
    this.connected = false,
    this.position = const [0, 0, 0],
    this.orientation = const [0, 0, 0, 1],
    this.linearVelocity = const [0, 0, 0],
    this.angularVelocity = const [0, 0, 0],
    this.trigger = 0,
    this.squeeze = 0,
    this.stick = const [0, 0],
    this.trackpad = const [0, 0],
    this.buttons = 0,
    this.touches = 0,
    this.battery = 0,
    this.sampleTimeNs = 0,
    this.recenter = 0,
    this.usesTrackpad = false,
  });

  /// Maps one pipeline sample to the host's hand layout.
  ///
  /// The pipeline supplies orientation and angular velocity. Angular velocity
  /// is the bias-corrected view-frame rate, body-local and unrotated, and is
  /// zero when the sample has none (baseline, discontinuity, large gap, or
  /// non-finite input). [position] and linear velocity stay zero unless a
  /// caller supplies a tracked position (the host accepts a rotation-only
  /// pose). The gamepad state supplies the analog values after the user's
  /// mapping, so stick inversion and trigger thresholds match the rest of the
  /// app.
  factory DroidDeckXrHand.fromPipeline(
    DecodedSample sample,
    GamepadState gamepad, {
    List<double>? position,
  }) {
    final side = sample.record.hand == 0 ? 0 : 1;
    final q = sample.orientation;
    final rigid =
        _isFinite(q.x) &&
        _isFinite(q.y) &&
        _isFinite(q.z) &&
        _isFinite(q.w) &&
        ((q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w) - 1).abs() < 0.01;
    final raw = sample.record;
    final pressed = side == 0 ? gamepad.leftConnected : gamepad.rightConnected;
    final stick = _pair(
      pressed
          ? (side == 0 ? gamepad.leftStick : gamepad.rightStick)
          : sample.stick,
    );
    final trackpad = _pair([
      for (final v in raw.trackpad)
        (v / StickNormalizer.fullScale).clamp(-1.0, 1.0),
    ]);
    final trackpadTouch = raw.buttons & wmrBtnTrackpadTouch != 0;
    final trackpadClick = raw.buttons & wmrBtnTrackpadClick != 0;
    final usesTrackpad =
        trackpadTouch || trackpadClick || trackpad.any((v) => v != 0);

    var buttons = 0;
    var touches = 0;
    final squeeze =
        raw.buttons & wmrBtnSqueeze != 0 ||
        gamepad.pressed(side == 0 ? GamepadButton.l1 : GamepadButton.r1);
    if (squeeze) buttons |= DroidDeckXrProtocol.buttonSqueeze;
    if (raw.buttons & wmrBtnThumbstickClick != 0 ||
        gamepad.pressed(side == 0 ? GamepadButton.l3 : GamepadButton.r3)) {
      buttons |= DroidDeckXrProtocol.buttonStick;
    }
    if (gamepad.pressed(side == 0 ? GamepadButton.l2 : GamepadButton.r2)) {
      buttons |= DroidDeckXrProtocol.buttonTrigger;
    }
    if (raw.buttons & wmrBtnHome != 0 || gamepad.pressed(GamepadButton.guide)) {
      buttons |= DroidDeckXrProtocol.buttonSystem;
    }
    // The v0 host has no separate menu/select bit. Home and menu both reach
    // SteamVR's system button, matching the HID gamepad's Guide mapping.
    if (raw.buttons & wmrBtnMenu != 0 ||
        gamepad.pressed(GamepadButton.select) ||
        gamepad.pressed(GamepadButton.start)) {
      buttons |= DroidDeckXrProtocol.buttonSystem;
    }
    if (side == 0) {
      if (gamepad.pressed(GamepadButton.dpadUp) ||
          gamepad.pressed(GamepadButton.dpadRight)) {
        buttons |= DroidDeckXrProtocol.buttonPrimary;
      }
      if (gamepad.pressed(GamepadButton.dpadDown) ||
          gamepad.pressed(GamepadButton.dpadLeft)) {
        buttons |= DroidDeckXrProtocol.buttonSecondary;
      }
    } else {
      if (gamepad.pressed(GamepadButton.a) ||
          gamepad.pressed(GamepadButton.y)) {
        buttons |= DroidDeckXrProtocol.buttonPrimary;
      }
      if (gamepad.pressed(GamepadButton.b) ||
          gamepad.pressed(GamepadButton.x)) {
        buttons |= DroidDeckXrProtocol.buttonSecondary;
      }
    }

    if (trackpadTouch) {
      touches |=
          DroidDeckXrProtocol.touchTrackpad | DroidDeckXrProtocol.touchPrimary;
    }
    if (trackpadClick) {
      touches |= DroidDeckXrProtocol.touchTrackpadClick;
    }

    return DroidDeckXrHand(
      connected: true,
      position: _triple(position ?? const [0, 0, 0]),
      angularVelocity: _angularVelocity(sample),
      orientation: rigid ? [q.x, q.y, q.z, q.w] : const [0, 0, 0, 1],
      trigger: _unit(side == 0 ? gamepad.leftTrigger : gamepad.rightTrigger),
      squeeze: squeeze ? 1 : 0,
      stick: stick,
      trackpad: trackpad,
      buttons: buttons,
      touches: touches,
      battery: _unit(raw.battery / 255),
      usesTrackpad: usesTrackpad,
    );
  }

  final bool connected;
  final List<double> position;
  final List<double> orientation;
  final List<double> linearVelocity;
  final List<double> angularVelocity;
  final double trigger;
  final double squeeze;
  final List<double> stick;
  final List<double> trackpad;
  final int buttons;
  final int touches;
  final double battery;
  final int sampleTimeNs;
  final int recenter;

  /// Selects the trackpad axes instead of the stick axes on the host.
  final bool usesTrackpad;
}

/// A framed `v0` transport. DroidDeck exposes one abstract `SOCK_SEQPACKET`
/// UDS; the companion uses that path only, so every packet is a single
/// fixed-size record.
abstract interface class DroidDeckXrTransport {
  Future<void> send(Uint8List packet);
  Future<void> close();
}

/// The app's Bluetooth HID peripheral role, which must be off while the 6DoF
/// sink is active so the host does not also see the flat gamepad.
abstract interface class DroidDeckXrHidPeripheral {
  Future<void> disable();
  Future<void> restore();
}

/// Serializes the pipeline and gamepad state and sends it to DroidDeck.
///
/// A null hand is sent disconnected; the host then releases that controller
/// instead of using the last pose. [start] sends the claim and disables the
/// HID peripheral role; [stop] closes the transport and restores it.
class DroidDeckXrSink {
  DroidDeckXrSink({
    required this.transport,
    this.claim,
    this.sourceId = 0,
    this.clockNs = droidDeckMonotonicNs,
    this.hidPeripheral,
    this.claimInterval = const Duration(milliseconds: 250),
    this.focused = true,
  });

  final DroidDeckXrTransport transport;

  /// The Android input devices to exclude while this sink is live. Null sends
  /// input without claiming a flat gamepad.
  final DroidDeckXrClaim? claim;
  final int sourceId;
  final int Function() clockNs;
  final DroidDeckXrHidPeripheral? hidPeripheral;

  /// Repeats the claim so the host keeps the device excluded even when input
  /// packets stop for a moment.
  final Duration claimInterval;
  final bool focused;

  bool _active = false;
  bool _ready = false;
  int _generation = 0;
  int _sequence = 0;
  Timer? _claimTimer;

  bool get active => _active;

  Future<void> start() async {
    if (_active) return;
    _active = true;
    final generation = ++_generation;
    try {
      await hidPeripheral?.disable();
      if (generation != _generation) return;
      await _sendClaim();
      if (generation != _generation) return;
      _ready = true;
      if (claimInterval > Duration.zero) {
        _claimTimer = Timer.periodic(
          claimInterval,
          (_) => unawaited(_claimTick()),
        );
      }
    } catch (_) {
      if (generation == _generation) {
        _active = false;
        _ready = false;
        _claimTimer?.cancel();
        _claimTimer = null;
        await hidPeripheral?.restore();
      }
      rethrow;
    }
  }

  /// Sends one frame. Does nothing before [start] has sent the claim.
  Future<void> submit({
    required DecodedSample? left,
    required DecodedSample? right,
    required GamepadState gamepad,
    List<double> leftPosition = const [0, 0, 0],
    List<double> rightPosition = const [0, 0, 0],
  }) async {
    if (!_active || !_ready) return;
    final now = clockNs();
    await transport.send(
      encodeDroidDeckXrInput(
        sequence: _nextSequence(),
        timeNs: now,
        left: left == null
            ? const DroidDeckXrHand()
            : DroidDeckXrHand.fromPipeline(
                left,
                gamepad,
                position: leftPosition,
              ),
        right: right == null
            ? const DroidDeckXrHand()
            : DroidDeckXrHand.fromPipeline(
                right,
                gamepad,
                position: rightPosition,
              ),
        sourceId: sourceId,
        focused: focused,
      ),
    );
  }

  Future<void> stop() async {
    if (!_active) return;
    _active = false;
    _ready = false;
    final generation = ++_generation;
    _claimTimer?.cancel();
    _claimTimer = null;
    try {
      await transport.close();
    } finally {
      if (generation == _generation) await hidPeripheral?.restore();
    }
  }

  Future<void> _sendClaim() async {
    final c = claim;
    if (c == null || c.isEmpty) return;
    await transport.send(
      encodeDroidDeckXrClaim(
        claim: c,
        sequence: _nextSequence(),
        timeNs: clockNs(),
        sourceId: sourceId,
        focused: focused,
      ),
    );
  }

  Future<void> _claimTick() async {
    try {
      await _sendClaim();
    } on Object {
      // The periodic claim is best effort; a caller that sees send failures
      // through submit() decides whether to stop the session.
    }
  }

  int _nextSequence() => _sequence++;
}

/// Encodes one fixed-size input packet.
Uint8List encodeDroidDeckXrInput({
  required int sequence,
  required int timeNs,
  DroidDeckXrHand left = const DroidDeckXrHand(),
  DroidDeckXrHand right = const DroidDeckXrHand(),
  int sourceId = 0,
  bool focused = true,
}) {
  final out = Uint8List(DroidDeckXrProtocol.packetBytes);
  final d = ByteData.sublistView(out);
  _writeHeader(
    d,
    sequence: sequence,
    flags: focused ? DroidDeckXrProtocol.flagFocused : 0,
    sourceId: sourceId,
    timeNs: timeNs,
  );
  _writeHand(d, DroidDeckXrProtocol.headerBytes, left, timeNs);
  _writeHand(
    d,
    DroidDeckXrProtocol.headerBytes + DroidDeckXrProtocol.handBytes,
    right,
    timeNs,
  );
  return out;
}

/// Encodes one claim packet. DroidDeck validates it before excluding a device.
Uint8List encodeDroidDeckXrClaim({
  required DroidDeckXrClaim claim,
  required int sequence,
  required int timeNs,
  int sourceId = 0,
  bool focused = true,
}) {
  if (claim.isEmpty) {
    throw ArgumentError.value(
      claim,
      'claim',
      'a claim needs a vendor/product pair, a descriptor or a user-set name',
    );
  }
  final out = Uint8List(DroidDeckXrProtocol.claimBytes);
  final d = ByteData.sublistView(out);
  _writeHeader(
    d,
    sequence: sequence,
    flags:
        DroidDeckXrProtocol.flagPacketClaim |
        (focused ? DroidDeckXrProtocol.flagFocused : 0),
    sourceId: sourceId,
    timeNs: timeNs,
  );
  const e = Endian.little;
  d
    ..setUint32(40, claim.vendorId, e)
    ..setUint32(44, claim.productId, e)
    ..setUint32(48, 0, e)
    ..setUint32(52, 0, e);
  _writeString(d, 56, claim.descriptor, DroidDeckXrProtocol.descriptorBytes);
  _writeString(d, 120, claim.name, DroidDeckXrProtocol.nameBytes);
  return out;
}

void _writeHeader(
  ByteData d, {
  required int sequence,
  required int flags,
  required int sourceId,
  required int timeNs,
}) {
  const e = Endian.little;
  d
    ..setUint32(0, DroidDeckXrProtocol.magic, e)
    ..setUint32(4, DroidDeckXrProtocol.version, e)
    ..setUint32(8, sequence, e)
    ..setUint32(12, DroidDeckXrProtocol.headerBytes, e)
    ..setUint32(16, flags, e)
    ..setUint32(20, sourceId, e)
    ..setInt64(24, timeNs, e)
    ..setUint32(32, 0, e)
    ..setUint32(36, 0, e);
}

void _writeHand(ByteData d, int offset, DroidDeckXrHand hand, int timeNs) {
  const e = Endian.little;
  final poseValid = hand.connected && _validPose(hand.orientation);
  var flags = 0;
  if (hand.connected) flags |= DroidDeckXrProtocol.handConnected;
  if (poseValid) flags |= DroidDeckXrProtocol.handPoseValid;
  if (hand.connected) {
    flags |= hand.usesTrackpad
        ? DroidDeckXrProtocol.handTrackpad
        : DroidDeckXrProtocol.handStick;
  }
  d
    ..setUint32(offset, flags, e)
    ..setUint32(offset + 4, hand.buttons, e)
    ..setUint32(offset + 8, hand.touches, e)
    ..setUint32(offset + 12, 0, e);
  _writeFloats(d, offset + 16, _triple(hand.position), 3);
  _writeFloats(d, offset + 28, _quad(hand.orientation), 4);
  _writeFloats(d, offset + 44, _triple(hand.linearVelocity), 3);
  _writeFloats(d, offset + 56, _triple(hand.angularVelocity), 3);
  d
    ..setFloat32(offset + 68, _unit(hand.trigger), e)
    ..setFloat32(offset + 72, _unit(hand.squeeze), e);
  _writeFloats(d, offset + 76, _pair(hand.stick), 2);
  _writeFloats(d, offset + 84, _pair(hand.trackpad), 2);
  d
    ..setFloat32(offset + 92, _unit(hand.battery), e)
    ..setInt64(
      offset + 96,
      hand.sampleTimeNs > 0 ? hand.sampleTimeNs : timeNs,
      e,
    )
    ..setUint32(offset + 104, hand.recenter, e)
    ..setUint32(offset + 108, 0, e);
}

void _writeFloats(ByteData d, int offset, List<double> values, int count) {
  const e = Endian.little;
  for (var i = 0; i < count; i++) {
    d.setFloat32(offset + i * 4, _isFinite(values[i]) ? values[i] : 0, e);
  }
}

void _writeString(ByteData d, int offset, String value, int capacity) {
  final encoded = utf8.encode(value);
  final bytes = Uint8List.fromList(encoded);
  final limit = capacity - 1;
  for (var i = 0; i < limit; i++) {
    d.setUint8(offset + i, i < bytes.length ? bytes[i] : 0);
  }
  d.setUint8(offset + capacity - 1, 0);
}

bool _validPose(List<double> q) {
  if (q.length != 4) return false;
  for (final v in q) {
    if (!_isFinite(v)) return false;
  }
  final length = q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3];
  return (length - 1).abs() < 0.01;
}

bool _isFinite(double v) => v.isFinite;

double _unit(double v) => _isFinite(v) ? v.clamp(0.0, 1.0).toDouble() : 0;

/// View-frame angular velocity (rad/s) of a fused sample; zeros when there is
/// none. Non-finite components become zero in [_triple].
List<double> _angularVelocity(DecodedSample sample) {
  final w = sample.angularVelocity;
  return _triple(w == null ? const [0, 0, 0] : [w.x, w.y, w.z]);
}

List<double> _triple(List<double> v) => [
  for (var i = 0; i < 3; i++) i < v.length && _isFinite(v[i]) ? v[i] : 0.0,
];

List<double> _quad(List<double> v) => [
  for (var i = 0; i < 4; i++)
    i < v.length && _isFinite(v[i]) ? v[i] : (i == 3 ? 1.0 : 0.0),
];

List<double> _pair(List<double> v) => [
  for (var i = 0; i < 2; i++) i < v.length && _isFinite(v[i]) ? v[i] : 0.0,
];

/// `CLOCK_MONOTONIC` in nanoseconds, the time base DroidDeck validates against.
int droidDeckMonotonicNs() => _monotonicNs();

typedef _ClockGetTimeNative = Int32 Function(Int32, Pointer<Int64>);
typedef _ClockGetTimeDart = int Function(int, Pointer<Int64>);
typedef _MallocNative = Pointer<Void> Function(IntPtr);
typedef _MallocDart = Pointer<Void> Function(int);
typedef _FreeNative = Void Function(Pointer<Void>);
typedef _FreeDart = void Function(Pointer<Void>);

final int Function() _monotonicNs = _openMonotonicClock();

int Function() _openMonotonicClock() {
  try {
    final libc = DynamicLibrary.process();
    final clockGetTime = libc
        .lookupFunction<_ClockGetTimeNative, _ClockGetTimeDart>(
          'clock_gettime',
        );
    final malloc = libc.lookupFunction<_MallocNative, _MallocDart>('malloc');
    final free = libc.lookupFunction<_FreeNative, _FreeDart>('free');
    return () {
      final timespec = malloc(16).cast<Int64>();
      try {
        if (clockGetTime(1, timespec) != 0) return 0;
        return timespec[0] * 1000000000 + timespec[1];
      } finally {
        free(timespec.cast());
      }
    };
  } catch (_) {
    // A caller that needs the real host time base must inject a clock; this
    // fallback at least keeps pure-Dart tests and desktop tooling alive.
    final stopwatch = Stopwatch()..start();
    return () => stopwatch.elapsedMicroseconds * 1000;
  }
}
