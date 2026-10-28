# Headset hand and head tracking for controller 6DoF

Research date: 2026-10-25. Desk research plus an in-repo framework. **Nothing here was tested on a headset, glasses or phone.** Vendor SDK details come from the public docs linked in [RESEARCH.md](tracking/RESEARCH.md#sources); where a page did not state something, it is marked unknown rather than guessed.

Companion research: [CAMERAS.md](CAMERAS.md) covers raw camera access.

## Status

- `packages/wmr_tracking`: pure-Dart seam, `TrackingFrame`, capability profiles, `SourceClockAligner`, `SixDofFuser`, One Euro filter, Unity relay contract. Unit-tested, no hardware.
- `packages/wmr_tracking_android_xr`: default-off Kotlin Android XR source (ONY-212). Compiles and host-tested; no device run.
- `packages/wmr_tracking_viture`: default-off VITURE Pro Neckband Unity UaaL relay (ONY-213). Host/JVM-tested; Unity 6000.0.27f1 / VITURE XR SDK v0.9.0 (`Viture.XR.VitureXR`) external gate.
- `packages/wmr_tracking_xreal`: default-off XREAL Air 2 Ultra Unity UaaL relay (ONY-214). Host/JVM-tested; Unity/XREAL SDK external gate.
- `packages/wmr_tracking_dispatch`: native glasses detection and one shared `SharedUnityRuntime` for VITURE/XREAL (ONY-274).
- Unified Unity prototype: `packages/wmr_tracking_unity` (ONY-273); coexistence unproven.
- Android build flavors `base`/`viture`/`xreal` (ONY-271); see [BUILDS.md](tracking/BUILDS.md).

## Index

- [RESEARCH.md](tracking/RESEARCH.md) — vendor research and sources.
- [FRAMEWORK.md](tracking/FRAMEWORK.md) — seam, filter, vectors, adapter recipes, vertical slices.
- [BUILDS.md](tracking/BUILDS.md) — build matrix, flavors, `--dart-define`, Unity exports.
- [GATES.md](tracking/GATES.md) — hardware gates and open questions.
- [PREFLIGHT.md](tracking/PREFLIGHT.md) — named 1.0 path (XREAL), current unified APK, and the desk-only export/permission check.
- Run sheets: [Android XR](runs/sheets/pose-androidxr.md), [VITURE](runs/sheets/pose-viture.md), [XREAL](runs/sheets/pose-xreal.md).

No 6DoF claim: no vendor adapter has run on hardware.
