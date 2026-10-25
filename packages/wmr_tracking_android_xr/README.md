# wmr_tracking_android_xr

Default-off Android XR head and 26-joint hand tracking source for
[`wmr_tracking`](../wmr_tracking).

The Kotlin plugin owns an ARCore for Jetpack XR `Session`, requests
`android.permission.HAND_TRACKING` and `android.permission.HEAD_TRACKING`,
configures `HandTrackingMode.BOTH` with `DeviceTrackingMode.SPATIAL`, and
forwards head pose plus both hands as `TrackingFrameCodec` JSON. The Dart
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
`start`, `stop` and `dispose` are idempotent. A Jetpack XR session is tied to
its activity, so activity recreation stops tracking and the consumer restarts
the source.

Android XR exposes `PALM`, `WRIST` and the other OpenXR joints; it does not
expose a controller `grip` pose. Fusion uses the palm plus its configured or
calibrated grip offset. Tracking cameras are not available to apps.

Nothing in this package has run on an Android XR device or glasses. The
current gates are Kotlin compilation, the Kotlin joint-name unit test and the
Dart host tests; rates, permission prompts and whether a gripping hand stays
tracked are unknown.
