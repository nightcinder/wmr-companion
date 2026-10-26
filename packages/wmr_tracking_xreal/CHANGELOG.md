# Changelog

## Unreleased

- Target XREAL SDK 3.1.0 in the Unity project and declare its AR Foundation,
  URP, Input System, XRI and Image Conversion dependencies in the manifest.
  No Dart or Kotlin API change.

## 0.2.1

- Version aligned with the v0.2.1 gate and harness release; `wmr_tracking` and `wmr_tracking_dispatch` constraints raised to `^0.2.1`. No breaking public API change.

## 0.2.0

- Add a minimal Unity 6000.0 smoke project, frame/error events and pause/resume
  handling in the C# relay bridge, plus an editor script that exports the
  `unityLibrary` Gradle module for the Flutter host.

## 0.1.0

- Add the default-off XREAL Air 2 Ultra head and 26-joint hand
  `TrackingSource` (`XrealAir2UltraTrackingSource`).
- Add the Kotlin Unity-as-a-Library (UaaL) relay plugin, camera permission gate,
  typed capability/error mapping across `XrealGlassesModel`, and the minimal
  Unity C# `XrealTrackingRelayBridge` using the XREAL SDK 3.x XR Hands
  subsystem.
