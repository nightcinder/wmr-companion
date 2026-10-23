import 'dart:typed_data';

/// The 16-byte value returned by a read of FF11 (docs/PROTOCOL.md).
/// Diagnostics only; do not poll at stream rate.
class BridgeStatus {
  const BridgeStatus({
    required this.version,
    required this.connected,
    required this.hidDescriptorReceived,
    required this.uptimeSeconds,
    required this.reportsReceived,
  });

  static const int length = 16;

  final int version;

  /// Indexed by hand (0 = LEFT, 1 = RIGHT).
  final List<bool> connected;
  final List<bool> hidDescriptorReceived;

  /// Seconds since ESP32 boot. Not a frame sequence.
  final int uptimeSeconds;

  /// Reports received per hand on the current controller connection.
  final List<int> reportsReceived;

  /// Returns null if [value] is too short.
  static BridgeStatus? parse(Uint8List value) {
    if (value.length < length) return null;
    final b = ByteData.sublistView(value);
    return BridgeStatus(
      version: value[0],
      connected: [value[1] & 1 != 0, value[1] & 2 != 0],
      hidDescriptorReceived: [value[2] & 1 != 0, value[2] & 2 != 0],
      uptimeSeconds: b.getUint32(4, Endian.little),
      reportsReceived: [
        b.getUint32(8, Endian.little),
        b.getUint32(12, Endian.little),
      ],
    );
  }
}
