# Headset hand and head tracking for controller 6DoF (research + framework)

Research date: 2026-10-25. This is desk research plus an in-repo framework. **Nothing in this document was tested on a headset, glasses or phone.** Vendor SDK details come from the public docs linked in [Sources](#sources); where a page did not state something, it is marked unknown rather than guessed.

Companion research: [CAMERAS.md](../CAMERAS.md) covers raw camera access. This page covers the tracking APIs, what they give the companion for controller fusion, and the vendor-neutral code that lets an adapter be added without touching the controller pipeline.


## Short answer

- **No shipping API gives this app the WMR controller's 6DoF pose.** WMR controllers are not OpenXR devices, so Android XR, XREAL, RayNeo, Rokid and VITURE runtimes do not track them. The controller's own IMU still provides orientation at 150–180 Hz.
- **Android XR is the cleanest native path** for both 6DoF head pose and 26-joint hand tracking, with documented permissions. It is a Kotlin/Jetpack XR API, so the companion needs a small Flutter Android plugin. Its IR tracking cameras are still not app-accessible ([CAMERAS.md](../CAMERAS.md)).
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
- **What is not available:** the tracking cameras. Android XR permits the outward passthrough camera (subject to permission), not the non-standard tracking cameras ([CAMERAS.md](../CAMERAS.md)). This rules out direct WMR LED constellation tracking on the headset.
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
- **IR-capable tracking frames.** VITURE's stereo frames are grayscale and their IR response is unknown; XREAL and Android XR hide the tracking cameras. LED constellation tracking remains unproven on all of them ([CAMERAS.md](../CAMERAS.md)).
- **A shared clock.** Every SDK has its own monotonic epoch. The companion must align tracking timestamps to the BLE transport's `Stopwatch` before fusion. The controller stream uses `receivedAtUs` from that clock; tracking frames go through `SourceClockAligner`.
- **Fusion on the glasses.** Android XR, RayNeo X3 Pro, the VITURE Pro Neckband and Rokid AR Studio all run tracking on the device that hosts the app. XREAL Air 2 Ultra and VITURE's C SDK compute on the phone. The companion can therefore run where the BLE link is, or relay frames to it; the framework only assumes one fusion host with a monotonic clock.


## Sources

All accessed 2026-10-25.

- Android XR, hands: https://developer.android.com/develop/xr/jetpack-xr-sdk/arcore/hands
- Android XR, device pose: https://developer.android.com/develop/xr/jetpack-xr-sdk/arcore/device-pose
- Android XR camera restrictions (secondary): [CAMERAS.md](../CAMERAS.md), which cites Android Authority's report.
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


