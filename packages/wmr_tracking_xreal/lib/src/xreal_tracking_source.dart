import 'dart:async';

import 'package:flutter/services.dart';
import 'package:wmr_tracking/wmr_tracking.dart';

/// The default-off build flag for the XREAL Air 2 Ultra vertical slice.
///
/// Pass `--dart-define=WMR_XREAL_TRACKING=true` to opt in. With the flag off,
/// [XrealAir2UltraTrackingSource.create] returns null without touching the
/// platform channels, so BLE, controller IMU and 3DoF behaviour are unchanged.
abstract final class XrealTracking {
  static const bool enabled = bool.fromEnvironment(
    'WMR_XREAL_TRACKING',
    defaultValue: false,
  );
}

/// Glasses models reported by `XREALPlugin.GetDeviceType()` in XREAL SDK 3.x
/// (`Unity.XR.XREAL.XREALDeviceType`).
///
/// Only [air2Ultra] provides 6DoF head pose and 26-joint XR Hands skeletal
/// hand tracking. The One series adds 6DoF head pose with the XREAL Eye but
/// never exposes hands; Air, Air 2 and Air 2 Pro are 3DoF head-only.
enum XrealGlassesModel {
  air2Ultra(
    'Air2Ultra',
    sdkNames: ['Air2Ultra', 'XREALAir2Ultra', 'NRAir2Ultra'],
    supports6DofHead: true,
    supportsHandTracking: true,
  ),
  one(
    'One',
    sdkNames: ['One', 'XREALOne', 'NRGlassesOne'],
    supports6DofHead: true,
    supportsHandTracking: false,
  ),
  onePro(
    'OnePro',
    sdkNames: ['OnePro', 'XREALOnePro'],
    supports6DofHead: true,
    supportsHandTracking: false,
  ),
  air(
    'Air',
    sdkNames: ['Air', 'XREALAir', 'NRAir'],
    supports6DofHead: false,
    supportsHandTracking: false,
  ),
  air2(
    'Air2',
    sdkNames: ['Air2', 'XREALAir2', 'NRAir2'],
    supports6DofHead: false,
    supportsHandTracking: false,
  ),
  air2Pro(
    'Air2Pro',
    sdkNames: ['Air2Pro', 'XREALAir2Pro', 'NRAir2Pro'],
    supports6DofHead: false,
    supportsHandTracking: false,
  ),
  light(
    'Light',
    sdkNames: ['Light', 'XREALLight', 'NRLight'],
    supports6DofHead: false,
    supportsHandTracking: false,
  ),
  unknown(
    'Unknown',
    sdkNames: ['Unknown'],
    supports6DofHead: false,
    supportsHandTracking: false,
  );

  const XrealGlassesModel(
    this.sdkName, {
    required this.sdkNames,
    required this.supports6DofHead,
    required this.supportsHandTracking,
  });

  /// Canonical name reported by this slice in capability responses.
  final String sdkName;

  /// Accepted `XREALDeviceType` spellings, including the legacy NRSDK names.
  final List<String> sdkNames;

  /// Whether this model exposes 6DoF head tracking through XREAL SDK 3.x.
  final bool supports6DofHead;

  /// Whether this model exposes 26-joint XR Hands skeletal tracking.
  final bool supportsHandTracking;

  /// Honest static capabilities for this glasses model.
  ///
  /// Never advertises hand joints on the One series, Air, Air 2 or Air 2 Pro,
  /// and never advertises WMR controller poses.
  TrackingCapabilities get capabilities {
    if (this == XrealGlassesModel.unknown) {
      return TrackingCapabilities.none;
    }
    if (supportsHandTracking) {
      return const TrackingCapabilities(
        features: {
          TrackingFeature.headPose6Dof,
          TrackingFeature.handJoints,
          TrackingFeature.handGestures,
          TrackingFeature.passthroughCamera,
        },
        handJointCount: 26,
        maxHandRateHz: 0,
        maxHeadRateHz: 0,
      );
    }
    return TrackingCapabilities(
      features: {
        supports6DofHead
            ? TrackingFeature.headPose6Dof
            : TrackingFeature.headPose3Dof,
      },
      handJointCount: 0,
      maxHandRateHz: 0,
      maxHeadRateHz: 0,
    );
  }

  /// Resolves a `XREALPlugin.GetDeviceType()` enum name.
  static XrealGlassesModel fromSdkName(Object? raw) {
    if (raw is! String || raw.trim().isEmpty) return XrealGlassesModel.unknown;
    final normalized = _normalize(raw);
    for (final model in XrealGlassesModel.values) {
      for (final alias in model.sdkNames) {
        if (_normalize(alias) == normalized) return model;
      }
    }
    return XrealGlassesModel.unknown;
  }

  static String _normalize(String value) =>
      value.replaceAll(RegExp('[^A-Za-z0-9]'), '').toLowerCase();
}

/// The platform seam behind [XrealAir2UltraTrackingSource].
///
/// Tests replace this with a fake; production uses the two named channels
/// implemented by the Kotlin Unity-as-a-Library relay plugin.
class XrealTrackingPlatform {
  const XrealTrackingPlatform({
    this.methods = const MethodChannel('wmr_tracking_xreal/methods'),
    this.events = const EventChannel('wmr_tracking_xreal/frames'),
  });

  final MethodChannel methods;
  final EventChannel events;

  /// Host, Unity UaaL bridge, glasses model and permission state without
  /// starting hand tracking.
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

/// Alias for [XrealAir2UltraTrackingSource].
typedef XrealTrackingSource = XrealAir2UltraTrackingSource;

/// A [TrackingSource] for the XREAL Air 2 Ultra Unity XR Hands relay.
///
/// The Kotlin plugin owns the Unity-as-a-Library (UaaL) relay bridge: it
/// checks `android.permission.CAMERA`, sends `UnityRelayCommand`s to the
/// `WmrTrackingRelay` GameObject via `UnityPlayer.UnitySendMessage`, and
/// forwards head pose plus 26 OpenXR-named hand joints back over an event
/// channel. The C# bridge converts left-handed Unity coordinates
/// (`"space": "openxr"`) before leaving the Unity scene.
///
/// Failures are typed: a missing Unity UaaL library is `unavailable`, a
/// non-Air-2-Ultra glasses model (`One`, `OnePro`, `Air`, `Air2`, `Air2Pro`,
/// `Light`) is `unsupported`, a denied camera permission is `permissionDenied`,
/// and a malformed frame or handshake is `protocol`.
class XrealAir2UltraTrackingSource implements TrackingSource {
  XrealAir2UltraTrackingSource._({
    required this.platform,
    required this.capabilities,
    required this.glassesModel,
    Map<String, String> permissions = const {},
  }) : permissions = Map.unmodifiable(permissions);

  /// Creates the source when the default-off flag is enabled.
  ///
  /// Returns null when [enabled] (or [XrealTracking.enabled]) is false without
  /// calling the platform. Throws [TrackingException] when the Unity UaaL
  /// runtime is absent (`unavailable`), the connected glasses do not support
  /// 6DoF + hand tracking (`unsupported`), or the capability handshake is
  /// malformed (`protocol`).
  static Future<XrealAir2UltraTrackingSource?> create({
    bool? enabled,
    XrealTrackingPlatform platform = const XrealTrackingPlatform(),
  }) async {
    if (!(enabled ?? XrealTracking.enabled)) return null;

    final Map<String, Object?> raw;
    try {
      raw = await platform.capabilities();
    } on PlatformException catch (error) {
      throw _mapPlatformError(error);
    }

    final unityAvailable = raw['unityAvailable'];
    final reason = raw['reason'];
    if (unityAvailable == false) {
      throw TrackingException(
        TrackingExceptionKind.unavailable,
        reason is String && reason.isNotEmpty
            ? reason
            : 'XREAL Unity UaaL relay is not linked in this build',
      );
    }

    final glassesModel = XrealGlassesModel.fromSdkName(raw['glassesModel']);
    final supported = raw['supported'] == true;
    final handTracking = raw['handTracking'] == true;
    final headTracking = raw['headTracking'] == true;
    final jointCount = raw['handJointCount'];

    if (!supported ||
        !handTracking ||
        !headTracking ||
        (glassesModel != XrealGlassesModel.unknown &&
            !glassesModel.supportsHandTracking)) {
      throw TrackingException(
        TrackingExceptionKind.unsupported,
        reason is String && reason.isNotEmpty
            ? reason
            : 'XREAL hand tracking requires Air 2 Ultra '
                  '(reported ${glassesModel.sdkName})',
      );
    }
    if (jointCount is! int || jointCount <= 0) {
      throw const TrackingException(
        TrackingExceptionKind.protocol,
        'capabilities did not report a positive handJointCount',
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

    final features = <TrackingFeature>{
      TrackingFeature.headPose6Dof,
      TrackingFeature.handJoints,
      if (raw['handGestures'] != false) TrackingFeature.handGestures,
      if (raw['passthroughCamera'] != false) TrackingFeature.passthroughCamera,
    };

    return XrealAir2UltraTrackingSource._(
      platform: platform,
      glassesModel: glassesModel == XrealGlassesModel.unknown
          ? XrealGlassesModel.air2Ultra
          : glassesModel,
      capabilities: TrackingCapabilities(
        features: features,
        handJointCount: jointCount,
        // XREAL does not document nominal XR Hands or head rates; 0 = unknown.
        maxHandRateHz: 0,
        maxHeadRateHz: 0,
      ),
      permissions: permissions,
    );
  }

  final XrealTrackingPlatform platform;

  @override
  final TrackingCapabilities capabilities;

  /// Glasses model reported by the XREAL Unity SDK during [create].
  final XrealGlassesModel glassesModel;

  /// Permission state reported during [create] (for example `camera`: `granted`
  /// or `missing`).
  final Map<String, String> permissions;

  final StreamController<TrackingFrame> _frames =
      StreamController<TrackingFrame>.broadcast();
  final UnityRelayFrameCodec _relayCodec = const UnityRelayFrameCodec();

  StreamSubscription<Object?>? _sub;
  bool _started = false;
  bool _disposed = false;

  @override
  String get id => 'xreal-air-2-ultra';

  @override
  TrackingVendor get vendor => TrackingVendor.xreal;

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
        String text => _relayCodec.decodeString(text),
        Map<Object?, Object?> map => _relayCodec.decode(map),
        _ => throw const FormatException(
          'XREAL relay frame must be a JSON map or string',
        ),
      };
      _frames.add(frame);
    } catch (error) {
      _frames.addError(
        TrackingException(
          TrackingExceptionKind.protocol,
          'Invalid XREAL tracking frame',
          cause: error,
        ),
      );
    }
  }

  void _ensureOpen() {
    if (_disposed) {
      throw StateError('XrealAir2UltraTrackingSource has been disposed');
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
    return TrackingException(
      kind,
      error.message ?? 'XREAL tracking failed (${error.code})',
      cause: error,
    );
  }
  return TrackingException(
    TrackingExceptionKind.protocol,
    'XREAL tracking failed',
    cause: error,
  );
}
