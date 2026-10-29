# Build matrix — tracking flavors (v0.2.2)

Companion app Android builds. Source: `apps/wmr_companion_app/tool/build_flavor.sh`,
`apps/wmr_companion_app/tool/install_unity_export.sh`,
`apps/wmr_companion_app/android/app/build.gradle.kts` and
`apps/wmr_companion_app/android/settings.gradle.kts`. No build here has been run on
hardware; these are compile/packaging facts only.

## Current release: v0.2.2 unified APK

| Item | Value |
|---|---|
| Tag / commit | `v0.2.2` (release tag) |
| App version | `0.2.2+4` (`versionName 0.2.2`, `versionCode 4`) |
| Artifact | `wmr-companion-0.2.2-unified-debug.apk`, 584,288,364 B, SHA-256 `2507626a981b060566d2e3c7da41a7aa24844435c0db6ea7fbd68d5ca222c755` |
| Flavor | `unified`, linking one shared `unityLibrary` with VITURE 0.9.0 and XREAL 3.1.0; the vendor is selected at runtime |
| Unified or fallback | Truly unified. The approved all-flags `base` fallback was **not** used |
| Signing | Android debug key; not suitable for store distribution |
| Hardware | **Not run on a VITURE or XREAL device**; vendor dispatch, tracking rates and permissions are unverified |
| Licence gate | The owner approved bundling both proprietary SDKs and exported the shared `unityLibrary` (ONY-354; export SHA-256 `945bd4254310766313fac81d0daa472408223c82cbee55186bcbcf3d144333b5`) |

Release notes: [`v0.2.2`](https://github.com/nightcinder/wmr-companion/releases/tag/v0.2.2).
The APK was built from the ONY-481 release branch with the owner export, and the
GATT probe asset is `wmr-gatt-probe-0.2.2-debug.apk`. The only app change from
v0.2.1 is the FF16 firmware string and FF11–FF16 feature bits on the Debug screen.

Host-side pre-flight (no device): `python3 apps/wmr_companion_app/tool/check_unified_apk.py <apk>`
checks the merged permissions, both Unity runtimes and their versions, the vendor
metadata and the tracking/session classes in the dex. It passed on the v0.2.2
artifact; the open gaps are listed in [PREFLIGHT.md](PREFLIGHT.md).

## Release signing

Release APKs use the project-owned RSA-4096 key (`CN=WMR Companion`), not the
Android debug key. Configure `apps/wmr_companion_app/android/key.properties` or
the `WMR_RELEASE_*` environment variables; debug builds keep the debug key. Key
storage, the offline backup procedure, `apksigner` verification and the
versionCode bump are documented in [RELEASE_SIGNING.md](../RELEASE_SIGNING.md).

## Flavors

| Flavor | `--dart-define` | Unity export linked | What it ships |
|---|---|---|---|
| `base` | `WMR_ANDROID_XR_TRACKING=true`, `WMR_VITURE_TRACKING=true`, `WMR_XREAL_TRACKING=true` | none | Android XR, emulator, BLE/3DoF; every Dart adapter exists, but VITURE/XREAL `start()` reports typed `unavailable` with no Unity runtime linked |
| `viture` | `WMR_ANDROID_XR_TRACKING=false`, `WMR_VITURE_TRACKING=true`, `WMR_XREAL_TRACKING=false` | `android/unity/viture/unityLibrary` (optional) | VITURE Pro Neckband Unity UaaL head + 26-joint hand relay |
| `xreal` | `WMR_ANDROID_XR_TRACKING=false`, `WMR_VITURE_TRACKING=false`, `WMR_XREAL_TRACKING=true` | `android/unity/xreal/unityLibrary` (optional) | XREAL Air 2 Ultra Unity UaaL head + 26-joint hand relay |
| `unified` | `WMR_ANDROID_XR_TRACKING=true`, `WMR_VITURE_TRACKING=true`, `WMR_XREAL_TRACKING=true` | `android/unity/unified/unityLibrary` (required for a real unified APK) | one shared Unity UaaL runtime that selects VITURE or XREAL at runtime; with no export, both report typed `unavailable` |

`unified` requires Android 13 (API 33) when the VITURE runtime is linked, because
`VitureUnityXR.aar` in the export declares `minSdk 33`.

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
  entries; the supported way to get both vendors into one APK is the unified export.

A missing Unity export is not an error: `viture`, `xreal` and `unified` still build and
the Dart sources report `unavailable` when asked to start.

## Unified Unity library (ONY-273, ONY-355, ONY-388)

`packages/wmr_tracking_unity` puts one Unity 6000.0 project and one
`WmrTrackingRelay` in front of both vendor bridges. `configure`/`start` carry
`"vendor":"viture"` or `"vendor":"xreal"`; only that vendor's bridge and XR loader are
selected, and the per-vendor relay JSON is unchanged. The 0.2.1 export migrated the
vendors to VITURE 0.9.0 / XREAL 3.1.0 (ONY-378).

The `unified` app flavor links that shared export from
`android/unity/unified/unityLibrary` only. To build it:

1. In `packages/wmr_tracking_unity/unity`, with both proprietary SDKs imported, choose
   **WMR > Export unified unityLibrary**. Exporting needs Unity 6000.0.27f1 and the
   vendors' SDK terms; the export is gitignored and is never committed.
2. Install and normalise the export from `apps/wmr_companion_app`:

   ```sh
   tool/install_unity_export.sh unified path/to/unityLibrary.zip
   ```

   The installer treats the input as immutable and rewrites only its copy: it removes
   the missing `../shared/keepUnitySymbols.gradle` include, remaps `:unityLibrary` and
   `:unityLibrary:xrmanifest.androidlib` to `:unityLibraryUnified`, replaces the
   absolute `ndkPath`, fixes `unityStreamingAssets`, rewrites AAR dependencies for AGP 9
   and patches Unity's `buildIl2Cpp` helper for Gradle 9. See
   `apps/wmr_companion_app/android/unity/README.md` for the full list and the manual
   copy steps. `tool/test_unity_export_install.sh` tests this without Unity.
3. Build:

   ```sh
   tool/build_flavor.sh unified --debug
   ```

No export is needed for CI: `tool/build_flavor.sh unified` still builds and the
VITURE/XREAL sources report `unavailable`. The 0.2.1 release installed the owner export
(SHA-256 `945bd42…`, ONY-354), which carried both vendor runtimes in one `unityLibrary`.

## Commands

```bash
cd apps/wmr_companion_app
tool/install_unity_export.sh unified path/to/unityLibrary.zip
tool/build_flavor.sh base
tool/build_flavor.sh viture
tool/build_flavor.sh xreal
tool/build_flavor.sh unified
```

Extra arguments pass through to `flutter build apk` (e.g. `--release`). APKs land in
`apps/wmr_companion_app/build/app/outputs/flutter-apk/`.

## Unknowns

- The 0.2.1 unified APK has **not** run on a VITURE or XREAL device. Runtime vendor
  selection, permissions and the two SDKs coexisting in one process are unverified.
- Vendor head/hand update rates are unpublished (`maxHeadRateHz: 0`, `maxHandRateHz: 0`).
- Android permissions the VITURE/XREAL Unity runtimes need beyond `android.permission.CAMERA`
  are not documented.
- No per-vendor flavor has been run on its target hardware either.
