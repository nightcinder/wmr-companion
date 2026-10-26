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
| `unified` | `WMR_ANDROID_XR_TRACKING=true`, `WMR_VITURE_TRACKING=true`, `WMR_XREAL_TRACKING=true` | `android/unity/unified/unityLibrary` (optional) | one shared Unity UaaL runtime that selects VITURE or XREAL at runtime; with no export, both report typed `unavailable` |

## Why the Unity exports cannot be mixed

- Only one `UnityPlayer` may run in a process (Unity as a Library restriction).
- The Gradle build links at most one `unityLibrary` module per flavor; `settings.gradle.kts`
  throws if both `android/unity/viture/unityLibrary` and `android/unity/xreal/unityLibrary`
  exist at the same time.
- It also throws when `android/unity/unified/unityLibrary` exists alongside either
  per-vendor export ("The unified unityLibrary cannot be combined with per-vendor Unity
  exports"). The unified export carries both SDKs, so a per-vendor export would be a
  second runtime.
- `app/build.gradle.kts` also asserts that multiple modules are never linked together
  (`Cannot link multiple unityLibrary modules into one APK`).
- Each vendor SDK contributes its own native libraries, XR loader and manifest
  entries; coexistence of the two separate exports in one process is unproven (see
  below). The unified export is the supported way to get both vendors into one APK.

A missing Unity export is not an error: the flavor still builds and the Dart source
reports `unavailable` when asked to start.

## Unified Unity library (ONY-273, ONY-355)

`packages/wmr_tracking_unity` is a prototype that puts one Unity 6000.0 project and one
`WmrTrackingRelay` in front of both vendor bridges. `configure`/`start` carry
`"vendor":"viture"` or `"vendor":"xreal"`; only that vendor's bridge and XR loader are
selected, and the per-vendor relay JSON is unchanged. Its README lists the coexistence
unknowns: two XR Management loaders and deferred init, duplicate native `.so`/manifest
entries, SDK redistribution terms, static initialisers from the inactive vendor,
Kotlin-side selection, and the absence of any export or hardware run. The dispatch is
compiled and tested outside Unity; the Unity assembly and export remain an external gate.
If coexistence is ruled out, ONY-271 flavors stay the answer.

The `unified` app flavor (ONY-355) links that shared export from
`android/unity/unified/unityLibrary` only. Export it with **WMR > Export unified
unityLibrary** in `packages/wmr_tracking_unity/unity`, then copy
`unity/Build/Android/unityLibrary` to `apps/wmr_companion_app/android/unity/unified/`.
No export is needed for CI: `tool/build_flavor.sh unified` still builds and the
VITURE/XREAL sources report `unavailable`. See
`apps/wmr_companion_app/android/unity/README.md`.

## Commands

```bash
cd apps/wmr_companion_app
tool/build_flavor.sh base
tool/build_flavor.sh viture
tool/build_flavor.sh xreal
tool/build_flavor.sh unified
```

Extra arguments pass through to `flutter build apk` (e.g. `--release`).

## Unknowns

- No Unity export or APK build with either vendor SDK has happened in this repo.
- Vendor head/hand update rates are unpublished (`maxHeadRateHz: 0`, `maxHandRateHz: 0`).
- Android permissions the VITURE/XREAL Unity runtimes need beyond `android.permission.CAMERA`
  are not documented.
