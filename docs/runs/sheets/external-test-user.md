# External tester quickstart: WMR Companion v0.3.19 (unified APK)
Three setups, 20-40 minutes. Android 13+ host (phone, Neckband or headset). The bridge instructions are for the ESP32 bridge; Raspberry Pi is still in development.

## 0. Pick your setup
- **A: Bridge + WMR controllers.** You have the bridge and one or two WMR controllers. Full run.
- **B: 6DoF only (glasses, no bridge).** Glasses with hand tracking or URXR One day-one environment discovery, no bridge. Short path.
- **C: Bridge + PSVR2 Sense controllers.** Same as A with PSVR2. Experimental; read 6C first.

Record the setup in the intake block.

## Prerequisites
- Android 13 or newer.
- Setups A/C: the board must be flashed to v0.3.5. Flasher: https://nightcinder.github.io/WMR_Bridge/. A pre-flashed board is fine; say so. Reflashing erases pairings, so the first pairing after a flash is normal.
- LED: red = no controllers, yellow = left only, blue = right only, green = both.

### VITURE and Android XR hosts
VITURE hand tracking runs only on a **VITURE Pro Neckband** with **Luma Ultra**. The app runs on the Neckband, not a paired phone. 3DoF models (One, OneLite, Pro, Pro2, Luma, LumaPro, LumaCyber, Beast) do not deliver hand tracking: record setup B as "not supported", not a failure.

Android XR hand tracking runs on the headset. It requests `CAMERA`, `SCENE_UNDERSTANDING_COARSE`, `HAND_TRACKING` and `HEAD_TRACKING`. A "Precise movement and area data" prompt (`SCENE_UNDERSTANDING_FINE`) must not appear; if it does, record a regression. The VITURE slice requests `CAMERA` only.

### URXR One day-one checks
URXR One connects to the host phone through USB-C. Day-one checks do not need paired controllers or a bridge. These checks require an app build cut after PR #260 / ONY-1137 (commit `75655c8` on `main`, or the next release) because v0.3.19 does not contain the device environment probe. The app captures USB identities, display metrics, and OpenXR features into `device_environment.json` inside the diagnostic test bundle.

## 1. Get the APK
https://github.com/nightcinder/wmr-companion/releases/download/v0.3.19/wmr-companion-0.3.19-unified-arm64-v8a.apk

SHA256SUMS: https://github.com/nightcinder/wmr-companion/releases/download/v0.3.19/SHA256SUMS

Confirm the v0.3.19 release exists and the installed APK reports `versionName` 0.3.19 before testing. If it reports 0.3.18, the tag was cut from a bumped tree: record it and stop.

For URXR One day-one checks, install an APK built from `main` after commit `75655c8` (ONY-1137, for example `flutter build apk --debug` in `apps/wmr_companion_app`) or a subsequent release. v0.3.19 predates the probe and does not generate `device_environment.json`.

One APK carries VITURE and XREAL and runs on a Galaxy XR. Uninstall an older WMR Companion first (CI APKs are signed differently): `adb uninstall com.onyxlens.wmr_companion` or app settings.

Do not run an older build. v0.3.19 carries the 6-run pose capture (v0.3.15), Android XR detection before USB IDs (v0.3.16), and the Semgrep/gitleaks/Dependabot scans (ONY-890). The Connect-screen LAN scan and opt-in CompositeBleTransport link (ONY-1143), the device_environment snapshot (ONY-1137), and the pose-capture speed-gate validator (ONY-1138) need a build cut after those commits and are not in the v0.3.19 APK.

## 2. Install
1. Download the APK and SHA256SUMS. Verify: `sha256sum -c SHA256SUMS` on a computer (or Termux), or compare the APK's SHA-256.
2. Open the APK on the host device (Neckband for VITURE, headset for Android XR, phone otherwise) and allow "install unknown apps".
3. Install. If Android blocks it, record the message and stop.

## 3. Connect the bridge: A and C only
Skip in setup B.

1. Power the board. LED is red.
2. Open the app and grant Bluetooth/Nearby devices.
3. On **Connect**, scan for `WMR Bridge` and connect.
4. Confirm **connected, streaming** and MTU 517 (>=61 is usable). Record the MTU.
5. Tap **Open 3D debug view**.

> Firmware 0.3.5 exposes a BLE HID gamepad (HOGP) to Android on pairing. Do not enable app-level HID output (`BluetoothHidDevice`) at the same time: it disables Android's HID Host service and degrades latency. Keep Companion HID output disabled.

## 4. Pair controllers: A and C only
Skip in setup B. Pair both together, not one at a time.

1. No other host is connected to the controllers.
2. Hold the Windows button on BOTH controllers until their LEDs flash.
3. On the debug screen, open **Controller control** and tap **Scan for controllers**.
4. Wait up to 60 s. Success: both hands `LEFT/RIGHT connected`, live stream on both, LED green. Setup C shows `PSVR2` instead of `WMR`.
5. If it fails, tap **Forget bond (LEFT)** / **Forget bond (RIGHT)**, retry once, then stop.

## 5. Latency capture: setup A only
1. Open **Latency test**.
2. Set Run length **120 s**, Stream **FF14 batched**, Measure round trip (FF15 echo) on, Ping interval **250 ms**.
3. Start, do not touch anything for 120 s, Stop.
4. Tap **Export CSV + JSON** and save/share the files.

## 6. Guided bench
From **Connect**, tap **Run guided bench**. It ends with **Write test bundle**, the zip you send. Every step can be skipped and is recorded as skipped.

- **6A: 3DoF only / Combined.** Pick 3DoF only for controllers, or Combined for bridge + glasses. Follow the wizard: connect, both hands, firmware/config, still, slow move, 60 s FF11, latency, serial.
- **6B: 6DoF only (no bridge).** Pick 6DoF only. The bridge steps are skipped and the run is shorter; that is expected. There are no controllers to pair. If your glasses do not report hand tracking, **Capture 6DoF pose** is unavailable: record it as skipped.

**URXR One day-one discovery (setup B).** Connect URXR One to the phone over USB-C. Without an active hand-tracking runtime, the 6DoF-only guided bench is unavailable. Tap **Export test bundle** directly on the Connect screen. The app creates `wmr-ext-<yyyyMMdd>.zip`. Make sure that the zip file contains `device_environment.json`. Open `manifest.md` in the zip file and confirm the device environment summary line.

Check these items in `device_environment.json`:
1. USB devices: make sure that the URXR One vendor ID, product ID, and interface class list appear under `usb.devices`.
2. Displays: make sure that the external panel resolution, refresh rate, and external flag appear under `displays.items`.
3. OpenXR features: make sure that system features (`android.hardware.xr` or vendor extensions) appear under `xr_features`.

The exported environment bundle completes the day-one check.

**Stereo check (VITURE, setup B).** The Unity player must render stereo 3D (SpaceWalker). The debug overlay shows `playerHosted`, `stereoMode` and `stage`. A healthy run reaches `firstFrame` with `stereoMode` `multiPass`/`singlePass`/`singlePassInstanced` and fills both eyes. If the stage stops at `playerHosted`/`loaderStarted`, `stereoMode` is `unknown`, or one eye shows half an image, record the values and capture logs. A 2D/mono player fails closed with `unavailable`. If the right eye is black, see 6D.

**Capture 6DoF pose.** Appears only while the glasses report hand tracking. It records six short runs: still, held drifting, slow pan, medium pan, fast flick and one occlusion check. Each lasts 15-20 s; the step takes about 1.5 min and alternates hands. Brace your arm for still. For drifting, hold as if aiming and let the hand wander. Pan 30 cm in 3 s for slow, 50 cm in 1 s for medium, flick 45 cm in 0.3 s for fast. Hide the hand for a second or two for occlusion. Skipped runs are recorded as skipped, and the files are in the bundle.

- **6C: PSVR2 Sense (experimental).** Support is on by default and compiled into every v0.3.3 image, but it has never run on a controller: treat it as data collection, not pass/fail. Pair as in section 4; the app labels it `PSVR2` (a `WMR` label is worth reporting). PSVR2 is raw-only: FF11 carries `0xA1 0x31` frames up to 79 bytes; FF12/FF14 have no PSVR2 decoder, FF13 is not read, and the 3D view may show nothing. Use FF11 raw and the serial log; record `model PSVR2`, the wake line and the first report's `frame_len`. One retry only.

**6D: Luma Ultra + Pro Neckband black right eye.** On v0.3.7/v0.3.8 the app draws only in the left eye of the 32:9 (3840x1080) viewport. The app is not crashed; the UI fills one half. v0.3.9 and later mirror both eyes. If v0.3.19 still shows a black right eye, record a regression.

1. Switch the glasses to 2D mode with the glasses 2D/3D button; the app fills the view.
2. In 3D mode use the Neckband controls (it has no D-pad): short Volume Up/Down move the focus ring, hold Volume Down selects, hold Volume Up goes back. With headgaze on (Settings + Power), Volume Down selects and Volume Up goes back. Do not use ADB to inject touches.
3. Switch back to 3D before Capture 6DoF pose, which needs stereo.

**Mirroring the screen (6D).** Do not use Android Studio Device Mirroring, and do not use plain `scrcpy`: the Neckband exposes an empty virtual Display 5 (`SYSTEM_NOTIFICATION_VD`) that the tools attach to, while the real UI is on Display 3, which excludes touch. PC clicks therefore land on nothing and touch injection is dropped. View only with `scrcpy --display-id=3`. Drive the app with the physical Volume Up/Down keys, headgaze (Settings + Power), the phone Neckband Remote app, or a paired Bluetooth controller.

Capture: `adb shell dumpsys package com.onyxlens.wmr_companion | grep -E "versionName|versionCode"`, `adb shell wm size`, `adb shell dumpsys display | grep -iE "DisplayDeviceInfo|size=|density=|mode="`, and `adb logcat -v threadtime > wmr-neckband-sbs-<YYYYMMDD-HHMMSS>.log`. Connect wireless ADB first: `adb connect <neckband-ip>:5555`.

### 6E: Neckband 0DoF / 6DoF triage
In release 0.3.10 and earlier, the app could drop to 0DoF with 6DoF disabled. Release 0.3.11 fixed the Unity player pause state and required stereo 3D. The Pro Neckband has no physical D-pad. Use short Volume Up or Down presses to move focus. Hold Volume Down to select. Hold Volume Up to go back. If headgaze is active (Settings and Power), Volume Down selects and Volume Up goes back. If the app still shows 0DoF, record the status line. Capture logcat filtered on `0DoF|6DoF|spacewalker|running in 2d`. Do not use ADB to inject touches.

Do not use Android Studio Device Mirroring. Do not use plain `scrcpy`. The Neckband exposes an empty virtual Display 5 (`SYSTEM_NOTIFICATION_VD`). The active UI runs on Display 3, which rejects touch injection. For a visible screen, run `scrcpy --display-id=3` for viewing only. Send input with the Volume buttons, headgaze, the phone Neckband Remote app, or a paired Bluetooth controller.

### 6F: Pro Neckband hand-tracking disambiguation

The Pro Neckband uses three distinct hand-tracking layers:
- SpaceWalker OS hand pointer: SpaceWalker displays an optical hand pointer. The pointer disappears when `VitureHandTracking.Start` runs, because the camera enters exclusive mode. In release 0.3.21 and later, the app starts Unity only after you open the Bench screen or the Debug screen.
- In-app optical hand skeleton: Unity runs the 26-joint optical hand skeleton in the app. The bare hand skeleton appears in the HUD on the Bench screen during the `handEmpty` step.
- SixDofFuser controller anchor: `SixDofFuser` fuses controller IMU orientation with optical hand anchor pose data. When a controller covers fingers during `handGrip`, optical tracking drops out. The pose then falls back to head-relative tracking.

The VITURE Pro Neckband has no physical D-pad. Use only these controls:
- Physical Volume Up and Volume Down buttons. Short press moves focus. Long press Volume Down selects. Long press Volume Up navigates back.
- Settings button together with Power button to turn on headgaze navigation.
- Phone Neckband Remote application.
- Paired Bluetooth controller or mouse.

Follow this checklist to find which tracking layer fails:
1. Connect screen test: make sure that the SpaceWalker OS hand pointer works before you open Bench or Debug.
2. Empty hand test: during `handEmpty` on the Bench screen, make sure that the 26-joint skeleton appears in the HUD.
3. Controller grip test: during `handGrip` on the Bench screen, observe whether tracking drops out when you hold a controller.

Capture diagnostic evidence over wireless ADB:
1. Connect to the Neckband:
   ```bash
   adb connect <neckband-ip>:5555
   ```
2. Clear the logcat buffer and start capture:
   ```bash
   adb logcat -c && adb logcat -v threadtime > wmr-neckband-hand-diag-<timestamp>.log
   ```
3. Filter hand tracking and relay log messages:
   ```bash
   grep -E "HAND_HEARTBEAT|WmrTrackingUnitySmoke|VitureXR|WmrTrackingUnity|WmrTrackingViture" wmr-neckband-hand-diag-<timestamp>.log
   ```
   `WmrTrackingUnitySmoke` reports relay frame intervals and whether `hasHands` is true. `HAND_HEARTBEAT` reports the camera frame rate.
4. Capture SurfaceFlinger and display layers while the Bench screen is visible:
   ```bash
   adb shell dumpsys SurfaceFlinger > wmr-neckband-surfaceflinger.txt
   adb shell dumpsys display > wmr-neckband-display.txt
   ```
   Make sure that `MainActivity` appears on `layerStack=3` with `coveredRegion=[0, 0, 0, 0]`.

## 7. Logs and files
Capture for every run and include in the zip:

- `adb logcat -v threadtime > wmr-<setup>-<YYYYMMDD-HHMMSS>.log`
- Filter tracking problems: `grep -iE "WmrTracking|TrackingException|stage=|stereo=|UnityPlayer|playerHosted" wmr-*.log`
- Filter hand tracking problems: `grep -E "HAND_HEARTBEAT|WmrTrackingUnitySmoke" wmr-*.log`
- SurfaceFlinger layer dump for Neckband runs: `adb shell dumpsys SurfaceFlinger > wmr-surfaceflinger-<timestamp>.txt`
- Display dump for Neckband runs: `adb shell dumpsys display > wmr-display-<timestamp>.txt`
- Bridge serial: save the `STREAM`/`LINKLOG` lines as `wmr-serial-<timestamp>.txt`
- Screenshot the debug overlay showing `playerHosted`, `stereoMode` and `stage` (VITURE) or the permission list (Android XR)
- If a file is missing, state the missing file name. Do not reconstruct numbers from memory.

## 8. Send
Zip the exported files plus the intake block. Send in the thread where you received this runbook.

### Intake block
```markdown
### WMR external test
- Path: A (bridge + WMR) / B (6DoF only) / C (bridge + PSVR2)
- Handle:
- Date/timezone:
- Firmware: 0.3.5
- App: <versionName from ADB> unified (signed release) (expected 0.3.19, or post-ONY-1137 build for URXR One)
- Host: Neckband / Android XR headset / URXR One / phone (make/model/OS)
- Phone: make/model/Android
- Controllers: make/model (WMR / PSVR2), or none
- Result: PASS / PARTIAL / FAIL / BLOCKED
- Pairing: BOTH controllers paired together ____
- LED: red / yellow / blue / green
- MTU shown: ____
- Neckband SBS: black right eye / full screen / n/a
- Hand tracking source: auto-detected (VITURE / XREAL / Android XR) / Simulated / none (URXR One)
- Device environment JSON: captured / missing
- 0DoF status line: ____
- 6DoF only enabled: yes / no
- ADB wm size: ____
- ADB display mode: ____
- Files: manifest, exports
- What happened (3 lines max):
```
