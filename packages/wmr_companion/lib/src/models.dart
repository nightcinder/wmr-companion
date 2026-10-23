import 'package:vector_math/vector_math_64.dart' show Quaternion;
import 'package:wmr_core/domain/gamepad.dart';
import 'package:wmr_core/domain/loss_window.dart';
import 'package:wmr_core/domain/tick_timer.dart';
import 'package:wmr_core/protocol/decoded_record.dart';
import 'package:wmr_core/protocol/firmware_version.dart';
import 'package:wmr_core/protocol/wmr_fragment.dart';
import 'package:wmr_core/services/controller_service.dart'
    show DecodedStats, StreamMode;

/// Which controller of the bridge a value belongs to.
enum Hand {
  left,
  right;

  /// Index used by `wmr_core` (0 LEFT, 1 RIGHT).
  int get wireIndex => this == Hand.left ? 0 : 1;

  /// The hand for a `wmr_core` index. Values other than 1 mean [left]; the
  /// protocol layer rejects a bad hand byte before it reaches this.
  static Hand of(int index) => index == 1 ? Hand.right : Hand.left;
}

/// Lifecycle of the facade. [reconnecting] is a normal state, not an error:
/// a dropped link is retried while [WmrCompanionConfig.autoReconnect] is on.
enum WmrConnectionState {
  idle,
  scanning,
  connecting,
  ready,
  reconnecting,
  failed,
}

/// A bridge found during a scan.
class WmrBridgeDevice {
  const WmrBridgeDevice({required this.id, this.name, this.rssi});

  /// Platform-specific identifier (a UUID on iOS, a MAC on Android).
  final String id;

  /// Advertised name, when the platform exposes it.
  final String? name;

  /// Signal strength in dBm at the latest sighting, when available.
  final int? rssi;
}

/// What went wrong with an FF11/FF12/FF14 stream request.
enum WmrStreamModeFaultKind {
  /// ATT 0x80: the bridge says another stream is still enabled.
  otherStreamActive,
  enableFailed,
  disableFailed,

  /// Negotiated ATT MTU below 59 (FF12) or 61 (FF14), so the bridge sends
  /// nothing on the requested stream.
  mtuTooSmall,
}

/// The stream fault last reported by the controller service.
class WmrStreamModeFault {
  const WmrStreamModeFault(this.kind, this.message);

  final WmrStreamModeFaultKind kind;
  final String message;

  @override
  String toString() => '$kind: $message';
}

/// Per-hand counters, in the units of the active stream.
///
/// FF11 (raw) fills [frames], [incompleteFrames] and the sequence counters;
/// FF12/FF14 (decoded) fill [records], [rateHz], [missingFromTicks] and the
/// timing figures. Fields that the active stream does not produce stay zero
/// or null.
class WmrHandStats {
  const WmrHandStats({
    this.frames = 0,
    this.incompleteFrames = 0,
    this.lastSequence,
    this.sequenceGaps = 0,
    this.outOfOrder = 0,
    this.records = 0,
    this.rateHz = 0,
    this.missingFromTicks = 0,
    this.periodTicks,
    this.dt,
    this.windowLoss,
  });

  /// Reassembled FF11 frames.
  final int frames;

  /// FF11 fragments that never completed a frame.
  final int incompleteFrames;

  /// Last sequence number seen on the active stream.
  final int? lastSequence;

  /// Sequence numbers missing between consecutive received ones.
  final int sequenceGaps;

  /// Received sequence numbers not greater than the previous one.
  final int outOfOrder;

  /// Decoded records (FF12/FF14).
  final int records;

  /// Records per second over about a second, by phone arrival time.
  final double rateHz;

  /// Reports the controller numbered but that never arrived, from its own
  /// tick deltas. Includes loss before the ESP32 saw the report.
  final int missingFromTicks;

  /// Controller ticks per report, when known.
  final int? periodTicks;

  /// Device-tick timing statistics.
  final DtStats? dt;

  /// Received and missing reports over the trailing five seconds, when the
  /// decoded window has filled.
  final LossWindowStats? windowLoss;

  /// Reports estimated missing as a share of expected reports, 0 when
  /// nothing was expected yet.
  double get cumulativeLoss {
    final received = records.toDouble();
    final lost = missingFromTicks.toDouble();
    final expected = received + lost;
    return expected == 0 ? 0 : lost / expected;
  }
}

/// One frame (FF11) or decoded sample (FF12/FF14) of one hand.
class WmrControllerUpdate {
  const WmrControllerUpdate({
    required this.hand,
    required this.receivedAtUs,
    this.bridgeId = '',
    this.frame,
    this.decoded,
    this.orientation,
    this.input,
    this.stats = const WmrHandStats(),
  });

  final Hand hand;

  /// Transport device id of the bridge that delivered this update. Empty only
  /// when the update was synthesized without one.
  final String bridgeId;

  /// Monotonic receive time stamped by the transport before parsing.
  final int receivedAtUs;

  /// The reassembled FF11 frame; null on the decoded streams.
  final WmrFrame? frame;

  /// The FF12/FF14 record; null on the raw stream.
  final DecodedRecord? decoded;

  /// View-frame orientation after fusion, null until the filter is seeded.
  final Quaternion? orientation;

  /// Buttons, stick, trackpad, trigger and orientation of this sample; null
  /// on the raw stream, which carries no parsed input.
  final HandInput? input;

  final WmrHandStats stats;
}

/// What the link currently looks like.
class WmrLinkSnapshot {
  const WmrLinkSnapshot({
    required this.state,
    this.deviceId,
    this.mtu,
    this.rssi,
    this.connectionIntervalUs,
    this.phy,
    this.mode,
    this.fault,
    this.stats,
    this.protocol,
  });

  final WmrConnectionState state;
  final String? deviceId;

  /// Fields the platform does not expose are null.
  final int? mtu;
  final int? rssi;
  final int? connectionIntervalUs;
  final String? phy;

  /// The requested stream, after [WmrCompanion.setStreamMode].
  final StreamMode? mode;

  /// Set when the requested stream could not be enabled.
  final WmrStreamModeFault? fault;

  /// Decoded-stream counters while connected; null otherwise.
  final DecodedStats? stats;

  /// The bridge's firmware version (FF16) and its FF feature matrix.
  ///
  /// Null until the one-time read after connect completes, and when service
  /// discovery failed. A bridge without FF16 reports
  /// [WmrProtocolVersion.withoutFirmwareVersion]: an older firmware, not an
  /// error. See [WmrProtocolVersion.firmwareVersionMalformed] for a value that
  /// could not be decoded.
  final WmrProtocolVersion? protocol;

  bool get connected => state == WmrConnectionState.ready;
}
