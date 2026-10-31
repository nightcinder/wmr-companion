# Build matrix — tracking flavors (v0.3.5)

Companion app Android builds. Source: `apps/wmr_companion_app/tool/build_flavor.sh`,
`apps/wmr_companion_app/tool/install_unity_export.sh`,
`apps/wmr_companion_app/android/app/build.gradle.kts` and
`apps/wmr_companion_app/android/settings.gradle.kts`. No build here has been run on
hardware; these are compile/packaging facts only.

## Current release: v0.3.5 unified APK

| Item | Value |
|---|---|
| Tag / commit | `v0.3.5` (release tag) at `6648ffd` |
| App version | `0.3.5+10` (`versionName 0.3.5`, `versionCode 10`) |
| Artifact | `wmr-companion-0.3.5-unified-arm64-v8a.apk`, 428,243,881 B, SHA-256 `f95078c7a68079eed7d78f0f17f61bc874814d8c5dcd9b2cfea6598c7dd712dc` |
| Flavor | `unified`, linking one shared `unityLibrary` with VITURE 0.9.0 and XREAL 3.1.0; the vendor is selected at runtime |
| Unified or fallback | Truly unified. Per-vendor build flavors were dropped in 0.3.2; `unified` is the only published flavor |
| Signing | Project release key (`CN=WMR Companion`); signed by CI on `v*` tags |
| Hardware | **Not run on a VITURE or XREAL device**; vendor dispatch, tracking rates and permissions are unverified |
| Licence gate | Pinned `unity-export-1.1` (SHA-256 `29a9b9066d1b8dcee7b7acf5dddf7075dbd987c6dcbf29fde9216ed7084d2072`); owner approved SDK redistribution (ONY-354) |

Release notes: [`v0.3.5`](https://github.com/nightcinder/wmr-companion/releases/tag/v0.3.5).
Carrying the VITURE stereo Unity player host (ONY-612), Android XR full permission set (ONY-614), pinned unity-export-1.1 (ONY-617), and the self-hosted Liesa release build (ONY-605).

Host-side pre-flight (no device): `python3 apps/wmr_companion_app/tool/check_unified_apk.py <apk>`
checks the merged permissions, both Unity runtimes and their versions, the vendor
metadata and the tracking/session classes in the dex. It passed on the v0.3.5
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
| `unified` | `WMR_ANDROID_XR_TRACKING=true`, `WMR_VITURE_TRACKING=true`, `WMR_XREAL_TRACKING=true` | `android/unity/unified/unityLibrary` (required for a real unified APK) | one shared Unity UaaL runtime that selects VITURE or XREAL at runtime; with no export, both report typed `unavailable` |

The per-vendor `viture` and `xreal` flavors are retired (ONY-565); only the
unified APK ships and there is no per-vendor flavor to build.

`unified` requires Android 13 (API 33) when the VITURE runtime is linked, because
`VitureUnityXR.aar` in the export declares `minSdk 33`.

## Why there is only one Unity export

- Only one `UnityPlayer` may run in a process (Unity as a Library restriction).
- The Gradle build links at most one `unityLibrary`, and only the `unified`
  flavor depends on it (`settings.gradle.kts` includes the module only when
  `android/unity/unified/unityLibrary` exists).
- A leftover per-vendor export under `android/unity/viture` or
  `android/unity/xreal` fails configuration with "retired per-vendor Unity
  export"; delete it (ONY-565).
- Each vendor SDK contributes its own native libraries, XR loader and manifest
  entries; the supported way to get both vendors into one APK is the unified export.

A missing Unity export is not an error: `unified` still builds and
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
- No per-vendor flavor remains to run on target hardware.
