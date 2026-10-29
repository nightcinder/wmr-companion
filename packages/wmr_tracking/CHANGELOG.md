# Changelog

## Unreleased

- ONY-502: the hand-anchor `OneEuroFilter` now runs on the anchor sample's own
  clock, once per new anchor sample, and the fuser holds the filtered value
  between samples. `minDt` follows the anchor rate (11 ms) instead of the
  240 Hz IMU. Adds `PoseFilterConfig`, `PoseCapture`, the offline grid tuner
  (`tool/pose_filter_tune.dart`) and the synthetic harness-vector generator
  (`tool/generate_pose_captures.dart`). The tuner evaluates the full
  `filter-spec` rev 4 grid (4,264 points per runtime), scores `J`, `J_D`,
  slow/medium/fast lag, selects the lowest-`J_D` passing point and treats a
  winner on a bar-limiting boundary as inconclusive. `PoseCapture.fromRecording`
  keeps the raw anchor joint position so the harness measures what the filter
  sees. The `minCutoff`/`beta`/`dCutoff` defaults stay at the published values
  until hardware captures exist; no point is chosen by reasoning.

## 0.2.2

- Update the VITURE capability profile to name VITURE XR SDK for Unity 0.9.0
  and Unity 6000.0.27f1. No API change.
- Version aligned with the v0.2.2 release; no breaking public API change.

## 0.2.1

- `FakeXrAdapter`, `XrContractHarness` and `tool/xr_contract_harness.dart`:
  hardware-free replay of deterministic head and 26-joint hand frames through
  both adapter JSON contracts (native OpenXR and Unity relay), with paired
  golden fixtures, head/hand rate assertions and malformed-frame rejection.
- `tool/gate7_clock_replay.dart`: hardware-free clock-alignment replay over
  recorded controller captures and synthetic head traces, failing on offset
  drift, controller gaps and out-of-window frames.
- `tool/gate8_fallback_quality.dart`: hardware-free nod/walk replay proving the
  `headRelative` fallback is not positional tracking while a rigid head-local
  control stays accurate.

## 0.2.0

Migration note: no existing public API changed; `PoseRecording` is additive.

- `PoseRecording`, `PoseRecordingSample` and `PoseRecordingBuilder`: versioned,
  deterministic JSON recording of fused `ControllerPose`s plus the
  `TrackingFrame` that positioned them, with typed `PoseRecordingException`
  errors. `PoseRecording.sampleAt` replays samples as a step function for
  regression fixtures.

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
