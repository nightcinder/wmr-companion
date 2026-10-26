# Unified VITURE + XREAL Unity project

One Unity 6000.0 project, one `WmrTrackingRelay` object and one dispatching
bridge for both vendors. This is the ONY-273 prototype for shipping both SDKs
in a **single** `unityLibrary`. The per-vendor projects in
`packages/wmr_tracking_viture/unity` and `packages/wmr_tracking_xreal/unity`
stay in place and remain the source of truth for their scripts; their Runtime
folders are copied into this project and kept byte-identical by a sync check.
ONY-271 flavors remain the fallback until a real export and device run happen.

No proprietary SDK, no Unity install and no hardware are used by this
repository. Neither vendor's native code is vendored. Nothing here is a
hardware result.

## Layout

```
packages/wmr_tracking_unity/
  unity/                                  Unity 6000.0 project
    Assets/WmrTrackingUnity/Runtime/
      Dispatch/VendorRelayDispatch.cs     Unity-independent routing + tests target
      WmrTrackingUnifiedBridge.cs         WmrTrackingRelay / OnCommand dispatcher
      VendorLoaderGate.cs                 XR Plug-in Management loader selection
      WmrTrackingUnifiedSmokeHarness.cs   editor-only smoke logging
    Assets/WmrTrackingUnity/Editor/
      WmrTrackingUnityExport.cs           one-unityLibrary export + checks
    Assets/WmrTrackingViture/Runtime/     copy of the VITURE relay scripts + asmdef
    Assets/WmrTrackingXreal/Runtime/      copy of the XREAL relay scripts + asmdef
    Assets/Scenes/WmrTrackingUnifiedSmoke.unity
  tests/WmrTrackingUnity.Dispatch.Tests/  .NET console tests for the dispatch
  tests/WmrTrackingUnity.LoaderGate.Tests/ switch-after-start loader gate checks
  tool/sync_vendor_unity_runtime.sh       copy + --check for the vendor Runtime folders
  tool/test_dispatch.sh                   compile + test gate
```

## Vendor sources in this project

Unity does not reference the sibling per-vendor Unity projects, so the unified
project carries their Runtime folders: the bridge scripts, their asmdefs and
their `.meta` files.

- `Assets/WmrTrackingViture/Runtime/` → assembly `WmrTrackingViture.Runtime`
- `Assets/WmrTrackingXreal/Runtime/` → assembly `WmrTrackingXreal.Runtime`

The copies keep the original `.meta` GUIDs, which is what the smoke scene's
`VitureBackend` and `XrealBackend` components reference. Do not edit the
copies: the per-vendor projects remain the source of truth. After changing a
vendor bridge, re-run the sync and the check:

```sh
packages/wmr_tracking_unity/tool/sync_vendor_unity_runtime.sh
packages/wmr_tracking_unity/tool/sync_vendor_unity_runtime.sh --check
```

`tool/test_dispatch.sh` (and CI) runs `--check` before compiling. The export
script also fails before building when either bridge asset is missing, when
the scene no longer references its GUID, or when the assembly did not compile.
The copied bridges compile as part of the C# gate, so the unified namespace
imports and `OnCommand` call sites are checked against the real scripts rather
than stubs.

While importing the bridges, their `using System.Diagnostics;` was narrowed to
a `Stopwatch` alias because it made `Debug` ambiguous with `UnityEngine.Debug`
under Unity's compiler. That fix is in the per-vendor sources and the copies.

## Relay contract (unchanged)

Kotlin still calls:

```
UnityPlayer.UnitySendMessage("WmrTrackingRelay", "OnCommand", json)
```

Envelopes keep `{"v":1,"cmd":...}` and the existing `options`. The only new
input is the existing `vendor` field now being authoritative:

| Command | Behaviour |
| --- | --- |
| `configure` + `"vendor":"viture"\|"xreal"` | Selects and enables that backend. Does not start tracking and does not initialise an XR loader. VITURE receives the `configure` relay command and applies `options`; XREAL has no `configure` command, so the unified bridge only enables its backend and does not forward it (no spurious `protocol` error). |
| `start` + `"vendor":"viture"\|"xreal"` | Selects the vendor (overriding an idle `configure`), enables its bridge, initialises only its XR loader, then forwards `start`. |
| `start` without `vendor` | Reuses the vendor from the last successful `configure`, or the running vendor. Rejected with `protocol` when neither is known. |
| `stop` | Forwards to the running vendor. Keeps the selection so a later `start` can omit `vendor`. |
| `recenter` | Forwards to the running vendor. Rejected with `unavailable` when stopped. XREAL's existing bridge reports `protocol` for `recenter`; that behaviour is unchanged. |
| `dispose` | Forwards, deinitialises the selected XR loader, and clears the selection. |

Frames, glasses-model callbacks and vendor failures still come from the vendor
bridge, through the existing Kotlin entry points:

- VITURE: `com.onyxlens.wmr_tracking_viture.WmrTrackingViturePlugin.onUnityFrame`,
  `onUnityError`, `onUnityGlassesModel`.
- XREAL: `com.onyxlens.wmr_tracking_xreal.WmrTrackingXrealPlugin.onUnityFrame`,
  `onUnityError`, `onUnityGlassesModel`.

Relay-level failures (unknown command, unknown/absent vendor, busy switch,
missing loader) are raised on `WmrTrackingUnifiedBridge.ErrorReported` and sent
to `onUnityError` of the selected vendor plugin. A failure before any vendor is
selected is log-only because no vendor plugin owns it yet. The JSON frame and
command shapes are not modified.

Switching vendor requires `stop` (or `dispose`) first while running. The
dispatcher returns `busy` rather than silently restarting.

## Scene

`WmrTrackingUnifiedSmoke.unity` contains one `WmrTrackingRelay` object with the
unified bridge and smoke harness. Its two children, `VitureBackend` and
`XrealBackend`, are initially inactive and carry the reusable vendor bridges.
Keeping them inactive prevents either vendor's `Awake` from running before the
host selects it. A host that puts a vendor bridge on the relay object itself
loses that guarantee.

The scene never starts tracking in a player build: `autoStart` is editor-only,
matching the per-vendor harnesses. The Android host owns `start`/`stop`, so the
vendor CAMERA-permission and default-off flow stays in the plugin.

## Export one `unityLibrary`

Import both proprietary SDKs into the same project first:

1. Open `packages/wmr_tracking_unity/unity` with Unity 6000.0.x.
2. Add `com.viture.xr` v0.7.0 and `com.xreal.xr` 3.x from their vendor packages.
   Do not commit either SDK.
3. Confirm the runtime assembly sees `WMR_VITURE_XR_SDK`, `WMR_XREAL_XR_SDK`
   and `WMR_UNITY_XR_HANDS`.
4. XR Plug-in Management > Android: assign **both** vendor loaders. Disable
   **Initialize XR on Startup** so the unified bridge can choose; the gate also
   turns off `automaticLoading`/`automaticRunning` before it initialises manually.
5. Player > Android: minimum API 24, ARM64, IL2CPP, script backends per each
   SDK's requirements (the export script sets the first three).

Then use **WMR > Export unified unityLibrary** or:

```sh
Unity -batchmode -quit \
  -projectPath packages/wmr_tracking_unity/unity \
  -buildTarget Android \
  -executeMethod OnyxLens.WmrTrackingUnity.Editor.WmrTrackingUnityExport.Export \
  -logFile -
```

The script writes `unity/Build/Android/` and fails unless:

- both vendor bridge assets are present and referenced by the scene, and their
  assemblies compiled;
- both SDKs and XR Hands are installed;
- exactly one directory named `unityLibrary` exists, at
  `Build/Android/unityLibrary`;
- no two `.so` files share the same ABI directory and file name (the overwrite
  case).

It writes `Build/Android/unityLibrary-native-libs.txt` listing every exported
`.so`, and warns when no exported library name contains `viture` or
`xreal`/`nrsdk` so the reviewer can inspect the report. `Build/` stays ignored.

## C# gate

`VendorRelayDispatch.cs` is plain C# with no UnityEngine dependency. The gate
also compiles `VendorLoaderGate.cs` and the real vendor bridges against
minimal Unity/XR Management stubs:

```sh
packages/wmr_tracking_unity/tool/test_dispatch.sh
```

Requires the .NET 8 SDK. It:

- runs `tool/sync_vendor_unity_runtime.sh --check`;
- compiles the unified bridge plus both copied vendor bridges in the Android
  player and Editor configurations;
- runs 59 dispatch assertions covering vendor parsing,
  configure/start/stop/dispose, idempotent start, busy vendor switches,
  recenter-before-start and start-failure retry;
- runs 14 loader-gate assertions covering start, stop, switch to the other
  vendor, switch back, already-active, missing loader and unavailable settings.

CI runs it from `.github/workflows/unity-dispatch.yml`.

The scene and export script compile only inside Unity with both proprietary
SDKs; that external compile/export gate is documented, not faked. The existing
per-vendor relay contract tests (Kotlin) are unchanged.

## Coexistence unknowns

Everything below is **unproven**. Do not read this project as evidence that
both SDKs coexist in one build.

1. **Two XR Management loaders.** Unity's `XRManagerSettings` has one
   `activeLoader`; `InitializeLoaderSync()` initialises the first assigned
   loader that succeeds. The gate caches the full assigned list, reorders the
   selected vendor first and keeps the other assigned, but whether both vendor
   loaders may be assigned together, whether their loader type names are
   recognisable by `viture`/`xreal`, and whether XREAL tolerates
   deinitialise-then-reinitialise are untested.
2. **Deferred loader init.** The design requires **Initialize XR on Startup**
   off and calls `InitializeLoaderSync()` when `start` arrives. Whether VITURE
   or XREAL can initialise that late (camera/JNI/session assumptions, Android
   lifecycle timing) is unknown and needs a device. If one SDK must own startup,
   the unified project is not viable as designed.
3. **Duplicate native libraries.** Both SDKs may ship same-named `.so` files
   (for example an ONNX/OpenXR helper). Unity flattens native plugins by ABI,
   so the same basename in the same ABI directory would overwrite. The export
   script detects that case and fails, but the check cannot run until both
   SDKs are present.
4. **Duplicate manifest entries.** Both SDKs may contribute permissions,
   `<uses-feature>`, providers, activities, queries, Gradle dependencies,
   ProGuard rules or `res` assets. The Android manifest merger usually
   deduplicates identical entries but not conflicting provider authorities,
   feature versions or package names. None of this is inspected by the export
   script.
5. **SDK licence terms.** Redistributing both proprietary SDKs inside one
   `unityLibrary`/APK may be restricted by each vendor's terms. This repository
   only points at the vendor packages; it does not grant redistribution
   rights. Legal review is required before shipping the combined build.
6. **Both vendors' static initialisers.** Even if only one XR loader is
   active, content providers, `JNI_OnLoad` hooks and static initialisers from
   the other SDK may still run when its Kotlin classes or native libraries are
   packaged. Whether that is harmless is unknown.
7. **Kotlin dispatch.** This project only dispatches inside Unity. The host
   still needs both vendor Flutter plugin Kotlin classes in one app and an
   app-level selection path; that is out of scope here (a separate issue) and
   depends on ONY-271.
8. **Glasses detection.** Unity does not auto-detect the vendor. The Kotlin
   host must detect the glasses and send the correct `vendor`; `auto` is
   intentionally rejected.
9. **Per-vendor `recenter`.** Only the VITURE bridge implements recenter today.
   The unified bridge preserves XREAL's existing `protocol` rejection rather
   than inventing an API.
10. **No run.** No Unity import, no export, no `unityLibrary`, no APK, no
    Neckband, no Air 2 Ultra, no measured frames. The C# assertions and static
    docs are the entire evidence base.

If any of items 1–5 is shown impossible on paper or by a real export, record it
here and stop: ONY-271 flavors remain the supported answer.
