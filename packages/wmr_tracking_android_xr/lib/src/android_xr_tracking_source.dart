import 'dart:async';

import 'package:flutter/services.dart';
import 'package:wmr_tracking/wmr_tracking.dart';

/// The default-off build flag for the Android XR vertical slice.
///
/// Pass `--dart-define=WMR_ANDROID_XR_TRACKING=true` to opt in. With the flag
/// off, [AndroidXrTrackingSource.create] returns null without touching the
/// platform channels, so BLE, controller IMU and 3DoF behaviour are unchanged.
abstract final class AndroidXrTracking {
  static const bool enabled = bool.fromEnvironment(
    'WMR_ANDROID_XR_TRACKING',
    defaultValue: false,
  );
}

/// The platform seam behind [AndroidXrTrackingSource].
///
/// Tests replace this with a fake; production uses the two named channels
/// implemented by the Kotlin plugin. [create] only asks for capabilities;
/// permissions and the XR session start in [start].
class AndroidXrTrackingPlatform {
  const AndroidXrTrackingPlatform({
    this.methods = const MethodChannel('wmr_tracking_android_xr/methods'),
    this.events = const EventChannel('wmr_tracking_android_xr/frames'),
  });

  final MethodChannel methods;
  final EventChannel events;

  /// Device support and permission state without starting a session.
  Future<Map<String, Object?>> capabilities() async {
    final result = await methods.invokeMapMethod<String, Object?>(
      'capabilities',
    );
    if (result == null) {
      throw PlatformException(
        code: 'protocol',
        message: 'capabilities returned no map',
      );
    }
    return result;
  }

  Future<void> start() => methods.invokeMethod<void>('start');

  Future<void> stop() => methods.invokeMethod<void>('stop');

  Future<void> dispose() => methods.invokeMethod<void>('dispose');

  /// One JSON string (or map) per tracking frame, plus typed platform errors.
  Stream<Object?> frames() => events.receiveBroadcastStream();
}

/// A [TrackingSource] for Android XR headsets and wired XR glasses.
///
/// The Kotlin plugin owns the ARCore for Jetpack XR session. It requests
/// `CAMERA`, `SCENE_UNDERSTANDING_COARSE`, `HAND_TRACKING` and
/// `HEAD_TRACKING`, waits for every grant and for the activity to resume,
/// configures `HandTrackingMode.BOTH` and `DeviceTrackingMode.SPATIAL`,
/// converts perception-space poses to the activity space and emits 26
/// OpenXR-named joints plus the device pose as `TrackingFrameCodec` JSON.
///
/// Failures are typed: a denied permission, an unsupported device or a refused
/// SPATIAL mode throws [TrackingException] from [create] or [start] instead of
/// leaving an empty stream. A platform failure carries the boundary that
/// failed in [TrackingException.stage] (`permissions`, `sessionCreate`,
/// `sessionConfigure` or `trackingStart`). Runtime tracking loss arrives as
/// frames without the missing hand or head; it is not an error.
class AndroidXrTrackingSource implements TrackingSource {
  AndroidXrTrackingSource._({
    required this.platform,
    required this.capabilities,
    Map<String, String> permissions = const {},
  }) : permissions = Map.unmodifiable(permissions);

  /// Creates the source when the default-off flag is enabled.
  ///
  /// Returns null when [enabled] (or [AndroidXrTracking.enabled]) is false
  /// without calling the platform. Throws [TrackingException] when the device
  /// is not an XR device, Android XR hand tracking is unavailable, or the
  /// capability handshake is malformed.
  static Future<AndroidXrTrackingSource?> create({
    bool? enabled,
    AndroidXrTrackingPlatform platform = const AndroidXrTrackingPlatform(),
  }) async {
    if (!(enabled ?? AndroidXrTracking.enabled)) return null;

    final Map<String, Object?> raw;
    try {
      raw = await platform.capabilities();
    } on PlatformException catch (error) {
      throw _mapPlatformError(error);
    }

    final supported = raw['supported'] == true;
    final handTracking = raw['handTracking'] == true;
    final headTracking = raw['headTracking'] == true;
    final jointCount = raw['handJointCount'];
    final reason = raw['reason'];
    if (!supported || !handTracking || !headTracking) {
      throw TrackingException(
        TrackingExceptionKind.unsupported,
        reason is String && reason.isNotEmpty
            ? reason
            : 'Android XR head and hand tracking are not supported here',
      );
    }
    if (jointCount is! int || jointCount <= 0) {
      throw const TrackingException(
        TrackingExceptionKind.protocol,
        'capabilities did not report a hand joint count',
      );
    }

    final permissions = <String, String>{};
    final permissionsJson = raw['permissions'];
    if (permissionsJson is Map) {
      for (final entry in permissionsJson.entries) {
        if (entry.key is String && entry.value is String) {
          permissions[entry.key as String] = entry.value as String;
        }
      }
    }

    return AndroidXrTrackingSource._(
      platform: platform,
      capabilities: TrackingCapabilities(
        features: const {
          TrackingFeature.headPose6Dof,
          TrackingFeature.handJoints,
        },
        handJointCount: jointCount,
        // Android XR does not document a nominal rate; 0 means unknown.
        maxHandRateHz: 0,
        maxHeadRateHz: 0,
      ),
      permissions: permissions,
    );
  }

  final AndroidXrTrackingPlatform platform;

  @override
  final TrackingCapabilities capabilities;

  /// Permission state reported during [create]: `granted`, `denied`, `missing`
  /// or another runtime value. Empty when the platform did not report it.
  final Map<String, String> permissions;

  final StreamController<TrackingFrame> _frames =
      StreamController<TrackingFrame>.broadcast();
  final TrackingFrameCodec _codec = const TrackingFrameCodec();

  StreamSubscription<Object?>? _sub;
  bool _started = false;
  bool _disposed = false;

  @override
  String get id => 'android-xr';

  @override
  TrackingVendor get vendor => TrackingVendor.androidXr;

  @override
  Stream<TrackingFrame> get frames => _frames.stream;

  bool get started => _started;
  bool get disposed => _disposed;

  @override
  Future<void> start() async {
    _ensureOpen();
    if (_started) return;
    _started = true;
    _sub = platform.frames().listen(
      _onMessage,
      onError: (Object error, StackTrace stackTrace) {
        // The platform stopped sending (for example, the activity was
        // detached). Drop this subscription so a later start() can resubscribe
        // instead of silently returning while no frames arrive.
        _started = false;
        final subscription = _sub;
        _sub = null;
        unawaited(subscription?.cancel());
        if (!_frames.isClosed) {
          _frames.addError(_mapPlatformError(error), stackTrace);
        }
      },
    );
    try {
      await platform.start();
    } catch (error) {
      _started = false;
      await _sub?.cancel();
      _sub = null;
      throw _mapPlatformError(error);
    }
  }

  @override
  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    await _sub?.cancel();
    _sub = null;
    await platform.stop();
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await stop();
    } finally {
      try {
        await platform.dispose();
      } finally {
        await _frames.close();
      }
    }
  }

  void _onMessage(Object? message) {
    if (!_started || _frames.isClosed) return;
    try {
      final frame = switch (message) {
        String text => _codec.decodeString(text),
        Map<String, Object?> map => _codec.decode(map),
        Map map => _codec.decode(Map<String, Object?>.from(map)),
        _ => throw const FormatException(
          'Android XR frame must be a JSON map or string',
        ),
      };
      if (frame.timeNs <= 0) {
        throw const FormatException('Android XR timestamp must be positive');
      }
      _frames.add(frame);
    } catch (error) {
      _frames.addError(
        TrackingException(
          TrackingExceptionKind.protocol,
          'Invalid Android XR tracking frame',
          cause: error,
        ),
      );
    }
  }

  void _ensureOpen() {
    if (_disposed) {
      throw StateError('AndroidXrTrackingSource has been disposed');
    }
  }
}

TrackingException _mapPlatformError(Object error) {
  if (error is TrackingException) return error;
  if (error is PlatformException) {
    final kind = switch (error.code) {
      'permissionDenied' => TrackingExceptionKind.permissionDenied,
      'unsupported' => TrackingExceptionKind.unsupported,
      'unavailable' => TrackingExceptionKind.unavailable,
      'closed' => TrackingExceptionKind.closed,
      'protocol' => TrackingExceptionKind.protocol,
      _ => TrackingExceptionKind.protocol,
    };
    final details = error.details;
    final stage = details is Map && details['stage'] is String
        ? details['stage'] as String
        : null;
    return TrackingException(
      kind,
      error.message ?? 'Android XR tracking failed (${error.code})',
      cause: error,
      stage: stage,
    );
  }
  return TrackingException(
    TrackingExceptionKind.protocol,
    'Android XR tracking failed',
    cause: error,
  );
}
