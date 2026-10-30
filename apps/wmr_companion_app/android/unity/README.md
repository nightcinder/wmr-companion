# Android build flavors (ONY-271, ONY-355)

The WMR Companion app ships four product flavors under the `vendor`
dimension. The Dart vendor flags are compile-time only, so one APK could carry
every adapter; the flavors exist because VITURE and XREAL both need their own
exported `unityLibrary`, and Unity allows one runtime per process.

| Flavor | Unity runtime | Intended target | Dart flags |
| --- | --- | --- | --- |
| `base` | none | Android XR headsets, emulator, BLE/3DoF | all three on in CI |
| `viture` | optional VITURE `unityLibrary` | VITURE Pro Neckband + Luma Ultra | `WMR_VITURE_TRACKING=true` |
| `xreal` | optional XREAL `unityLibrary` | XREAL Air 2 Ultra | `WMR_XREAL_TRACKING=true` |
| `unified` | optional shared `unityLibrary` (VITURE + XREAL) | both vendors from one APK, selected at runtime | all three on |

`unified` requires Android 13 (API 33): VITURE 0.9.0's `VitureUnityXR.aar` in
the export declares `minSdk 33`. The other flavors keep Flutter's default
minimum.

`base` is the default CI artifact. It links no Unity code. With every flag on,
`VitureNeckbandTrackingSource` and `XrealAir2UltraTrackingSource` still build;
asking either to start returns the typed `unavailable` failure instead of a
missing-class crash.

`unified` compiles the same Dart adapters and links one `unityLibrary` exported
from `packages/wmr_tracking_unity`, which selects VITURE or XREAL at runtime.
With no export linked it builds exactly like `base`: both sources exist and
`start()` reports `unavailable`.

## One launcher icon

The Flutter `MainActivity` is the only home-screen entry point. A Unity export
is a library here, started from the app, but the XREAL SDK still marks its
`ai.nreal.activitylife.NRXRActivity` as `MAIN`/`LAUNCHER` (and leanback) for
standalone Unity apps, and Unity can mark `UnityPlayerActivity` the same way.
If those filters survive manifest merging, the APK installs two icons; the
extra one opens the bare Unity scene, which shows the Unity splash and then a
black screen (ONY-561). The `xreal`, `viture` and `unified` flavor manifests in
`android/app/src/` remove those filters with `tools:node="remove"`. Keep them
when adding a flavor or upgrading a vendor SDK, and check the built APK:

```sh
aapt dump badging build/app/outputs/flutter-apk/app-unified-debug.apk |
  grep launchable-activity
# only com.onyxlens.wmr_companion.MainActivity
```

`tool/check_unified_apk.py` enforces this on the release artifact, and
`tool/test_flavor_wiring.sh` builds a stub export whose activities carry
launcher filters for each of the `unified`, `viture` and `xreal` flavors and
asserts every merged APK exposes one icon.

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

Then copy the exported module to the matching gitignored path. Prefer the
installer, which also fixes the Unity-generated Gradle file for this app (see
below):

```sh
cd apps/wmr_companion_app

# From an export zip (e.g. an artefact from another machine)
tool/install_unity_export.sh unified path/to/unityLibrary.zip

# Or from an extracted export directory
tool/install_unity_export.sh viture \
  packages/wmr_tracking_viture/unity/Build/Android/unityLibrary
```

It replaces any previous export for that flavor and prints the module and NDK it
used. The equivalent manual copy is:

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

A manual copy needs the same edits the installer makes to
`unityLibrary/build.gradle`, because Unity generates that file for a module
named `:unityLibrary` on the exporting machine (ONY-388):

- remove `apply from: '../shared/keepUnitySymbols.gradle'` (the zip has no
  sibling `shared/` directory);
- remap `project(':unityLibrary')` and `project(':unityLibrary:xrmanifest.androidlib')`
  to `:unityLibraryViture`, `:unityLibraryXreal` or `:unityLibraryUnified`;
- remove the absolute `ndkPath` and set `ndkVersion` to an NDK installed on
  this machine;
- define `unityStreamingAssets = ""` when the export omits the
  `unityLibrary/gradle.properties` that normally provides it;
- rewrite `implementation(name: 'x', ext: 'aar')` to
  `implementation files('libs/x.aar')`, which AGP 9 still supports;
- give a later AAR with a duplicate manifest package a unique suffix, which
  AGP 9 requires. The installer only does this for native-only AARs (empty
  `classes.jar` and `R.txt`) and refuses otherwise;
- update Unity's `buildIl2Cpp` helper for Gradle 9: `providers.exec` instead of
  `Project.exec`, an explicit `this.BuildIl2CppImpl(...)` call and a qualified
  `project.android.ndkDirectory`.

The installer treats its zip/directory input as immutable and only rewrites the
copy. `tool/test_unity_export_install.sh` checks that normalisation without
Unity, an Android SDK or the real export.

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
