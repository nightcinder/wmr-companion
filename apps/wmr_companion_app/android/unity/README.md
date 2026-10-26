# Android build flavors (ONY-271, ONY-355)

The WMR Companion app ships three product flavors under the `vendor`
dimension. The Dart vendor flags are compile-time only, so one APK could carry
every adapter; the flavors exist because VITURE and XREAL both need their own
exported `unityLibrary`, and Unity allows one runtime per process.

| Flavor | Unity runtime | Intended target | Dart flags |
| --- | --- | --- | --- |
| `base` | none | Android XR headsets, emulator, BLE/3DoF | all three on in CI |
| `viture` | optional VITURE `unityLibrary` | VITURE Pro Neckband + Luma Ultra | `WMR_VITURE_TRACKING=true` |
| `xreal` | optional XREAL `unityLibrary` | XREAL Air 2 Ultra | `WMR_XREAL_TRACKING=true` |
| `unified` | optional shared `unityLibrary` (VITURE + XREAL) | both vendors from one APK, selected at runtime | all three on |

`base` is the default CI artifact. It links no Unity code. With every flag on,
`VitureNeckbandTrackingSource` and `XrealAir2UltraTrackingSource` still build;
asking either to start returns the typed `unavailable` failure instead of a
missing-class crash.

`unified` compiles the same Dart adapters and links one `unityLibrary` exported
from `packages/wmr_tracking_unity`, which selects VITURE or XREAL at runtime.
With no export linked it builds exactly like `base`: both sources exist and
`start()` reports `unavailable`.

## Build

From the repository root:

```sh
cd apps/wmr_companion_app
tool/build_flavor.sh base
tool/build_flavor.sh viture
tool/build_flavor.sh xreal
tool/build_flavor.sh unified
```

The script passes the flavor's `--dart-define` flags and defaults to
`--debug`; add `--release` (or `--profile`) for another mode. The plain Flutter
commands are equivalent:

```sh
flutter build apk --debug --flavor base \
  --dart-define=WMR_ANDROID_XR_TRACKING=true \
  --dart-define=WMR_VITURE_TRACKING=true \
  --dart-define=WMR_XREAL_TRACKING=true

flutter build apk --debug --flavor viture \
  --dart-define=WMR_VITURE_TRACKING=true
```

APKs land in `apps/wmr_companion_app/build/app/outputs/flutter-apk/` as
`app-<flavor>-debug.apk`.

## Opting into Unity

The Unity exports are not committed: they contain vendor SDK code that is not
redistributable. Export one with the package's Unity project:

- VITURE: `packages/wmr_tracking_viture/unity`, menu **WMR > Export VITURE
  unityLibrary** (see that project's README).
- XREAL: `packages/wmr_tracking_xreal/unity`, menu **WMR > Export XREAL
  unityLibrary**.
- Unified: `packages/wmr_tracking_unity/unity` with both proprietary SDKs
  imported, menu **WMR > Export unified unityLibrary** (see that project's
  README).

Then copy the exported module to the matching gitignored path:

```sh
# VITURE
mkdir -p apps/wmr_companion_app/android/unity/viture
cp -R packages/wmr_tracking_viture/unity/Build/Android/unityLibrary \
  apps/wmr_companion_app/android/unity/viture/

# XREAL
mkdir -p apps/wmr_companion_app/android/unity/xreal
cp -R packages/wmr_tracking_xreal/unity/Build/Android/unityLibrary \
  apps/wmr_companion_app/android/unity/xreal/

# Unified
mkdir -p apps/wmr_companion_app/android/unity/unified
cp -R packages/wmr_tracking_unity/unity/Build/Android/unityLibrary \
  apps/wmr_companion_app/android/unity/unified/
```

Only the matching flavor depends on its module: `vitureImplementation` for
`:unityLibraryViture`, `xrealImplementation` for `:unityLibraryXreal`, and
`unifiedImplementation` for `:unityLibraryUnified`. `base` never links one.
Unity allows one runtime per process, so the build accepts at most one export.
If both per-vendor directories exist, Gradle fails during configuration with
"Cannot link both Unity libraries into one APK". If `unified` exists alongside
`viture` or `xreal`, it fails with "The unified unityLibrary cannot be combined
with per-vendor Unity exports". Remove the other exports and rebuild.

Without an export, `viture`, `xreal` and `unified` still build and the
Unity-backed sources report `unavailable`. That is the supported fallback for CI
and for developers who do not have the proprietary SDKs.

`tool/test_flavor_wiring.sh` exercises this path without Unity: it writes
throwaway `unityLibrary` stubs into the gitignored locations, checks that
`base` ignores them, that `viture` links the VITURE stub (by finding its
manifest permission in the APK), that `unified` links only its own stub, that
mixing exports fails with the messages above, and that `unified` still builds
with no export at all.
