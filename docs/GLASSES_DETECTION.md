# Native glasses detection and vendor dispatch

Status: desk research plus host-tested Kotlin/Dart. **Nothing here was run on a
Neckband, Beam Pro, phone, glasses or Android XR headset.**

## Why detection runs before Unity

The VITURE (ONY-213) and XREAL (ONY-214) relays learn the glasses model by
asking Unity (`queryGlassesModel`). That cannot choose which vendor SDK Unity
starts: Unity has to be told the vendor first. The native detector therefore
runs before any `start` command and returns a typed `GlassesDetection`:
`viture`, `xreal`, `androidXr` or `none`.

The per-vendor glasses-model check stays as a **second confirmation** inside
`WmrTrackingViturePlugin.startUnityRelay` and
`WmrTrackingXrealPlugin.startUnityRelay`. Detection chooses the vendor; the
model check then rejects an unsupported model (for example XREAL One with no
hand tracking) with `unsupported`. Detection never overrides the model check.

## Detection order

`packages/wmr_tracking_dispatch` runs this order, highest priority first:

1. **Host marker.** `Build.MANUFACTURER`/`MODEL` contains a configured marker:
   VITURE -> `neckband` host and `viture`; XREAL/Nreal -> `beamPro` host and
   `xreal`. The host is the vendor compute unit, so its glasses are known even
   when USB access is denied.
2. **USB IDs.** Exactly one configured vendor/product match -> that vendor.
   Both VITURE and XREAL -> `none` with `usbAmbiguous`: refuse to guess.
3. **Android XR host.** `android.software.xr.api.openxr` or
   `android.software.xr.api.spatial` -> `androidXr`.
4. **Nothing.** `none` with `noMatch`, or `usbPermissionDenied` when USB access
   was denied on a host with no vendor marker.

The detector does not run on plugin attach. `TrackingSourceSelector` calls it
only when at least one vendor flag is enabled, so BLE, controller and 3DoF
flag-off paths touch no channel.

## USB and host IDs

| Item | Value | Source / status |
| --- | --- | --- |
| VITURE USB vendor ID | `0x35CA` | Public; recorded in [TRACKING.md](TRACKING.md). |
| VITURE USB product IDs | unknown | Not published in this repository; default matches any product. Configurable. |
| XREAL USB vendor ID | unknown | Not published in this repository; default is empty (no USB match). Configurable. |
| XREAL USB product IDs | unknown | Not published in this repository; configurable, but only with a vendor ID. |
| VITURE host markers | `viture` | Product-name heuristic, case-insensitive on manufacturer/model. Configurable in `GlassesUsbConfig`. |
| XREAL host markers | `xreal`, `nreal` | Product-name heuristic. Configurable in `GlassesUsbConfig`. |
| Android XR features | `android.software.xr.api.openxr`, `android.software.xr.api.spatial` | Android XR platform feature strings. |

No product ID is guessed. Until a vendor publishes them, supply known-good IDs
at runtime:

```dart
await const PlatformGlassesDetector().configureIds(
  vitureProductIds: [0x1011], // only IDs confirmed from vendor docs/hardware
  xrealVendorIds: [0x3318],
  xrealProductIds: [0x0424],
);
```

Empty product-ID sets match any product from that vendor ID. An empty vendor-ID
set never matches, which is how XREAL stays fail-closed by default.

## Permission denied

`UsbManager.hasPermission` is checked for every attached device. On a host with
no vendor marker, any denied device makes the result `none /
usbPermissionDenied`; nothing is started. On a Neckband or Beam Pro the host
already identifies the vendor, so detection still returns it and reports
`usbPermissionGranted: false` for diagnostics.

Detection reads IDs only. Opening a `UsbDeviceConnection` (for example for the
VITURE C SDK) still needs the platform USB permission flow, which is outside
this issue.

## One UnityPlayer per process

`SharedUnityRuntime` is process-wide:

- The first VITURE or XREAL plugin to start claims the runtime and becomes the
  owner; `createPlayer` is called once.
- The other vendor reuses the same runtime (`UnityClaimState.REUSED`) and never
  creates a second player.
- Frame, error and glasses-model callbacks are addressed by vendor and go to
  that plugin's registered handler; the owner is the fallback for untagged
  callbacks. An unregistered vendor's callbacks are dropped rather than sent to
  the wrong plugin.
- The glasses model is stored per vendor, so each plugin's `queryGlassesModel`
  reads only its own report.
- Releasing ownership does not tear down the linked runtime; the next claimant
  reuses it.

The Kotlin unit tests use fake runtimes and handlers to prove the creator is
called once across both vendors and that callbacks route by vendor. No Unity
runtime or vendor SDK is required.

## Verification

- `packages/wmr_tracking_dispatch/android/src/test` - detector and shared-runtime
  JVM tests (VITURE, XREAL, both, neither, permission denied, host markers,
  single creation, reuse, routing).
- `packages/wmr_tracking_dispatch/test` - Dart detection parsing, selector
  outcomes (`attached`, `unsupported`, `unavailable`, `permissionDenied`,
  `none`), and a flag-off test asserting zero channel calls.
- `flutter analyze` and `flutter test` in the workspace.
- Existing VITURE/XREAL Dart and Kotlin suites remain green; no BLE/3DoF code was
  touched.

## Open questions

- XREAL USB IDs and both vendors' product IDs are unknown in public docs and
  are configurable rather than guessed.
- Host markers are product-name heuristics; a firmware string change falls back
  to USB detection.
- Whether Android reports the glasses as USB devices on every host/firmware is
  unverified. The host-marker path covers the Neckband and Beam Pro.
- No hardware claim: detection, ownership and routing are host-tested only.
