/// Errors raised before or outside a notification stream.
///
/// A failed *subscription* is not raised here: it is delivered as
/// [BleStreamException] on the stream returned by
/// `BleTransport.subscribe`, exactly as on BLE.
library;

/// The socket, handshake or control protocol failed. The transport is left
/// disconnected; call `connect()` again.
class WmrWsException implements Exception {
  const WmrWsException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => cause == null
      ? 'WmrWsException: $message'
      : 'WmrWsException: $message ($cause)';
}

/// `hello` was missing, malformed, or announced a protocol this client does
/// not implement.
class WmrWsHandshakeException extends WmrWsException {
  const WmrWsHandshakeException(super.message, {super.cause});

  @override
  String toString() => 'WmrWsHandshakeException: $message';
}

/// Why authentication did not complete.
enum WmrWsAuthFailure {
  /// No token is configured for the endpoint, but the daemon requires one.
  noToken,

  /// The daemon answered `{"type":"error","code":"auth_failed"}` or closed
  /// with 4401.
  rejected,

  /// No answer arrived before the auth timeout. The daemon also closes with
  /// 4401 after five seconds; this is the local deadline.
  timeout,
}

/// Authentication failed; `connect()` throws this instead of returning a
/// half-open session.
class WmrWsAuthException extends WmrWsException {
  const WmrWsAuthException(this.failure, String message, {super.cause})
    : super(message);

  final WmrWsAuthFailure failure;

  @override
  String toString() => 'WmrWsAuthException(${failure.name}): $message';
}

/// A control message was refused with `{"type":"error","code":...}`.
class WmrWsControlException extends WmrWsException {
  const WmrWsControlException(this.code, String message, {super.cause})
    : super(message);

  /// Protocol error code, e.g. `stream_active`, `bad_stream`, `bad_json`,
  /// `unknown_type`, `binary_not_accepted`.
  final String code;

  @override
  String toString() => 'WmrWsControlException($code): $message';
}

/// The socket closed while it was needed.
class WmrWsClosedException extends WmrWsException {
  const WmrWsClosedException(
    String message, {
    this.closeCode,
    this.closeReason,
    super.cause,
  }) : super(message);

  final int? closeCode;
  final String? closeReason;

  @override
  String toString() =>
      'WmrWsClosedException: $message'
      '${closeCode == null ? '' : ' (code $closeCode'
                '${closeReason == null || closeReason!.isEmpty ? '' : ', $closeReason'}'
                ')'}';
}

/// The daemon does not implement this GATT characteristic.
///
/// FF13 (calibration) is the documented case: the Pi daemon has no equivalent,
/// so reading or writing it fails here rather than pretending.
class WmrWsUnsupportedException extends UnsupportedError {
  WmrWsUnsupportedException(String message) : super(message);
}
