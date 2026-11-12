# Changelog

## 0.3.0

- Version aligned with the v0.3.0 release; `wmr_tracking` constraint raised to `^0.3.0`.

- Detect an Android XR host before USB IDs and host markers, and refuse to
  construct the vendor Unity player on one. Google Aura exposes the headset as
  XREAL USB `0x3318:0x043A`, so dispatch selected XREAL and started the shared
  Unity player; loading the player reached VITURE's Android plugin, which
  crashed on the missing `android.viture.xr.XRManager` class.
- Migrate the Android plugin to AGP 9 built-in Kotlin: drop the Kotlin Gradle Plugin classpath and `org.jetbrains.kotlin.android`, and require Flutter 3.44 or later.

## 0.2.2

- Version aligned with the v0.2.2 release; `wmr_tracking` constraint raised to `^0.2.2`. No breaking public API change.

## 0.2.1

- Version aligned with the v0.2.1 gate and harness release; `wmr_tracking` constraint raised to `^0.2.1`. No breaking public API change.

## 0.2.0

- Version aligned with the v0.2.0 release; no breaking public API change.

## 0.1.0

- Add the pre-Unity glasses vendor detector (host and USB IDs), the typed
  `GlassesDetection` result and the Dart `TrackingSourceSelector`.
- Add the process-wide `SharedUnityRuntime`: one plugin owns the single
  UnityPlayer and the other reuses it; frame, error and glasses-model callbacks
  route by vendor.
- VITURE and XREAL plugins now claim the shared runtime when they start and read
  the reported glasses model from it. The per-vendor model check is unchanged.
