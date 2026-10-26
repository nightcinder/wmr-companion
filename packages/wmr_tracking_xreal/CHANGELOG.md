# Changelog

## Unreleased

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
