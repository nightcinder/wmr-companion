# wmr_tracking_dispatch

Native glasses vendor detection and one UnityPlayer owner for the
default-off VITURE and XREAL tracking plugins, plus the Dart
`TrackingSourceSelector`.

VITURE and XREAL hand tracking both run through an embedded Unity runtime, but
a process can host only one `UnityPlayer`. This package answers two questions
before any Unity command is sent:

1. **Which vendor is attached?** A Kotlin detector inspects the host (VITURE
   Neckband, XREAL Beam Pro or a phone) and the connected USB device IDs, then
   returns `viture`, `xreal`, `androidXr` or `none` as a typed
   `GlassesDetection`.
2. **Who owns Unity?** The first vendor plugin to claim the shared runtime owns
   it; the other reuses the same player. `onUnityFrame`, `onUnityError` and
   `onUnityGlassesModel` callbacks are routed to the plugin registered for their
   vendor.

The detector only runs when at least one vendor flag is enabled, so flag-off
paths never touch the native channel. The existing per-vendor glasses model
check (`queryGlassesModel`) remains as a second confirmation.

USB IDs and detection order are documented in
[`docs/GLASSES_DETECTION.md`](../../docs/GLASSES_DETECTION.md). IDs that public
docs do not state are configurable instead of guessed.

```dart
final selector = TrackingSourceSelector(
  detector: const PlatformGlassesDetector(),
  flags: TrackingSourceFlags(viture: VitureTracking.enabled),
  vitureSource: VitureNeckbandTrackingSource.create,
);

final selection = await selector.select();
if (selection.hasSource) {
  // selection.source is started; dispose it when done.
}
```
