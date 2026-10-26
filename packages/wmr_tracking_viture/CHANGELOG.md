# Changelog

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
