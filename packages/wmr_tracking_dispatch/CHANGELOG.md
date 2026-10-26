# Changelog

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
