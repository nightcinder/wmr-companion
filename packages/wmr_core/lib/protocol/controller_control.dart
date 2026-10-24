import 'dart:typed_data';

/// FF17 write opcodes (docs/PROTOCOL.md, "Controller scan and status v2").
/// These map 1:1 onto the ESP32 console actions; the firmware keeps the
/// guards (forget is refused while a hand is connected).
enum ControllerCommand {
  discover(0x01),
  connect(0x02),
  disconnect(0x03),
  forgetAddresses(0x04),
  forgetBond(0x05);

  const ControllerCommand(this.opcode);

  final int opcode;

  /// True for commands that address one hand (byte 1). The others ignore it.
  bool get needsHand =>
      this == connect || this == disconnect || this == forgetBond;
}

/// Result codes of an FF17 write. The firmware returns success as ATT 0x00
/// and a failure as ATT application error `0x80 + code`, and records the code
/// in the status v2 `last_result` field.
enum ControllerResult {
  ok(0x00),
  busy(0x01),
  noAddress(0x02),
  nothingToDo(0x03),
  notConnected(0x04),
  notEnabled(0x05),
  invalidParam(0x06);

  const ControllerResult(this.code);

  final int code;

  static ControllerResult? fromCode(int? code) {
    for (final r in values) {
      if (r.code == code) return r;
    }
    return null;
  }
}

enum ControllerAddressSource {
  none,
  compileOverride,
  stored;

  static ControllerAddressSource fromCode(int code) =>
      switch (code) { 1 => compileOverride, 2 => stored, _ => none };
}

enum ControllerModel {
  wmr,
  psvr2;

  static ControllerModel fromCode(int code) =>
      code == 1 ? psvr2 : wmr;
}

enum ControllerDiscoveryState {
  idle,
  inquiry,
  remoteNameRequests,
  connectingDiscovered;

  static ControllerDiscoveryState fromCode(int code) => switch (code) {
    1 => inquiry,
    2 => remoteNameRequests,
    3 => connectingDiscovered,
    _ => idle,
  };
}

/// One hand's flags in a status v2 payload.
class HandControllerStatus {
  const HandControllerStatus({
    required this.connected,
    required this.connecting,
    required this.descriptorReceived,
    required this.addressSource,
    required this.model,
    required this.addressTail,
  });

  final bool connected;
  final bool connecting;
  final bool descriptorReceived;
  final ControllerAddressSource addressSource;
  final ControllerModel model;

  /// Last three bytes of the controller's Bluetooth address, zero when the
  /// hand has no address.
  final Uint8List addressTail;

  bool get hasAddress => addressTail.any((b) => b != 0);
}

/// The 20-byte status v2 value returned by an FF17 read or notification.
class ControllerStatusV2 {
  const ControllerStatusV2({
    required this.version,
    required this.hands,
    required this.discoveryState,
    required this.discoveryRound,
    required this.lastCommand,
    required this.lastResult,
  });

  static const int length = 20;
  static const int version1 = 1;

  final int version;

  /// Indexed by hand (0 = LEFT, 1 = RIGHT).
  final List<HandControllerStatus> hands;
  final ControllerDiscoveryState discoveryState;
  final int discoveryRound;

  /// Opcode of the last write command, null if none.
  final ControllerCommand? lastCommand;
  final ControllerResult lastResult;

  /// Returns null if [value] is too short for the version 1 layout.
  static ControllerStatusV2? parse(Uint8List value) {
    if (value.length < length) return null;
    HandControllerStatus handAt(int base) {
      final flags = value[base];
      return HandControllerStatus(
        connected: flags & 1 != 0,
        connecting: flags & 2 != 0,
        descriptorReceived: flags & 4 != 0,
        addressSource: ControllerAddressSource.fromCode(value[base + 1]),
        model: ControllerModel.fromCode(value[base + 2]),
        addressTail: Uint8List.fromList([
          value[base + 3],
          value[base + 4],
          value[base + 5],
        ]),
      );
    }

    ControllerCommand? lastCommand;
    for (final command in ControllerCommand.values) {
      if (command.opcode == value[17]) lastCommand = command;
    }
    return ControllerStatusV2(
      version: value[0],
      hands: [handAt(1), handAt(8)],
      discoveryState: ControllerDiscoveryState.fromCode(value[15]),
      discoveryRound: value[16],
      lastCommand: lastCommand,
      lastResult:
          ControllerResult.fromCode(value[18]) ?? ControllerResult.ok,
    );
  }
}

/// Thrown by a fake or test transport when the bridge refuses a command with
/// ATT error `0x80 + result`. A real platform reports the ATT status its own
/// way; [ControllerControlClient.send] does not depend on this type.
class ControllerCommandException implements Exception {
  const ControllerCommandException(this.command, this.result);

  final ControllerCommand? command;
  final ControllerResult result;

  @override
  String toString() =>
      'Controller command ${command?.name ?? '(none)'} refused: '
      '${result.name}';
}

/// Encodes an FF17 write: the opcode, plus the hand for commands that take
/// one (0 = LEFT, 1 = RIGHT).
///
/// Throws [ArgumentError] for a hand outside 0..1 or a command that needs a
/// hand but was given none, so a caller cannot send a malformed command.
Uint8List encodeControllerCommand(ControllerCommand command, {int? hand}) {
  if (hand != null && (hand < 0 || hand > 1)) {
    throw ArgumentError.value(hand, 'hand', 'must be 0 (LEFT) or 1 (RIGHT)');
  }
  if (command.needsHand && hand == null) {
    throw ArgumentError.notNull('hand');
  }
  if (command.needsHand) {
    return Uint8List.fromList([command.opcode, hand!]);
  }
  return Uint8List.fromList([command.opcode]);
}
