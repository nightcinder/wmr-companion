# Build matrix : tracking flavors (v0.3.19)

Companion app Android builds. Source: `apps/wmr_companion_app/tool/build_flavor.sh`,
`apps/wmr_companion_app/tool/install_unity_export.sh`,
`apps/wmr_companion_app/android/app/build.gradle.kts` and
`apps/wmr_companion_app/android/settings.gradle.kts`. No build here has been run on
hardware; these are compile/packaging facts only.

## Current release: v0.3.19 unified APK

| Item | Value |
|---|---|
| Tag / commit | `v0.3.19` (release tag) at `136be00` |
| App version | `0.3.19+24` (`versionName 0.3.19`, `versionCode 2024` for `arm64-v8a`) |
| Artifact | `wmr-companion-0.3.19-unified-arm64-v8a.apk`, 430,900,214 B, SHA-256 `4e1973aa006bf7e85282d917cdcee7f8c2082723f6b90b10878093ae72478e27` |
| Flavor | `unified`, linking one shared `unityLibrary` with VITURE 0.9.0 and XREAL 3.1.0; the vendor is selected at runtime |
| Unified or fallback | Truly unified. Per-vendor build flavors were dropped in 0.3.2; `unified` is the only published flavor |
| Signing | Project release key (`CN=WMR Companion`); signed by CI on `v*` tags |
| Hardware | **Not run on a VITURE or XREAL device**; vendor dispatch, tracking rates and permissions are unverified. The 0.3.15 and 0.3.16 builds ran on a Google Aura headset for pose-filter captures (`../runs/sheets/pose-filter.md`) |
| Licence gate | Pinned `unity-export-1.4` (SHA-256 `da077615c7925a37fea7c41f8815ff2ff25e760b7c5c4be3c04f84a7467bfae3`); owner approved SDK redistribution  |

Release notes: [`v0.3.19`](https://github.com/nightcinder/wmr-companion/releases/tag/v0.3.19).
This is the signed (project-key) cut at commit `136be00`. It adds pure-Dart LAN discovery in `wmr_ws`, a `CompositeBleTransport` TCP-to-BLE fallback in `wmr_companion`, a native visionOS app scaffold ( and ), and CI scanning with CodeQL, OSV and MobSF ( and ). It removes the GATT latency probe. The 0.3.17 Semgrep, gitleaks and Dependabot scans remain, as do the six-run pose-filter corpus, the 0.3.16 Android XR gate and vendor-player guard, the 0.3.15 six-run pose capture protocol, the 0.3.14 `unity-export-1.4` head-pose path, Bench skeleton and stereo panes ( /  / ).

Host-side pre-flight (no device): `python3 apps/wmr_companion_app/tool/check_unified_apk.py <apk>`
checks the merged permissions, both Unity runtimes and their versions, the vendor
metadata and the tracking/session classes in the dex. The last recorded pass is
on the v0.3.19 artifact. The open gaps are listed in [PREFLIGHT.md](PREFLIGHT.md).

## Release signing

Release APKs use the project-owned RSA-4096 key (`CN=WMR Companion`), not the
Android debug key. Configure `apps/wmr_companion_app/android/key.properties` or
the `WMR_RELEASE_*` environment variables; debug builds keep the debug key. Key
storage, the offline backup procedure, `apksigner` verification and the
versionCode bump are documented in [RELEASE_SIGNING.md](../RELEASE_SIGNING.md).

## Flavors

| Flavor | `--dart-define` | Unity export linked | What it ships |
|---|---|---|---|
| `base` | `WMR_ANDROID_XR_TRACKING=true`, `WMR_VITURE_TRACKING=true`, `WMR_XREAL_TRACKING=true` | none | Android XR, emulator, BLE/3DoF; every Dart adapter exists, but with no Unity runtime linked VITURE reports the 3DoF fallback and XREAL reports typed `unavailable` |
| `unified` | `WMR_ANDROID_XR_TRACKING=true`, `WMR_VITURE_TRACKING=true`, `WMR_XREAL_TRACKING=true` | `android/unity/unified/unityLibrary` (required for a real unified APK) | one shared Unity UaaL runtime that selects VITURE or XREAL at runtime; with no export, VITURE reports the 3DoF fallback and XREAL reports typed `unavailable` |

The per-vendor `viture` and `xreal` flavors are retired ; only the
unified APK ships and there is no per-vendor flavor to build.

`unified` requires Android 13 (API 33) when the VITURE runtime is linked, because
`VitureUnityXR.aar` in the export declares `minSdk 33`.

## Why there is only one Unity export

- Only one `UnityPlayer` can run in a process (Unity as a Library restriction).
- The Gradle build links at most one `unityLibrary`, and only the `unified`
  flavor depends on it (`settings.gradle.kts` includes the module only when
  `android/unity/unified/unityLibrary` exists).
- A leftover per-vendor export under `android/unity/viture` or
  `android/unity/xreal` fails configuration with "retired per-vendor Unity
  export"; delete it.
- Each vendor SDK contributes its own native libraries, XR loader and manifest
  entries; the supported way to get both vendors into one APK is the unified export.

A missing Unity export is not an error: `unified` still builds; VITURE reports
the 3DoF fallback and XREAL reports `unavailable` when asked to start.

## Unified Unity library 

`packages/wmr_tracking_unity` puts one Unity 6000.0 project and one
`WmrTrackingRelay` in front of both vendor bridges. `configure`/`start` carry
`"vendor":"viture"` or `"vendor":"xreal"`; only that vendor's bridge and XR loader are
selected, and the per-vendor relay JSON is unchanged. The 0.2.1 export migrated the
vendors to VITURE 0.9.0 / XREAL 3.1.0.

The `unified` app flavor links that shared export from
`android/unity/unified/unityLibrary` only. To build it:

1. In `packages/wmr_tracking_unity/unity`, with both proprietary SDKs imported, choose
   **WMR > Export unified unityLibrary**. Exporting needs Unity 6000.0.27f1 and the
   vendors' SDK terms; the export is gitignored and is never committed. The
   configuration step pins **Graphics APIs = OpenGLES3 only**: VITURE's display
   provider is EGL/OpenGL ES only, and a Vulkan player null-derefs in
   `VitureDisplayProvider::GfxThread_Stop` when hand tracking starts.
   The unified bridge is embedded in Flutter, so the runtime gate always starts
   VITURE's input and hand subsystems without the display subsystem, because the
   display provider would take over the host activity ; the input
   subsystem is what drives 6DoF head pose. The pinned
   `unity-export-1.4` was built from merge commit `35d8015` (; Unity
   subtree identical to `main` at `94573b2`) and carries both the hand-only gate
   and the input start; `unity-export-1.3` carries the gate but predates the
   input start, so it stays at 0DoF; `unity-export-1.2` and earlier still
   start the display. A non-GLES3
   player also runs hand-only instead of taking the Vulkan stop path.
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

No export is needed for CI: `tool/build_flavor.sh unified` still builds; VITURE
reports the 3DoF fallback and XREAL reports `unavailable`. The 0.2.1 release installed the owner export
(SHA-256 `945bd42…`), which carried both vendor runtimes in one `unityLibrary`.

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
