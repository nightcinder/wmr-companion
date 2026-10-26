# Headset hand and head tracking — framework

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

The Dart/Kotlin relay contract and the VITURE Neckband slice (`packages/wmr_tracking_viture`) are implemented and host-tested; exporting the Unity 6000.0.27f1 `unityLibrary` AAR with the proprietary VITURE XR SDK (`com.viture.xr` v0.9.0, `Viture.XR.VitureXR`) and running on a physical Pro Neckband remain external SDK/hardware gates.

### One `unityLibrary` for both vendors

`packages/wmr_tracking_unity` is a prototype that puts one Unity 6000.0 project and one `WmrTrackingRelay` in front of both vendor bridges. `configure`/`start` carry `"vendor":"viture"` or `"vendor":"xreal"`; only that vendor's bridge and XR loader are selected, and the per-vendor relay JSON is unchanged. Its [README](../../packages/wmr_tracking_unity/README.md) lists the coexistence unknowns: two XR Management loaders and deferred init, duplicate native `.so`/manifest entries, SDK redistribution terms, static initialisers from the inactive vendor, Kotlin-side selection, and the absence of any export or hardware run. The dispatch is compiled and tested outside Unity; the Unity assembly and export remain an external gate. If coexistence is ruled out, ONY-271 flavors stay the answer.


## The framework

`packages/wmr_tracking` is pure Dart, depends only on `vector_math`, and is publishable but not on pub.dev (like the other packages, on owner hold). `packages/wmr_tracking_android_xr` is the optional Flutter plugin around it and adds `androidx.xr.runtime`, `androidx.xr.arcore` and `androidx.xr.scenecore` 1.0.0. `packages/wmr_tracking_viture` is the optional Flutter plugin for the VITURE Pro Neckband Unity UaaL relay, and `packages/wmr_tracking_xreal` is the optional Flutter plugin for the XREAL Air 2 Ultra Unity UaaL relay. All three sit below the facade:

```
Android XR plugin ──┤ (implemented)
XREAL Unity ────────┤ (implemented)
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


### Debug viewer and simulator

The reference app's debug screen shows `ControllerPoseView` for the selected hand plus position (metres) and position-source readouts for both hands. A **Tracking source** selector offers None, Simulated, Android XR, VITURE and XREAL and defaults to None, which shows the controller IMU orientation and an `orientationOnly` badge. Selecting a vendor calls that package's `create()` only when its `--dart-define` flag is on, starts the source, aligns its frames to the viewer clock and feeds `SixDofFuser`; a typed `TrackingException` (`unavailable` when the Unity relay is not linked, `unsupported`, `permissionDenied`, `protocol`) is shown in the selector status instead of crashing. Simulated keeps the deterministic `FakeTrackingSource` hand trajectory that moves the viewer without a headset. One APK built with all three flags is safe to run with no Unity runtime linked. The debug screen still runs on `ControllerService` rather than the `WmrCompanion` facade, so it fuses the same decoded samples locally; no exported API changed.

### Native detection and one UnityPlayer

`packages/wmr_tracking_dispatch` detects the vendor before any Unity command: the host (Neckband, Beam Pro or phone) and USB IDs, returning a typed `GlassesDetection`. Its Dart `TrackingSourceSelector` attaches the matching source or reports `unsupported` / `unavailable` / `permissionDenied`, and it never probes the native channel while every vendor flag is off. VITURE and XREAL now share one process-wide `SharedUnityRuntime`: the first claimant owns the single `UnityPlayer`, the other reuses it, and frame/error/glasses-model callbacks route by vendor. The per-vendor model check still runs as a second confirmation. USB IDs that public docs do not state are configurable rather than guessed; see [GLASSES_DETECTION.md](../GLASSES_DETECTION.md).


### Adapter recipes

**Android XR (implemented first target).**
1. `packages/wmr_tracking_android_xr` is the Kotlin plugin; the debug screen's tracking-source selector starts it when `WMR_ANDROID_XR_TRACKING` is on.
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

**XREAL Air 2 Ultra.** `packages/wmr_tracking_xreal` embeds a one-scene Unity UaaL relay and reuses the shared `UnityRelayCommand` / `UnityRelayFrameCodec` contract. The C# bridge reads the head pose and the 26 `XRHandJointID` joints from the XREAL XR Hands subsystem, converts Unity to OpenXR space, and calls back through JNI. The Unity project must set **Initial Input Source = Hands**; the bridge does not switch input source at runtime. See the vertical-slice section below.

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
cd apps/wmr_companion_app && tool/build_flavor.sh base
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
| Minimal Unity C# bridge (`VitureTrackingRelayBridge.cs` + `.asmdef`) | Implemented in `packages/wmr_tracking_viture/unity/`; Unity 6000.0.27f1 and `com.viture.xr` v0.9.0 (`Viture.XR.VitureXR`) are external SDK gates |
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
cd apps/wmr_companion_app && tool/build_flavor.sh viture
cd apps/wmr_companion_app/android && ./gradlew :wmr_tracking_viture:testDebugUnitTest
```

Explicit unknowns and SDK-bound gates:
- **External SDK gate:** Unity 6000.0.27f1 Android build support, `com.unity.xr.hands`, and the VITURE XR SDK for Unity v0.9.0 (`com.viture.xr`, API `Viture.XR.VitureXR`) are not redistributable in this repo. `WmrTrackingViturePlugin` isolates `com.unity3d.player.UnityPlayer` behind `VitureUnityBridge` so standard CI builds and tests pass, and reports `TrackingExceptionKind.unavailable` when `unityLibrary` is not linked.
- **Undocumented vendor parameters:** Unity head and hand update rates on the Pro Neckband are not stated in VITURE's public docs (`maxHeadRateHz: 0`, `maxHandRateHz: 0`); Android permissions required by the VITURE Unity runtime beyond `android.permission.CAMERA` are not documented; and whether a hand gripping a WMR controller stays tracked by `Viture.XR.VitureXR.HandTracking` is unproven.


## XREAL Air 2 Ultra vertical slice (ONY-214)

What landed, and what remains an external SDK or hardware gate:

| Piece | State |
|---|---|
| Reusable Unity relay contract (`UnityRelayCommand`, `UnityRelayFrameCodec`, `UnityXrHandJoints`) | Reused from `packages/wmr_tracking` (ONY-213); no public API change |
| Unity → OpenXR conversion (`p=(x,y,z) -> (x,y,-z)`, `q=(qx,qy,qz,qw) -> (-qx,-qy,qz,qw)`) | Implemented in Kotlin and C# (the C# bridge emits `"space": "openxr"`); Dart also converts `"space": "unity"` sidecar frames; verified within `1e-6` with round-trip (`frame_conversion`) |
| Dart `XrealAir2UltraTrackingSource`, default-off `WMR_XREAL_TRACKING` flag, typed errors | Implemented in `packages/wmr_tracking_xreal` and host-tested |
| Glasses capability matrix | `Air2Ultra` only advertises 6DoF head + 26 hands; `One`/`OnePro` report 6DoF head only (XREAL Eye); `Air`/`Air2`/`Air2Pro`/`Light` report 3DoF head only. All non-Ultra models fail `create()` with `unsupported` |
| Kotlin `WmrTrackingXrealPlugin`, camera permission gate (`PendingStartGate`), reflective `UnitySendMessage` bridge | Implemented and JVM-tested; compiles without the proprietary `unityLibrary` AAR |
| Minimal Unity C# bridge (`XrealTrackingRelayBridge.cs` + `.asmdef`) | Implemented in `packages/wmr_tracking_xreal/unity/`; reads `XREALPlugin.GetDeviceType()` and the running `XRHandSubsystem`. Unity 2021.3+/6000.0 and XREAL SDK 3.x (`com.xreal.xr`) are external SDK gates |
| Flag-off BLE/3DoF parity | `apps/wmr_companion_app/test/xreal_flag_off_test.dart` replays 400 deterministic bridge ticks, matches PR #78 (`c3be059`) golden orientations, and touches no XREAL channel |
| Hardware / Unity UaaL smoke test | **Not run** |

Synthetic vectors and fixtures:
- `packages/wmr_tracking/test/xreal_fixture_test.dart`: `frame_conversion` (Unity `p=(1,2,3)`, `q=(qx,qy,qz,qw)` → OpenXR `(1,2,-3)`, `(-qx,-qy,qz,qw)` within `1e-6` and round-trip), `xreal_26_joint_unity_frame.json` (26 `XRHandJointID` joints + palm anchoring), `xreal_26_joint_grip_frame.json` (grip anchor priority over palm), and `xreal_relay_commands.json` (`start`, `stop`, `dispose` command envelopes).
- `packages/wmr_tracking_xreal/test/xreal_tracking_source_test.dart`: default-off flag, Air 2 Ultra capabilities, One + Eye rejection (`xreal_one_eye_unsupported.json`), 3DoF Air rejection (`xreal_air2_3dof_unsupported.json`), unlinked Unity UaaL runtime (`xreal_unity_unavailable.json`), camera permission denial (`xreal_permission_denied.json`), idempotent `start`/`stop`/`dispose`, malformed frames and stream error recovery.
- `packages/wmr_tracking_xreal/android/src/test/kotlin/`: JVM unit tests for 26-joint `XRHandJointID` mapping, Unity→OpenXR conversion, `XrealGlassesModelSpec` (including `XREAL_AIR_2_ULTRA`-style aliases), unreported/null glasses model default, command JSON builders, `WmrTrackingXrealPlugin` capability/start flows and `PendingStartGate`.

Commands used for this slice:

```bash
cd packages/wmr_tracking && dart analyze && dart test
cd packages/wmr_tracking_xreal && flutter analyze && flutter test
cd apps/wmr_companion_app && flutter analyze && flutter test
cd apps/wmr_companion_app && tool/build_flavor.sh xreal
cd apps/wmr_companion_app/android && ./gradlew :wmr_tracking_xreal:testDebugUnitTest
```

Explicit unknowns and SDK-bound gates:
- **External SDK gate:** Unity 2021.3+/6000.0 Android build support, `com.unity.xr.hands`, and the XREAL SDK for Unity 3.x (`com.xreal.xr`) are not redistributable in this repo. `WmrTrackingXrealPlugin` isolates `com.unity3d.player.UnityPlayer` behind `XrealUnityBridge`, and the C# bridge guards `XREALPlugin.GetDeviceType()` and the XR Hands API behind `WMR_XREAL_XR_SDK` / `WMR_UNITY_XR_HANDS`; CI without the AAR compiles and reports `unavailable`.
- **Project-setting gate:** the XREAL XR Plug-in must be enabled with **Initial Input Source = Hands**, Unity XR Hands + XRI installed, and `XREAL_DEVICE_CATEGORY_REALITY` included in Support Devices. The bridge does not change the input source at runtime because no runtime API for it was verified; a project left on Controller input reports `unavailable` when `start` cannot find a running `XRHandSubsystem`.
- **Undocumented vendor parameters:** XREAL does not publish Unity head or hand update rates (`maxHeadRateHz: 0`, `maxHandRateHz: 0`); the Android permissions the XREAL Unity runtime needs are not documented, so `android.permission.CAMERA` is an unverified assumption (declared optional and inert while the flag is off); `XREALPlugin.GetDeviceType()` enum spellings are not fully documented, so both Dart and Kotlin normalise and alias the name and fail closed on anything unrecognised; and whether an Air 2 Ultra keeps tracking a hand gripping a WMR controller is unproven. Passthrough camera frames are not relayed.


