import 'dart:async';

import 'package:flutter/services.dart';
import 'package:wmr_tracking/wmr_tracking.dart';

/// The default-off build flag for the VITURE Pro Neckband vertical slice.
///
/// Pass `--dart-define=WMR_VITURE_TRACKING=true` to opt in. With the flag off,
/// [VitureNeckbandTrackingSource.create] returns null without touching the
/// platform channels, so BLE, controller IMU and 3DoF behaviour are unchanged.
abstract final class VitureTracking {
  static const bool enabled = bool.fromEnvironment(
    'WMR_VITURE_TRACKING',
    defaultValue: false,
  );
}

/// Glasses models reported by `VitureXR.Glasses.GetGlassesModel()` in the
/// VITURE XR SDK for Unity (v0.9.0, `Viture.XR.VitureXR`).
///
/// Only [lumaUltra] provides 6DoF head pose and XR Hands skeletal hand
/// tracking on the Pro Neckband; the remaining models are 3DoF head-only.
enum VitureGlassesModel {
  one('One', supports6DofHead: false, supportsHandTracking: false),
  oneLite('OneLite', supports6DofHead: false, supportsHandTracking: false),
  pro('Pro', supports6DofHead: false, supportsHandTracking: false),
  pro2('Pro2', supports6DofHead: false, supportsHandTracking: false),
  luma('Luma', supports6DofHead: false, supportsHandTracking: false),
  lumaPro('LumaPro', supports6DofHead: false, supportsHandTracking: false),
  lumaUltra('LumaUltra', supports6DofHead: true, supportsHandTracking: true),
  lumaCyber('LumaCyber', supports6DofHead: false, supportsHandTracking: false),
  beast('Beast', supports6DofHead: false, supportsHandTracking: false),
  unknown('Unknown', supports6DofHead: false, supportsHandTracking: false);

  const VitureGlassesModel(
    this.sdkName, {
    required this.supports6DofHead,
    required this.supportsHandTracking,
  });

  /// Canonical enum name in `VitureXR.Glasses.GetGlassesModel()`.
  final String sdkName;

  /// Whether this model exposes 6DoF head tracking on the Pro Neckband.
  final bool supports6DofHead;

  /// Whether this model exposes 26-joint XR Hands skeletal tracking on the Pro
  /// Neckband.
  final bool supportsHandTracking;

  /// Honest static capabilities for this glasses model on the Pro Neckband.
  ///
  /// Never advertises hand joints or 6DoF head pose on 3DoF-only glasses, and
  /// never advertises WMR controller poses.
  TrackingCapabilities get capabilities {
    if (this == VitureGlassesModel.unknown) {
      return TrackingCapabilities.none;
    }
    if (supportsHandTracking) {
      return const TrackingCapabilities(
        features: {
          TrackingFeature.headPose6Dof,
          TrackingFeature.handJoints,
          TrackingFeature.handGestures,
          TrackingFeature.passthroughCamera,
          TrackingFeature.originReset,
        },
        handJointCount: 26,
        maxHandRateHz: 0,
        maxHeadRateHz: 0,
      );
    }
    return const TrackingCapabilities(
      features: {TrackingFeature.headPose3Dof},
      handJointCount: 0,
      maxHandRateHz: 0,
      maxHeadRateHz: 0,
    );
  }

  /// Resolves a `VitureXR.Glasses.GetGlassesModel()` name.
  static VitureGlassesModel fromSdkName(Object? raw) {
    if (raw is! String || raw.isEmpty) return VitureGlassesModel.unknown;
    final normalized = raw
        .replaceAll('_', '')
        .replaceAll('-', '')
        .toLowerCase();
    for (final model in VitureGlassesModel.values) {
      if (model.sdkName.toLowerCase() == normalized) {
        return model;
      }
    }
    return VitureGlassesModel.unknown;
  }
}

/// Filter modes exposed by `VitureXR.HandTracking.filterMode`.
enum VitureHandFilterMode {
  responsive('responsive'),
  stable('stable');

  const VitureHandFilterMode(this.wireName);

  final String wireName;
}

/// Aim sensitivity exposed by `VitureXR.HandTracking.aimSensitivity` (6DoF only).
enum VitureAimSensitivity {
  low('low'),
  high('high');

  const VitureAimSensitivity(this.wireName);

  final String wireName;
}

/// The platform seam behind [VitureNeckbandTrackingSource].
///
/// Tests replace this with a fake; production uses the two named channels
/// implemented by the Kotlin Unity-as-a-Library relay plugin.
class VitureTrackingPlatform {
  const VitureTrackingPlatform({
    this.methods = const MethodChannel('wmr_tracking_viture/methods'),
    this.events = const EventChannel('wmr_tracking_viture/frames'),
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

  Future<void> start({
    VitureHandFilterMode filterMode = VitureHandFilterMode.responsive,
    VitureAimSensitivity aimSensitivity = VitureAimSensitivity.high,
  }) => methods.invokeMethod<void>('start', <String, Object?>{
    'filter_mode': filterMode.wireName,
    'aim_sensitivity': aimSensitivity.wireName,
  });

  Future<void> stop() => methods.invokeMethod<void>('stop');

  Future<void> dispose() => methods.invokeMethod<void>('dispose');

  /// Sends a typed [UnityRelayCommand] to the embedded Unity relay.
  Future<void> sendCommand(UnityRelayCommand command) =>
      methods.invokeMethod<void>('command', command.toJson());

  /// One JSON string (or map) per tracking frame, plus typed platform errors.
  Stream<Object?> frames() => events.receiveBroadcastStream();

  /// Debug-only: opens the VITURE glasses and returns the USB fd metadata
  /// (`session`, `fd`, `productId`) for the Carina native harness.
  Future<Map<String, Object?>> openCarinaDiagnosticUsb() async {
    final result = await methods.invokeMapMethod<String, Object?>(
      'carinaDiagnosticUsb',
    );
    if (result == null) {
      throw PlatformException(
        code: 'protocol',
        message: 'carinaDiagnosticUsb returned no map',
      );
    }
    return result;
  }

  /// Closes the USB connection that owns the fd handed to the native harness.
  Future<void> closeCarinaDiagnosticUsb(String session) =>
      methods.invokeMethod<void>('carinaDiagnosticUsbClose', <String, Object?>{
        'session': session,
      });
}

/// Alias for [VitureNeckbandTrackingSource].
typedef VitureTrackingSource = VitureNeckbandTrackingSource;

/// A [TrackingSource] for the VITURE Pro Neckband + Luma Ultra Unity XR relay.
///
/// The Kotlin plugin owns the Unity-as-a-Library (UaaL) relay bridge: it
/// checks `android.permission.CAMERA`, sends `UnityRelayCommand`s to the
/// `WmrTrackingRelay` GameObject via `UnityPlayer.UnitySendMessage`, and
/// forwards head pose plus 26 OpenXR-named hand joints back over an event
/// channel. Left-handed Unity coordinates (`"space": "unity"`) are converted to
/// right-handed OpenXR coordinates before leaving this source.
///
/// Failures are typed: a missing Unity UaaL library is `unavailable`, a 3DoF
/// glasses model (`One`, `Pro`, `Luma`, `LumaPro`, ...) or non-Neckband host is
/// `unsupported`, a denied camera permission is `permissionDenied`, and a
/// malformed frame or handshake is `protocol`.
class VitureNeckbandTrackingSource implements TrackingSource {
  VitureNeckbandTrackingSource._({
    required this.platform,
    required this.capabilities,
    required this.glassesModel,
    required this.filterMode,
    required this.aimSensitivity,
    Map<String, String> permissions = const {},
  }) : permissions = Map.unmodifiable(permissions);

  /// Creates the source when the default-off flag is enabled.
  ///
  /// Returns null when [enabled] (or [VitureTracking.enabled]) is false without
  /// calling the platform. Throws [TrackingException] when the Unity UaaL
  /// runtime is absent (`unavailable`), the connected glasses do not support
  /// 6DoF + hand tracking (`unsupported`), or the capability handshake is
  /// malformed (`protocol`).
  static Future<VitureNeckbandTrackingSource?> create({
    bool? enabled,
    VitureTrackingPlatform platform = const VitureTrackingPlatform(),
    VitureHandFilterMode filterMode = VitureHandFilterMode.responsive,
    VitureAimSensitivity aimSensitivity = VitureAimSensitivity.high,
  }) async {
    if (!(enabled ?? VitureTracking.enabled)) return null;

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
            : 'VITURE Unity UaaL relay is not linked in this build',
      );
    }

    final glassesModel = VitureGlassesModel.fromSdkName(raw['glassesModel']);
    // The unified Unity scene keeps the VITURE backend inactive until `start`,
    // so the native layer cannot report a model before capabilities and marks
    // it with `modelReported: false`. Defer the Luma Ultra check to the Unity
    // start handshake in that case. Absent means reported, so an older native
    // plugin keeps failing closed.
    final modelReported = raw['modelReported'] != false;
    final supported = raw['supported'] == true;
    final handTracking = raw['handTracking'] == true;
    final headTracking = raw['headTracking'] == true;
    final jointCount = raw['handJointCount'];

    if (!supported ||
        !handTracking ||
        !headTracking ||
        (modelReported &&
            (glassesModel == VitureGlassesModel.unknown ||
                !glassesModel.supportsHandTracking))) {
      throw TrackingException(
        TrackingExceptionKind.unsupported,
        reason is String && reason.isNotEmpty
            ? reason
            : 'VITURE Pro Neckband hand tracking requires Luma Ultra glasses '
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
      TrackingFeature.originReset,
    };

    return VitureNeckbandTrackingSource._(
      platform: platform,
      glassesModel: glassesModel == VitureGlassesModel.unknown
          ? VitureGlassesModel.lumaUltra
          : glassesModel,
      filterMode: filterMode,
      aimSensitivity: aimSensitivity,
      capabilities: TrackingCapabilities(
        features: features,
        handJointCount: jointCount,
        // VITURE does not document nominal Unity head/hand rates; 0 = unknown.
        maxHandRateHz: 0,
        maxHeadRateHz: 0,
      ),
      permissions: permissions,
    );
  }

  final VitureTrackingPlatform platform;

  @override
  final TrackingCapabilities capabilities;

  /// Glasses model reported by the VITURE Unity SDK during [create].
  final VitureGlassesModel glassesModel;

  /// Initial `VitureXR.HandTracking.filterMode` sent on [start].
  final VitureHandFilterMode filterMode;

  /// Initial `VitureXR.HandTracking.aimSensitivity` sent on [start].
  final VitureAimSensitivity aimSensitivity;

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
  String get id => 'viture-neckband';

  @override
  TrackingVendor get vendor => TrackingVendor.viture;

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
      await platform.start(
        filterMode: filterMode,
        aimSensitivity: aimSensitivity,
      );
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

  /// Sends a `recenter` command to the embedded Unity VITURE relay.
  Future<void> recenter() async {
    _ensureOpen();
    try {
      await platform.sendCommand(UnityRelayCommand.recenter(vendor: 'viture'));
    } catch (error) {
      throw _mapPlatformError(error);
    }
  }

  /// Updates `VitureXR.HandTracking.filterMode` and/or `aimSensitivity` on the
  /// embedded Unity VITURE relay.
  Future<void> configure({
    VitureHandFilterMode? filterMode,
    VitureAimSensitivity? aimSensitivity,
  }) async {
    _ensureOpen();
    final options = <String, Object?>{
      if (filterMode != null) 'filter_mode': filterMode.wireName,
      if (aimSensitivity != null) 'aim_sensitivity': aimSensitivity.wireName,
    };
    try {
      await platform.sendCommand(
        UnityRelayCommand.configure(options, vendor: 'viture'),
      );
    } catch (error) {
      throw _mapPlatformError(error);
    }
  }

  void _onMessage(Object? message) {
    if (!_started || _frames.isClosed) return;
    try {
      final frame = switch (message) {
        String text => _relayCodec.decodeString(text),
        Map<Object?, Object?> map => _relayCodec.decode(map),
        _ => throw const FormatException(
          'VITURE relay frame must be a JSON map or string',
        ),
      };
      _frames.add(frame);
    } catch (error) {
      _frames.addError(
        TrackingException(
          TrackingExceptionKind.protocol,
          'Invalid VITURE tracking frame',
          cause: error,
        ),
      );
    }
  }

  void _ensureOpen() {
    if (_disposed) {
      throw StateError('VitureNeckbandTrackingSource has been disposed');
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
      error.message ?? 'VITURE tracking failed (${error.code})',
      cause: error,
      stage: stage,
    );
  }
  return TrackingException(
    TrackingExceptionKind.protocol,
    'VITURE tracking failed',
    cause: error,
  );
}
