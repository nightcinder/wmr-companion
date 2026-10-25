import 'models.dart';

/// Base of every error the facade reports. Raw platform exceptions never
/// leave the facade; they arrive as [cause] instead.
sealed class WmrException implements Exception {
  const WmrException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => '$runtimeType: $message';
}

/// The bridge could not be connected.
class WmrConnectionException extends WmrException {
  const WmrConnectionException(super.message, {this.deviceId, super.cause});

  final String? deviceId;
}

/// The transport failed for a reason that is not a connection or a stream
/// mode fault (scan failure, write failure, platform error).
class WmrTransportException extends WmrException {
  const WmrTransportException(super.message, {super.cause});
}

/// The requested FF11/FF12/FF14 stream could not be enabled. The link may
/// still be up; see [WmrStreamModeFaultKind] for the specific fault.
class WmrStreamModeException extends WmrException {
  const WmrStreamModeException(super.message, this.kind, {super.cause});

  final WmrStreamModeFaultKind kind;
}

/// The configuration or the decoded bridge data is not usable (for example
/// an FF13 block with a bad CRC or a missing Monado key).
class WmrConfigException extends WmrException {
  const WmrConfigException(super.message, {super.cause});
}

/// A headset tracking source could not be started or reported a failure.
class WmrTrackingException extends WmrException {
  const WmrTrackingException(super.message, {super.cause});
}
