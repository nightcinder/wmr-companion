# Build matrix — tracking flavors (v0.2)

Companion app Android builds. Source: `apps/wmr_companion_app/tool/build_flavor.sh`,
`apps/wmr_companion_app/android/app/build.gradle.kts` and
`apps/wmr_companion_app/android/settings.gradle.kts`. No build here has been run on
hardware; these are compile/packaging facts only.

## Flavors

| Flavor | `--dart-define` | Unity export linked | What it ships |
|---|---|---|---|
| `base` | `WMR_ANDROID_XR_TRACKING=true`, `WMR_VITURE_TRACKING=true`, `WMR_XREAL_TRACKING=true` | none | Android XR, emulator, BLE/3DoF; every Dart adapter exists, but VITURE/XREAL `start()` reports typed `unavailable` with no Unity runtime linked |
| `viture` | `WMR_ANDROID_XR_TRACKING=false`, `WMR_VITURE_TRACKING=true`, `WMR_XREAL_TRACKING=false` | `android/unity/viture/unityLibrary` (optional) | VITURE Pro Neckband Unity UaaL head + 26-joint hand relay |
| `xreal` | `WMR_ANDROID_XR_TRACKING=false`, `WMR_VITURE_TRACKING=false`, `WMR_XREAL_TRACKING=true` | `android/unity/xreal/unityLibrary` (optional) | XREAL Air 2 Ultra Unity UaaL head + 26-joint hand relay |

## Why VITURE and XREAL cannot share one APK

- Only one `UnityPlayer` may run in a process (Unity as a Library restriction).
- The Gradle build links at most one `unityLibrary` module per flavor; `settings.gradle.kts`
  throws if both `android/unity/viture/unityLibrary` and `android/unity/xreal/unityLibrary`
  exist at the same time.
- `app/build.gradle.kts` also asserts that both modules are never linked together
  (`Cannot link both unityLibrary modules into one APK`).
- Each vendor SDK contributes its own native libraries, XR loader and manifest
  entries; coexistence in one process is unproven (see below).

A missing Unity export is not an error: the flavor still builds and the Dart source
reports `unavailable` when asked to start.

## Unified Unity prototype (ONY-273)

`packages/wmr_tracking_unity` is a prototype that puts one Unity 6000.0 project and one
`WmrTrackingRelay` in front of both vendor bridges. `configure`/`start` carry
`"vendor":"viture"` or `"vendor":"xreal"`; only that vendor's bridge and XR loader are
selected, and the per-vendor relay JSON is unchanged. Its README lists the coexistence
unknowns: two XR Management loaders and deferred init, duplicate native `.so`/manifest
entries, SDK redistribution terms, static initialisers from the inactive vendor,
Kotlin-side selection, and the absence of any export or hardware run. The dispatch is
compiled and tested outside Unity; the Unity assembly and export remain an external gate.
If coexistence is ruled out, ONY-271 flavors stay the answer.

## Commands

```bash
cd apps/wmr_companion_app
tool/build_flavor.sh base
tool/build_flavor.sh viture
tool/build_flavor.sh xreal
```

Extra arguments pass through to `flutter build apk` (e.g. `--release`).

## Unknowns

- No Unity export or APK build with either vendor SDK has happened in this repo.
- Vendor head/hand update rates are unpublished (`maxHeadRateHz: 0`, `maxHandRateHz: 0`).
- Android permissions the VITURE/XREAL Unity runtimes need beyond `android.permission.CAMERA`
  are not documented.
