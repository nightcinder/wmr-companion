# Changelog

## 0.1.0

- Initial framework: `TrackingSource` seam, normalised `TrackingFrame` and
  OpenXR-named hand joints, vendor capability profiles and the JSON relay codec.
- `SourceClockAligner` maps vendor timestamps onto the host monotonic clock.
- `SixDofFuser` combines controller IMU orientation with runtime controller,
  hand-anchor and head-relative position sources.
- `OneEuroFilter`: a timestamp-aware speed-adaptive low-pass for hand-anchor
  controller translation. `SixDofFuser` uses it on hand anchors and resets it
  across gaps and source transitions; IMU orientation is never filtered.
  Migration note: `SixDofFusionConfig.positionSmoothing` now applies only to
  runtime-tracked controller poses; hand anchors use the One Euro filter. BLE
  and IMU-only 3DoF consumers see no change.
- `FakeTrackingSource` and `RelayTrackingSource` for hardware-free tests,
  UI development and Unity/native sidecars.
- RayNeo X3 Pro and Rokid AR Studio capability profiles, plus `rayneo` and
  `rokid` vendor values. Both record head pose only where the public API
  documents it: RayNeo has no hand API, Rokid exposes gestures but no joints.
- VITURE Pro Neckband profile now records the Unity SDK requirement and the
  embedded-Unity integration path; hand tracking is not available from the C
  glasses SDK.
- `UnityRelayCommand`, `UnityRelayFrameCodec`, `UnityXrHandJoints`, and
  `unityToOpenXrPose` / `openXrToUnityPose`: reusable Unity UaaL relay command
  contract, 26-joint `XRHandJointID` to OpenXR mapping, and left-handed Unity to
  right-handed OpenXR coordinate conversion (ONY-213).
