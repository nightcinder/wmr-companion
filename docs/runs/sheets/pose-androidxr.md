# Run sheet: pose validation - Android XR (Aura-class headset)
Status: active. The 0.3.15 and 0.3.16 builds ran on a Google Aura headset for pose captures; both missed the 10-50 cm/s speed gate. Result tables below record gate criteria.

Gates: 1, 2, 6 (optional), 7, 8. See [GATES.md](../../tracking/GATES.md).

## 1. Prerequisites
| Item | Required |
|---|---|
| Headset | Android XR device with an outward passthrough camera: Samsung Galaxy XR, Aura or similar, or a dev kit. Record model and Android version. |
| Bridge | One board on `main`, flashed, powered, both controllers paired and awake. Record firmware SHA and boot banner. |
| App | Signed v0.3.27-rc.2 unified APK (`com.onyxlens.wmr_companion`, `versionCode` 2035, `versionName` 0.3.27). It carries Android XR, VITURE, and XREAL tracking; no manual build flags are needed. Record the commit. |
| Permissions | `CAMERA`, `SCENE_UNDERSTANDING_COARSE`, `HAND_TRACKING`, `HEAD_TRACKING` declared. `SCENE_UNDERSTANDING_FINE` ("Precise movement and area data") must not be requested; its appearance is a regression. |
| Tooling | `adb`, a terminal, logcat capture. |
| Controllers | Both charged, connected and awake for the sitting. |

Download: `https://github.com/nightcinder/wmr-companion/releases/download/v0.3.27-rc.2/wmr-companion-0.3.27-rc.2-unified-arm64-v8a.apk` (SHA-256 `473cf034cb9ca8ae29d3e439b76fffecedea572a136042bd2920c88f1ffbacd1`). Install: `adb install -r wmr-companion-0.3.27-rc.2-unified-arm64-v8a.apk`. The debug overlay shows "Attached androidXr tracking" when running on an Android XR device.

## 2. Setup, once per sitting
1. Put the bridge in place, controllers on taped marks ~0.5 m away. Photo the setup.
2. Start logcat and the bridge serial capture. Copy the `STREAM` block at the start of every run.
3. Confirm `bridge_hands=0`; 1 or 2 means a single-hand build and the both-hands blocks cannot run.
4. Connect the app, select **Batched FF14**, confirm `stream=batched`, `sub=1`, live `rate_rx`.
5. Set Madgwick beta to 0.05 and leave calibration off unless a run says otherwise.

## 3. Gate 1 - capture one frame
1. In a dim room, power both controllers so their LEDs are active.
2. Open the passthrough camera view in the app, or the system camera preview.
3. Capture a still and a 5 s video at ~0.5 m, ~1.0 m and ~1.5 m, in three orientations each.
4. Save as `pose-androidxr-gate1-<distance>-<orientation>.jpg`/`.mp4`.

| Item | Value |
|---|---|
| Frame captured? | |
| LEDs visible in passthrough? | |
| Distance at which LEDs disappear | |
| Camera resolution / fps | |
| Permission prompt shown | |

Pass: a frame is captured and LED visibility is recorded for at least three distances. Fail only if no frame can be captured.

## 4. Gate 2 - plugin smoke test
1. From the debug overlay tap **Start tracking (Android XR)**.
2. Accept `CAMERA`, `SCENE_UNDERSTANDING_COARSE`, `HAND_TRACKING` and `HEAD_TRACKING`; record granted/denied. If a "Precise movement and area data" prompt appears, stop and record a regression.
3. Confirm Kotlin sets `HandTrackingMode.BOTH` and `DeviceTrackingMode.SPATIAL`. If `SPATIAL` throws `UnsupportedOperationException`, record `unsupported` and stop.
4. Log 60 s with an empty visible hand; record head and joint rates.
5. Repeat while gripping a WMR controller (awake, not streaming); record whether joints arrive.
6. Start/stop three times; record crashes or stale sessions.
7. Force activity recreation; tracking must report `unavailable` and restart cleanly.

```bash
adb logcat -v threadtime > pose-androidxr-gate2-<YYYYMMDD-HHMMSS>.log
grep -iE "WmrTracking|TrackingException|stage=" pose-androidxr-gate2-*.log
```

| Item | Value |
|---|---|
| Permissions: CAMERA / COARSE / HAND / HEAD | |
| `SCENE_UNDERSTANDING_FINE` prompt appeared? (must be no) | |
| SPATIAL mode | supported / unsupported |
| Head-pose rate (Hz) | |
| Joint rate, empty hand / gripping (Hz) | |
| Hand tracked while gripping? | |
| Joints present (of 26) | |
| Idempotent start/stop? | |
| Activity recreation restarts cleanly? | |
| Errors / `TrackingException.stage` | |

Pass: permissions granted or denial documented, `SPATIAL` supported, joints arrive for an empty hand, and the gripping result is recorded. A "no" for gripping is a valid result.

## 5. Gate 6 - RayNeo and Rokid (optional)
Only if the hardware is on hand; otherwise mark "not run - no hardware".

- RayNeo X3 Pro: install a Unity ARDK build with `Algorithm.EnableSlamHeadTracker()`; log `Algorithm.GetSlamStatus()` to `FFVINS_TRACKING_SUCCESS` or `FFVINS_TRACKING_FAIL`; capture `HeadTrackedPoseDriver.OnPostUpdate` rate for 60 s; record whether the VGA spatial camera is reachable outside the ARDK.
- Rokid AR Studio: run a UXR 3.0 scene; log which gestures `InputManager` emits and whether joint data is reachable from C# (expected gesture-only).

| Item | RayNeo X3 Pro | Rokid AR Studio |
|---|---|---|
| SLAM reaches TRACKING_SUCCESS? | | |
| Head-pose rate (Hz) | | |
| Hand joints reachable? | | |
| Gestures emitted | | |
| VGA spatial camera reachable? | n/a | |

Pass: status and rates recorded; gesture-only means the anchor path is unavailable, not a failure.

## 6. Gate 7 - clock test
Log controller `receivedAtUs` and tracking host timestamps together for 60 s. Capture the `SourceClockAligner` offset and per-frame age.

| Duration (s) | Offset mean (ms) | Offset std (ms) | Max age (ms) | Frames >100 ms | Rebases | Backward jumps >1 s |
|---|---|---|---|---|---|---|
| | | | | | | |

Pass: offset std < 5 ms and < 1% of frames older than 100 ms. Fail if the offset drifts or more than 5% are stale.

## 7. Gate 8 - fallback quality
1. Stand at a mark 1.0 m from the bridge, hold the controller at a taped point at arm's length, then nod (pitch +/-20 deg, 10 reps), walk 2 m forward and back, and turn 90 deg in place. Record position error against the mark.
2. Repeat with the hand anchor available (empty hand) and unavailable (gripping).

| Motion | Anchor? | Position error (cm) | Notes |
|---|---|---|---|
| Static, arm's length | yes | | |
| Nod +/-20 deg | yes | | |
| Walk 2 m and back | yes | | |
| Turn 90 deg in place | yes | | |
| Static, gripping | no (headRelative) | | |
| Nod, gripping | no (headRelative) | | |

Pass: the test is run and the failure of `headRelative` as positional tracking is recorded.

## 8. Guided speed checks (filter-spec rev 4 section 8)
Run the 6-run pose capture from the guided bench on the headset. The bench guides each segment:

1. LEFT still (0 cm/s): brace your forearm on a table. Keep your hand relaxed for 15 s. Scores static jitter J <= 0.5 mm.
2. RIGHT held, drifting (10-50 cm/s): hold your hand as if aiming. Move smoothly at 10-50 cm/s for 15 s. Do not move slower than 10 cm/s. Scores drift jitter J_D <= 0.75 mm.
3. LEFT slow pan (10 cm/s): move 30 cm sideways in 3 s (10 cm/s) back and forth for 18 s. Scores lag L <= 160 ms.
4. RIGHT medium pan (50 cm/s): move 50 cm sideways in 1 s (50 cm/s) back and forth for 15 s. Scores lag L <= 20 ms.
5. LEFT fast flick (150 cm/s): flick 45 cm in 0.3 s (150 cm/s), pause, and return for 20 s. Scores lag L <= 20 ms.
6. RIGHT occlusion: hold aim, then cover the hand for 1-2 s. Duration is 15 s. Diagnostic check only.

Make sure that segment D stays within the 10-50 cm/s speed band. The tuner drops samples below 10 cm/s.

| Segment | Speed | Bar | Result |
|---|---|---|---|
| LEFT still | 0 cm/s | J <= 0.5 mm | |
| RIGHT held, drifting | 10-50 cm/s | J_D <= 0.75 mm | |
| LEFT slow pan | 10 cm/s | L <= 160 ms | |
| RIGHT medium pan | 50 cm/s | L <= 20 ms | |
| LEFT fast flick | 150 cm/s | L <= 20 ms | |
| RIGHT occlusion | n/a | diagnostic | |

## 9. Send
Capture per gate: logcat `pose-androidxr-<gate>-<timestamp>.log`; exported JSON/CSV; bridge serial `pose-androidxr-serial-<timestamp>.txt`; setup and permission-dialog photos. Zip as `pose-androidxr-<YYYYMMDD>.zip`, record its SHA-256, and attach it with the filled tables. If a file is missing, say which; do not reconstruct numbers.

## 10. Pass/fail for 1.0
- Gate 1 recorded.
- Gate 2: permission outcome recorded; if `SPATIAL` is unsupported, the path is not 6DoF-capable.
- Gate 7 pass.
- Gate 8: failure of `headRelative` recorded.
- Guided speed checks pass (J <= 0.5 mm, J_D <= 0.75 mm, medium and fast lag <= 20 ms).
- Android XR needs joints arriving while gripping. If gripping kills tracking, the path is "head-relative fallback only (grip kills tracking)".

## 11. Aura combined sitting (pose and ONY-1338 DroidDeck)

Run this sitting in order on an XREAL Aura headset with a Raspberry Pi 3B+ bridge (onboard Bluetooth only) and two WMR controllers.

`needs counsel:` Aura-specific physical button bindings and system gestures are not in vendor docs in this repository. Use the on-screen Android and SteamVR controls, and record any Aura gesture you use.

### 11.1 Pi 3B+ Option C setup

1. On the Raspberry Pi 3B+ (64-bit Raspberry Pi OS Bookworm or Trixie), install `WMR_Bridge` `v0.3.28` (`wmr-bridge_0.3.28_all.deb`, SHA-256 `4b4b4f8b9d14f7c20b8bec55ff22dc199b50ccdb0694a4b4abeca8b8e7746c75`, or `install.sh` with `WMR_BRIDGE_TAG=v0.3.28` and `WMR_BRIDGE_VERSION=0.3.28`).
2. Keep Option C BLE load cuts enabled. Onboard `hci_uart` and `serial` Bluetooth adapters (`BCM4345C0`) turn on Option C load cuts by default (`MTU <= 247`, at most 4 records per FF14 PDU, `50 Hz/hand` FF14 decimation, and `0x2A4D` paused while `FF1x` streams), while TCP stays unthrottled at 200 Hz nominal.
3. Connect the Pi over Ethernet or 5 GHz Wi-Fi so Wi-Fi does not contend with 2.4 GHz Classic Bluetooth.
4. Pair both WMR controllers via BlueZ and record the boot banner (`journalctl -u wmr-bridge -n 50`) and installed package version (`0.3.28`).

### 11.2 Aura adb installs and DroidDeck check

1. Install the companion APK on Aura from a computer over `adb`: `adb install -r wmr-companion-0.3.27-rc.2-unified-arm64-v8a.apk`.
2. Make sure that the installed DroidDeck build on Aura is at or after `nightcinder/DroidDeck` `android-xr` commit `eb03e88`. Run `adb shell pm path <droiddeck-package>` and `adb shell dumpsys package <droiddeck-package> | grep -E "versionName|lastUpdateTime"`. If it predates `eb03e88`, rebuild and install from commit `dcbc017d`.
3. Start logcat on the computer before starting the tests: `adb logcat -v threadtime > aura-sitting-<YYYYMMDD>.log`.

### 11.3 6DoF pose gates and 6-run guided bench

1. Run sections 2 through 8 of this sheet: setup, Gate 1 (capture one frame), Gate 2 (plugin smoke test), optional Gate 6 (if RayNeo or Rokid hardware is on hand; otherwise mark "not run - no hardware"), Gate 7 (clock test), Gate 8 (fallback quality), and the guided speed checks.
2. On the **Connect** screen, open **Guided bench run** and select **Combined** (or **6DoF only**).
3. Complete the 6-run guided bench per [pose-filter.md](pose-filter.md) ("Capture protocol"): LEFT still (0 cm/s, forearm on table, 15 s), RIGHT held drifting (10-50 cm/s, 15 s), LEFT slow pan (10 cm/s, 18 s), RIGHT medium pan (50 cm/s, 15 s), LEFT fast flick (150 cm/s, 20 s), and RIGHT occlusion (15 s).
4. Export the TestBundle zip and record its SHA-256.

### 11.4 DroidDeck transport and M6-H1 through M6-H4

1. Connect the companion app to the Pi bridge in FF12 or FF14 mode on the Debug screen and attach Android XR tracking.
2. Start DroidDeck on Aura.
3. Open the **Gamepad** screen in `wmr-companion`, expand **DroidDeck 6DoF streaming**, and press **Start streaming**.
4. Record which transport connects. The app tries the abstract Unix domain socket (`droiddeck-ext-xr`) first. If that connect fails (for example, because SELinux blocks it), read the decimal uint32 token (`parseDroidDeckToken`, radix 10) from `droiddeck-ext-xr.token` in DroidDeck's private files directory (for example, `adb shell run-as <droiddeck-package> cat files/droiddeck-ext-xr.token` on a debuggable build, or `adb shell su -c "cat /data/data/<droiddeck-package>/files/droiddeck-ext-xr.token"` on a rooted device), enter it in **Pairing token (optional)**, and press **Start streaming** again to use loopback UDP on `127.0.0.1:29842`.
5. Run M6-H1 through M6-H4 from [TEST_PLAN_PI_WMR.md](../../TEST_PLAN_PI_WMR.md) (§M6):
   - M6-H1: Stream both controllers from the Pi bridge to DroidDeck for 5 minutes and log packets on DroidDeck (`sampleTimeNs` non-zero, strictly monotonic per hand, trails receive time by under 100 ms median).
   - M6-H2: Stop and restart the DroidDeck receiver during the run; output must resume within 2 s without restarting `wmr-companion`.
   - M6-H3: Test buttons, trigger, stick, and orientation in DroidDeck on the correct hand.
   - M6-H4: Turn Aura Wi-Fi off and back on during the run; DroidDeck input must continue across both switches with monotonic `sampleTimeNs`.

### 11.5 ONY-1338 controls, HID-role restore, and OS key-leak check

1. In SteamVR through DroidDeck, test each control on both hands and record pass or fail: trigger (analog), grip (squeeze), thumbstick X/Y, thumbstick click, trackpad X/Y, trackpad click, trackpad touch, and menu button.
2. Check the Bluetooth HID role restore (R1). Before starting the stream, note whether the companion's Bluetooth HID peripheral role (Option A) is on. Make sure that the companion's HID role stays off during the DroidDeck stream (the **Start** button in the Bluetooth HID panel is disabled). Press **Stop streaming** and make sure that the HID role restores if it was on before the stream started.
3. Check for OS key leaks. Press all controller buttons, thumbsticks, and trackpads while DroidDeck and SteamVR have focus, and record whether any Android OS key events leak to the system UI.

### 11.6 What to post on ONY-1338

Post the following artifacts and results on ONY-1338:

1. Exported TestBundle zip and its SHA-256.
2. Logcat capture (`aura-sitting-<YYYYMMDD>.log`).
3. Pi bridge `0.3.28` boot banner, DroidDeck `pm path` and `dumpsys package` output, and the transport used (UDS or UDP with token).
4. Pass or fail for every row: Gates 1, 2, 6 (or "not run - no hardware"), 7, and 8, guided speed checks, the 6-run guided bench, M6-H1 through M6-H4, each ONY-1338 control, the HID-role restore check, and the OS key-leak check.
