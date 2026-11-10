# Run sheet: pose validation - Android XR (Aura-class headset)
Status: active. The 0.3.15 and 0.3.16 builds ran on a Google Aura headset for pose captures; both missed the 10-50 cm/s speed gate. Result tables below record gate criteria.

Gates: 1, 2, 6 (optional), 7, 8. See [GATES.md](../../tracking/GATES.md).

## 1. Prerequisites
| Item | Required |
|---|---|
| Headset | Android XR device with an outward passthrough camera: Samsung Galaxy XR, Aura or similar, or a dev kit. Record model and Android version. |
| Bridge | One board on `main`, flashed, powered, both controllers paired and awake. Record firmware SHA and boot banner. |
| App | Signed v0.3.19 unified APK (versionCode 2024). It carries Android XR, VITURE, and XREAL tracking; no manual build flags are needed. Record the commit. |
| Permissions | `CAMERA`, `SCENE_UNDERSTANDING_COARSE`, `HAND_TRACKING`, `HEAD_TRACKING` declared. `SCENE_UNDERSTANDING_FINE` ("Precise movement and area data") must not be requested; its appearance is a regression. |
| Tooling | `adb`, a terminal, logcat capture. |
| Controllers | Both charged, connected and awake for the sitting. |

Download: `https://github.com/nightcinder/wmr-companion/releases/download/v0.3.19/wmr-companion-0.3.19-unified-arm64-v8a.apk`. Install: `adb install -r wmr-companion-0.3.19-unified-arm64-v8a.apk`. The debug overlay shows "Android XR tracking: available" when running on an Android XR device.

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
