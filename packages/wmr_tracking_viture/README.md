# wmr_tracking_viture

Default-off VITURE Pro Neckband head and 26-joint hand tracking relay source for
[`wmr_tracking`](../wmr_tracking).

VITURE hand tracking is available only through the VITURE XR SDK for Unity
(v0.7.0, Unity 6000.0+) running on the VITURE Pro Neckband with Luma Ultra
glasses; the cross-platform C glasses SDK exposes head pose and cameras only.
This plugin bridges an embedded Unity-as-a-Library (UaaL) tracking scene to
Flutter:

1. Kotlin sends `UnityRelayCommand` JSON (`start`, `stop`, `dispose`,
   `recenter`, `configure`) via `UnityPlayer.UnitySendMessage("WmrTrackingRelay", "OnCommand", json)`.
   `recenter` delegates to `VitureXR.HeadTracking.SetWorldOrigin()`.
2. The minimal C# component (`unity/Assets/WmrTrackingViture/Runtime/VitureTrackingRelayBridge.cs`)
   calls `VitureXR.Glasses.GetGlassesModel()`, `VitureXR.HandTracking.Start()` /
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
  VITURE XR SDK bridge is not linked, or the host activity is detached.
- `unsupported`: the glasses model is unreported / unknown, the connected glasses
  are a 3DoF-only model (`One`, `OneLite`, `Pro`, `Pro2`, `Luma`, `LumaPro`,
  `LumaCyber`, `Beast`) rather than `LumaUltra`, or the host is not a VITURE
  Pro Neckband.
- `permissionDenied`: `android.permission.CAMERA` was denied. The permission is
  declared in the plugin manifest (with `android.hardware.camera` optional)
  and is inert while `WMR_VITURE_TRACKING` is false. Host apps not using the
  VITURE slice can exclude it using `tools:node="remove"`.
- `protocol`: a relay frame or capability handshake was malformed.

## Unity smoke project

`unity/` is a minimal Unity 6000.0 project with the relay bridge, a smoke scene
that sends `start`, logs frames and survives pause/resume, and an editor script
that exports the `unityLibrary` Gradle module. Import and export steps are in
[`unity/README.md`](unity/README.md). The VITURE XR SDK is not vendored.

Nothing in this package has run on a VITURE Pro Neckband or glasses. The Unity
6000.0+ UaaL export and proprietary VITURE Unity SDK (`com.viture.xr` v0.7.0)
are external SDK gates; Kotlin and Dart compile and pass host/JVM tests without
requiring the proprietary AAR at build time.
