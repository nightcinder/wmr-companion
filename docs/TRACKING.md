# Headset hand and head tracking for controller 6DoF

Research date: 2026-10-25. Desk research plus an in-repo framework. **Nothing here was tested on a headset, glasses or phone.** Vendor SDK details come from the public docs linked in [RESEARCH.md](tracking/RESEARCH.md#sources); where a page did not state something, it is marked unknown rather than guessed.

Companion research: [CAMERAS.md](CAMERAS.md) covers raw camera access.

## Status

- `packages/wmr_tracking`: pure-Dart seam, `TrackingFrame`, capability profiles, `SourceClockAligner`, `SixDofFuser`, One Euro filter, Unity relay contract. Unit-tested, no hardware.
- `packages/wmr_tracking_android_xr`: default-off Kotlin Android XR source . Compiles and host-tested; no device run.
- `packages/wmr_tracking_viture`: default-off VITURE Pro Neckband Unity UaaL relay . Host/JVM-tested; Unity 6000.0.27f1 / VITURE XR SDK v0.9.0 (`Viture.XR.VitureXR`) external gate.
- `packages/wmr_tracking_xreal`: default-off XREAL Air 2 Ultra Unity UaaL relay . Host/JVM-tested; Unity/XREAL SDK external gate.
- `packages/wmr_tracking_dispatch`: native glasses detection and one shared `SharedUnityRuntime` for VITURE/XREAL .
- Unified Unity prototype: `packages/wmr_tracking_unity` ; coexistence unproven.
- Android build flavors `base`/`unified` (; per-vendor flavors retired); see [BUILDS.md](tracking/BUILDS.md).

## Native visionOS companion app (`apps/wmr_visionos_app`)

`apps/wmr_visionos_app` is a native Swift target. It is not a Unity app. It links `packages/WMRCompanionKit` and runs on visionOS 1, iOS 18, and macOS 14. See [IOS.md](IOS.md) for the full setup.

Architecture:

- `ARKitVisionOSTrackingProvider` wraps `ARKitSession` with `WorldTrackingProvider` and `HandTrackingProvider`.
- `VisionOSControllerPoseComposer` fuses the tracked wrist position with the bridge's 3DoF orientation into a 6DoF controller pose.
- `VisionOSCompanionViewModel` joins BLE controller state with wrist poses and publishes per-hand poses.

ARKit plus BLE 6DoF fusion:

The bridge sends 3DoF orientation over BLE. ARKit sends wrist position. The app composes one 6DoF pose per hand. The wrist supplies translation. The bridge supplies orientation.

Permissions:

The app declares four privacy keys in `apps/wmr_visionos_app/Sources/WMRVisionOSApp/Resources/Info.plist`: `NSBluetoothAlwaysUsageDescription`, `NSBluetoothPeripheralUsageDescription`, `NSHandsTrackingUsageDescription`, and `NSWorldSensingUsageDescription`.

Simulator limits:

- The package builds and tests on macOS.
- ARKit hand tracking does not run in the visionOS Simulator. Hardware is required for 6DoF composition.
- BLE needs a physical WMR Bridge.

No-Unity boundary:

The visionOS target does not link Unity. It has no `base` or `unified` flavor and no `--dart-define` flags. Android keeps its own Unity gates.

Signing:

Use Xcode signing. Open the package, add a visionOS app target, set a bundle ID and team, turn on automatic signing, copy the privacy keys into Info.plist, and build on an Apple Vision Pro. Distribution needs an Apple Developer Program account, a distribution certificate, and a provisioning profile. See [IOS.md](IOS.md) for the full steps.

Status note: no hardware run has validated 6DoF on Apple Vision Pro. The package tests cover the simulated seam only.

## Index

- [RESEARCH.md](tracking/RESEARCH.md): vendor research and sources.
- [FRAMEWORK.md](tracking/FRAMEWORK.md): seam, filter, vectors, adapter recipes, vertical slices.
- [BUILDS.md](tracking/BUILDS.md): build matrix, flavors, `--dart-define`, Unity exports.
- [GATES.md](tracking/GATES.md): hardware gates and open questions.
- [PREFLIGHT.md](tracking/PREFLIGHT.md): named 1.0 path (XREAL), current unified APK, and the desk-only export/permission check.
- Run sheets: [Android XR](runs/sheets/pose-androidxr.md), [VITURE](runs/sheets/pose-viture.md), [XREAL](runs/sheets/pose-xreal.md).
- Filter tuning: [pose-filter.md](runs/sheets/pose-filter.md) (; synthetic first pass, hardware replay still open).

No 6DoF claim: no vendor adapter has run on hardware.
