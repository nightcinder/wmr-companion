# 6DoF pre-flight: named path, current build, desk evidence

Status: **desk work only, 2026-10-28.** No glasses, phone or Unity runtime was
started. The artifact checks below are real host-side results; every tracking
figure and permission prompt remains a hardware gate.

This is the ONY-440 pre-flight companion to [GATES.md](GATES.md),
[TRACKING.md](../TRACKING.md) and the hardware sheet
[`docs/runs/sheets/pose-xreal.md`](../runs/sheets/pose-xreal.md).

## 1. Named 1.0 path: XREAL Air 2 Ultra

**Decision: XREAL Air 2 Ultra + an existing Beam Pro / Samsung S24-or-later
phone is the 6DoF path for 1.0. VITURE is a fallback, not a second primary.**

| Criterion | XREAL Air 2 Ultra | VITURE Luma Ultra + Pro Neckband |
|---|---|---|
| Hardware to buy | Glasses only; host phone is already owned | Glasses **and** Neckband |
| Where the app runs | The phone, unchanged | The Neckband; the phone-only path has no hands |
| Hand tracking | 26 XR Hands joints (Air 2 Ultra only) | 26 XR Hands joints (Luma Ultra + Neckband only) |
| API shape | Unity XR Hands through XREAL SDK 3.x | Unity XR Hands through VITURE XR SDK 0.9.0 |
| Joins the current APK | Yes: both SDKs are in the `unified` export | Yes, same export |
| Extra bench friction | Wireless ADB not needed | Wireless ADB, second Android host to charge and update |
| Main risk | Android 16 warning; input source is a project setting | Two purchases before the first gate |

Both vendors are Unity-only for hands, both have unknown runtime permissions
beyond `CAMERA`, and neither has been run. The tie-breakers are cost and host
count, not capability. Android XR is the cleaner native API but needs an XR
headset and moves the app off the phone, so it is out of scope this month.

**If the Air 2 Ultra cannot be bought for the hardware month,** record 6DoF as
not started. Do not buy a Neckband plus Luma Ultra as a substitute: that is two
purchases for the same unproven gates.

## 2. Current build

| Item | Value |
|---|---|
| Artifact | `wmr-companion-0.3.5-unified-arm64-v8a.apk` |
| Release | [`v0.3.5`](https://github.com/nightcinder/wmr-companion/releases/tag/v0.3.5), commit `6648ffd` |
| APK SHA-256 | `f95078c7a68079eed7d78f0f17f61bc874814d8c5dcd9b2cfea6598c7dd712dc` |
| Unity export SHA-256 | `29a9b9066d1b8dcee7b7acf5dddf7075dbd987c6dcbf29fde9216ed7084d2072` (`unity-export-1.1`, pinned in CI) |
| Flavor | `unified`: VITURE 0.9.0 + XREAL 3.1.0 in one `unityLibrary`, vendor selected at runtime |
| Signing | release key; tester build, not a store upload |

The release APK already enables every tracking flag, so the XREAL sheet does
not need a `--dart-define` rebuild. To rebuild locally from the owner export:

```bash
apps/wmr_companion_app/tool/install_unity_export.sh unified path/to/unityLibrary.zip
apps/wmr_companion_app/tool/build_flavor.sh unified --debug
```

Validate any unified APK without a device before installing it:

```bash
gh release download v0.3.5 -p 'wmr-companion-0.3.5-unified-arm64-v8a.apk'
python3 apps/wmr_companion_app/tool/check_unified_apk.py wmr-companion-0.3.5-unified-arm64-v8a.apk
```

## 3. Permission and session path (host-validated)

`check_unified_apk.py` passed on the v0.3.5 release artifact in CI with its
recorded SHA-256.
It reads the binary manifest, dex and Unity subsystem files. A `uses-feature`
without `android:required` counts as required, as Android does — `camera` must
say `required="false"`. `tool/test_check_unified_apk.py` covers the binary-XML
parser (UTF-16 and UTF-8 pools) and that camera gate.

| Check | Result |
|---|---|
| Merged permissions | `BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT`, `CAMERA` (checked by `check_unified_apk.py`); the Android XR plugin manifest declares `SCENE_UNDERSTANDING_COARSE`, `HAND_TRACKING` and `HEAD_TRACKING`; `SCENE_UNDERSTANDING_FINE` must not be declared |
| Features | `bluetooth_le`, `usb.host`, and `camera` declared `required=false` |
| Both runtimes | `libVitureUnityXR.so`, `libXREALXRPlugin.so`, one `libunity.so`; Unity subsystems 0.9.0 and 3.1.0 |
| Session classes | `WmrTrackingDispatchPlugin`, `WmrTrackingViturePlugin`, `WmrTrackingXrealPlugin` in the dex; `SharedUnityRuntime` and `PendingStartGate` are reported as informational because R8 may rename them in a release build |
| Activities | Flutter `MainActivity`, `UnityPlayerActivity`, XREAL `NRXRActivity` |
| Vendor metadata | VITURE `sdk 0.9.0`, `dof 6dof`; XREAL `supportDevices` present |

This proves the build contains the permission declarations and both relay
runtimes, not that Android grants them. The runtime prompt, vendor selection,
Unity start, frame rate and joint delivery are gates 3 and 5 in the run sheet.

## 4. Gaps to close on hardware (or before)

1. **XREAL support devices.** The merged manifest carries
   `com.nreal.supportDevices = 1|XrealLight|2|XrealAir`. Whether Air 2 Ultra
   needs an additional category in the export is not provable from the APK.
   If `start` reports `unsupported`, rebuild the export with
   `XREAL_DEVICE_CATEGORY_REALITY` in Support Devices ([run sheet §1](../runs/sheets/pose-xreal.md)).
2. **Input source is a project setting.** `Initial Input Source = Hands` cannot
   be switched at runtime (no API verified). An export left on Controller fails
   at start with `unavailable`, not at detection.
3. **Unknown XREAL USB IDs.** Detection is fail-closed by default and the
   `xreal`/`nreal` host marker only covers the Beam Pro. On a bare Samsung phone,
   either configure confirmed IDs at runtime or rely on the host marker plus the
   Unity model check.
4. **Android 16.** XREAL warns against Android 16 on development devices. Record
   the host build in the run sheet; do not upgrade a working host mid-campaign.
5. **No permission or rate evidence.** The camera prompt, granted/denied
   behaviour, head/joint rates, and whether a gripping hand stays tracked are all
   still unmeasured. They are run-sheet fields, not assumptions.
6. **VITURE remains unvalidated.** It is carried in the same artifact; the
   unified export's coexistence of both SDKs is still only host-tested.

## 5. What was not done here

- No Unity export was produced; the owner export is taken as supplied (SHA above).
- No APK was installed, no permission was granted, no vendor runtime started.
- No iOS, Pi or controller hardware is involved in this path.
- No VITURE purchase is proposed.

Next: run gates 3, 5, 7 and 8 from
[`pose-xreal.md`](../runs/sheets/pose-xreal.md) on the Air 2 Ultra. A pass in
gates 3 and 5 with joints arriving while gripping is what lets 1.0 say
"6DoF supported"; anything less is recorded as head-relative fallback or not
supported.
