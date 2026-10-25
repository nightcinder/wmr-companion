# wmr_tracking

Pure-Dart head and hand tracking seam for 6DoF controller fusion in the WMR
companion. This package is publish-ready but like the other packages is not on pub.dev
yet; no vendor adapter has been run on hardware. The research and integration plan are in
[`docs/TRACKING.md`](../../docs/TRACKING.md).

## What it does

- `TrackingSource`: one interface per runtime (Android XR, XREAL, RayNeo,
  Rokid, VITURE or a relay), with declared `TrackingCapabilities`.
- `TrackingFrame` / `HandPose` / `TrackedPose`: normalised OpenXR-style poses
  (metres, +X right, +Y up, -Z forward) and 26 OpenXR-named hand joints.
- `SourceClockAligner`: maps a vendor timestamp domain onto the host monotonic
  clock used by the BLE stream.
- `SixDofFuser`: combines controller IMU orientation with a runtime controller
  pose, a hand anchor or a head-local fallback, and reports which one it used.
- `TrackingFrameCodec` / `RelayTrackingSource`: versioned JSON and a source that decodes it, for a native plugin or Unity sidecar.
- `FakeTrackingSource`: hardware-free tests and UI development.

No vendor SDK is bundled. That is deliberate: XREAL, RayNeo, Rokid and VITURE
hand tracking are Unity-only today, VITURE's C SDK exposes head pose but not
hands, and Android XR needs a Kotlin plugin. The package makes the fusion side
stable while those adapters are added. Kotlin and Unity belong in sibling
Flutter plugin packages; see the packaging section of
[`docs/TRACKING.md`](../../docs/TRACKING.md#packaging-kotlin-and-unity-inside-a-flutter-plugin).

## Usage

```dart
import 'package:wmr_companion/wmr_companion.dart';

final companion = WmrCompanion(ble: transport);
await companion.attachTrackingSource(source);

companion.poses.listen((pose) {
  if (!pose.hasPosition) return; // orientation only
  final world = pose.pose!;
  final quaternion = pose.orientation;
});
```

`ControllerPose.source` is `runtimeController`, `handAnchor`, `headRelative` or
`orientationOnly`. Only the first two are absolute; `headRelative` moves the
controller with the head and is marked low confidence.

## Test

```sh
dart test
dart analyze
```
