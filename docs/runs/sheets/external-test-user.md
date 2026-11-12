# External tester quickstart: WMR Companion v0.3.24

Three setups, 20-40 minutes. Android 13+ host (phone, Neckband, or headset). The bridge steps are for the ESP32 bridge. The Raspberry Pi bridge is still in development.

## 0. Pick your setup

- A: Bridge + WMR controllers. Full run.
- B: 6DoF only (glasses, no bridge). Short path.
- C: Bridge + PSVR2 Sense controllers. Experimental; read 6C first.

Record the setup in the intake block.

## Prerequisites

- Android 13 or newer.
- Setups A and C: the board must be flashed to v0.3.5. Flasher: https://nightcinder.github.io/WMR_Bridge/. A pre-flashed board is fine; say so. Reflashing erases pairings, so the first pairing after a flash is normal.
- LED: red = no controllers, yellow = left only, blue = right only, green = both.

### VITURE and Android XR hosts

VITURE hand tracking runs only on a VITURE Pro Neckband with Luma Ultra. The app runs on the Neckband, not a paired phone. 3DoF models (One, OneLite, Pro, Pro2, Luma, LumaPro, LumaCyber, Beast) do not deliver hand tracking: record setup B as "not supported", not a failure.

Android XR hand tracking runs on the headset. It requests `CAMERA`, `SCENE_UNDERSTANDING_COARSE`, `HAND_TRACKING`, and `HEAD_TRACKING`. A "Precise movement and area data" prompt (`SCENE_UNDERSTANDING_FINE`) must not appear; if it does, record a regression. The VITURE slice requests `CAMERA` only.

### URXR One day-one checks

URXR One connects to the host phone over USB-C. Day-one checks need no paired controllers or bridge. The device environment probe is in v0.3.20 and later, so the current release includes it. The app captures USB identities, display metrics, and OpenXR features into `device_environment.json` inside the diagnostic bundle.

## 1. Get the APK

https://github.com/nightcinder/wmr-companion/releases/download/v0.3.24/wmr-companion-0.3.24-unified-arm64-v8a.apk

SHA256SUMS: https://github.com/nightcinder/wmr-companion/releases/download/v0.3.24/SHA256SUMS

Make sure that the v0.3.24 release exists and the installed APK reports `versionName` 0.3.24 before testing. If it reports 0.3.23, record it and stop.

One APK carries VITURE and XREAL and runs on a Galaxy XR. Uninstall an older WMR Companion first: `adb uninstall com.onyxlens.wmr_companion` or app settings.

## 2. Install

1. Download the APK and SHA256SUMS. Verify with `sha256sum -c SHA256SUMS` or compare the APK's SHA-256.
2. Open the APK on the host device and allow "install unknown apps".
3. Install. If Android blocks it, record the message and stop.

## 3. Connect the bridge: A and C only

Skip in setup B.

1. Power the board. LED is red.
2. Open the app and grant Bluetooth/Nearby devices.
3. On **Connect**, scan for `WMR Bridge` and connect.
4. Confirm **connected, streaming** and MTU 517 (>=61 is usable). Record the MTU.
5. Tap **Open 3D debug view**.

Firmware 0.3.5 exposes a BLE HID gamepad (HOGP). Do not enable app-level HID output at the same time. Keep Companion HID output disabled.

## 4. Pair controllers: A and C only

Skip in setup B. Pair both together.

1. No other host is connected to the controllers.
2. Hold the Windows button on both controllers until their LEDs flash.
3. On the debug screen, open **Controller control** and tap **Scan for controllers**.
4. Wait up to 60 s. Success: both hands show LEFT/RIGHT connected, live stream on both, LED green. Setup C shows `PSVR2`.
5. If it fails, tap **Forget bond (LEFT)** / **Forget bond (RIGHT)**, retry once, then stop.

## 5. Latency capture: setup A only

1. Open **Latency test**.
2. Set Run length 120 s, Stream FF14 batched, Measure round trip (FF15 echo) on, Ping interval 250 ms.
3. Start, do not touch anything for 120 s, Stop.
4. Tap **Export CSV + JSON** and save/share the files.

## 6. Guided bench

From **Connect**, tap **Run guided bench**. It ends with **Write test bundle**, the zip you send. Every step can be skipped and is recorded as skipped.

- 6A: 3DoF only or Combined. Follow the wizard: connect, both hands, firmware/config, still, slow move, 60 s FF11, latency, serial.
- 6B: 6DoF only (no bridge). Bridge steps are skipped. No controllers to pair. If your glasses do not report hand tracking, **Capture 6DoF pose** is unavailable: record it as skipped.

URXR One day-one discovery (setup B). Connect URXR One to the phone over USB-C. With no active hand-tracking runtime, the 6DoF-only guided bench is unavailable. Tap **Export test bundle** on the Connect screen. The app creates `wmr-ext-<yyyyMMdd>.zip`. Make sure the zip contains `device_environment.json`. Open `manifest.md` in the zip and confirm the device environment summary line.

Check these items in `device_environment.json`:
1. USB devices: URXR One vendor ID, product ID, and interface class list under `usb.devices`.
2. Displays: external panel resolution, refresh rate, and external flag under `displays.items`.
3. OpenXR features: system features under `xr_features`.

The exported bundle completes the day-one check.

Stereo check (VITURE, setup B). The Unity player must render stereo 3D (SpaceWalker). The debug overlay shows `playerHosted`, `stereoMode`, and `stage`. A healthy run reaches `firstFrame` with `stereoMode` `multiPass`/`singlePass`/`singlePassInstanced` and fills both eyes. If the stage stops at `playerHosted`/`loaderStarted`, `stereoMode` is `unknown`, or one eye shows half an image, record the values and capture logs. A 2D/mono player fails closed with `unavailable`. If the right eye is black, see 6D.

Capture 6DoF pose. Appears only while the glasses report hand tracking. It records six short runs: still, held drifting, slow pan, medium pan, fast flick, and one occlusion check. Each lasts 15-20 s; the step takes about 1.5 min and alternates hands. Brace your arm for still. For drifting, hold as if aiming and let the hand wander. Pan 30 cm in 3 s for slow, 50 cm in 1 s for medium, flick 45 cm in 0.3 s for fast. Hide the hand for a second or two for occlusion. Skipped runs are recorded as skipped, and the files are in the bundle.

- 6C: PSVR2 Sense (experimental). Support is on by default and compiled into every image, but it has never run on a controller: treat it as data collection, not pass/fail. Pair as in section 4; the app labels it `PSVR2`. PSVR2 is raw-only: FF11 carries `0xA1 0x31` frames up to 79 bytes; FF12/FF14 have no PSVR2 decoder, FF13 is not read, and the 3D view may show nothing. Use FF11 raw and the serial log. Record `model PSVR2`, the wake line, and the first report's `frame_len`. One retry only.
- 6D: Luma Ultra + Pro Neckband black right eye. On older builds the app draws only in the left eye of the 32:9 (3840x1080) viewport. v0.3.9 and later mirror both eyes. If v0.3.24 still shows a black right eye, record a regression.
  1. Switch the glasses to 2D mode with the glasses 2D/3D button. The app fills the view.
  2. In 3D mode use the Neckband controls: short Volume Up/Down move the focus ring, hold Volume Down selects, hold Volume Up goes back. With headgaze on (Settings + Power), Volume Down selects and Volume Up goes back. Do not use ADB to inject touches.
  3. Switch back to 3D before Capture 6DoF pose, which needs stereo.
- 6E: Neckband 0DoF / 6DoF triage. On older builds the app could open and drop to 0DoF with **6DoF only** greyed out. If the app still shows 0DoF on v0.3.24, record the status line and capture logcat filtered on `0DoF|6DoF|spacewalker|running in 2d`. Do not use ADB to inject touches.

Mirroring the screen (6D and 6E). Do not use Android Studio Device Mirroring, and do not use plain `scrcpy`: the Neckband exposes an empty virtual Display 5 (`SYSTEM_NOTIFICATION_VD`) that the tools attach to, while the real UI is on Display 3, which excludes touch. View only with `scrcpy --display-id=3`. Drive the app with the physical Volume Up/Down keys, headgaze, the phone Neckband Remote app, or a paired Bluetooth controller.

Capture for 6D: `adb shell dumpsys package com.onyxlens.wmr_companion | grep -E "versionName|versionCode"`, `adb shell wm size`, `adb shell dumpsys display | grep -iE "DisplayDeviceInfo|size=|density=|mode="`, and `adb logcat -v threadtime > wmr-neckband-sbs-<YYYYMMDD-HHMMSS>.log`. Connect wireless ADB first: `adb connect <neckband-ip>:5555`.

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
1. Connect screen test: on release 0.3.21 and later, make sure that the SpaceWalker OS hand pointer works before you open Bench or Debug.
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
   grep -E "WmrTrackingUnitySmoke|VitureXR|WmrTrackingUnity|WmrTrackingViture" wmr-neckband-hand-diag-<timestamp>.log
   ```
   `WmrTrackingUnitySmoke` reports frame count, payload size, and whether `hasHands` is true. In release 0.3.24 and later, the exported test bundle records frame rate and gap metrics in `hand_tracking_diagnostics.effective_hz` and `hand_tracking_diagnostics.max_gap_ms`.
4. Capture SurfaceFlinger and display layers while the Bench screen is visible:
   ```bash
   adb shell dumpsys SurfaceFlinger > wmr-surfaceflinger-<timestamp>.txt
   adb shell dumpsys display > wmr-display-<timestamp>.txt
   ```
   Make sure that `MainActivity` appears on `layerStack=3` with `coveredRegion=[0, 0, 0, 0]`.

## 7. Logs and files

Capture for every run and include in the zip:

- `adb logcat -v threadtime > wmr-<setup>-<YYYYMMDD-HHMMSS>.log`
- Filter tracking problems: `grep -iE "WmrTracking|TrackingException|stage=|stereo=|UnityPlayer|playerHosted" wmr-*.log`
- Filter hand tracking problems: `grep -E "WmrTrackingUnitySmoke" wmr-*.log`
- SurfaceFlinger layer dump for Neckband runs: `adb shell dumpsys SurfaceFlinger > wmr-surfaceflinger-<timestamp>.txt`
- Display dump for Neckband runs: `adb shell dumpsys display > wmr-display-<timestamp>.txt`
- Bridge serial: save the `STREAM`/`LINKLOG` lines as `wmr-serial-<timestamp>.txt`
- Screenshot the debug overlay showing `playerHosted`, `stereoMode`, and `stage` (VITURE) or the permission list (Android XR)
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
- App: <versionName from ADB> unified (signed release) (expected 0.3.24)
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
