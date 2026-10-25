# Headset hand and head tracking for controller 6DoF (research + framework)

Research date: 2026-10-25. This is desk research plus an in-repo framework. **Nothing in this document was tested on a headset, glasses or phone.** Vendor SDK details come from the public docs linked in [Sources](#sources); where a page did not state something, it is marked unknown rather than guessed.

Companion research: [CAMERAS.md](CAMERAS.md) covers raw camera access. This page covers the tracking APIs, what they give the companion for controller fusion, and the vendor-neutral code that lets an adapter be added without touching the controller pipeline.

## Short answer

- **No shipping API gives this app the WMR controller's 6DoF pose.** WMR controllers are not OpenXR devices, so Android XR, XREAL and VITURE runtimes do not track them. The controller's own IMU still provides orientation at 150–180 Hz.
- **Android XR is the only path that gives both 6DoF head pose and 26-joint hand tracking to a native Android app**, with documented permissions. It is a Kotlin/Jetpack XR API, so the companion needs a small Flutter Android plugin. Its IR tracking cameras are still not app-accessible ([CAMERAS.md](CAMERAS.md)).
- **XREAL hand tracking is Air 2 Ultra only and Unity-only.** XREAL SDK 3.1.0 adds 6DoF on the One series with Eye, but not hand tracking. There is no native Android or Flutter API; a Unity sidecar or a native NRSDK port would be required.
- **VITURE splits the APIs.** The cross-platform C glasses SDK has 6DoF head pose (Luma Ultra) and 25 Hz raw grayscale stereo tracking cameras, but **no hand tracking**. Hand tracking exists only in the Unity XR SDK running on the Pro Neckband, which is not the companion's host.
- **Realistic fusion levels:**
  1. Android XR head pose + hand palm/grip anchor → absolute controller position while the hand is visible. Whether a hand holding a WMR controller is trackable is unproven.
  2. Head pose + controller IMU + a learned head-local offset → stable orientation and a plausible position that moves with the head. This is **not** positional tracking; it is the framework's low-confidence fallback.
  3. Controller IMU only → the current 3DoF behaviour, unchanged.
- **The framework** is `packages/wmr_tracking` plus `WmrCompanion.attachTrackingSource`: a `TrackingSource` seam, a normalised `TrackingFrame`, vendor capability profiles, a clock aligner, a JSON relay codec and `SixDofFuser`. It is pure Dart and hardware-free to test.

## What "hand tracking" means for this project

The companion's long-term goal is controller 6DoF: position as well as orientation, so a controller can act as a spatial pointer or a gamepad in 3D. Two different hand-tracking outputs are useful:

| Output | Used for | Android XR | XREAL | VITURE |
|---|---|---|---|---|
| Head/device pose | Places the controller relative to the headset; gives the tracking origin | Yes, 6DoF | Yes, 6DoF (Air 2 Ultra; One + Eye on SDK 3.1) | Yes, 6DoF on Luma Ultra |
| Skeletal hand joints | An anchor for a controller held in the hand | Yes, 26 joints | Yes, Air 2 Ultra only | Unity SDK on Pro Neckband only |
| Controller pose | Direct 6DoF, no fusion needed | No for WMR | No for WMR | No for WMR |

The framework consumes all three when present. It never invents a controller pose the runtime did not provide.

## Android XR (ARCore for Jetpack XR)

Official guidance: [Work with hands using ARCore for Jetpack XR](https://developer.android.com/develop/xr/jetpack-xr-sdk/arcore/hands) and [Track a device's pose](https://developer.android.com/develop/xr/jetpack-xr-sdk/arcore/device-pose).

- **Hand tracking is opt-in per session.** Build a session config with `setHandTracking(HandTrackingMode.BOTH)` and apply it with `session.configure(...)`. Without that, no hand data arrives.
- **Permission:** `android.permission.HAND_TRACKING` is a runtime permission. Device pose in `DeviceTrackingMode.SPATIAL` needs `android.permission.HEAD_TRACKING` on immersive devices.
- **API shape:** `Hand.left(session).state` and `Hand.right(session).state` are flows of hand state. The state has `trackingState` and `handJoints`, a map of `HandJointType` to `Pose`. Joint poses follow OpenXR conventions; the documented examples use `HandJointType.PALM` and `HandJointType.INDEX_TIP`.
- **Device pose:** `ArDevice.getInstance(session).state` exposes `devicePose` (translation and rotation) relative to the tracking origin. `DeviceTrackingMode.SPATIAL` is not supported on every device, so configure and handle `UnsupportedOperationException`.
- **Space conversion:** poses live in the perception space; `session.scene.perceptionSpace.transformPoseTo(pose, session.scene.activitySpace)` converts them to the activity space.
- **Gestures:** there is no fixed set beyond the joint data; the docs show pinch and "stop" detected from joint distances/angles. The framework treats palms and joints as anchors, not vendor gestures.
- **What is not available:** the tracking cameras. Android XR permits the outward passthrough camera (subject to permission), not the non-standard tracking cameras ([CAMERAS.md](CAMERAS.md)). This rules out direct WMR LED constellation tracking on the headset.
- **Host constraint:** this API runs in an Android XR app on the XR device, not on a phone driving display glasses. The companion's BLE link would have to move to that device, or the pose has to be relayed to the phone.

**Companion path:** a Kotlin Flutter plugin owns the XR session, requests the permissions, configures both modes, and forwards head and hand poses as `TrackingFrame`s. The `TrackingFrameCodec` JSON contract is ready for that boundary. The plugin must keep the OpenXR axis convention (already what the companion uses) and forward a monotonic timestamp.

## XREAL

Official docs: [XREAL SDK 3.1.0 hand tracking](https://docs.xreal.com/Input%20and%20Interactions/Hand%20Tracking), [compatibility](https://docs.xreal.com/XREALDevices/Compatibility), [3.1.0 release note](https://docs.xreal.com/Release%20Note/XREAL%20SDK%203.1.0), and [2.4.1 hand tracking](https://docs.xreal.com/2.4.1/Hand%20Tracking).

- **XREAL SDK 3.x is a Unity SDK.** Hand tracking is built on Unity XR Hands and XR Interaction Toolkit; XREAL supplies an XR Hands subsystem and a `HandVisualizer`. The SDK is installed as `com.xreal.xr.tar.gz`. There is no Flutter or native Android hand-tracking API documented.
- **Device support (SDK 3.1.0 compatibility table):**

  | Feature | XREAL One series (with RGB camera) | Air / Air 2 / Air 2 Pro | Air 2 Ultra |
  |---|---|---|---|
  | Head tracking | 6DoF | 3DoF | 6DoF |
  | Hand tracking | No | No | **Yes** |
  | Plane / image / depth / anchors | No | No | Yes |

  SDK 3.1.0 adds 6DoF on the One series **with XREAL Eye**, requiring updated glasses firmware. Eye is still not a hand-tracking path.
- **Host devices:** Beam Pro or Samsung flagships. SDK 3.1.0 was tested with Beam Pro and Samsung S25; the docs recommend Samsung S24 and later. XREAL warns against upgrading development devices to Android 16 while compatibility is investigated.
- **Joints:** NRSDK 2.4.1 documents 23 key points per hand (wrist, palm, five fingers without metacarpals except thumb/pinky) and six poses, plus a pinch/select gesture. XREAL SDK 3.x replaces this with Unity XR Hands, whose skeleton has 26 joints; XREAL exposes it through the standard XR Hands API. The framework's `HandJoint` enum follows the OpenXR 26-joint names, and adapters simply omit missing joints (palm and wrist fallbacks are built in).
- **Coordinates:** NRSDK 2.4.1 uses Unity's left-handed world frame and documents `NRFrame.HeadPose` plus camera extrinsics. Converting to the companion's right-handed OpenXR frame means negating the Z axis (and handling the quaternion handedness) before building a `Pose`.
- **What is not available:** raw tracking-camera frames. The RGB camera is a separate, documented stream; the grayscale tracking cameras are internal. So XREAL cannot feed Monado-style LED tracking either.

**Companion path:** no supported Flutter path today. Options are (a) a Unity companion app that hosts the XREAL session and streams `TrackingFrame` JSON to the Flutter app over localhost/adb, or (b) a custom native port of NRSDK, which is not a small task. The framework's JSON codec exists so option (a) does not require changing the fusion code. This is a defer, not a v1 dependency.

## VITURE

Official docs: [VITURE XR Glasses SDK (C)](https://www.viture.com/developer/glasses-sdk/glasses) and [VITURE XR SDK for Unity](https://www.viture.com/developer/unity-sdk/unity).

### C glasses SDK

- **Cross-platform C API** (`libglasses` on Linux, macOS, Windows; `libglasses.so` on Android), USB vendor ID `0x35CA`. Android needs the USB host feature, runtime USB permission and the `UsbDeviceConnection` file descriptor passed to `xr_device_provider_create`.
- **Hardware tracking** from the official table:

  | Product | Tracking | Camera |
  |---|---|---|
  | One, Lite, Pro, Pro 2, Luma, Luma Cyber | 3DoF | None or UVC passthrough |
  | Luma Pro | 3DoF | UVC passthrough |
  | **Luma Ultra** | **3/6DoF** | UVC passthrough + stereo (VIO) |
  | Beast, Phantom Beast | 3DoF (native mode) | UVC or none |

- **Head pose:**
  - Gen1/Gen2 (One/Lite/Pro/Luma/Beast/Pro 2): `xr_device_provider_register_imu_pose_callback` + `open_imu(VITURE_IMU_MODE_POSE, ...)`. Callback data is `[roll, pitch, yaw, qw, qx, qy, qz]` in **North-West-Up** (X north, Y west, Z up), with a timestamp in the device timebase.
  - Carina/Luma Ultra: poll `xr_device_provider_get_gl_pose_carina(handle, pose, predict_time, &status)`. `pose` is `[px, py, pz, qw, qx, qy, qz]` in **OpenGL** (X right, Y up, Z backward), with forward prediction in seconds and a status flag. This is already the companion's convention, up to the quaternion order.
  - `set_dof_type_carina` selects 3DoF or 6DoF and must be called between create and initialize. `reset_origin_carina` recentres; `reset_pose_carina` reinitialises VIO.
- **Cameras:** the UVC passthrough stream is 1920×1080 at 30 fps MJPEG. On Luma Ultra, `register_callbacks_carina` delivers four 8-bit grayscale buffers per frame (left/right primary and secondary) at 25 Hz, with manual exposure/gain. This is the only app-visible stereo tracking feed found in this research.
- **No hand tracking in the C SDK.** The docs list no skeletal or gesture API. A Flutter FFI adapter can get head pose and cameras, not hands.

### Unity XR SDK

- The VITURE XR SDK for Unity 0.7.0 documents **6DoF tracking**, **hand tracking** (skeletal joints, built-in and custom gestures), XR Hands/XRI integration, camera access and marker tracking.
- Requirements: Unity 6000.0+, Android build support, and a **VITURE Pro Neckband** with compatible glasses. Luma Ultra is the 6DoF model; Luma, Luma Pro, Pro and One are 3DoF.
- Hand tracking is exposed through `VitureXR.Hand Tracking` and the standard Unity XR Hands subsystem. There is no Flutter or native C hand-tracking API documented.
- It is not the companion's host: the Pro Neckband runs the Unity app, while the companion would run on the phone. A sidecar relay would be needed.

**Companion path:** the C SDK is the only directly wrap-able VITURE path (`dart:ffi`). It gives head pose but no hands, so it lands on the head-relative fallback. The stereo grayscale feed is interesting for future LED tracking but not usable yet: 25 Hz, unknown IR sensitivity, and no calibration or extrinsic documentation in what was read.

## Comparison

| | Android XR | XREAL Air 2 Ultra | XREAL One + Eye | VITURE Luma Ultra (C) | VITURE Neckband (Unity) |
|---|---|---|---|---|---|
| Head pose | 6DoF | 6DoF | 6DoF | 6DoF | 6DoF |
| Hand joints | 26 | 26 (XR Hands) | No | No | XR Hands |
| Controller pose for WMR | No | No | No | No | No |
| App-visible tracking cameras | No | No | No | **Yes, 8-bit gray 25 Hz** | No |
| Passthrough RGB | Yes (permission) | Yes | Yes (Eye) | Yes (UVC) | Yes |
| Native Android/Flutter API | Kotlin plugin | No (Unity) | No (Unity) | **Yes (C/FFI)** | No (Unity) |
| Permission gates | `HAND_TRACKING`, `HEAD_TRACKING` | Camera | Camera | USB + camera | Camera |
| Practical companion path | Native plugin | Unity sidecar | Unity sidecar | FFI plugin | Unity sidecar |

## What no API provides

- **WMR controller pose.** None of these runtimes knows the WMR controller. A hand anchor or the head-relative fallback is the only source of position.
- **IR-capable tracking frames.** VITURE's stereo frames are grayscale and their IR response is unknown; XREAL and Android XR hide the tracking cameras. LED constellation tracking remains unproven on all of them ([CAMERAS.md](CAMERAS.md)).
- **A shared clock.** Every SDK has its own monotonic epoch. The companion must align tracking timestamps to the BLE transport's `Stopwatch` before fusion. The controller stream uses `receivedAtUs` from that clock; tracking frames go through `SourceClockAligner`.
- **Fusion on the glasses.** Except for an Android XR app running on the headset, tracking runs on the phone or a host process. The companion is the fusion host, which is the architecture the framework assumes.

## The framework

`packages/wmr_tracking` is pure Dart, depends only on `vector_math`, and is publishable but not on pub.dev (like the other packages, on owner hold). It sits below the facade:

```
Android XR plugin ─┐
XREAL sidecar ─────┤   TrackingFrame (OpenXR axes, metres, host-clock estimate)
VITURE FFI plugin ─┼─> TrackingSource ──> SourceClockAligner ──> SixDofFuser
JSON relay ────────┘                                                   │
                                                                       v
WMR BLE stream ──> ControllerService ──> DecodedSample ────────> ControllerPose
                                       (IMU orientation)
```

### The source seam

Implement `TrackingSource` for one runtime:

```dart
abstract interface class TrackingSource {
  String get id;
  TrackingVendor get vendor;
  TrackingCapabilities get capabilities;
  Stream<TrackingFrame> get frames;
  Future<void> start();
  Future<void> stop();
  Future<void> dispose();
}
```

`TrackingCapabilities` declares head pose, hand joints, controller pose, stereo/passthrough cameras, pose prediction and origin reset before `start()`. The app can therefore choose a fusion strategy without probing the hardware. `knownTrackingProfiles` records the public facts per device; `FakeTrackingSource` covers tests and `RelayTrackingSource` decodes the JSON contract from a sidecar.

A `TrackingFrame` carries a source timestamp, an optional host timestamp, a head `TrackedPose`, left/right `HandPose`, and any runtime controller poses. `HandPose` maps OpenXR-named `HandJoint`s to poses and falls back from `grip` to `palm` to `wrist` for the controller anchor.

### Timestamps

Fusion compares a controller sample at `receivedAtUs * 1000` with a tracking frame. The source's clock is arbitrary, so the facade re-stamps every frame:

```dart
final arrivalNs = transport.clock.nowUs * 1000;
final hostNs = aligner.align(sourceTimeNs: frame.timeNs, hostTimeNs: arrivalNs);
fuser.onTrackingFrame(frame.withHostTime(hostNs));
```

`SourceClockAligner` seeds the offset from the first frame, low-pass filters jitter, rejects jumps larger than 50 ms, and rebases if the source clock goes backwards (device/session restart). The contract is documented on `TrackingFrame`: source time in nanoseconds, host time optional, both monotonic.

### Fusion and confidence

`SixDofFuser.update(hand:, orientation:, hostTimeNs:)` picks the newest buffered frame at or before the sample (5 ms late tolerance), rejects frames older than 100 ms, and chooses a position source:

| Source | Position | Confidence | Honest description |
|---|---|---|---|
| `runtimeController` | Runtime-tracked controller pose | Vendor's | True 6DoF (not available for WMR) |
| `handAnchor` | `palm/grip * gripOffset` | Hand's | Absolute while the hand is tracked |
| `headRelative` | Head pose * last learned head-local offset | Low | Moves with the head; not positional tracking |
| `orientationOnly` | null | None | Current 3DoF behaviour |

The last absolute position is converted to a head-local offset and reused when the hand drops out. That keeps the controller stable through brief occlusion but avoids pretending the fallback is real tracking. `positionSmoothing` (default 0.5) hides anchor jitter at the cost of lag. `calibrateGrip` captures a real controller-to-palm offset when a runtime provides both poses; otherwise the default offset is 2 cm below and 6 cm forward of the palm.

### Facade integration

```dart
final companion = WmrCompanion(ble: transport);
await companion.attachTrackingSource(androidXrSource); // or fake/relay
companion.poses.listen((pose) {
  if (pose.hasPosition) {
    // pose.pose is an OpenXR-space Pose; pose.orientation is the IMU quaternion.
  }
});
```

The facade owns the source (start, alignment, stop and dispose), emits one `ControllerPose` per decoded controller sample, and keeps tracking independent of the BLE connection. Attaching another source disposes the first. A failed `start()` throws `WmrTrackingException` and detaches cleanly.

### Adapter recipes

**Android XR (recommended first target).**
1. Add a Kotlin plugin to `apps/wmr_companion_app/android`.
2. Request `HAND_TRACKING` and `HEAD_TRACKING`; configure `HandTrackingMode.BOTH` and `DeviceTrackingMode.SPATIAL`.
3. On each frame, read `ArDevice.getInstance(session).state.value.devicePose` and `Hand.left/right(session).state.value`, convert `HandJointType` to the `HandJoint` names, and send the fields in `TrackingFrameCodec` format over an event channel.
4. Timestamp with `System.nanoTime()`; let the facade's aligner map it. Do not compare it with wall-clock time.
5. Gate the UI on capability support: a device may refuse `SPATIAL`, and hand tracking can be unavailable.

**VITURE C SDK (head pose only).**
1. Wrap `libglasses` with `dart:ffi`; the Android build needs the USB host feature and the fd from `UsbDeviceConnection`.
2. For Carina, poll `get_gl_pose_carina` on a background thread; for Gen1/Gen2, register the IMU pose callback.
3. Convert the quaternion `[qw, qx, qy, qz]` to the framework's `[x, y, z, w]`; Gen1/Gen2 also needs North-West-Up to OpenXR conversion.
4. Emit a `TrackingFrame` with `head` only. The fuser will use the head-relative fallback.
5. Optional later work: expose the 25 Hz grayscale stereo frames through a separate camera seam, not through `TrackingFrame`.

**XREAL (defer).** There is no supported Flutter route. If the project later wants it, a Unity sidecar can emit `TrackingFrameCodec` JSON; otherwise a native port is required. Air 2 Ultra is the only hand-tracking model.

**Relay/native test.** `TrackingFrameCodec.encodeToString` / `decodeString` is the wire contract. It is versioned (`v: 1`), uses metres and `[x, y, z, w]` quaternions, and ignores unknown joints for forward compatibility.

## Gates before calling this 6DoF

The code is a framework, not a hardware result. In order:

1. **Capture one frame per device.** For VITURE Luma Ultra, capture the stereo grayscale frames with the WMR controller LEDs lit and check whether the LEDs appear. For Android XR, capture the passthrough camera (not the tracking cameras, which are unavailable). This settles the IR question before any optical work.
2. **Android XR plugin smoke test.** Request permissions, configure both modes, and log joint/head rates on a real headset. Confirm whether a hand holding a WMR controller is tracked at all; if not, the hand-anchor path is unusable while gripping.
3. **Clock test.** Log controller `receivedAtUs` and tracking host timestamps together for a minute; check the aligner offset is stable and frames stay within the 100 ms window.
4. **Fallback quality test.** Compare `headRelative` against a known physical position while nodding and walking. Expect it to fail as positional tracking; record the failure so it is not sold as 6DoF.
5. **VITURE C path.** Run `get_gl_pose_carina` on an Android phone with Luma Ultra, measure pose rate/status and USB permission behaviour. If it works, it is the lowest-friction head-pose source.

Until 1–5 produce reported hardware results, describe the framework as "ready for an adapter", not "6DoF supported".

## Sources

All accessed 2026-10-25.

- Android XR, hands: https://developer.android.com/develop/xr/jetpack-xr-sdk/arcore/hands
- Android XR, device pose: https://developer.android.com/develop/xr/jetpack-xr-sdk/arcore/device-pose
- Android XR camera restrictions (secondary): [CAMERAS.md](CAMERAS.md), which cites Android Authority's report.
- XREAL hand tracking (3.1.0): https://docs.xreal.com/Input%20and%20Interactions/Hand%20Tracking
- XREAL compatibility table: https://docs.xreal.com/XREALDevices/Compatibility
- XREAL SDK 3.1.0 release note: https://docs.xreal.com/Release%20Note/XREAL%20SDK%203.1.0
- XREAL 2.4.1 hand tracking (23 joints, gestures): https://docs.xreal.com/2.4.1/Hand%20Tracking
- XREAL coordinate systems: https://docs.xreal.com/2.4.1/Miscellaneous/NRSDK%20Coordinate%20Systems
- VITURE C glasses SDK: https://www.viture.com/developer/glasses-sdk/glasses
- VITURE Unity XR SDK: https://www.viture.com/developer/unity-sdk/unity
- OpenXR hand tracking extension (joint names): https://registry.khronos.org/OpenXR/specs/1.1/html/xrspec.html#XR_EXT_hand_tracking

## Open questions

- Does a WMR controller's hand remain trackable while gripping it on Android XR or XREAL? Desk research cannot answer this.
- Are VITURE Luma Ultra's stereo cameras sensitive enough to 850/940 nm LEDs, and what are their intrinsics/extrinsics?
- Can XREAL's XR Hands subsystem expose joints outside Unity through a native plugin in SDK 3.x? Not documented.
- Does Android XR allow a long-running background session while the phone handles BLE, or must the companion move onto the headset?
- Is the `HEAD_TRACKING` permission needed for `DeviceTrackingMode.SPATIAL` on wired XR glasses as well as immersive headsets? The docs say immersive devices; glasses are untested.
