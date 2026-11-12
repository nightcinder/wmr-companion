# wmr_tracking_android_xr

Off by default: Android XR head and 26-joint hand tracking source for
[`wmr_tracking`](../wmr_tracking).

The Kotlin plugin owns an ARCore for Jetpack XR `Session`. Before creating it
the plugin requests `android.permission.CAMERA`,
`android.permission.SCENE_UNDERSTANDING_COARSE`,
`android.permission.HAND_TRACKING` and `android.permission.HEAD_TRACKING`, and
waits for every grant and for the activity to resume. It configures
`HandTrackingMode.BOTH` with `DeviceTrackingMode.SPATIAL`, and forwards head
pose plus both hands as `TrackingFrameCodec` JSON. `SCENE_UNDERSTANDING_FINE`
("Precise movement and area data") is not requested: it is only needed for fine
scene geometry, and this source reads head and hand poses only. The Dart
`AndroidXrTrackingSource` implements `TrackingSource`, so
`WmrCompanion.attachTrackingSource` aligns timestamps and feeds
`SixDofFuser`.

```dart
final source = await AndroidXrTrackingSource.create(); // null when off
if (source != null) {
  await companion.attachTrackingSource(source);
}
```

Enable the slice with `--dart-define=WMR_ANDROID_XR_TRACKING=true`. With the
flag off, `create()` returns null without touching a platform channel.

Failures are typed `TrackingException`s: a denied permission is
`permissionDenied`, a non-XR device or a refused `SPATIAL` mode is
`unsupported`, and activity detach or a missing runtime is `unavailable`.
Each platform failure also names the boundary that failed in
`TrackingException.stage` (`permissions`, `sessionCreate`, `sessionConfigure`
or `trackingStart`). `start`, `stop` and `dispose` are idempotent. A Jetpack XR session is tied to
its activity, so activity recreation stops tracking and the consumer restarts
the source.

Android XR exposes `PALM`, `WRIST` and the other OpenXR joints; it does not
expose a controller `grip` pose. Fusion uses the palm plus its configured or
calibrated grip offset. Tracking cameras are not available to apps.

Nothing in this package has run on an Android XR device or glasses. The
current gates are Kotlin compilation, the Kotlin joint-name unit test and the
Dart host tests; rates, permission prompts and whether a gripping hand stays
tracked are unknown.
