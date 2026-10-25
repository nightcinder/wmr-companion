# Headset hand and head tracking for controller 6DoF (research + framework)

Research date: 2026-10-25. This is desk research plus an in-repo framework. **Nothing in this document was tested on a headset, glasses or phone.** Vendor SDK details come from the public docs linked in [Sources](#sources); where a page did not state something, it is marked unknown rather than guessed.

Companion research: [CAMERAS.md](CAMERAS.md) covers raw camera access. This page covers the tracking APIs, what they give the companion for controller fusion, and the vendor-neutral code that lets an adapter be added without touching the controller pipeline.

## Short answer

- **No shipping API gives this app the WMR controller's 6DoF pose.** WMR controllers are not OpenXR devices, so Android XR, XREAL, RayNeo, Rokid and VITURE runtimes do not track them. The controller's own IMU still provides orientation at 150–180 Hz.
- **Android XR is the cleanest native path** for both 6DoF head pose and 26-joint hand tracking, with documented permissions. It is a Kotlin/Jetpack XR API, so the companion needs a small Flutter Android plugin. Its IR tracking cameras are still not app-accessible ([CAMERAS.md](CAMERAS.md)).
- **XREAL hand tracking is Air 2 Ultra only and Unity-only.** XREAL SDK 3.1.0 adds 6DoF on the One series with Eye, but not hand tracking. There is no native Android or Flutter API; a Unity sidecar or a native NRSDK port would be required.
- **VITURE hand tracking requires the Pro Neckband and the Unity XR SDK.** The cross-platform C glasses SDK has 6DoF head pose (Luma Ultra) and 25 Hz grayscale stereo cameras but no hands. The Pro Neckband is a real host for the companion: embed the Unity build in the Flutter Android app and keep BLE, fusion and UI in Dart (see [Packaging](#packaging-kotlin-and-unity-inside-a-flutter-plugin)).
- **RayNeo X3 Pro gives 6DoF head pose through the Unity ARDK, not the Android SDK, and documents no hand-joint API.** The Android SDK exposes Camera2 and IMU only. RayNeo Air is a display, with no tracking path.
- **Rokid AR Studio (Max Pro + Station Pro) gives 6DoF and gesture interaction through the Unity UXR SDK.** The public API is gesture events, not a joint stream. Rokid Glasses runs YodaOS-Sprite and is a different, non-tracking platform.
- **Realistic fusion levels:**
  1. Runtime head pose + hand palm/grip anchor → absolute controller position while the hand is visible. Whether a hand holding a WMR controller is trackable is unproven.
  2. Head pose + controller IMU + a learned head-local offset → stable orientation and a plausible position that moves with the head. This is **not** positional tracking; it is the framework's low-confidence fallback.
  3. Controller IMU only → the current 3DoF behaviour, unchanged.
- **The framework** is `packages/wmr_tracking` plus `WmrCompanion.attachTrackingSource`: a `TrackingSource` seam, a normalised `TrackingFrame`, vendor capability profiles, a clock aligner, a JSON relay codec, a reusable Unity UaaL relay contract with left-handed Unity to right-handed OpenXR conversion, a shared One Euro filter and `SixDofFuser`. It is pure Dart and hardware-free to test. Kotlin and Unity belong in Flutter *plugin* packages around it, not inside it.
- **The Android XR adapter is implemented** in `packages/wmr_tracking_android_xr` (Kotlin + Dart, default off). It compiles and its host tests pass, but it has not run on an Android XR device or glasses, so nothing here is a hardware result.
- **The VITURE Pro Neckband relay is implemented** in `packages/wmr_tracking_viture` (Dart + Kotlin UaaL relay plugin + minimal Unity C# bridge script, default off). Dart and Kotlin compile and pass host/JVM tests without the proprietary Unity 6000.0+ UaaL export or VITURE Unity SDK (`com.viture.xr` v0.7.0); no Neckband or glasses hardware run has happened.

## What "hand tracking" means for this project

The companion's long-term goal is controller 6DoF: position as well as orientation, so a controller can act as a spatial pointer or a gamepad in 3D. Two different hand-tracking outputs are useful:

| Device | Head pose | Hand output | Controller pose for WMR |
|---|---|---|---|
| Android XR | 6DoF | 26 joints | No |
| XREAL Air 2 Ultra | 6DoF | 26 joints (XR Hands) | No |
| XREAL One + Eye | 6DoF | No | No |
| RayNeo X3 Pro | 6DoF, Unity ARDK only | No public joint API | No |
| Rokid AR Studio | 6DoF, Unity UXR only | Gestures only, no public joints | No |
| VITURE Luma Ultra (C SDK) | 6DoF | No | No |
| VITURE Luma Ultra + Pro Neckband | 6DoF | Unity XR Hands joints | No |

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

**Companion path (implemented in `wmr_tracking_android_xr`):** a Kotlin Flutter plugin owns the XR session, requests `HAND_TRACKING` and `HEAD_TRACKING`, configures `HandTrackingMode.BOTH` with `DeviceTrackingMode.SPATIAL`, converts perception-space poses to the activity space and forwards head plus both hands as `TrackingFrameCodec` JSON over one event channel. The Dart side implements `TrackingSource`; `WmrCompanion.attachTrackingSource` aligns the `System.nanoTime()` timestamp to the BLE clock and feeds `SixDofFuser`.

- **Default off.** `AndroidXrTracking.enabled` is `bool.fromEnvironment('WMR_ANDROID_XR_TRACKING')`, default false. `AndroidXrTrackingSource.create()` returns null without touching a channel when the flag is off, so BLE, controller IMU and 3DoF are unchanged. Enable with `--dart-define=WMR_ANDROID_XR_TRACKING=true` and attach the returned source explicitly.
- **Typed outcomes.** A denied permission, a non-XR device, a refused `SPATIAL` mode, an unlinked runtime library and activity detach all surface as `TrackingException` kinds (`permissionDenied`, `unsupported`, `unavailable`), not as an empty stream.
- **Lifecycle.** `start`/`stop`/`dispose` are idempotent in Dart; the Kotlin side cancels its collectors and drops the session on stop/activity detach. A Jetpack XR `Session` is tied to its activity, so activity recreation reports `unavailable` and the consumer must start again.
- **Not claimed.** No hardware run, no measured rate, no proof that a hand holding a WMR controller stays tracked, and no `grip` pose: Android XR exposes `PALM`/`WRIST` and the other 24 OpenXR joints, so fusion uses the palm plus the configured grip offset. The head pose is converted with `perceptionSpace.transformPoseTo(..., activitySpace)` when SceneCore is available.

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

**Companion path:** no supported Flutter path today. Options are (a) a Unity companion app that hosts the XREAL session and streams `TrackingFrame` JSON to the Flutter app over localhost/adb, or (b) a custom native port of NRSDK, which is not a small task. The framework's JSON codec exists so option (a) does not require changing the fusion code.

## RayNeo

Official docs: [RayNeo DevDocs](https://rayneo-en.gitbook.io/rayneo-devdoc/), [X3 Pro device introduction](https://rayneo-en.gitbook.io/rayneo-devdoc/x-series/device-introduction), [Android SDK](https://rayneo-en.gitbook.io/rayneo-devdoc/x-series/android-sdk), [Unity 6DOF (SLAM)](https://rayneo-en.gitbook.io/rayneo-devdoc/x-series/unity-sdk/ar-capabilities-and-api/6dof-slam), and the [OpenXR Unity ARDK repository](https://github.com/github-for-rayneo/OpenXR-Unity-ARDK).

- **The X-Series is standalone Android.** X3 Pro runs Android 12 on Snapdragon AR1 with 4 GB RAM, two MicroLED displays at 640×480, a 12 MP RGB camera, a VGA spatial camera, and an IMU. Interaction is documented as temple touch, voice and watch/phone; it is not a hand-tracking product in the current docs. X2 is the older XR2 device.
- **6DoF lives in the Unity ARDK.** The runtime is RayNeo OpenXR; the ARDK is a Unity package (`com.rayneo.xr.runtime` plus the plugin). In the 6DOF page, select SLAM as the head-control mode, call `Algorithm.EnableSlamHeadTracker()`, watch `Algorithm.GetSlamStatus()` for `FFVINS_INITIALIZING`, `FFVINS_TRACKING_SUCCESS` or `FFVINS_TRACKING_FAIL`, and read the pose from `HeadTrackedPoseDriver.OnPostUpdate(Pose)`. The ARDK also documents 3DoF, gaze interaction and face detection.
- **The Android SDK does not expose head pose or hands.** Its feature matrix covers binocular display, focus, touch/gesture events from the temple touchpad, audio, Camera2, IMU and phone connection/GPS. IMU guidance is the standard Android `TYPE_GAME_ROTATION_VECTOR` software sensor, which gives orientation only. The "gesture recognition" in that table is touchpad gesture distribution, not optical hand tracking. Camera2 enumerates and previews a camera; the docs do not say whether the VGA spatial camera is one of the exposed IDs.
- **Hand tracking is not in the public API.** Secondary coverage describes gesture recognition as a beta capability, but the ARDK page index has no hand-tracking page and the device page lists no hand input. Treat it as unconfirmed until RayNeo publishes joints or a hand extension. The 6DOF page is the only tracking API that is documented end to end.
- **Host constraint:** the ARDK app runs on the glasses themselves. That is an advantage over phone-tethered XREAL: the companion could run entirely on the X3 Pro and talk BLE to the WMR bridge, at the cost of a 245 mAh battery and a 60 Hz display.
- **Coordinates:** Unity is left-handed, Y-up. Converting to the companion's right-handed OpenXR frame means negating Z on positions and handling the quaternion handedness, as with XREAL.

**Companion path:** an Android app on the X3 Pro that embeds a Unity ARDK build. The Unity scene reads `HeadTrackedPoseDriver.OnPostUpdate`, serialises a `TrackingFrame` and sends it to Dart through the embedded-Unity plugin; Dart keeps the BLE link and fusion. If embedding is rejected, the same JSON can come from a relay. Head-relative fusion only — no hand anchor.

## Rokid

Official docs: [Rokid Open Platform](https://open.rokid.com/), [SDK selection](https://developerdoc.rokid.com/sdk), [YodaOS-Master](https://global.rokid.com/blogs/yodaos-master), and the archived [UXR docs](https://github.com/RokidGlass/UXR-docs). UXR 2.0 is documented in the [Rokid AR platform docs](https://custom.rokid.com/prod/rokid_web/c88be4bcde4c42c0b8b53409e1fa1701/pc/us/45fee59150374e91be10fcb2d2a753c7.html).

- **Two different platforms share the Rokid name.**
  - **YodaOS-Master** is the spatial system for AR Studio (Max Pro + Station Pro) and AR Lite. It is built on SLAM, gesture recognition and spatial audio. UXR 2.0 gives 6DoF on Max Pro and 3DoF/0DoF on the Max series. UXR 3.0 targets AR Studio and AR Lite, uses Unity 2022 LTS, and is adapted to MRTK3/OpenXR.
  - **YodaOS-Sprite** is the AI-glasses system for Rokid Glasses. The public CXR-L SDK runs on the phone, reaches the glasses through the Rokid AI app, and exposes image, audio, display and button/command channels. Bare-metal development is a normal AOSP (API 31) app on the glasses with buttons, IMU and Camera access. Neither path documents head pose or hand joints.
- **Tracking is Unity-only and gesture-level.** The UXR input manager documents controller 3DoF rays, touchpad input (Station 2) and gesture interaction. The AR Studio design guidance recommends gestures as the primary interaction for Max Pro + Station Pro. What is published is *gesture interaction*, not a joint list, joint count or pose stream. No public Android/Kotlin or Flutter hand API was found.
- **Host:** Station Pro is an Android-based compute unit, so a Flutter app is plausible there, but the tracking API is still the Unity UXR SDK. The companion's BLE link would run on the Station or be relayed from the phone.
- **Coordinates:** UXR is Unity-based, so the same left-handed to right-handed conversion applies. The tracking origin and recenter call (`NativeInterface.NativeAPI.Recenter()` in UXR samples) are runtime-managed.

**Companion path:** no supported Flutter route today. If Rokid is pursued, embed the Unity UXR build and use gesture events only as a UI/select signal, not as a controller anchor. Without a joint stream, it cannot beat the head-relative fallback. The profile records `handGestures` and deliberately not `handJoints`.

## VITURE

Official docs: [VITURE XR Glasses SDK (C)](https://www.viture.com/developer/glasses-sdk/glasses) and [VITURE XR SDK for Unity](https://www.viture.com/developer/unity-sdk/unity).

### C glasses SDK

- **Cross-platform C API** (`libglasses` on Linux, macOS, Windows; `libglasses.so` on Android), USB vendor ID `0x35CA`. Android needs the USB host feature, runtime USB permission and the `UsbDeviceConnection` file descriptor passed to `xr_device_provider_create`.
- **Hardware tracking** from the official table:

  | Product | Tracking | Camera |
  |---|---|---|
  | One, Lite, Pro, Pro 2, Luma | 3DoF | None |
  | Luma Pro, Luma Cyber | 3DoF | UVC passthrough |
  | **Luma Ultra** | **3/6DoF** | UVC passthrough + stereo (VIO) |
  | Beast | 3DoF (native mode) | UVC passthrough |
  | Phantom Beast | 3DoF (native mode) | None |

- **Head pose:**
  - Gen1/Gen2 (One/Lite/Pro/Luma/Luma Cyber/Beast/Phantom Beast/Pro 2): `xr_device_provider_register_imu_pose_callback` + `open_imu(VITURE_IMU_MODE_POSE, ...)`. Callback data is `[roll, pitch, yaw, qw, qx, qy, qz]` in **North-West-Up** (X north, Y west, Z up), with a timestamp in the device timebase.
  - Carina/Luma Ultra: poll `xr_device_provider_get_gl_pose_carina(handle, pose, predict_time, &status)`. `pose` is `[px, py, pz, qw, qx, qy, qz]` in **OpenGL** (X right, Y up, Z backward), with forward prediction in seconds and a status flag. This is already the companion's convention, up to the quaternion order.
  - `set_dof_type_carina` selects 3DoF or 6DoF and must be called between create and initialize. `reset_origin_carina` recentres; `reset_pose_carina` reinitialises VIO.
- **Cameras:** the UVC passthrough stream is 1920×1080 at 30 fps MJPEG. On Luma Ultra, `register_callbacks_carina` delivers four 8-bit grayscale buffers per frame (left/right primary and secondary) at 25 Hz, with manual exposure/gain. This is the only app-visible stereo tracking feed found in this research.
- **No hand tracking in the C SDK.** The docs list no skeletal or gesture API. A Flutter FFI adapter can get head pose and cameras, not hands.

### Unity XR SDK (the hand-tracking path)

- The VITURE XR SDK for Unity 0.7.0 documents **6DoF tracking**, **hand tracking** (skeletal joints, built-in and custom gestures), XR Hands/XRI integration, camera access and marker tracking.
- **Requirements are the whole story: Unity 6000.0+, Android build support, and a VITURE Pro Neckband with compatible glasses.** The docs list the Pro Neckband as required hardware, full stop. Luma Ultra is the 6DoF model; Luma, Luma Pro, Pro, One and One Lite are 3DoF.
- Hand tracking is a first-class API: `VitureXR.HandTracking.IsActive`, `Start()`, `Stop()`, `filterMode` (`Responsive`/`Stable`) and `aimSensitivity` (6DoF only), with joints supplied to Unity XR Hands and interactions built on XRI. The SDK also has a "Activate Hand Tracking on Startup" project setting. There is no Flutter or native C hand-tracking API documented.
- **The Pro Neckband is a viable companion host, not a dead end.** It runs Android, has wireless ADB, and runs the Unity app itself. A Flutter Android app on the Neckband can embed the Unity scene (UaaL), keep BLE and fusion in Dart, and get real hand joints. The phone-only architecture would need a relay instead.
- **Do not expect hands from the C SDK on the phone.** The C library talks to the glasses over USB and has no hand pipeline; hand tracking is computed for the Neckband's Unity XR runtime.

**Companion path:** two VITURE adapters, in preference order.
1. **Neckband + embedded Unity (implemented in `wmr_tracking_viture`, default off).** Flutter app on the Pro Neckband, Unity 6000.0+ UaaL module with the VITURE XR SDK (`com.viture.xr` v0.7.0) and `com.unity.xr.hands`, `UnitySendMessage` for `UnityRelayCommand`s (`start`, `stop`, `dispose`, `recenter`, `configure`) and a JNI/`AndroidJavaClass` callback (`WmrTrackingViturePlugin.onUnityFrame`) streaming `TrackingFrame` JSON back to Dart. Head recentering delegates to `VitureXR.HeadTracking.SetWorldOrigin()`. Only `LumaUltra` advertises 6DoF head and 26-joint hand tracking; 3DoF glasses (`One`, `OneLite`, `Pro`, `Pro2`, `Luma`, `LumaPro`, `LumaCyber`, `Beast`) and unreported glasses models are rejected as `unsupported` for hand tracking. Enable with `--dart-define=WMR_VITURE_TRACKING=true`.
2. **C SDK over FFI (head only, out of scope for ONY-213).** Wrap `libglasses` on the phone; poll `get_gl_pose_carina` or register the IMU callback. It gives head pose but no hands, so it lands on the head-relative fallback. The stereo grayscale feed is interesting for future LED tracking but not usable yet: 25 Hz, unknown IR sensitivity, and no calibration or extrinsic documentation in what was read.

## Packaging: Kotlin and Unity inside a Flutter plugin

**Yes, both can ship in a Flutter library.** They belong in separate platform packages, because `wmr_tracking` is pure Dart and should stay that way.

### Kotlin plugin (Android XR)

- A standard Flutter plugin's `android/` module can hold Kotlin code, a manifest with `HAND_TRACKING`/`HEAD_TRACKING`, and a `MethodChannel`/`EventChannel`. Dart registers a `TrackingSource` that listens to the event channel and passes each map to `TrackingFrameCodec`/`RelayTrackingSource`.
- Android XR tracking is a Kotlin API and does not require Flutter to render XR. A tracking-only plugin can own the XR session and forward poses; if the app also wants XR content, that content is a Jetpack XR/Compose view and needs a platform view or a native activity. The tracking seam is the same either way.
- Permissions and the session lifecycle stay in the plugin. A refused `SPATIAL` mode or a missing hand must surface as `TrackingExceptionKind.unsupported`, not an empty stream.

### Unity as a Library (UnitySendMessage)

- Unity exports an Android Gradle project with a `unityLibrary` module. Add it to the Flutter plugin's `android/` Gradle project (or publish it as an `.aar` plus the Unity assets) and the plugin can start/stop the Unity player. Unity's own docs restrict UaaL to **full-screen rendering**, **one Unity runtime instance per process**, and warn that native/managed plugins may need adaptation.
- **`UnitySendMessage` is one-way, Java/Kotlin → C#, string-only, with a one-frame delay.** Use it for commands such as `start`, `stop`, `recenter` or `setFilterMode`. It is not a way to get poses out of Unity.
- **Poses travel the other way.** C# either calls a Kotlin object through `AndroidJavaObject`/`AndroidJavaProxy`, or writes into a JNI callback the plugin exposed. The plugin forwards the JSON on an event channel; Dart decodes it with `TrackingFrameCodec`. A `Stream<Object?>` of those messages plugs straight into `RelayTrackingSource`.
- Practical costs: a Unity build adds the whole player and its assets, needs its own Gradle/NDK setup, and must be licensed and versioned per Unity 6. The player is a second render loop competing with Flutter for the same GPU, so a tracking-only scene should stay minimal or render nothing when hidden.
- **Recommended shape:** a sibling package such as `wmr_tracking_viture` that depends on `wmr_tracking` and owns the Unity relay channels, permissions and C# bridge script, while sharing `UnityRelayCommand`, `UnityRelayFrameCodec`, `UnityXrHandJoints` and `unityToOpenXrPose` in `wmr_tracking`. The pure-Dart fusion package remains hardware-free, and apps that do not need Unity pay nothing.

The Dart/Kotlin relay contract and the VITURE Neckband slice (`packages/wmr_tracking_viture`) are implemented and host-tested; exporting the Unity 6000.0+ `unityLibrary` AAR with the proprietary VITURE XR SDK (`com.viture.xr` v0.7.0) and running on a physical Pro Neckband remain external SDK/hardware gates.

## Comparison

| | Android XR | XREAL Air 2 Ultra | XREAL One + Eye | RayNeo X3 Pro | Rokid AR Studio | VITURE Luma Ultra (C) | VITURE Neckband (Unity) |
|---|---|---|---|---|---|---|---|
| Head pose | 6DoF | 6DoF | 6DoF | 6DoF (Unity ARDK) | 6DoF (Unity UXR) | 6DoF | 6DoF |
| Hand joints | 26 | 26 (XR Hands) | No | No public API | No public API | No | XR Hands |
| Hand gestures | Yes | Yes | No | No public API | **Yes** | No | Yes |
| Controller pose for WMR | No | No | No | No | No | No | No |
| App-visible tracking cameras | No | No | No | VGA spatial camera (no raw feed documented) | No | **Yes, 8-bit gray 25 Hz** | No |
| Passthrough RGB | Yes (permission) | Yes | Yes (Eye) | Yes, 12 MP | Yes | Yes (UVC) | Yes |
| Native Android/Flutter API | Kotlin plugin | No (Unity) | No (Unity) | No (Unity for tracking) | No (Unity) | **Yes (C/FFI)** | No (Unity) |
| Permission gates | `HAND_TRACKING`, `HEAD_TRACKING` | Camera | Camera | Camera | Camera | USB + camera | Camera |
| Practical companion path | Native plugin | Unity sidecar | Unity sidecar | Embedded Unity on glasses | Embedded Unity on Station | FFI plugin | **Embedded Unity on Neckband** |

## What no API provides

- **WMR controller pose.** None of these runtimes knows the WMR controller. A hand anchor or the head-relative fallback is the only source of position.
- **IR-capable tracking frames.** VITURE's stereo frames are grayscale and their IR response is unknown; XREAL and Android XR hide the tracking cameras. LED constellation tracking remains unproven on all of them ([CAMERAS.md](CAMERAS.md)).
- **A shared clock.** Every SDK has its own monotonic epoch. The companion must align tracking timestamps to the BLE transport's `Stopwatch` before fusion. The controller stream uses `receivedAtUs` from that clock; tracking frames go through `SourceClockAligner`.
- **Fusion on the glasses.** Android XR, RayNeo X3 Pro, the VITURE Pro Neckband and Rokid AR Studio all run tracking on the device that hosts the app. XREAL Air 2 Ultra and VITURE's C SDK compute on the phone. The companion can therefore run where the BLE link is, or relay frames to it; the framework only assumes one fusion host with a monotonic clock.

## The framework

`packages/wmr_tracking` is pure Dart, depends only on `vector_math`, and is publishable but not on pub.dev (like the other packages, on owner hold). `packages/wmr_tracking_android_xr` is the optional Flutter plugin around it and adds `androidx.xr.runtime`, `androidx.xr.arcore` and `androidx.xr.scenecore` 1.0.0. `packages/wmr_tracking_viture` is the optional Flutter plugin for the VITURE Pro Neckband Unity UaaL relay. Both sit below the facade:

```
Android XR plugin ──┤ (implemented)
XREAL Unity ────────┤
RayNeo Unity ───────┤   TrackingFrame (OpenXR axes, metres, host-clock estimate)
Rokid Unity ────────┤
VITURE Unity ───────┼─> TrackingSource ──> SourceClockAligner ──> SixDofFuser
  (implemented)     │                                                   │
VITURE C/FFI ───────┤                                                   v
JSON relay ─────────┘                                                   v
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

`SourceClockAligner` seeds the offset from the first frame, low-pass filters jitter, rejects jumps larger than 50 ms, and rebases only when the source clock jumps backwards by more than a second (device/session restart); smaller backwards steps are delayed frames mapped with the existing offset. The contract is documented on `TrackingFrame`: source time in nanoseconds, host time optional, both monotonic.

### Fusion and confidence

`SixDofFuser.update(hand:, orientation:, hostTimeNs:)` picks the newest buffered frame at or before the sample (5 ms late tolerance), rejects frames older than 100 ms, and chooses a position source:

| Source | Position | Confidence | Honest description |
|---|---|---|---|
| `runtimeController` | Runtime-tracked controller pose | Vendor's | True 6DoF (not available for WMR) |
| `handAnchor` | `palm/grip * gripOffset` | Hand's | Absolute while the hand is tracked |
| `headRelative` | Head pose * last learned head-local offset | Low | Moves with the head; not positional tracking |
| `orientationOnly` | null | None | Current 3DoF behaviour |

Hand-anchor positions pass through the shared `OneEuroFilter` (`packages/wmr_tracking/lib/src/one_euro.dart`) on the controller sample clock. Defaults are `minCutoff=1.0 Hz`, `beta=0.02`, `dCutoff=1.0 Hz` and a clamped `dt` of 1/240–0.1 s. The filter works in centimetres internally because the paper's `beta` is scale-dependent; feeding metre-scale speed into 0.02 would leave the cutoff near constant and add about 158 ms of lag. Orientation is never filtered: it stays the controller IMU quaternion. The filter resets on the first sample, a gap over 100 ms, a source transition, a source restart or `SixDofFuser.reset()`, so a head-relative fallback is never smoothed into a tracked pose.

The last absolute position is converted to a head-local offset and reused when the hand drops out. That keeps the controller stable through brief occlusion but avoids pretending the fallback is real tracking. `positionSmoothing` (default 0.5) remains for runtime-tracked controller poses only; it does not apply to hand anchors. `calibrateGrip` captures a real controller-to-palm offset when a runtime provides both poses; otherwise the default offset is 2 cm below and 6 cm forward of the palm.

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

**Android XR (implemented first target).**
1. `packages/wmr_tracking_android_xr` is the Kotlin plugin; `apps/wmr_companion_app` depends on it, but no app code starts it yet.
2. The plugin requests `HAND_TRACKING` and `HEAD_TRACKING`, then configures `HandTrackingMode.BOTH` and `DeviceTrackingMode.SPATIAL`.
3. It reads `ArDevice.getInstance(session).state` and `Hand.left/right(session).state`, maps all 26 `HandJointType`s to the OpenXR `HandJoint` names, and sends `TrackingFrameCodec` JSON over an event channel.
4. Frames use `System.nanoTime()`; the facade's aligner maps them to the BLE clock. No wall-clock comparison is made.
5. `AndroidXrTrackingSource.create()` returns null when the flag is off and throws `unsupported`/`permissionDenied`/`unavailable` when the device cannot deliver the slice.

**Unity bridge (VITURE Neckband, XREAL, RayNeo, Rokid).**
1. Build a Unity Android project with the vendor XR plugin and one scene that reads head pose and, where available, `XRHandSubsystem` joints.
2. Export with Unity as a Library and add the `unityLibrary` module to the Flutter plugin's Gradle build. One Unity runtime per process, full-screen only.
3. Kotlin starts/stops the player and sends commands with `UnityPlayer.UnitySendMessage(go, "OnCommand", json)`; C# receives `void OnCommand(string)`.
4. C# sends poses back through a Kotlin callback (JNI/`AndroidJavaProxy`) as one `TrackingFrameCodec` JSON string per sample. The plugin forwards it on an event channel.
5. Dart adapts the channel to `RelayTrackingSource(messages: channelStream, vendor: ...)`; the facade aligns the timestamp. Do not use `UnitySendMessage` for the return direction — it is string-only, one-way, one frame late.
6. Keep the Unity scene tracking-only. It must not own BLE or the gamepad mapping; that stays in Dart.

**VITURE C SDK (head pose only, no Neckband).**
1. Wrap `libglasses` with `dart:ffi`; the Android build needs the USB host feature and the fd from `UsbDeviceConnection`.
2. For Carina, poll `get_gl_pose_carina` on a background thread; for Gen1/Gen2, register the IMU pose callback.
3. Convert the quaternion `[qw, qx, qy, qz]` to the framework's `[x, y, z, w]`; Gen1/Gen2 also needs North-West-Up to OpenXR conversion.
4. Emit a `TrackingFrame` with `head` only. The fuser will use the head-relative fallback.
5. Optional later work: expose the 25 Hz grayscale stereo frames through a separate camera seam, not through `TrackingFrame`.

**RayNeo X3 Pro.** Embed a Unity ARDK scene and read `HeadTrackedPoseDriver.OnPostUpdate`. Enable SLAM head control and treat `FFVINS_TRACKING_FAIL` as a tracking gap. No hand anchor exists, so expect `headRelative` only.

**Rokid AR Studio.** Embed a UXR 3.0 Unity scene. Use head pose for the origin; wire gesture events to UI actions, not to the controller anchor. If Rokid later exposes joints, the profile can move from `handGestures` to `handJoints` without a fusion change.

**XREAL (defer).** There is no supported Flutter route. If the project later wants it, a Unity sidecar can emit `TrackingFrameCodec` JSON; otherwise a native port is required. Air 2 Ultra is the only hand-tracking model.

**Relay/native test.** `TrackingFrameCodec.encodeToString` / `decodeString` is the wire contract. It is versioned (`v: 1`), uses metres and `[x, y, z, w]` quaternions, and ignores unknown joints for forward compatibility.

## Android XR vertical slice (ONY-212)

What landed, and what is still unverified:

| Piece | State |
|---|---|
| Kotlin session, permissions, `BOTH` + `SPATIAL` configure | Implemented; compiles against `androidx.xr.*` 1.0.0; not run on a device |
| Head pose + 26 OpenXR-named joints | Implemented with `perceptionSpace→activitySpace` conversion; device rate and frames unverified |
| Dart `TrackingSource`, default-off flag, typed errors | Implemented and host-tested |
| `SixDofFuser` + shared One Euro filter | Implemented and host-tested with synthetic vectors |
| Palm/grip anchoring | Palm from the fixture; no `grip` joint exists in the public Android XR API, so the default/calibrated grip offset applies |
| Flag-off BLE/3DoF parity | `apps/wmr_companion_app/test/android_xr_flag_off_test.dart` replays the deterministic fake bridge and matches PR #78 (`c3be059`) golden orientations; no tracking channel or pose stream is touched |
| Activity recreation | Stops tracking and reports `unavailable`; the consumer restarts the source |
| Hardware smoke test | **Not run** |

Synthetic vectors in `packages/wmr_tracking/test/filter_test.dart`: `filter_static` (10 s, 5 mm Gaussian, 30 Hz, filtered RMSE below raw, mean drift under 2 mm, orientation follows the controller IMU), `filter_ramp` (0.5 m/s, 5 s, 30/60/90 Hz, deterministic jitter, steady-state lag under 150 ms), `filter_gap` (10 cm step, 150 ms dropout, reset and correct fallback), plus a source-transition test, a non-finite sample test and a non-positive timestamp test. `packages/wmr_tracking/test/android_xr_fixture_test.dart` decodes a 26-joint fixture and checks palm and grip anchoring. `packages/wmr_tracking_android_xr/test/` covers the default-off flag, capability handshake, permission and `SPATIAL` denial fixtures, idempotent lifecycle, malformed frames and monotonic timestamps; its Kotlin JVM tests cover joint naming plus `stop`/`dispose` while a permission request is pending (a late permission result must not open a session). `apps/wmr_companion_app/test/android_xr_flag_off_test.dart` is the `ble_flag_off` vector: it replays 400 deterministic bridge ticks, matches the PR #78 golden 3DoF quaternions for both hands, asserts no `poses` event and no tracking-channel call.

Commands used for this slice:

```bash
cd packages/wmr_tracking && dart test
cd packages/wmr_tracking_android_xr && flutter test && flutter analyze
cd apps/wmr_companion_app && flutter analyze && flutter test
cd apps/wmr_companion_app && flutter build apk --debug
cd apps/wmr_companion_app/android && ./gradlew :wmr_tracking_android_xr:testDebugUnitTest
```

The APK build and the Kotlin unit test are compile/host gates, not hardware results. The 26-joint fixture and every error path are synthetic. The remaining hardware questions are unchanged: permission prompts and `SPATIAL` support on a real headset/glasses, joint and head rates, whether a gripping hand is tracked, and the BLE/pose relay latency.

## VITURE Pro Neckband vertical slice (ONY-213)

What landed, and what remains an external SDK or hardware gate:

| Piece | State |
|---|---|
| Reusable Unity relay contract (`UnityRelayCommand`, `UnityRelayFrameCodec`, `UnityXrHandJoints`) | Implemented in `packages/wmr_tracking` and host-tested |
| Unity → OpenXR conversion (`p=(x,y,z) -> (x,y,-z)`, `q=(qx,qy,qz,qw) -> (-qx,-qy,qz,qw)`) | Implemented in Dart, Kotlin and C#; verified within `1e-6` with round-trip (`frame_conversion`) |
| Dart `VitureNeckbandTrackingSource`, default-off `WMR_VITURE_TRACKING` flag, typed errors | Implemented in `packages/wmr_tracking_viture` and host-tested |
| Glasses model capability matrix (`LumaUltra` vs 3DoF `One`/`OneLite`/`Pro`/`Pro2`/`Luma`/`LumaPro`/`LumaCyber`/`Beast`) | Implemented; 3DoF models never advertise hand tracking or 6DoF head and fail with `unsupported` |
| Kotlin `WmrTrackingViturePlugin`, camera permission gate (`PendingStartGate`), reflective `UnitySendMessage` bridge | Implemented and JVM-tested; compiles without proprietary `unityLibrary` AAR |
| Minimal Unity C# bridge (`VitureTrackingRelayBridge.cs` + `.asmdef`) | Implemented in `packages/wmr_tracking_viture/unity/`; Unity 6000.0+ and `com.viture.xr` v0.7.0 are external SDK gates |
| Flag-off BLE/3DoF parity | `apps/wmr_companion_app/test/viture_flag_off_test.dart` replays 400 deterministic bridge ticks, matches PR #78 (`c3be059`) golden orientations, and touches no VITURE channel |
| Hardware / Unity UaaL smoke test | **Not run** |

Synthetic vectors and fixtures:
- `packages/wmr_tracking/test/viture_fixture_test.dart`: `frame_conversion` (Unity `p=(1,2,3)`, `q=(qx,qy,qz,qw)` → OpenXR `(1,2,-3)`, `(-qx,-qy,qz,qw)` within `1e-6` and round-trip), `viture_26_joint_unity_frame.json` (26 `XRHandJointID` joints + palm anchoring), `viture_26_joint_grip_frame.json` (grip anchor priority over palm), and `viture_relay_commands.json` (`start`, `configure`, `recenter`, `stop`, `dispose` command envelopes).
- `packages/wmr_tracking/test/clock_test.dart`: `clock_jitter` (irregular arrival timestamps, duplicate timestamps and out-of-order frames with `SourceClockAligner` + `SixDofFuser`; no future or stale sample used).
- `packages/wmr_tracking_viture/test/viture_tracking_source_test.dart`: default-off flag, Luma Ultra capabilities, 3DoF glasses rejection (`viture_luma_3dof_unsupported.json`), unlinked Unity UaaL runtime (`viture_unity_unavailable.json`), camera permission denial (`viture_permission_denied.json`), idempotent `start`/`configure`/`recenter`/`stop`/`dispose`, malformed frames and stream error recovery.
- `packages/wmr_tracking_viture/android/src/test/kotlin/`: JVM unit tests for 26-joint `XRHandJointID` mapping, Unity→OpenXR conversion, `VitureGlassesModelSpec`, unreported/null glasses model default, command JSON builders, `WmrTrackingViturePlugin` capability/start flows and `PendingStartGate`.

Commands used for this slice:

```bash
cd packages/wmr_tracking && dart analyze && dart test
cd packages/wmr_tracking_viture && flutter analyze && flutter test
cd apps/wmr_companion_app && flutter analyze && flutter test
cd apps/wmr_companion_app && flutter build apk --debug
cd apps/wmr_companion_app/android && ./gradlew :wmr_tracking_viture:testDebugUnitTest
```

Explicit unknowns and SDK-bound gates:
- **External SDK gate:** Unity 6000.0+ Android build support, `com.unity.xr.hands`, and the VITURE XR SDK for Unity v0.7.0 (`com.viture.xr`) are not redistributable in this repo. `WmrTrackingViturePlugin` isolates `com.unity3d.player.UnityPlayer` behind `VitureUnityBridge` so standard CI builds and tests pass, and reports `TrackingExceptionKind.unavailable` when `unityLibrary` is not linked.
- **Undocumented vendor parameters:** Unity head and hand update rates on the Pro Neckband are not stated in VITURE's public docs (`maxHeadRateHz: 0`, `maxHandRateHz: 0`); Android permissions required by the VITURE Unity runtime beyond `android.permission.CAMERA` are not documented; and whether a hand gripping a WMR controller stays tracked by `VitureXR.HandTracking` is unproven.

## Gates before calling this 6DoF

The code is a framework, not a hardware result. In order:

1. **Capture one frame per device.** For VITURE Luma Ultra, capture the stereo grayscale frames with the WMR controller LEDs lit and check whether the LEDs appear. For Android XR, capture the passthrough camera (not the tracking cameras, which are unavailable). For RayNeo X3 Pro, check whether the VGA spatial camera feed is reachable outside the ARDK. This settles the IR question before any optical work.
2. **Android XR plugin smoke test.** Request permissions, configure both modes, and log joint/head rates on a real headset. Confirm whether a hand holding a WMR controller is tracked at all; if not, the hand-anchor path is unusable while gripping.
3. **Unity-in-Flutter smoke test.** Build a one-scene UaaL plugin, send `start` with `UnitySendMessage`, receive JSON frames back, and log them in Dart. Check the plugin survives Flutter hot restart, activity recreation and Unity pause/resume. This is the gate for VITURE Neckband, XREAL, RayNeo and Rokid.
4. **VITURE Neckband hand test.** On a Pro Neckband + Luma Ultra, run `VitureXR.HandTracking.Start()`, log `XRHandSubsystem` joints and confirm whether a hand gripping a WMR controller is tracked. This is the only VITURE path that can beat `headRelative`.
5. **RayNeo and Rokid presence test.** On an X3 Pro, confirm `Algorithm.GetSlamStatus()` reaches `FFVINS_TRACKING_SUCCESS` and capture `HeadTrackedPoseDriver.OnPostUpdate` rate. On Rokid AR Studio, confirm which gestures the UXR `InputManager` emits and whether any joint data is reachable from C#; if it is gesture-only, record that the anchor path is unavailable.
6. **Clock test.** Log controller `receivedAtUs` and tracking host timestamps together for a minute; check the aligner offset is stable and frames stay within the 100 ms window.
7. **Fallback quality test.** Compare `headRelative` against a known physical position while nodding and walking. Expect it to fail as positional tracking; record the failure so it is not sold as 6DoF.
8. **VITURE C path.** Run `get_gl_pose_carina` on an Android phone with Luma Ultra, measure pose rate/status and USB permission behaviour. If it works, it is the lowest-friction phone-only head-pose source.

Until 1–8 produce reported hardware results, describe the framework as "ready for an adapter", not "6DoF supported".

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
- RayNeo DevDocs: https://rayneo-en.gitbook.io/rayneo-devdoc/
- RayNeo X3 Pro / X2 hardware: https://rayneo-en.gitbook.io/rayneo-devdoc/x-series/device-introduction
- RayNeo Android SDK feature matrix: https://rayneo-en.gitbook.io/rayneo-devdoc/x-series/android-sdk
- RayNeo Android IMU: https://rayneo-en.gitbook.io/rayneo-devdoc/x-series/android-sdk/capabilities-and-api/imu-data-acquisition
- RayNeo Unity 6DOF (SLAM): https://rayneo-en.gitbook.io/rayneo-devdoc/x-series/unity-sdk/ar-capabilities-and-api/6dof-slam
- RayNeo Unity AR capabilities: https://rayneo-en.gitbook.io/rayneo-devdoc/x-series/unity-sdk/ar-capabilities-and-api
- RayNeo OpenXR Unity ARDK: https://github.com/github-for-rayneo/OpenXR-Unity-ARDK
- Qualcomm, RayNeo X3 Pro AR setup: https://www.qualcomm.com/developer/project/get-started-with-rayneo-x3-pro-ar-development
- Rokid Open Platform: https://open.rokid.com/
- Rokid SDK selection (CXR-L, CXR-M, bare metal): https://developerdoc.rokid.com/sdk
- Rokid YodaOS-Master: https://global.rokid.com/blogs/yodaos-master
- Rokid UXR 2.0 platform docs (6DoF Max Pro, gestures): https://custom.rokid.com/prod/rokid_web/c88be4bcde4c42c0b8b53409e1fa1701/pc/us/45fee59150374e91be10fcb2d2a753c7.html
- Rokid UXR docs (archived 2021, Dock/Phone SDK split): https://github.com/RokidGlass/UXR-docs
- Rokid UXR 3.0 field notes (Unity 2022, input modes, gesture interaction; community): https://github.com/fallingheaven/Rokid-Striking-Iron-Flower/blob/main/Rokid%20UXR3.0%20SDK%E4%BD%BF%E7%94%A8%E6%80%BB%E7%BB%93.md
- VITURE C glasses SDK: https://www.viture.com/developer/glasses-sdk/glasses
- VITURE Unity XR SDK 0.7.0 (Pro Neckband requirement, `VitureXR.HandTracking`): https://www.viture.com/developer/unity-sdk/unity
- Unity as a Library (Android): https://docs.unity3d.com/Manual/UnityasaLibrary-Android.html
- Unity `UnitySendMessage` from Java/Kotlin: https://docs.unity3d.com/Manual/android-plugins-csharp-code-from-java-kotlin.html
- `flutter_embed_unity` (UaaL packaging reference): https://github.com/learntoflutter/flutter_embed_unity
- OpenXR hand tracking extension (joint names): https://registry.khronos.org/OpenXR/specs/1.1/html/xrspec.html#XR_EXT_hand_tracking

## Open questions

- Does a WMR controller's hand remain trackable while gripping it on Android XR, XREAL or VITURE Neckband? Desk research cannot answer this.
- Are VITURE Luma Ultra's stereo cameras sensitive enough to 850/940 nm LEDs, and what are their intrinsics/extrinsics?
- Can XREAL's XR Hands subsystem expose joints outside Unity through a native plugin in SDK 3.x? Not documented.
- Can RayNeo's ARDK expose hand joints, or is the gesture coverage in secondary sources only? The current public docs list no hand API.
- Can Rokid UXR expose joint poses on AR Studio, or only gesture events? The public input docs show gesture interaction, not skeletons.
- Does Unity as a Library run on the VITURE Pro Neckband and Rokid Station alongside their XR runtimes, and does it keep hand tracking alive while the Unity view is hidden? Needs the Unity-in-Flutter smoke test.
- Does Android XR allow a long-running background session while the phone handles BLE, or must the companion move onto the headset?
- Is the `HEAD_TRACKING` permission needed for `DeviceTrackingMode.SPATIAL` on wired XR glasses as well as immersive headsets? The docs say immersive devices; glasses are untested.
