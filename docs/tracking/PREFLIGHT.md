# 6DoF pre-flight: named path, build, desk evidence
Status: desk work only, re-checked 2026-11-02 on v0.3.12. No glasses, phone or Unity runtime was started. The checks below are host-side results; every tracking figure and permission prompt is a hardware gate.

Companion docs: [GATES.md](GATES.md), [TRACKING.md](../TRACKING.md), [pose-xreal.md](../runs/sheets/pose-xreal.md).

## 1. Named 1.0 path: XREAL Air 2 Ultra
Decision: XREAL Air 2 Ultra + an existing Beam Pro or Samsung S24-or-later phone. VITURE is the fallback, not a second primary.

| | XREAL Air 2 Ultra | VITURE Luma Ultra + Pro Neckband |
|---|---|---|
| Hardware | Glasses only | Glasses and Neckband |
| App runs on | The phone | The Neckband; phone-only has no hands |
| Hand tracking | 26 XR Hands joints (Air 2 Ultra only) | 26 joints (Luma Ultra + Neckband only) |
| API | Unity XR Hands through XREAL SDK 3.x | Unity XR Hands through VITURE XR SDK 0.9.0 |
| In the unified APK | Yes | Yes |
| Bench friction | None extra | Wireless ADB and a second Android host |
| Main risk | Android 16 warning; input source is a project setting | Two purchases |

Both vendors are Unity-only for hands and neither has run. The tie-breakers are cost and host count. Android XR is cleaner but needs an XR headset and moves the app off the phone, so it is out of scope.

If the Air 2 Ultra cannot be bought for the hardware month, record 6DoF as not started. Do not buy a Neckband plus Luma Ultra as a substitute.

## 2. Checked build
| Item | Value |
|---|---|
| Artifact | `wmr-companion-0.3.12-unified-arm64-v8a.apk` |
| Release | v0.3.12, commit `2a7e176` |
| APK SHA-256 | `93647e6f63191581bebcdc54f7e4d3bbd9caa8d84475db43cd86b2387a575458` |
| Unity export SHA-256 | `2a19edc07e9204094317efd2cda08175bca82f75181a77c3420948d2d14b6ef8` (`unity-export-1.2`; CI now pins 1.4) |
| Flavor | `unified`: VITURE 0.9.0 + XREAL 3.1.0, vendor selected at runtime |
| Signing | release key; tester build |

Check any unified APK without a device:

```bash
gh release download v0.3.12 -p 'wmr-companion-0.3.12-unified-arm64-v8a.apk'
python3 apps/wmr_companion_app/tool/check_unified_apk.py wmr-companion-0.3.12-unified-arm64-v8a.apk
```

## 3. Host-side checks
`check_unified_apk.py` passed on v0.3.12 with its recorded SHA-256 (re-run 2026-11-02). It reads the binary manifest, dex and Unity subsystem files. A `uses-feature` without `android:required` counts as required: `camera` must say `required="false"`. `tool/test_check_unified_apk.py` covers the binary-XML parser (UTF-16 and UTF-8 pools) and the camera gate.

| Check | Result |
|---|---|
| Permissions | `BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT`, `CAMERA`; the Android XR plugin declares `SCENE_UNDERSTANDING_COARSE`, `HAND_TRACKING`, `HEAD_TRACKING`; `SCENE_UNDERSTANDING_FINE` must not be declared |
| Features | `bluetooth_le`, `usb.host` and `camera` declared `required=false` |
| Runtimes | `libVitureUnityXR.so`, `libXREALXRPlugin.so`, one `libunity.so`; subsystems 0.9.0 and 3.1.0 |
| Session classes | `WmrTrackingDispatchPlugin`, `WmrTrackingViturePlugin`, `WmrTrackingXrealPlugin` in dex; `SharedUnityRuntime` and `PendingStartGate` are informational because R8 can rename them |
| Android XR callbacks | v0.3.9 and later keep every dex method that implements `function.Consumer`, `splitengine.RequestCallback` or `splitengine.MessageGroupCallback`. Older builds such as v0.3.7/v0.3.8 shrink them and crash with `AbstractMethodError` |
| Activities | Flutter `MainActivity`, `UnityPlayerActivity`, XREAL `NRXRActivity` |
| Vendor metadata | VITURE `sdk 0.9.0`, `dof 6dof`; XREAL `supportDevices` present |

This proves the declarations and runtimes are in the APK, not that Android grants them. Permission, vendor selection, Unity start, frame rate and joint delivery are gates 3 and 5.

## 4. Gaps to close on hardware
1. XREAL support devices: the manifest lists `XrealLight`/`XrealAir`. If `start` reports `unsupported`, rebuild the export with `XREAL_DEVICE_CATEGORY_REALITY` in Support Devices.
2. Input source is a project setting: `Initial Input Source = Hands` cannot be switched at runtime. A Controller export fails at start with `unavailable`.
3. XREAL USB IDs are unknown and fail-closed on a bare phone. Use confirmed IDs, or the host marker plus the Unity model check.
4. Android 16: XREAL warns against it on dev devices. Record the host build; do not upgrade mid-campaign.
5. No permission or rate evidence: the camera prompt, granted/denied behaviour, head and joint rates, and gripping-hand tracking are still unmeasured.
6. VITURE is unvalidated: both SDKs coexist in the artifact only on the host side.

## 5. HOGP and Companion HID coexistence
The ESP32 bridge advertises BLE HID-over-GATT (HOGP, `0x1812`) and `0xFF10` on the same LE link, and Android binds the HOGP gamepad on bonding. The Companion app can also output HID (`BluetoothHidDevice` / `wmr_companion_hid_android`) to a remote host.

Do not enable Companion HID output while the host is paired to the bridge's HOGP gamepad. Registering `BluetoothHidDevice` disables Android's HID Host service and causes radio contention. Keep Companion HID output disabled.

## 6. Not done here
No Unity export was produced; the owner export is taken as supplied. No APK was installed, no permission granted, no vendor runtime started. No iOS, Pi or controller hardware is involved. No VITURE purchase is proposed.

Next: run gates 3, 5, 7 and 8 from [pose-xreal.md](../runs/sheets/pose-xreal.md) on the Air 2 Ultra. Gates 3 and 5 passing with joints arriving while gripping is what lets 1.0 say "6DoF supported"; anything less is "head-relative fallback" or "not supported".
