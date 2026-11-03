# wmr_tracking_xreal

Off by default: XREAL Air 2 Ultra head and 26-joint hand tracking relay source for
[`wmr_tracking`](../wmr_tracking).

XREAL hand tracking is available only through the XREAL SDK for Unity 3.x
(`com.xreal.xr`) on the Air 2 Ultra; the One series has 6DoF head pose with the
XREAL Eye but no hands, and Air / Air 2 / Air 2 Pro are 3DoF head-only. There is
no native Android or Flutter hand-tracking API. This plugin bridges an embedded
Unity-as-a-Library (UaaL) tracking scene to Flutter:

1. Kotlin sends `UnityRelayCommand` JSON (`start`, `stop`, `dispose`) via
   `UnityPlayer.UnitySendMessage("WmrTrackingRelay", "OnCommand", json)`.
2. The minimal C# component (`unity/Assets/WmrTrackingXreal/Runtime/XrealTrackingRelayBridge.cs`)
   calls `XREALPlugin.GetDeviceType()`, reads the head pose and the 26
   `XRHandJointID` joints from the running `XRHandSubsystem`, converts
   left-handed Unity coordinates to right-handed OpenXR coordinates, and
   forwards frames to `WmrTrackingXrealPlugin.onUnityFrame(json)`.
3. Dart's `XrealAir2UltraTrackingSource` implements `TrackingSource` so
   `WmrCompanion.attachTrackingSource` aligns timestamps with
   `SourceClockAligner` and feeds `SixDofFuser` (with the shared One Euro
   hand-anchor filter).

```dart
final source = await XrealAir2UltraTrackingSource.create(); // null when off
if (source != null) {
  await companion.attachTrackingSource(source);
}
```

Enable the slice with `--dart-define=WMR_XREAL_TRACKING=true`. With the flag
off, `create()` returns `null` without touching a platform channel, so BLE,
controller IMU and 3DoF output are unchanged.

Failures are typed `TrackingException`s:
- `unavailable`: the Unity UaaL runtime (`com.unity3d.player.UnityPlayer`), the
  XREAL XR Hands subsystem or the host activity is missing.
- `unsupported`: the reported glasses model is not an Air 2 Ultra (`One`,
  `OnePro`, `Air`, `Air2`, `Air2Pro`, `Light`, or an unclassifiable name). An
  unreported model is not an error: `create()` succeeds and the Unity `start`
  handshake reports the real model. That handshake result is not surfaced back
  to Dart (`glassesModel` is the pre-start snapshot), so on the deferred path a
  successful `start` is the Air 2 Ultra confirmation; any other model fails
  `unsupported (found <model>)`.
- `permissionDenied`: `android.permission.CAMERA` was denied. The permission is
  declared in the plugin manifest (with `android.hardware.camera` optional)
  and is inert while `WMR_XREAL_TRACKING` is false.
- `protocol`: a relay frame or capability handshake was malformed.

The Unity project needs XR Plug-in Management → XREAL enabled, **Initial Input
Source = Hands**, `Support Devices` including `XREAL_DEVICE_CATEGORY_REALITY`,
and Unity XR Hands + XRI installed. None of this has run on an Air 2 Ultra or a
supported phone. The Unity 2021.3+/6000.0 UaaL export and the proprietary XREAL
SDK (`com.xreal.xr`) are external SDK gates; Kotlin and Dart compile and pass
host/JVM tests without requiring the proprietary AAR at build time.

## Unity smoke project

`unity/` is a minimal Unity 6000.0 project with the relay bridge, a smoke scene
that sends `start`, logs frames and survives pause/resume, and an editor script
that exports the `unityLibrary` Gradle module. Import and export steps are in
[`unity/README.md`](unity/README.md). The XREAL SDK is not vendored.
