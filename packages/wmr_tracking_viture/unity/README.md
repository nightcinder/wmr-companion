# VITURE Unity smoke project

Small Unity 6000.0 project for the `wmr_tracking_viture` Unity-as-a-Library
(UaaL) relay. It contains the runtime bridge, a one-scene smoke harness, and an
editor script that exports the `unityLibrary` Gradle module.

No proprietary SDK is vendored. The project opens without the VITURE XR SDK but
the bridge compiles its SDK calls only when `WMR_VITURE_XR_SDK` is defined, and
the export script fails closed with install instructions when either define is
missing.

## Prerequisites

- Unity 6000.0.x with Android Build Support (SDK, NDK, OpenJDK).
- VITURE XR SDK for Unity v0.9.0 (`com.viture.xr`) from the VITURE developer
  package.
- Unity XR Hands (`com.unity.xr.hands`, pinned in `Packages/manifest.json`).
- A VITURE Pro Neckband with Luma Ultra for real head/hand frames.

## Import steps

1. Open `packages/wmr_tracking_viture/unity` with Unity Hub / Unity 6000.0.x.
2. Add the VITURE XR SDK: **Window > Package Manager > + > Add package from
   tarball** (or from git URL), selecting `com.viture.xr` v0.9.0. Do not copy the
   SDK into this repository.
3. Confirm the runtime assembly picked up the defines: select
   `Assets/WmrTrackingViture/Runtime/WmrTrackingViture.Runtime.asmdef` and check
   **Version Defines** for `WMR_UNITY_XR_HANDS` and `WMR_VITURE_XR_SDK`.
4. **Player > Android**: minimum API 24, ARM64, IL2CPP (the export script also
   applies these). The export then configures **XR Plug-in Management > Android**
   through `WMR > Configure VITURE XR`: the VITURE loader is assigned and
   **Initialize XR on Startup** is on, so the exported player renders in stereo
   3D from launch. VITURE hand tracking only produces frames in stereo
   (SpaceWalker) mode; a mono 2D player reports `unavailable` from `start`
   instead of stalling. Run the menu item manually after changing XR settings.
5. Open `Assets/Scenes/WmrTrackingSmoke.unity` and enter Play mode to see the
   relay's local logs. Without a Luma Ultra the bridge reports `unsupported`
   through `onUnityError`; that is the expected fail-closed result.

## Export `unityLibrary`

Use **WMR > Export VITURE unityLibrary**, or run Unity in batch mode:

```sh
Unity -batchmode -quit \
  -projectPath packages/wmr_tracking_viture/unity \
  -buildTarget Android \
  -executeMethod OnyxLens.WmrTrackingViture.Editor.WmrTrackingVitureExport.Export \
  -logFile -
```

The script exports `unity/Build/Android/` and verifies that
`unity/Build/Android/unityLibrary` exists. `Build/` is gitignored; do not commit
the export. Delete `Build/Android` before re-exporting if you do not want to
keep generated Gradle changes.

## Host wiring

- Add the exported `unityLibrary` as a Gradle module of the Android host (or of
  the Flutter app that depends on `wmr_tracking_viture`). The Flutter plugin does
  not bundle it, because the export needs the proprietary SDK.
- The host activity must create the Unity player and forward
  `onCreate`/`onPause`/`onResume`/`onDestroy` to `UnityPlayer` per Unity's UaaL
  documentation. The smoke scene relies on `OnApplicationPause` to stop and
  resume frame emission.
- Relay contract (unchanged): Kotlin calls
  `UnityPlayer.UnitySendMessage("WmrTrackingRelay", "OnCommand", json)` with
  `{"v":1,"cmd":"start"|"stop"|"dispose"|"recenter"|"configure",...}`. Frames
  return as OpenXR-space JSON through
  `WmrTrackingViturePlugin.onUnityFrame(json)`; errors go to `onUnityError`, and
  the glasses model to `onUnityGlassesModel`.
- The host owns `start`/`stop`. The smoke scene never starts vendor tracking on
  its own in a player build: the scene ships with `autoStart` off and the
  harness ignores that field outside the editor, so the session stays inside
  the plugin's CAMERA-permission and default-off flow. On resume the harness
  only logs state; a session the host stopped stays stopped.
- `start` is idempotent, so a repeated `start` from the host is accepted
  without restarting the SDK session.

## What the smoke scene does

- Can send the same `start` envelope as `VitureRelayCommandBuilder.start()`
  (`filter_mode=responsive`, `aim_sensitivity=high`) via `SendStart()`, or on
  editor Play when `autoStart` is enabled. Player builds never send it.
- Subscribes to `VitureTrackingRelayBridge.FrameEmitted`, logs the first full
  frame and every 30th frame (size, head/hands presence).
- Logs `ErrorReported` codes so an unsupported glasses model or missing SDK is
  visible without an attached debugger.
- On pause, logs the frame count and keeps `_running`; frames stop while paused
  and resume on the next `Update`. On resume it only logs; restarting is the
  host's decision, never the scene's.

## Gate

The Unity compile/export requires the proprietary VITURE SDK and Android build
support and is a documented external gate. CI only runs the Dart/Kotlin tests;
the C# bridge and smoke harness are statically reviewed against the relay
contract. No Neckband or Luma Ultra run has happened, so the stereo 3D handoff
(loader assigned at startup, `XRSettings.isDeviceActive` true on device) is
unverified; if it reports false the host must switch the glasses to 3D /
SpaceWalker before starting tracking.
