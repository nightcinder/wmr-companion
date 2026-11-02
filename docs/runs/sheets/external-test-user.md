# External tester quickstart : WMR Companion v0.3.13 (unified APK)

Three setups, 20–40 minutes depending on which one you are. Android 13+ host (phone, Neckband, or headset).

The WMR bridge instructions below are for the ESP32-based bridge. Raspberry Pi bridge instructions are still in development.

## 0. Which setup are you?

- **A : Bridge + controllers (WMR).** You have the `WMR Bridge` board and one or two WMR controllers. Full run.
- **B : 6DoF only (glasses, no bridge).** You have glasses with hand tracking and no bridge. No controllers needed; this is the short path.
- **C: Bridge + PSVR2 Sense controllers.** Same as A, but with PSVR2 Sense controllers. Experimental: see section 6C before you start.

Say which one you ran in the intake block.

## Prerequisites

- Android 13 or newer (minSdk 33 for the unified flavor).
- For setups A and C, the board must be flashed to v0.3.3. Flasher: https://nightcinder.github.io/WMR_Bridge/. A pre-flashed board is fine; say so in the intake block. If you are unsure of the version, reflash : flashing erases stored pairings (expected), so the first pairing after a flash is normal.

### LED legend

- Red : no controllers connected.
- Yellow : left controller only.
- Blue : right controller only.
- Green : both controllers connected.

## 0.5. VITURE 6DoF host requirement (read before setup B)

VITURE hand tracking runs only on a **VITURE Pro Neckband** hosting the app,
with **Luma Ultra** glasses. The app runs on the Neckband, not on a paired
phone, and wireless ADB is used. 3DoF VITURE models (One, OneLite, Pro,
Pro2, Luma, LumaPro, LumaCyber, Beast) do not deliver hand tracking and are
not supported for setup B. If your glasses are one of those, or you have no
Neckband, record setup B as "not supported" rather than as a failure.

Android XR hand tracking runs on the headset itself. It requests `CAMERA`,
`SCENE_UNDERSTANDING_COARSE` ("movement and area data"), `HAND_TRACKING`
and `HEAD_TRACKING`. A prompt for "Precise movement and area data"
(`SCENE_UNDERSTANDING_FINE`) must not appear; if it does, record it as a
regression. The VITURE slice requests `CAMERA` only.

## 1. Get the APK

https://github.com/nightcinder/wmr-companion/releases/download/v0.3.13/wmr-companion-0.3.13-unified-arm64-v8a.apk

SHA256SUMS: https://github.com/nightcinder/wmr-companion/releases/download/v0.3.13/SHA256SUMS

Confirm the v0.3.13 release exists and the installed APK reports `versionName` 0.3.13 before testing (see the ADB triage in sections 6D and 6E). If the installed build reports 0.3.12, the tag was not cut from a bumped tree: record the value and stop.

This one APK carries VITURE and XREAL and runs on a Galaxy XR. If an older WMR Companion is installed, uninstall it first (CI APKs are signed differently): `adb uninstall com.onyxlens.wmr_companion` or app settings.

Do not run an older build for this pass. v0.3.13 carries fixes that change results:
in embedded UaaL the Unity bridge is hand-only, so VITURE's display provider
can no longer take over the Flutter host activity, and the unshaded marker
cubes are gone (ONY-840), shipped through the pinned `unity-export-1.3`;
Unity and vendor player activities are no longer exported, so `MainActivity`
is the only entry point (ONY-842); plus the v0.3.12 fixes: the Unity player
is pinned to OpenGL ES 3, the loader gate starts only VITURE's hand subsystem
on a non-GLES3 player, and the hosted Unity view no longer takes D-pad focus
with Volume Up/Down moving focus (ONY-802); plus the v0.3.11 fixes: automatic
glasses detection, the XREAL cold-start fix, and the Unity player resume/focus
on first host so the Neckband no longer drops to 0DoF. None of the ONY-840 or
ONY-842 changes have been verified on hardware yet. A crash, a black right eye,
a pink cube, or a 0DoF drop on v0.3.13 is a regression worth recording.
Known older behaviour: a Vulkan crash on v0.3.7 through v0.3.9, a black right
eye on v0.3.7 or v0.3.8, a 0DoF drop with greyed 6DoF button on v0.3.7
through v0.3.10, and the pink cube / display takeover on v0.3.12.

## 2. Install

1. Download the APK and SHA256SUMS. Verify before installing : on a computer run `sha256sum -c SHA256SUMS` (or in Termux on the phone); otherwise compare the APK's SHA-256 to the value in SHA256SUMS.
2. Open the APK on the host device (Neckband for VITURE, headset for Android XR, phone otherwise); allow "install unknown apps" when asked.
3. Install. If Android blocks it, record the message and stop.

## 3. Connect to the bridge : setups A and C only

Skip this in setup B.

1. Power the board. Status LED should be **red** (no controllers).
2. Open the app; grant Bluetooth / Nearby-devices permission.
3. On the **Connect** screen, scan for `WMR Bridge` and connect.
4. Confirm the screen says **connected, streaming** with negotiated **MTU** 517 (>= 61 is usable). Record the MTU shown.
5. Tap **Open 3D debug view**; stay on the debug screen.

> **HID / Gamepad Coexistence Warning:** Firmware 0.3.3 exposes a standard BLE HID gamepad (HOGP) directly to Android upon pairing. Do not enable app-level HID output (`BluetoothHidDevice`) in WMR Companion at the same time: registering the app HID peripheral disables Android's HID Host service (stopping bridge HOGP input reception) and degrades latency across the phone's shared radio. Keep Companion app HID output disabled.

## 4. Pair controllers : setups A and C only

Skip this in setup B. You do not pair the controllers one at a time.

1. No other host connected to the controllers.
2. Put BOTH controllers in pairing mode **together**: hold the Windows button on each until their LEDs flash. Do not pair one, then the other : both at once is the flow, and they both connect.
3. On the debug screen, find **Controller control** and tap **Scan for controllers**.
4. Wait up to 60 s. Success: both hands `LEFT/RIGHT connected`, live stream on both, LED **green**. Setup C shows the model as `PSVR2` instead of `WMR`.
5. If it fails: tap **Forget bond (LEFT)** / **Forget bond (RIGHT)**, retry once, then stop.

## 5. Latency capture : setup A only

1. Open **Latency test**.
2. Set **Run length** to **120 s**, **Stream** to **FF14 batched**, **Measure round trip (FF15 echo)** on, **Ping interval** to **250 ms**.
3. Tap **Start**; do not touch anything for 120 s; tap **Stop**.
4. Tap **Export CSV + JSON** (or **Export CSV + JSON + echo**) and save/share the files.

## 6. Guided bench

From the **Connect** screen tap **Run guided bench**. It ends with **Write test bundle**, which produces the zip you send.

### 6A : 3DoF only, or Combined (bridge)

Pick **3DoF only** for the controller-only path, or **Combined** if you have both the bridge and glasses. Follow the wizard: connect, both hands, firmware/config, still, slow move, 60 s FF11, latency, serial. Every step can be skipped and is recorded as skipped.

### 6B : 6DoF only (no bridge)

Pick **6DoF only**. The bridge steps are skipped, the run is shorter, and that is expected : it is not a broken install. You need glasses with hand tracking active; there are no controllers to pair.

**Special note for 6DoF-only testers:** this path uses no bridge and no controllers. Do not attempt to pair controllers or connect to `WMR Bridge`. If your glasses do not report hand tracking, the **Capture 6DoF pose** step is unavailable and that is a valid result : record it as skipped. For deeper tracking observation (VITURE/XREAL hand-joint counts, recenter, etc.) see the WMR_Bridge internal runbook (https://github.com/nightcinder/WMR_Bridge/blob/main/docs/runs/sheets/internal-runbook.md) §7.4 and §7.5.


**Stereo check (VITURE, setup B):** the Unity player must render in stereo
3D (SpaceWalker mode). The debug overlay shows `playerHosted`,
`stereoMode` and `stage`. A healthy run reaches `firstFrame` with
`stereoMode` `multiPass`/`singlePass`/`singlePassInstanced` and the 3D view
fills both eyes. If the stage stops at `playerHosted` or `loaderStarted`, or
`stereoMode` is `unknown`, or you see half an image per eye, record the
values and capture logs (section 7.5 below). A 2D/mono player fails closed
with `unavailable` instead of stalling. If the app shows a black right eye on
launch, see section 6D.

**Capture 6DoF pose** appears only while your glasses report hand tracking. It records the full filter-spec rev 4 section 8 corpus: five motion classes (still, held drifting, slow pan, medium pan, fast flick), four runs per class per hand, each at least 30 s, plus one diagnostic occlusion run per hand. That is roughly 10 minutes per hand. Each run repeats its path until the timer ends, at the bench durations: still 30 s, held drifting 30 s, slow pan 36 s, medium pan 30 s, fast flick 40 s, occlusion 30 s. Paths: still (rest, arm braced), held drifting (aim and let it wander), slow pan 30 cm over 3 s back and forth, medium pan 50 cm in 1 s, fast flick 45 cm in 0.3 s. Skipping a run (whole or per run) is fine and does not break the run; skipped runs are recorded as skipped. Its files are inside the bundle you send.

### 6C : PSVR2 Sense (experimental)

PSVR2 Sense support is on by default and compiled into every v0.3.3 image (WMR_Bridge docs/PSVR2.md §1), but it has **never been run on a controller**. Treat everything here as data collection, not as pass/fail.

- Use the same pairing steps as section 4, with the pairing method you use with a PC. The app labels the controller `PSVR2`; if it says `WMR`, that is a result worth reporting.
- PSVR2 is **raw-only** in this build: FF11 carries `0xA1 0x31` frames (up to 79 bytes). There is no PSVR2 decoder for FF12/FF14, FF13 is not read for a PSVR2 hand, and the 3D debug view can show nothing. That is expected. Use FF11 raw and the serial log.
- Capture the serial log during pairing (see the WMR_Bridge internal runbook §6.1 and §7.7: https://github.com/nightcinder/WMR_Bridge/blob/main/docs/runs/sheets/internal-runbook.md) and record the `model PSVR2` line, the wake line, and the first report's `frame_len`.
- Expect the run to work or to fail; either is useful. Do not spend more than one retry on it.
- In the intake block, note `Controllers: PSVR2` and anything that looked wrong : LED colours, dropped hand, wrong model label.

### 6D : Luma Ultra + Pro Neckband: 3D SBS launch triage

On a Luma Ultra with a Pro Neckband the app opens on a 32:9 side-by-side viewport (3840x1080). On WMR Companion v0.3.7 and v0.3.8 the app draws only in the left eye: the right eye stays black and the launch screen can look stuck. The app is not crashed. The UI is there, but it fills one half. v0.3.9 and later mirror the viewport into both eyes; if v0.3.12 still shows a black right eye, record it as a regression with the diagnostics below.

Immediate workaround for v0.3.7/v0.3.8 testers:

1. Switch the glasses to 2D mode with the glasses 2D/3D mode toggle button. The viewport becomes single-screen, so the app fills the view and you can use it normally.
2. If you stay in 3D mode, use the Neckband instead of a D-pad (it has none). Short presses of Volume Up and Volume Down move the focus ring; hold Volume Down to select the focused control and hold Volume Up to go back. You can also turn on headgaze (press Settings and Power together), then Volume Down selects and Volume Up goes back. No ADB command is needed to control the app.
3. If you used 2D mode to navigate, switch back to 3D mode before the Capture 6DoF pose step, since that step needs stereo rendering.

Diagnostic capture for this case. Run these and include the output in the zip:

- APK version: `adb shell dumpsys package com.onyxlens.wmr_companion | grep -E "versionName|versionCode"`
- Display size: `adb shell wm size`
- Display info: `adb shell dumpsys display | grep -iE "DisplayDeviceInfo|size=|density=|mode="`
- Logs: `adb logcat -v threadtime > wmr-neckband-sbs-<YYYYMMDD-HHMMSS>.log`

If the Neckband is connected over wireless ADB, connect first: `adb connect <neckband-ip>:5555`.

Record the values in the intake block. Do not reconstruct them from memory.

### 6E : Neckband 0DoF / 6DoF triage (v0.3.13)

On a Luma Ultra with a Pro Neckband the app opens on a 32:9 side-by-side
viewport (3840x1080). In v0.3.10 and earlier the app could open and then drop
to 0DoF, with the **6DoF only** button greyed out, even though the UI looked
correct. Two causes, both fixed in v0.3.11:

1. The Unity player is created lazily during a VITURE start, after
   `MainActivity` has already run `onResume` and `onWindowFocusChanged`. The
   first host left the player paused and unfocused, so the VITURE XR loader
   never became active. v0.3.11 resumes and focuses the player once per
   successful host, and runs Flutter in transparent background mode so the
   Unity surface keeps compositing underneath.
2. 6DoF needs the VITURE XR source to be running and rendering in stereo 3D
   (SpaceWalker mode). Until that source starts, the app is 0DoF. A 2D /
   mono player fails closed with `unavailable` instead of stalling.

**Hand tracking source behaviour.** Detection runs automatically on startup for
every host: the app picks VITURE or XREAL from the device that is actually
connected. There is no tracking-source dropdown. Tap **Re-detect** to run
detection again. If nothing is detected, or both vendor USB IDs are attached,
the app stays on 3DoF and offers a **Simulated** 6DoF fallback. The button
**6DoF only** is enabled only while a started source reports hand joints. A
status line shows the current state:

- `6DoF: <source> hand tracking attached (<runtime> runtime).` when 6DoF is available.
- `0DoF: No VITURE, XREAL or Android XR glasses were detected` when nothing is detected.
- `0DoF: <source> is not built into this app.` when the flag is off.
- `Starting <source>...` while it starts.
- `0DoF: <source> failed to start (<kind>).` on a start failure.
- `0DoF: VITURE XR stereo is inactive, so hand tracking cannot start. Switch the glasses to 3D (SpaceWalker) and tap Re-detect.` when the glasses are in 2D mode.
- `0DoF: <source> does not report hand joints.` when the source runs but reports no joints.
- `0DoF: <message>.` for any other failure.

If the app still shows 0DoF on v0.3.13, capture logs and record the status line.

**Launch crash and input (ONY-802).** v0.3.12 is the first release on
`unity-export-1.2`: the Unity player is pinned to OpenGL ES 3 so VITURE's
display provider no longer takes the Vulkan stop path, and the loader gate
starts only VITURE's hand subsystem on a player that is not GLES3 as a
fallback. The hosted Unity view no longer takes input focus, so the Flutter UI
keeps its own focus and stays visible. A Pro Neckband has no D-pad, so use its
volume rocker instead: short Volume Up and Volume Down presses move the focus
ring, holding Volume Down selects the focused control, and holding Volume Up
goes back. With headgaze on (Settings + Power), Volume Down selects and Volume
Up goes back. Do not use ADB to inject touches as a control path. None of this
has been verified on hardware yet. If the app still crashes or the rocker does
nothing, capture the log and the tombstone.

**ADB triage for this case.** Connect first if wireless: `adb connect <neckband-ip>:5555`. Then run:

- APK version: `adb shell dumpsys package com.onyxlens.wmr_companion | grep -E "versionName|versionCode"`
- Display size: `adb shell wm size`
- Display info: `adb shell dumpsys display | grep -iE "DisplayDeviceInfo|size=|density=|mode="`
- Logs: `adb logcat -v threadtime > wmr-neckband-0dof-<YYYYMMDD-HHMMSS>.log`
- Filter: `grep -iE "WmrTracking|TrackingException|stage=|stereo=|UnityPlayer|playerHosted|0DoF|6DoF|spacewalker|running in 2d" wmr-neckband-0dof-*.log`

Record the status line and the highest `stage=` / `stereoMode` reached. Do not reconstruct them from memory.

### 6H : Pro Neckband 6DoF launch and recovery (v0.3.13)

Use only the controls that exist on the Pro Neckband. There is no D-pad. The
controls are: Power, Volume Up/Down, Settings, the pointer/air-mouse, hand
gestures, the Neckband Remote app, or a paired Bluetooth controller.

Launch into 6DoF:

1. Put the glasses in 3D mode (SpaceWalker). A 2D/mono player fails closed with `unavailable`.
2. Power on the Neckband and open WMR Companion. The app auto-detects VITURE and shows a status line.
3. If the status line shows 0DoF, tap Re-detect. Wait for `6DoF: Auto (USB) hand tracking attached`.
4. Use the volume rocker to move focus: short Volume Up/Down presses move the focus ring, hold Volume Down selects, hold Volume Up goes back. With headgaze on (Settings + Power), Volume Down selects and Volume Up goes back.
5. Start the guided bench 6DoF only path, or open Capture 6DoF pose.

Recovery if the app drops to 0DoF or shows a black screen:

1. Check the status line. If it says `VITURE XR stereo is inactive`, switch the glasses to 3D and tap Re-detect.
2. If the Unity player crashed (black screen, then close), reopen the app. The hand-only UaaL path in v0.3.13 keeps the display provider from taking over the host activity, so a reopen should recover.
3. If 6DoF stays greyed, capture the highest `stage=` and `stereoMode` from the debug overlay and the logcat below.
4. Do not use ADB to inject touches as a control path.

Logcat request for ONY-838 (crash mid-bench, then stuck in 0DoF with a pink cube):

Run these and include the output in the zip:

- `adb connect <neckband-ip>:5555` (if wireless)
- `adb shell dumpsys package com.onyxlens.wmr_companion | grep -E "versionName|versionCode"`
- `adb shell wm size`
- `adb logcat -v threadtime -d > wmr-neckband-ony838-<YYYYMMDD-HHMMSS>.log`
- Filter: `grep -iE "WmrTracking|TrackingException|stage=|stereo=|UnityPlayer|playerHosted|0DoF|6DoF|spacewalker|running in 2d|pink|cube|VitureDisplayProvider|GfxThread" wmr-neckband-ony838-*.log`

Record the status line, the highest `stage=` / `stereoMode`, and whether a pink cube or black screen appeared. Do not reconstruct them from memory.

## 7.5. Log capture (all setups)

Capture logs for every run and include them in the zip:

- Android: `adb logcat -v threadtime > wmr-<setup>-<YYYYMMDD-HHMMSS>.log`
- Filter for tracking problems: `grep -iE "WmrTracking|TrackingException|stage=|stereo=|UnityPlayer|playerHosted" wmr-*.log`
- Bridge serial: save the `STREAM`/`LINKLOG` lines as `wmr-serial-<timestamp>.txt`.
- Screenshot the debug overlay showing `playerHosted`, `stereoMode` and `stage` (VITURE) or the permission list (Android XR).
- If a file is missing, say which; do not reconstruct numbers from memory.

## 7. Send

Zip the exported files + the intake block below. Send in the thread where you received this runbook.

### Intake block

```markdown
### WMR external test : Tier 0

- Path: A (bridge + WMR) / B (6DoF only) / C (bridge + PSVR2)
- Handle:
- Date/timezone:
- Firmware: 0.3.3
- App: <versionName from ADB> unified (signed release) (expected 0.3.13; confirm the release exists and the installed APK reports it before testing)
- Host: Neckband / Android XR headset / phone (make/model/OS)
- Phone: make/model/Android
- Controllers: make/model (WMR / PSVR2), or none
- Result: PASS / PARTIAL / FAIL / BLOCKED
- Pairing: BOTH controllers paired together ____
- LED: red / yellow / blue / green
- MTU shown: ____
- Neckband SBS: black right eye / full screen / n/a
- Hand tracking source: auto-detected (VITURE / XREAL / Android XR) / Simulated
- 0DoF status line: ____
- 6DoF only enabled: yes / no
- ADB wm size: ____
- ADB display mode: ____
- Files: manifest, exports
- What happened (3 lines max):
```