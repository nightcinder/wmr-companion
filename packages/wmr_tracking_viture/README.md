# wmr_tracking_viture

Default-off VITURE Pro Neckband head and 26-joint hand tracking relay source for
[`wmr_tracking`](../wmr_tracking).

VITURE hand tracking is available only through the VITURE XR SDK for Unity
(v0.9.0, Unity 6000.0+) running on the VITURE Pro Neckband with Luma Ultra
glasses; the cross-platform C glasses SDK exposes head pose and cameras only.
The VITURE XR loader must render the player in stereo 3D (SpaceWalker mode):
the export assigns it and enables startup initialisation, and `start` reports
`unavailable` from a mono 2D player instead of stalling. The stereo mode is
fixed by the loader when its display subsystem initialises; Unity exposes
`XRSettings.stereoRenderingMode` read-only, so the player cannot switch modes at
runtime. The 2D gate is covered by the on-device check only: the stub-compile
project proves the bridge compiles, not that the gate fires.
This plugin bridges an embedded Unity-as-a-Library (UaaL) tracking scene to
Flutter:

0. On `start` the plugin hosts the shared Unity player in the foreground
   activity: `UnityPlayerHost` constructs `com.unity3d.player.UnityPlayer` by
   reflection, attaches its view full-screen over the Flutter view, and reports
   `playerHosted`. `stop` (or a detach/error) removes the view and gives the
   display back to Flutter; the activity forwards pause/resume/config/focus to
   the player. The `start` reply and `capabilities` carry `playerHosted`,
   `stereoMode` and the last scene `stage` (`playerHosted`, `loaderStarted`,
   `firstFrame`).
1. Kotlin sends `UnityRelayCommand` JSON (`start`, `stop`, `dispose`,
   `recenter`, `configure`) via `UnityPlayer.UnitySendMessage("WmrTrackingRelay", "OnCommand", json)`.
   `recenter` delegates to `Viture.XR.VitureXR.HeadTracking.SetWorldOrigin()`.
2. The minimal C# component (`unity/Assets/WmrTrackingViture/Runtime/VitureTrackingRelayBridge.cs`)
   calls `Viture.XR.VitureXR.Glasses.GetGlassesModel()`, `Viture.XR.VitureXR.HandTracking.Start()` /
   `.Stop()`, reads the head pose and 26 `XRHandJointID` joints from
   `XRHandSubsystem`, converts left-handed Unity coordinates to right-handed
   OpenXR coordinates, and forwards frames to
   `WmrTrackingViturePlugin.onUnityFrame(json)`.
3. Dart's `VitureNeckbandTrackingSource` implements `TrackingSource` so
   `WmrCompanion.attachTrackingSource` aligns timestamps with
   `SourceClockAligner` and feeds `SixDofFuser` (with the shared One Euro
   hand-anchor filter).

```dart
final source = await VitureNeckbandTrackingSource.create(); // null when off
if (source != null) {
  await companion.attachTrackingSource(source);
}
```

Enable the slice with `--dart-define=WMR_VITURE_TRACKING=true`. With the flag
off, `create()` returns `null` without touching a platform channel, so BLE,
controller IMU and 3DoF output are unchanged.

Failures are typed `TrackingException`s:
- `unavailable`: the Unity UaaL runtime (`com.unity3d.player.UnityPlayer`) or
  VITURE XR SDK bridge is not linked, the host activity is detached, or `start`
  runs while the VITURE XR loader is not rendering in stereo 3D (SpaceWalker
  mode) : a 2D player cannot deliver hand joints.
- `unsupported`: the reported glasses model is not a `LumaUltra` (`One`,
  `OneLite`, `Pro`, `Pro2`, `Luma`, `LumaPro`, `LumaCyber`, `Beast`, or an
  unclassifiable name), or the host is not a VITURE Pro Neckband. An unreported
  model is not an error: `create()` succeeds and the Unity `start` handshake
  reports the real model.
- `permissionDenied`: `android.permission.CAMERA` was denied. The permission is
  declared in the plugin manifest (with `android.hardware.camera` optional)
  and is inert while `WMR_VITURE_TRACKING` is false. Host apps not using the
  VITURE slice can exclude it using `tools:node="remove"`.
- `protocol`: a relay frame or capability handshake was malformed.

## Carina C-SDK diagnostic spike (debug only)

The Luma Ultra exposes four 8-bit grayscale stereo buffers through the C SDK's
`XRCameraCallback`. `VitureCarinaDiagnostics` is a local spike for deciding
whether that feed beats the hand-tracking route; it is not a product path.

Build a debug app with both the flag and a debuggable APK:

```sh
flutter run --debug --dart-define=WMR_VITURE_CARINA_DIAG=true
```

Then trigger one 12 s capture and write it to a directory you can pull:

```dart
final report = await VitureCarinaDiagnostics.capture(
  outputDirectory: '/data/user/0/com.onyxlens.wmr_companion/cache/carina-1',
);
```

The native harness (`android/src/main/cpp/carina_diag.c`, built as
`libcarina_diag.so`) hands the glasses' USB fd to
`xr_device_provider_create`, registers the Carina camera callback, polls
`xr_device_provider_get_gl_pose_carina` every 10 ms, and keeps one copied frame
per rung for `left0`, `right0`, `left1` and `right1`. It applies the fixed
ladder 0.1, 0.3, 1.0 and 3.0 ms at gain 6. Output is one PGM per channel per
rung (`carina-rung<N>-<channel>-<ms>ms.pgm`) plus
`carina-diagnostics.json` with width, height, fps, callback copy latency and
pose rate.

`libglasses.so` is proprietary and is not in this repository, so the harness
`dlopen`s it. For a local run, stage it in the app's
`android/unity/unified/unityLibrary/src/main/jniLibs/arm64-v8a/` (or any path
in `WMR_CARINA_LIBGLASSES`). Without it the capture returns a typed
`sdkUnavailable` error and never dereferences a missing symbol. Shipping the
SDK still needs written VITURE permission (ONY-732 audit).

The Kotlin side only requests USB permission and returns
`UsbDeviceConnection.fileDescriptor`; it is rejected unless the app is
debuggable. `flutter test` covers the ladder and telemetry decoding, not the
native call.

## Unity smoke project

`unity/` is a minimal Unity 6000.0 project with the relay bridge, a smoke scene
that sends `start`, logs frames and survives pause/resume, and an editor script
that exports the `unityLibrary` Gradle module. Import and export steps are in
[`unity/README.md`](unity/README.md). The VITURE XR SDK is not vendored.

Nothing in this package has run on a VITURE Pro Neckband or glasses. The Unity
6000.0+ UaaL export and proprietary VITURE Unity SDK (`com.viture.xr` v0.9.0)
are external SDK gates; Kotlin and Dart compile and pass host/JVM tests without
requiring the proprietary AAR at build time.
