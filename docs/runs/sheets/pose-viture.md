# Run sheet: pose validation — VITURE (Pro Neckband + Luma Ultra)

> **Proposed sheet, not yet run.** Nothing here is a hardware result. Every figure is recorded by the owner; all result tables are empty and must not be pre-filled. The Unity-in-Flutter relay is implemented and host-tested, but no Neckband run has happened. Current code targets VITURE XR SDK 0.9.0 (`Viture.XR.VitureXR`) on Unity 6000.0.27f1; v0.7.0 is historical.

Companion documents:

- App [`docs/tracking/GATES.md`](https://github.com/nightcinder/wmr-companion/blob/main/docs/tracking/GATES.md) — gates 1, 3, 4, 7, 8, 9 (this sheet).
- App [`docs/STATUS.md`](https://github.com/nightcinder/wmr-companion/blob/main/docs/STATUS.md)
- VITURE XR Glasses SDK (C) and VITURE XR SDK for Unity (links in RESEARCH.md Sources).

Gates covered: **1** (capture one frame), **3** (Unity-in-Flutter smoke test), **4** (VITURE Neckband hand test), **7** (clock), **8** (fallback quality), **9** (VITURE C path, optional).

## 0. What this sheet settles

- Whether the Luma Ultra stereo grayscale frames show the WMR controller LEDs (gate 1).
- Whether a one-scene Unity UaaL plugin survives Flutter hot restart, activity recreation and pause/resume (gate 3).
- Whether `VitureXR.HandTracking` delivers 26 joints on a Pro Neckband + Luma Ultra, and whether a gripping hand stays tracked (gate 4).
- Whether the aligner is stable (gate 7) and `headRelative` is honest (gate 8).
- Optionally, whether the phone-only C SDK head-pose path works (gate 9).

## 1. Prerequisites and builds

| Item | Required |
|---|---|
| Glasses | VITURE Luma Ultra (6DoF + stereo cameras) for gates 1/4/9. 3DoF models (`One`, `OneLite`, `Pro`, `Pro2`, `Luma`, `LumaPro`, `LumaCyber`, `Beast`) are rejected by the adapter for hand tracking and must not be used for gate 4. An unreported model is not an error: `create()` succeeds and the Unity `start` handshake reports the real model. |
| Host | **VITURE Pro Neckband** (Android, wireless ADB) for gates 3/4/7/8 stereo checks. The app runs on the Neckband, not on a paired phone. Gate 9 (optional C path) needs an Android phone with USB host instead. |
| Unity | Unity 6000.0+ with Android build support, `com.unity.xr.hands`, VITURE XR SDK for Unity v0.9.0 (`com.viture.xr`, `Viture.XR.VitureXR`; v0.7.0 is historical). External SDK gate; not redistributable. |
| App build | Debug APK from wmr-companion `main` after ONY-612/ONY-617, built with `--dart-define=WMR_VITURE_TRACKING=true`, with the `unityLibrary` AAR linked (export pinned by CI). The VITURE slice requests `android.permission.CAMERA` only. Record app commit and export SHA. |
| Bridge | One board on `main`, both controllers paired and awake. Record firmware SHA and boot banner. |
| Tooling | `adb` (wireless for the Neckband), terminal, logcat capture, and a way to screenshot the debug overlay. |

Build the APK (after exporting the Unity `unityLibrary` AAR per FRAMEWORK.md "Packaging"):

```bash
cd apps/wmr_companion_app
flutter build apk --debug --dart-define=WMR_VITURE_TRACKING=true
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

Confirm the flag is live: the debug overlay shows "VITURE tracking: available" when the plugin reports the AAR linked; otherwise it reports `unavailable`.

## 2. Setup, once per sitting

1. Power the Neckband, enable wireless ADB, confirm `adb connect <ip>:5555` succeeds.
2. Put the bridge in its usual place, controllers on taped marks ~0.5 m from it. Photo the setup.
3. Start the serial monitor (bridge) and a logcat capture (Neckband).
4. Connect the app to the bridge, select **Batched FF14**, confirm `STREAM` shows `stream=batched`, `sub=1`, live `rate_rx`. Confirm `bridge_hands=0`.
5. Confirm the glasses model reported by the app is `LumaUltra` before gate 4; if it is a 3DoF model, gate 4 fails with `unsupported` and must be recorded as such.
6. From the debug overlay, record the VITURE `start` reply fields: `playerHosted`, `stereoMode` and `stage`. A healthy run reaches `playerHosted` → `loaderStarted` → `firstFrame` with `stereoMode` one of `multiPass`/`singlePass`/`singlePassInstanced`. If `stereoMode` is `unknown` or the stage stops at `playerHosted`/`loaderStarted`, record it and stop; the loader is not rendering in stereo 3D (SpaceWalker mode). A 2D/mono player fails closed with `unavailable`.
7. Capture logcat for every gate (see §9): `adb logcat -v threadtime > pose-viture-gate<N>-<timestamp>.log`, then filter with `grep -iE "WmrTracking|TrackingException|stage=|stereo=|UnityPlayer|playerHosted"`.

## 3. Gate 1 — capture one frame per device (IR question)

**Question:** do the Luma Ultra stereo grayscale frames show the WMR controller LEDs?

Procedure:

1. Power on both WMR controllers (LEDs active). Dim the room.
2. Run the companion's VITURE camera preview (or a minimal Unity scene reading `register_callbacks_carina`) to capture the four grayscale buffers (left/right primary and secondary) at 25 Hz.
3. Capture frames with controllers at ~0.3 m, ~0.5 m, ~1.0 m, in three orientations each.
4. Save as `pose-viture-gate1-<distance>-<orientation>.png`.

Record:

| Item | Value (user-reported) |
|---|---|
| Glasses model | Luma Ultra |
| Frames captured? (yes/no) | |
| LEDs visible in grayscale? | |
| Distance at which LEDs disappear | |
| Frame rate observed (Hz) | |
| Exposure/gain used | |

**Pass for 1.0:** frames captured and LED visibility recorded for at least three distances.

## 4. Gate 3 — Unity-in-Flutter smoke test

**Question:** does a one-scene UaaL plugin survive Flutter hot restart, activity recreation and Unity pause/resume, and do JSON frames round-trip?

Procedure:

1. Launch the app with the flag on. From the debug overlay tap **Start tracking (VITURE)**.
2. Confirm the Unity player starts and the C# bridge receives `start` via `UnitySendMessage`.
3. Confirm poses arrive in Dart via the JNI callback as `TrackingFrameCodec` JSON.
4. Run for 60 s; record frame rate and any dropped frames.
5. Trigger Flutter hot restart (`r` in `flutter run`); confirm tracking stops and restarts without a crash.
6. Force activity recreation (rotate the device / relaunch); confirm `unavailable` is reported and a manual restart recovers.
7. Background the app for 30 s, then foreground; confirm Unity pause/resume does not deadlock the channel.

Capture logcat:

```bash
adb logcat -v threadtime > pose-viture-gate3-<YYYYMMDD-HHMMSS>.log
```

Record:

| Item | Value (user-reported) |
|---|---|
| Unity player starts? (yes/no) | |
| `start` command received by C#? | |
| JSON frames arrive in Dart? | |
| Frame rate (Hz) | |
| Hot restart survives? | |
| Activity recreation recovers? | |
| Pause/resume deadlocks? | |
| Unity→OpenXR conversion within 1e-6? | |
| `playerHosted` (true/false) | |
| `stereoMode` (multiPass/singlePass/singlePassInstanced/unknown) | |
| Highest stage reached (playerHosted/loaderStarted/firstFrame) | |
| Stereo timeout error (10 s loader / 20 s frame)? | |

**Pass for 1.0:** commands round-trip, frames arrive, and no deadlock across hot restart / recreation / pause-resume. If the AAR is not linked, record `unavailable` and stop; the gate is not failed, it is blocked on the SDK gate.

## 5. Gate 4 — VITURE Neckband hand test

**Question:** does `VitureXR.HandTracking.Start()` deliver 26 joints, and is a hand tracked while gripping a WMR controller?

Procedure:

1. Confirm glasses model is `LumaUltra` (gate fails with `unsupported` otherwise).
2. Start tracking. With the hand empty and visible, log for 60 s.
3. Record joint count and rate.
4. Repeat with the hand gripping a WMR controller (controller awake, not streaming). Record whether joints still arrive.
5. Tap recenter and confirm `VitureXR.HeadTracking.SetWorldOrigin()` recentres the head pose.
6. Stop and dispose; confirm no leak on repeat.

Capture logcat:

```bash
adb logcat -v threadtime > pose-viture-gate4-<YYYYMMDD-HHMMSS>.log
```

Record:

| Item | Value (user-reported) |
|---|---|
| Glasses model | |
| Head-pose rate (Hz) | |
| Joint rate, empty hand (Hz) | |
| Joint rate, gripping controller (Hz) | |
| Hand tracked while gripping? (yes/no/partial) | |
| Joints present (count of 26) | |
| Recenter works? | |
| Errors / exceptions | |
| `playerHosted` (true/false) | |
| `stereoMode` | |
| Highest stage reached | |

**Pass for 1.0:** joints arrive at >0 Hz for an empty hand and the gripping-hand result is recorded. "No" for gripping is a valid recorded result.

## 6. Gate 7 — clock test

Same procedure as the Android XR sheet §6, with the VITURE source. Log controller `receivedAtUs` and tracking host timestamps for 60 s; record offset mean/std, max frame age, stale-frame count, rebases.

Record:

| Item | Value (user-reported) |
|---|---|
| Duration (s) | |
| Offset mean (ms) | |
| Offset std (ms) | |
| Max frame age (ms) | |
| Frames older than 100 ms (count / %) | |
| Offset rebases (count) | |

**Pass for 1.0:** offset std < 5 ms and <1% stale frames.

## 7. Gate 8 — fallback quality test

Same procedure as the Android XR sheet §7, with the VITURE source (head pose + hand anchor when available). Record reported position error vs. physical mark while nodding and walking, with and without the hand anchor.

Record:

| Motion | Anchor available? | Reported position error (cm) | Notes |
|---|---|---|---|
| Static, arm's length | yes | | |
| Nod ±20° | yes | | |
| Walk 2 m and back | yes | | |
| Turn 90° in place | yes | | |
| Static, gripping controller | no (headRelative) | | |
| Nod, gripping controller | no (headRelative) | | |

**Pass for 1.0:** test run and the failure of `headRelative` as positional tracking recorded.

## 8. Gate 9 — VITURE C path (optional, phone-only head pose)

Only if a Luma Ultra and an Android phone with USB host are available and the Neckband path is not.

Procedure:

1. Wrap `libglasses` via FFI (or use a test harness) and call `get_gl_pose_carina` (Carina/Luma Ultra) on a background thread.
2. Measure pose rate and status flag for 60 s.
3. Record USB permission behaviour (`UsbDeviceConnection` fd hand-off, permission prompt).
4. Record whether `set_dof_type_carina` (3DoF vs 6DoF) is required and what happens if it is skipped.

Record:

| Item | Value (user-reported) |
|---|---|
| Pose rate (Hz) | |
| Status flag behaviour | |
| USB permission prompt? | |
| 6DoF selectable? | |
| Errors | |

**Pass for 1.0:** if it works, recorded as the lowest-friction phone-only head-pose source. If it fails, recorded as blocked; the Neckband path remains the only VITURE hand path.

## 9. How to attach recorded pose files

During each gate, capture:

1. `adb logcat -v threadtime > pose-viture-<gate>-<YYYYMMDD-HHMMSS>.log` (wireless ADB for the Neckband). Read it with `grep -iE "WmrTracking|TrackingException|stage=|stereo=|UnityPlayer|playerHosted"`; record the highest stage and `stereoMode`.
2. Screenshot the debug overlay showing `playerHosted`, `stereoMode` and `stage` for each start attempt (this is the field a tester can read without parsing logs).
3. Any app-exported JSON/CSV tracking frames, via Share or `adb pull <path>`; name them `pose-viture-<gate>-<timestamp>.json`.
4. The bridge serial capture as `pose-viture-serial-<timestamp>.txt`.
5. Unity player logs if available (`pose-viture-unity-<timestamp>.log`).
6. Photos of the setup.

After the sitting:

1. Put all files in a folder `pose-viture-<YYYYMMDD>/`.
2. Zip: `zip -r pose-viture-<YYYYMMDD>.zip pose-viture-<YYYYMMDD>/`.
3. Compute `sha256sum pose-viture-<YYYYMMDD>.zip`.
4. Attach the zip to the issue/PR thread and record filename + SHA-256 in the run log.
5. If attaching is impossible, paste the logcat excerpt and `STREAM` lines and state which files are missing.

## 10. Result tables (user-reported)

All values filled by the owner after the sitting. None pre-filled.

### Gate 1 — frame capture

| Distance | LEDs visible? | Frame file |
|---|---|---|
| 0.3 m | | |
| 0.5 m | | |
| 1.0 m | | |

### Gate 3 — UaaL smoke test

(see §4 record table)

### Gate 4 — hand test

(see §5 record table)

### Gate 7 — clock

(see §6 record table)

### Gate 8 — fallback quality

(see §7 record table)

### Gate 9 — C path (optional)

(see §8 record table)

### Invalid / repeated runs

| Gate | Run id | Reason | Repeated as |
|---|---|---|---|
| | | | |

## 11. Pass/fail criteria for 1.0

- Gate 1 recorded.
- Gate 3: pass (UaaL survives restart/recreation/pause-resume) or blocked on the SDK gate (recorded).
- Gate 4: joints arrive at >0 Hz for an empty hand; gripping result recorded.
- Gate 7: pass (offset stable, <1% stale).
- Gate 8: failure of `headRelative` recorded.

VITURE counts as "6DoF supported" for 1.0 only if gates 3 and 4 pass with joints arriving while gripping. Otherwise "head-relative fallback only" (if head pose works) or "not supported".

## 12. Paste-back block

1. Every logcat file and exported JSON/CSV from gates 1, 3, 4, 7, 8 (and 9 if run), with the run log.
2. The `STREAM ...` block at the start and end of every run and the link lines.
3. Zip filename and SHA-256 per gate.
4. Filled result tables.
5. Any invalid or repeated run with reason.

## 13. What this sheet cannot show

- Whether the Unity player survives a real production load (only a minimal tracking scene here).
- VITURE vendor SDK internals (black box).
- Behaviour on 3DoF glasses for hand tracking (rejected by design).
- Whether a gripping hand stays tracked over a long session.
- Any firmware or app change.
