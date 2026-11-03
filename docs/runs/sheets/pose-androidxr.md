# Run sheet: pose validation — Android XR (Aura-class headset)

> **Proposed sheet, not yet run.** Nothing here is a hardware result. Every figure is recorded by the owner; all result tables are empty and must not be pre-filled. The adapter is implemented and host-tested, but no device run has happened.

Companion documents:

- App [`docs/tracking/GATES.md`](https://github.com/nightcinder/wmr-companion/blob/main/docs/tracking/GATES.md) — gates 1, 2, 6, 7, 8 (this sheet). Gates 3–5 are covered by the VITURE and XREAL sheets.
- App [`docs/STATUS.md`](https://github.com/nightcinder/wmr-companion/blob/main/docs/STATUS.md) — what is implemented vs. unverified.
- App [`docs/CAMERAS.md`](https://github.com/nightcinder/wmr-companion/blob/main/docs/CAMERAS.md) — why the tracking cameras are unreachable.
- WMR_Bridge [`docs/DECODING.md`](https://github.com/nightcinder/WMR_Bridge/blob/main/docs/DECODING.md) — controller IMU/protocol reference.

Gates covered: **1** (capture one frame), **2** (Android XR smoke test), **6** (RayNeo/Rokid presence, optional), **7** (clock), **8** (fallback quality).

## 0. What this sheet settles

- Whether the Android XR headset can deliver a head pose and 26 hand joints while a hand grips a WMR controller, at what rate, and under which permission prompts.
- Whether the IR/optical question is settled by the passthrough camera (tracking cameras are unavailable on Android XR).
- Whether the aligner offset stays stable and frames stay inside the 100 ms window (gate 7).
- Whether `headRelative` is honest about not being positional tracking (gate 8).

## 1. Prerequisites and builds

Stop before starting if any required row is false.

| Item | Required |
|---|---|
| Headset | Android XR device/glasses with an Android XR runtime and outward passthrough camera: Samsung Galaxy XR, "Aura or similar", or a dev kit. Record model and Android version. |
| WMR bridge | One board on `main`, flashed, powered, both controllers paired and awake. Record firmware short SHA and boot banner. |
| App build | Debug APK from wmr-companion `main` **after** ONY-212, built with `--dart-define=WMR_ANDROID_XR_TRACKING=true`. Record app commit. |
| Permissions | `android.permission.CAMERA`, `android.permission.SCENE_UNDERSTANDING_COARSE`, `android.permission.HAND_TRACKING` and `android.permission.HEAD_TRACKING` declared in the manifest (shipped by the plugin). `SCENE_UNDERSTANDING_FINE` ("Precise movement and area data") is **not** requested; its appearance is a regression. |
| Host phone | Only needed if the headset is a display-glasses host; for a standalone XR headset the app runs on the device. One client at a time. |
| Tooling | `adb`, a terminal, and a way to capture `adb logcat` to a file. |
| Controller state | Both controllers charged, connected, awake for the whole sitting. |

Build the APK:

```bash
cd apps/wmr_companion_app
flutter build apk --debug --dart-define=WMR_ANDROID_XR_TRACKING=true
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

Confirm the flag is live: the debug overlay shows "Android XR tracking: available" when `AndroidXrTrackingSource.create()` does not return null.

## 2. Setup, once per sitting

1. Put the bridge in its usual place, controllers on taped marks ~0.5 m from it, phone/host off to the side. Photo the setup.
2. Start the serial monitor and save it: `adb logcat` is separate; for the bridge use its serial/monitor capture. At the start of every run copy the `STREAM ...` block.
3. Confirm `bridge_hands=0` (both hands). If 1 or 2, this is a single-hand build and the both-hands blocks cannot run as written.
4. Connect the app to the bridge, select **Batched FF14**, confirm `STREAM` shows `stream=batched`, `sub=1`, live `rate_rx`.
5. Record cold-start battery/temperature spot values if sharing the sitting with a tracking-quality run (optional).
6. Set the Madgwick beta to 0.05 and leave calibration off unless a run says otherwise.

## 3. Gate 1 — capture one frame per device (IR question)

**Question:** does the Android XR passthrough camera show the WMR controller LEDs, and what does that settle for optical work? (Tracking cameras are unavailable on Android XR; only passthrough RGB is permitted.)

Procedure:

1. In a dim room, power on both WMR controllers so their IR/LEDs are active (or hold a lit LED near the controller).
2. Open the Android XR passthrough camera view in the companion app (or the system camera preview if the app exposes it).
3. Capture a still frame and a 5 s video with the controllers at ~0.5 m, ~1.0 m and ~1.5 m, in three orientations each.
4. Save as `pose-androidxr-gate1-<distance>-<orientation>.jpg` / `.mp4`.

Record:

| Item | Value (user-reported) |
|---|---|
| Headset model / Android | |
| Frame captured? (yes/no) | |
| LEDs visible in passthrough? | |
| Distance at which LEDs disappear | |
| Camera resolution / fps | |
| Permission prompt shown | |

**Pass for 1.0:** a frame is captured and the LED visibility is recorded for at least three distances. Fail only if no frame can be captured at all.

## 4. Gate 2 — Android XR plugin smoke test

**Question:** do permissions, both modes and the joint/head stream work on a real device, and is a hand tracked while gripping a WMR controller?

Procedure:

1. Launch the app with the flag on. From the debug overlay tap **Start tracking (Android XR)**.
2. Accept the permission prompts: `CAMERA`, `SCENE_UNDERSTANDING_COARSE` ("movement and area data"), `HAND_TRACKING` and `HEAD_TRACKING`. Record whether each was granted, denied, or "not applicable". A prompt for "Precise movement and area data" (`SCENE_UNDERSTANDING_FINE`) must not appear; if it does, stop and record it as a regression.
3. Confirm the Kotlin side configures `HandTrackingMode.BOTH` and `DeviceTrackingMode.SPATIAL`. If `SPATIAL` throws `UnsupportedOperationException`, record it as `unsupported` and stop this gate.
4. With the hand empty and visible, log for 60 s. Record head-pose rate and joint rate from `adb logcat`.
5. Repeat with the hand gripping a WMR controller (controller awake, not streaming). Record whether joints still arrive.
6. Stop, then repeat start/stop 3 times to check idempotency; record any crash or stale session.
7. Force activity recreation (rotate/relaunch) and confirm tracking reports `unavailable` and restarts cleanly.

Capture logcat for the whole gate:

```bash
adb logcat -v threadtime > pose-androidxr-gate2-<YYYYMMDD-HHMMSS>.log
```

Filter for the tracking tag when reading: `grep -iE "WmrTracking|TrackingException|stage=" pose-androidxr-gate2-*.log`. Record `TrackingException.stage` for any failure.

Record:

| Item | Value (user-reported) |
|---|---|
| Permission CAMERA | granted / denied |
| Permission SCENE_UNDERSTANDING_COARSE | granted / denied |
| Permission HAND_TRACKING | granted / denied |
| Permission HEAD_TRACKING | granted / denied / n/a |
| `SCENE_UNDERSTANDING_FINE` prompt appeared? (must be no) | |
| SPATIAL mode | supported / unsupported |
| Head-pose rate (Hz) | |
| Joint rate, empty hand (Hz) | |
| Joint rate, gripping controller (Hz) | |
| Hand tracked while gripping? (yes/no/partial) | |
| Joints present (count of 26) | |
| Idempotent start/stop (yes/no) | |
| Activity recreation (clean restart yes/no) | |
| Errors / exceptions | |
| `TrackingException.stage` on failure (permissions/sessionCreate/sessionConfigure/trackingStart) | |

**Pass for 1.0:** permissions granted (or documented denial), `SPATIAL` supported, joints arrive at >0 Hz for an empty hand, and the gripping-hand result is recorded. A "no" for gripping is a valid, recorded result, not a failure of the sheet.

## 5. Gate 6 — RayNeo X3 Pro / Rokid AR Studio presence (optional)

Only if the hardware is on hand. Otherwise mark "not run — no hardware" and leave the table empty.

RayNeo X3 Pro:

1. Install a Unity ARDK build that enables SLAM head control (`Algorithm.EnableSlamHeadTracker()`).
2. Log `Algorithm.GetSlamStatus()` until `FFVINS_TRACKING_SUCCESS` (or `FFVINS_TRACKING_FAIL`).
3. Capture `HeadTrackedPoseDriver.OnPostUpdate` rate for 60 s.
4. Record whether the VGA spatial camera feed is reachable outside the ARDK.

Rokid AR Studio (Max Pro + Station Pro):

1. Run a UXR 3.0 Unity scene; log which gestures `InputManager` emits.
2. Record whether any joint data is reachable from C# (expected: gesture-only).

Record:

| Item | RayNeo X3 Pro | Rokid AR Studio |
|---|---|---|
| SLAM reaches TRACKING_SUCCESS? | | |
| Head-pose rate (Hz) | | |
| Hand joints reachable? | | |
| Gestures emitted | | |
| VGA spatial camera reachable? | n/a | |

**Pass for 1.0:** status and rates recorded; if gesture-only, the anchor path is recorded as unavailable (not a failure).

## 6. Gate 7 — clock test

**Question:** is the aligner offset stable and do frames stay inside the 100 ms window for a minute?

Procedure:

1. With tracking running and the bridge streaming FF14, log controller `receivedAtUs` and tracking host timestamps together for 60 s.
2. The app already aligns via `SourceClockAligner`; capture the logcat lines that print the offset and per-frame age.
3. Compute: offset mean and standard deviation over the minute; max frame age; count of frames older than 100 ms; count of offset rebases (>1 s jump).

Record:

| Item | Value (user-reported) |
|---|---|
| Duration (s) | |
| Offset mean (ms) | |
| Offset std (ms) | |
| Max frame age (ms) | |
| Frames older than 100 ms (count / %) | |
| Offset rebases (count) | |
| Backwards jumps > 1 s (count) | |

**Pass for 1.0:** offset std < 5 ms and <1% of frames older than 100 ms. Fail if offset drifts or >5% of frames are stale.

## 7. Gate 8 — fallback quality test

**Question:** does `headRelative` fail as positional tracking, and is that failure recorded so it is not sold as 6DoF?

Procedure:

1. Stand at a fixed mark 1.0 m from the bridge. Start tracking.
2. Hold the controller at a known physical point (tape mark) at arm's length.
3. Nod (pitch ±20°, 10 reps), then walk 2 m forward and back, then turn 90° in place.
4. Record the reported controller position error against the physical mark at each step (tape measure or known offset).
5. Repeat with the hand anchor available (empty hand) and with it unavailable (gripping controller) to compare.

Record:

| Motion | Anchor available? | Reported position error (cm) | Notes |
|---|---|---|---|
| Static, arm's length | yes | | |
| Nod ±20° | yes | | |
| Walk 2 m and back | yes | | |
| Turn 90° in place | yes | | |
| Static, gripping controller | no (headRelative) | | |
| Nod, gripping controller | no (headRelative) | | |

**Pass for 1.0:** the test is run and the failure of `headRelative` as positional tracking is recorded. This gate passes by documenting the failure, not by achieving accuracy.

## 8. How to attach recorded pose files

During each gate, capture:

1. `adb logcat -v threadtime > pose-androidxr-<gate>-<YYYYMMDD-HHMMSS>.log`
2. Any app-exported JSON/CSV tracking frames, via Share or `adb pull <path>`; name them `pose-androidxr-<gate>-<timestamp>.json`.
3. The serial-monitor capture (bridge `STREAM`/`LINKLOG` lines) as `pose-androidxr-serial-<timestamp>.txt`.
4. Photos of the setup and any permission dialogs.

After the sitting:

1. Put all files in a folder `pose-androidxr-<YYYYMMDD>/`.
2. Zip: `zip -r pose-androidxr-<YYYYMMDD>.zip pose-androidxr-<YYYYMMDD>/`.
3. Compute `sha256sum pose-androidxr-<YYYYMMDD>.zip` and record it.
4. Attach the zip (and the folder if small) to the issue/PR thread. In the run log, record the zip filename and SHA-256 next to the gate it covers.
5. If attaching is impossible, paste the logcat excerpt and the `STREAM` lines and state which files are missing; do not reconstruct numbers from memory.

## 9. Result tables (user-reported)

All values below are filled by the owner after the sitting. None are pre-filled.

### Gate 1 — frame capture

| Distance | LEDs visible? | Frame file |
|---|---|---|
| 0.5 m | | |
| 1.0 m | | |
| 1.5 m | | |

### Gate 2 — smoke test

(see §4 record table)

### Gate 6 — presence (optional)

(see §5 record table)

### Gate 7 — clock

(see §6 record table)

### Gate 8 — fallback quality

(see §7 record table)

### Invalid / repeated runs

| Gate | Run id | Reason | Repeated as |
|---|---|---|---|
| | | | |

## 10. Pass/fail criteria for 1.0

A vendor path counts as "6DoF supported" for 1.0 only if all of the following hold; otherwise it is recorded as "head-relative fallback only" or "3DoF only".

- Gate 1 recorded (frame captured or reason recorded).
- Gate 2: permissions outcome recorded; if `SPATIAL` unsupported, path is not 6DoF-capable and the reason is recorded.
- Gate 7: pass (offset stable, <1% stale frames).
- Gate 8: failure of `headRelative` as positional tracking recorded.

For Android XR specifically, 6DoF-capable additionally requires joints arriving while gripping a controller. If gripping kills tracking, the hand-anchor path is unusable while gripping and the path is "head-relative fallback only (grip kills tracking)".

## 11. Paste-back block

At the end of the sitting, paste back:

1. Every logcat file and exported JSON/CSV from gates 1–8, with the run log.
2. The `STREAM ...` block at the start and end of every run and the `LEFT link:` / `RIGHT link:` lines.
3. The zip filename and SHA-256 for each gate's files.
4. The filled result tables above.
5. Any invalid or repeated run, with the reason.

No number should be reconstructed from the debug panel if a file is missing; say which file is missing.

## 12. What this sheet cannot show

- Whether a hand holding a WMR controller stays tracked in practice over a long session (only a 60 s check here).
- Absolute orientation accuracy against an independent reference.
- Behaviour on headset models not tested.
- Whether the passthrough camera can feed future optical work (it is RGB, not IR).
- Any firmware or app change; this sheet changes neither.
