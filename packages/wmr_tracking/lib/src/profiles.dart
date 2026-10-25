import 'tracking_types.dart';

/// A documented device/software combination and what its tracking API
/// actually exposes.
///
/// This catalogue is deliberately separate from [TrackingSource]: a source
/// reports what it can do at runtime, while these profiles record the public
/// API facts the app was designed against. `docs/TRACKING.md` has the sources
/// and the hardware caveats.
class TrackingDeviceProfile {
  const TrackingDeviceProfile({
    required this.id,
    required this.name,
    required this.vendor,
    required this.capabilities,
    required this.host,
    required this.permissions,
    required this.integration,
    this.caveats = const [],
  });

  final String id;
  final String name;
  final TrackingVendor vendor;
  final TrackingCapabilities capabilities;

  /// The device or process that runs the tracking algorithm.
  final String host;

  /// Permissions or manifest entries the integration must request.
  final String permissions;

  /// How the source reaches this pure-Dart package.
  final String integration;

  final List<String> caveats;
}

/// Android XR headsets and wired XR glasses through ARCore for Jetpack XR.
const androidXrRuntimeProfile = TrackingDeviceProfile(
  id: 'android-xr-runtime',
  name: 'Android XR runtime',
  vendor: TrackingVendor.androidXr,
  capabilities: TrackingCapabilities(
    features: {TrackingFeature.headPose6Dof, TrackingFeature.handJoints},
    handJointCount: 26,
  ),
  host: 'On the headset or wired XR glasses; ARCore for Jetpack XR',
  permissions:
      'android.permission.HAND_TRACKING and '
      'android.permission.HEAD_TRACKING at runtime',
  integration: 'Flutter Android plugin (Kotlin) that forwards frames',
  caveats: [
    'Hand tracking is off by default: set HandTrackingMode.BOTH.',
    'Tracking cameras are not available to apps; only the passthrough camera is.',
    'WMR controllers are not OpenXR devices, so no runtime controller pose.',
  ],
);

/// XREAL Air 2 Ultra through the XREAL SDK for Unity 3.x.
const xrealAir2UltraProfile = TrackingDeviceProfile(
  id: 'xreal-air-2-ultra',
  name: 'XREAL Air 2 Ultra',
  vendor: TrackingVendor.xreal,
  capabilities: TrackingCapabilities(
    features: {
      TrackingFeature.headPose6Dof,
      TrackingFeature.handJoints,
      TrackingFeature.handGestures,
      TrackingFeature.passthroughCamera,
    },
    handJointCount: 26,
  ),
  host: 'Beam Pro or Samsung S24/S25 running the XREAL SDK for Unity 3.1.0',
  permissions: 'Camera permission for the RGB/passthrough camera',
  integration: 'Unity-only SDK; needs a Unity sidecar relay or a native port',
  caveats: [
    'Hand tracking is Air 2 Ultra only; One, Air, Air 2 and Air 2 Pro do not have it.',
    'No raw tracking-camera access; the RGB camera is a separate stream.',
    'Unity uses a left-handed world frame; convert before building a Pose.',
  ],
);

/// XREAL One series with the XREAL Eye camera, through SDK 3.1.0.
const xrealOneEyeProfile = TrackingDeviceProfile(
  id: 'xreal-one-eye',
  name: 'XREAL One series + Eye',
  vendor: TrackingVendor.xreal,
  capabilities: TrackingCapabilities(
    features: {TrackingFeature.headPose6Dof, TrackingFeature.passthroughCamera},
  ),
  host: 'Beam Pro or Samsung S25 running the XREAL SDK for Unity 3.1.0',
  permissions: 'Camera permission for the Eye RGB stream',
  integration: 'Unity-only SDK; needs a Unity sidecar relay or a native port',
  caveats: [
    '6DoF needs XREAL Eye and updated glasses firmware.',
    'No hand tracking on the One series, even with Eye.',
  ],
);

/// VITURE Luma Ultra through the cross-platform C glasses SDK.
const vitureLumaUltraCProfile = TrackingDeviceProfile(
  id: 'viture-luma-ultra-c',
  name: 'VITURE Luma Ultra (C SDK)',
  vendor: TrackingVendor.viture,
  capabilities: TrackingCapabilities(
    features: {
      TrackingFeature.headPose6Dof,
      TrackingFeature.stereoCamera,
      TrackingFeature.passthroughCamera,
      TrackingFeature.posePrediction,
      TrackingFeature.originReset,
    },
  ),
  host: 'Android, Linux, macOS or Windows; libglasses C SDK over USB',
  permissions: 'USB host feature and runtime USB permission on Android',
  integration: 'dart:ffi plugin; pass the Android UsbDeviceConnection fd',
  caveats: [
    'No hand tracking in the C glasses SDK; it exposes head pose and cameras only.',
    'Stereo tracking frames are 8-bit grayscale at 25 Hz, not confirmed IR-capable.',
    '6DoF is the default for Luma Ultra; Gen1/Gen2 devices are 3DoF.',
  ],
);

/// VITURE Luma Ultra through the Unity XR SDK on the Pro Neckband.
const vitureNeckbandUnityProfile = TrackingDeviceProfile(
  id: 'viture-neckband-unity',
  name: 'VITURE Pro Neckband (Unity SDK)',
  vendor: TrackingVendor.viture,
  capabilities: TrackingCapabilities(
    features: {
      TrackingFeature.headPose6Dof,
      TrackingFeature.handJoints,
      TrackingFeature.handGestures,
      TrackingFeature.passthroughCamera,
    },
  ),
  host: 'VITURE Pro Neckband running the VITURE XR SDK for Unity 0.7.0',
  permissions: 'Android camera permission for RGB/passthrough',
  integration: 'Unity-only SDK; needs a Unity sidecar relay',
  caveats: [
    'Hand tracking requires Luma Ultra and the Pro Neckband; it is not in the C SDK.',
    'The SDK builds on Unity XR Hands and XRI, so joints follow the Unity skeleton.',
    'Only 3DoF on Luma, Luma Pro, Pro and One glasses.',
  ],
);

/// All profiles the framework was designed against, in integration order.
const knownTrackingProfiles = <TrackingDeviceProfile>[
  androidXrRuntimeProfile,
  xrealAir2UltraProfile,
  xrealOneEyeProfile,
  vitureLumaUltraCProfile,
  vitureNeckbandUnityProfile,
];
