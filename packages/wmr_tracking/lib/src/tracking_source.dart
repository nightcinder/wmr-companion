import 'dart:async';

import 'codec.dart';
import 'tracking_types.dart';
import 'unity_relay.dart';

/// Why a tracking source is not running.
enum TrackingExceptionKind {
  /// The device or runtime does not support the requested feature.
  unsupported,

  /// A runtime permission was denied.
  permissionDenied,

  /// The SDK, service or relay is not present or not reachable.
  unavailable,

  /// A frame or handshake was malformed.
  protocol,

  /// The source was used after [TrackingSource.dispose].
  closed,
}

/// A typed failure from a tracking source.
class TrackingException implements Exception {
  const TrackingException(this.kind, this.message, {this.cause, this.stage});

  final TrackingExceptionKind kind;
  final String message;
  final Object? cause;

  /// The platform boundary that failed, when the source reports one.
  ///
  /// Android XR names `permissions`, `sessionCreate`, `sessionConfigure` and
  /// `trackingStart`, so a crash-safe failure says where it stopped instead of
  /// looking like an empty stream.
  final String? stage;

  @override
  String toString() => stage == null
      ? 'TrackingException($kind): $message'
      : 'TrackingException($kind, stage: $stage): $message';
}

/// A source of head and hand tracking for 6DoF fusion.
///
/// Implementations live outside this pure-Dart package: an Android XR app can
/// wrap ARCore for Jetpack XR behind a Flutter method/event channel, Viture
/// can wrap its C SDK with FFI, and the Unity-only SDKs (XREAL, RayNeo, Rokid,
/// VITURE Pro Neckband) need an embedded Unity build or a sidecar relay.
/// `FakeTrackingSource` covers tests and UI development.
///
/// Lifecycle: [start] subscribes to the platform, [frames] is a broadcast
/// stream, [stop] releases the platform subscription and [dispose] is final.
/// Implementations must not emit before [start] or after [stop].
abstract interface class TrackingSource {
  /// Stable id used in logs and to de-duplicate sources.
  String get id;

  TrackingVendor get vendor;

  /// Declared before [start]; the app uses it to choose a fusion strategy.
  TrackingCapabilities get capabilities;

  /// Tracking frames, newest last. Broadcast.
  Stream<TrackingFrame> get frames;

  Future<void> start();

  Future<void> stop();

  Future<void> dispose();
}

/// An in-process source for tests, examples and UI development.
///
/// It records whether it was started and rejects frames outside the running
/// window instead of silently dropping them, so a lifecycle mistake fails a
/// test.
class FakeTrackingSource implements TrackingSource {
  FakeTrackingSource({
    this.id = 'fake',
    this.capabilities = const TrackingCapabilities(
      features: {TrackingFeature.headPose6Dof, TrackingFeature.handJoints},
      handJointCount: 26,
      maxHeadRateHz: 60,
      maxHandRateHz: 30,
    ),
  });

  @override
  final String id;

  @override
  final TrackingCapabilities capabilities;

  @override
  TrackingVendor get vendor => TrackingVendor.fake;

  final StreamController<TrackingFrame> _frames =
      StreamController<TrackingFrame>.broadcast();

  bool _started = false;
  bool _disposed = false;

  bool get started => _started;
  bool get disposed => _disposed;

  @override
  Stream<TrackingFrame> get frames => _frames.stream;

  @override
  Future<void> start() async {
    _ensureOpen();
    _started = true;
  }

  @override
  Future<void> stop() async {
    _ensureOpen();
    _started = false;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _started = false;
    await _frames.close();
  }

  /// Adds a frame. Throws [StateError] unless the source is started.
  void addFrame(TrackingFrame frame) {
    _ensureOpen();
    if (!_started) {
      throw StateError('FakeTrackingSource is not started');
    }
    _frames.add(frame);
  }

  /// Reports a source failure on [frames].
  void addError(Object error, [StackTrace? stackTrace]) {
    _ensureOpen();
    if (!_started) {
      throw StateError('FakeTrackingSource is not started');
    }
    _frames.addError(error, stackTrace);
  }

  void _ensureOpen() {
    if (_disposed) {
      throw StateError('FakeTrackingSource has been disposed');
    }
  }
}

/// A [TrackingSource] over vendor-neutral JSON messages.
///
/// This is the seam for a Unity sidecar (XREAL/VITURE) or any native process
/// that cannot be linked directly: the adapter writes one `TrackingFrame`
/// JSON object or string per message, and this source decodes it with
/// [TrackingFrameCodec]. The facade still aligns [TrackingFrame.timeNs] to the
/// host clock.
///
/// The caller owns the transport that produces [messages]; [dispose] cancels
/// the subscription but does not close the transport.
class RelayTrackingSource implements TrackingSource {
  RelayTrackingSource({
    required this.messages,
    this.id = 'relay',
    this.vendor = TrackingVendor.relay,
    this.capabilities = const TrackingCapabilities(
      features: {TrackingFeature.headPose6Dof, TrackingFeature.handJoints},
    ),
    this.codec = const TrackingFrameCodec(),
    this.defaultSpace = UnityRelayCoordinateSpace.openXr,
  });

  @override
  final String id;

  @override
  final TrackingVendor vendor;

  @override
  final TrackingCapabilities capabilities;

  /// JSON maps or strings, one frame per event.
  final Stream<Object?> messages;

  final TrackingFrameCodec codec;

  /// Coordinate space assumed when a relay frame omits `"space"`.
  final UnityRelayCoordinateSpace defaultSpace;

  final StreamController<TrackingFrame> _frames =
      StreamController<TrackingFrame>.broadcast();

  StreamSubscription<Object?>? _sub;
  bool _started = false;
  bool _disposed = false;

  @override
  Stream<TrackingFrame> get frames => _frames.stream;

  @override
  Future<void> start() async {
    if (_disposed) {
      throw StateError('RelayTrackingSource has been disposed');
    }
    if (_started) return;
    _started = true;
    final relayCodec = UnityRelayFrameCodec(
      defaultSpace: defaultSpace,
      codec: codec,
    );
    _sub = messages.listen(
      (message) {
        try {
          final frame = switch (message) {
            String text => relayCodec.decodeString(text),
            Map<Object?, Object?> map => relayCodec.decode(map),
            _ => throw const FormatException(
              'relay frame must be a JSON map or string',
            ),
          };
          if (!_frames.isClosed) _frames.add(frame);
        } catch (error) {
          if (!_frames.isClosed) {
            _frames.addError(
              TrackingException(
                TrackingExceptionKind.protocol,
                'Invalid relay tracking frame',
                cause: error,
              ),
            );
          }
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!_frames.isClosed) {
          _frames.addError(
            TrackingException(
              TrackingExceptionKind.protocol,
              'Relay tracking stream failed',
              cause: error,
            ),
            stackTrace,
          );
        }
      },
    );
  }

  @override
  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    _started = false;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await stop();
    await _frames.close();
  }
}
