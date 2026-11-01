# Changelog

## Unreleased

- Add a debug-only Carina C-SDK diagnostic spike
  (`--dart-define=WMR_VITURE_CARINA_DIAG=true`): opens the glasses USB fd,
  polls `xr_device_provider_get_gl_pose_carina`, walks a fixed 0.1/0.3/1.0/3.0
  ms exposure ladder at one gain, and dumps 8-bit stereo PGM frames plus JSON
  telemetry from the `on_stereo` callback.
- Require stereo 3D (SpaceWalker) for hand tracking: the VITURE export now
  assigns the VITURE XR loader for Android and enables **Initialize XR on
  Startup** (`WMR > Configure VITURE XR`), and `start` fails closed with
  `unavailable` when the Unity player is still running in 2D instead of
  letting `HandTracking.Start()` stall the launch. The stereo mode comes from
  the loader at initialisation; the bridge does not set it at runtime.
- Start tracking when the glasses model has not been reported yet: the unified
  Unity scene keeps the VITURE backend inactive until `start`, so capabilities
  now report `modelReported: false` with the Luma Ultra capability set and the
  model check moves to the Unity start handshake. A reported non-Luma-Ultra
  model still fails closed as `unsupported`.
- Migrate the Android plugin to AGP 9 built-in Kotlin: drop the Kotlin Gradle Plugin classpath and `org.jetbrains.kotlin.android`, and require Flutter 3.44 or later.

## 0.2.2

- Target VITURE XR SDK 0.9.0 (`Viture.XR.VitureXR`, Unity 6000.0.27f1) in the
  Unity relay bridge. No Dart or Kotlin API change.
- Version aligned with the v0.2.2 release; `wmr_tracking` and `wmr_tracking_dispatch` constraints raised to `^0.2.2`. No breaking public API change.

## 0.2.1

- Version aligned with the v0.2.1 gate and harness release; `wmr_tracking` and `wmr_tracking_dispatch` constraints raised to `^0.2.1`. No breaking public API change.

## 0.2.0

- Add a minimal Unity 6000.0 smoke project, frame/error events and pause/resume
  handling in the C# relay bridge, plus an editor script that exports the
  `unityLibrary` Gradle module for the Flutter host.

## 0.1.0

- Add the default-off VITURE Pro Neckband head and 26-joint hand
  `TrackingSource` (`VitureNeckbandTrackingSource`).
- Add the Kotlin Unity-as-a-Library (UaaL) relay plugin, camera permission gate,
  typed capability/error mapping across `VitureGlassesModel`, Unity-to-OpenXR
  coordinate conversion, and the minimal Unity C# `VitureTrackingRelayBridge`.
