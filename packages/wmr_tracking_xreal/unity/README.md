# XREAL Unity smoke project

Minimal Unity 6000.0 project for the `wmr_tracking_xreal` Unity-as-a-Library
(UaaL) relay. It contains the runtime bridge, a one-scene smoke harness, and an
editor script that exports the `unityLibrary` Gradle module.

No proprietary SDK is vendored. The bridge compiles its XREAL and XR Hands calls
only when `WMR_XREAL_XR_SDK` / `WMR_UNITY_XR_HANDS` are defined, and the export
script fails closed with install instructions when either define is missing.

## Prerequisites

- Unity 6000.0.x with Android Build Support (SDK, NDK, OpenJDK).
- XREAL SDK for Unity 3.x (`com.xreal.xr`) from the XREAL developer package.
- Unity XR Hands (`com.unity.xr.hands`, pinned in `Packages/manifest.json`).
- An XREAL Air 2 Ultra on a supported Beam Pro / phone for real frames.

## Import steps

1. Open `packages/wmr_tracking_xreal/unity` with Unity Hub / Unity 6000.0.x.
2. Add the XREAL SDK: **Window > Package Manager > + > Add package from
   tarball** (or from git URL), selecting `com.xreal.xr` 3.x. Do not copy the SDK
   into this repository.
3. Confirm the runtime assembly picked up the defines: select
   `Assets/WmrTrackingXreal/Runtime/WmrTrackingXreal.Runtime.asmdef` and check
   **Version Defines** for `WMR_UNITY_XR_HANDS` and `WMR_XREAL_XR_SDK`.
4. **Project Settings > XR Plug-in Management > Android**: enable XREAL and set
   **Initial Input Source = Hands**. Include `XREAL_DEVICE_CATEGORY_REALITY` in
   **Support Devices**. The bridge does not switch input source at runtime.
5. **Player > Android**: minimum API 24, ARM64, IL2CPP (the export script also
   applies these).
6. Open `Assets/Scenes/WmrTrackingSmoke.unity` and enter Play mode to see the
   relay's local logs. Without an Air 2 Ultra the bridge reports `unsupported`
   through `onUnityError`; that is the expected fail-closed result.

## Export `unityLibrary`

Use **WMR > Export XREAL unityLibrary**, or run Unity in batch mode:

```sh
Unity -batchmode -quit \
  -projectPath packages/wmr_tracking_xreal/unity \
  -buildTarget Android \
  -executeMethod OnyxLens.WmrTrackingXreal.Editor.WmrTrackingXrealExport.Export \
  -logFile -
```

The script exports `unity/Build/Android/` and verifies that
`unity/Build/Android/unityLibrary` exists. `Build/` is gitignored; do not commit
the export. Delete `Build/Android` before re-exporting if you do not want to
keep generated Gradle changes.

## Host wiring

- Add the exported `unityLibrary` as a Gradle module of the Android host (or of
  the Flutter app that depends on `wmr_tracking_xreal`). The Flutter plugin does
  not bundle it, because the export needs the proprietary SDK.
- The host activity must create the Unity player and forward
  `onCreate`/`onPause`/`onResume`/`onDestroy` to `UnityPlayer` per Unity's UaaL
  documentation. The smoke scene relies on `OnApplicationPause` to stop and
  resume frame emission.
- Relay contract (unchanged): Kotlin calls
  `UnityPlayer.UnitySendMessage("WmrTrackingRelay", "OnCommand", json)` with
  `{"v":1,"cmd":"start"|"stop"|"dispose",...}`. Frames return as OpenXR-space
  JSON through `WmrTrackingXrealPlugin.onUnityFrame(json)`; errors go to
  `onUnityError`, and the device type to `onUnityGlassesModel`.
- `start` is idempotent. When the scene is hosted by the Flutter plugin both the
  smoke harness and the plugin send it; the second one is accepted without
  restarting the XR Hands subsystem.

## What the smoke scene does

- Sends the same `start` envelope as `XrealRelayCommandBuilder.start()`.
- Subscribes to `XrealTrackingRelayBridge.FrameEmitted`, logs the first full
  frame and every 30th frame (size, head/hands presence).
- Logs `ErrorReported` codes so an unsupported device, missing input source, or
  missing SDK is visible without an attached debugger.
- On pause, logs the frame count and keeps the XR Hands subsystem running;
  frames stop while paused and resume on the next `Update`. If the relay is no
  longer running on resume, the harness sends `start` again.

## Gate

The Unity compile/export requires the proprietary XREAL SDK and Android build
support and is a documented external gate. CI only runs the Dart/Kotlin tests;
the C# bridge and smoke harness are statically reviewed against the relay
contract. No Air 2 Ultra run has happened.
