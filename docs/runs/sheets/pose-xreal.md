# Run sheet: pose validation — XREAL Air 2 Ultra (named 1.0 path)

> **Proposed sheet, not yet run.** Nothing here is a hardware result. Every figure is recorded by the owner; all result tables are empty and must not be pre-filled. The Unity-in-Flutter relay is implemented and host-tested, but no Air 2 Ultra run has happened.
>
> **ONY-440 selected this as the 6DoF path for 1.0** (VITURE is the fallback). The desk pre-flight, including the current unified APK's merged permissions and both Unity runtimes, is in [`docs/tracking/PREFLIGHT.md`](../../tracking/PREFLIGHT.md).

Companion documents:

- App [`docs/tracking/GATES.md`](https://github.com/nightcinder/wmr-companion/blob/main/docs/tracking/GATES.md) — gates 3, 5, 7, 8 (this sheet). Gate 1 is not defined for XREAL (no app-visible tracking camera); passthrough RGB only.
- App [`docs/STATUS.md`](https://github.com/nightcinder/wmr-companion/blob/main/docs/STATUS.md)
- XREAL SDK 3.1.0 docs (links in RESEARCH.md Sources).

Gates covered: **3** (Unity-in-Flutter smoke test), **5** (XREAL Air 2 Ultra hand test), **7** (clock), **8** (fallback quality). Gate 1 is N/A (no tracking camera exposed); gate 9 is VITURE-only.

## 0. What this sheet settles

- Whether a one-scene Unity UaaL plugin works for XREAL and survives restart/recreation (gate 3).
- Whether `XRHandSubsystem` delivers 26 joints on a Beam Pro / S24/S25 + Air 2 Ultra, with the input source set to Hands, and whether a gripping hand stays tracked (gate 5).
- Whether `XREALPlugin.GetDeviceType()` reports a name the adapter recognises (gate 5).
- Whether the aligner is stable (gate 7) and `headRelative` is honest (gate 8).

## 1. Prerequisites and builds

| Item | Required |
|---|---|
| Glasses | XREAL Air 2 Ultra (the only model with hand tracking). `One`/`OnePro` (6DoF head only, no hands) and `Air`/`Air2`/`Air2Pro`/`Light` (3DoF) are rejected by the adapter and must not be used for gate 5. |
| Host | Beam Pro or Samsung S24/S25 or later. XREAL warns against Android 16 on dev devices. Record model and Android version. |
| Unity | Unity 2021.3+/6000.0 with Android build support, `com.unity.xr.hands`, XREAL SDK 3.x (`com.xreal.xr`). External SDK gate; not redistributable. |
| App build | Release `v0.3.7` unified APK (SHA-256 `d66f5147f85f76d8b4a7249b4cc7d29e969f06205599f04a5fb99825249d865c`, all tracking flags on, both SDKs in one `unityLibrary`), or a local `tool/build_flavor.sh unified --debug` from the same export. Record app commit. |
| Bridge | One board on `main`, both controllers paired and awake. Record firmware SHA and boot banner. |
| Tooling | `adb`, terminal, logcat capture. |

Unity project settings (must be set before export; the bridge does not change them at runtime):

- XREAL XR Plug-in enabled.
- **Initial Input Source = Hands**.
- Unity XR Hands + XRI installed.
- `XREAL_DEVICE_CATEGORY_REALITY` included in Support Devices.
- `WMR_XREAL_XR_SDK` and `WMR_UNITY_XR_HANDS` defined in the C# bridge.

Build the APK (the release artifact needs no rebuild; this is for a local build
from the owner export):

```bash
apps/wmr_companion_app/tool/install_unity_export.sh unified path/to/unityLibrary.zip
apps/wmr_companion_app/tool/build_flavor.sh unified --debug

# either the local build or the release asset
adb install -r apps/wmr_companion_app/build/app/outputs/flutter-apk/app-unified-debug.apk
```

Before installing, run the desk check from `docs/tracking/PREFLIGHT.md`; it
verifies the merged permissions, both vendor runtimes and the session classes
without a device.

Confirm the flag is live: the debug overlay shows "XREAL tracking: available" when the AAR is linked and the input source is Hands; otherwise `unavailable`.

## 2. Setup, once per sitting

1. Connect the host phone to the Air 2 Ultra; confirm 6DoF head tracking in the XREAL home.
2. Put the bridge in its usual place, controllers on taped marks ~0.5 m from it. Photo the setup.
3. Start the serial monitor (bridge) and a logcat capture (host).
4. Connect the app to the bridge, select **Batched FF14**, confirm `STREAM` shows `stream=batched`, `sub=1`, live `rate_rx`. Confirm `bridge_hands=0`.
5. Start tracking: the Unity `start` handshake is the model confirmation. A
   successful start means `Air2Ultra`; any other model fails gate 5 with
   `unsupported (found <model>)`. The handshake model is not re-reported to the
   app, so do not expect a pre-start `Air2Ultra` read.

## 2.1 Pre-flight (desk-only, re-run 2026-11-01 on v0.3.7)

Recorded in [`docs/tracking/PREFLIGHT.md`](../../tracking/PREFLIGHT.md). The
v0.3.7 unified APK (SHA-256 above) was re-checked on 2026-11-01: its merged
manifest declares `CAMERA`,
`SCENE_UNDERSTANDING_COARSE`, `BLUETOOTH_SCAN`/`CONNECT`, `HAND_TRACKING`/`HEAD_TRACKING`,
`usb.host` and an optional camera feature, and never `SCENE_UNDERSTANDING_FINE`; both vendor runtimes and their Unity subsystems are
present; and the session classes (`SharedUnityRuntime`, `PendingStartGate`,
both vendor plugins) are in the dex. This is a build-content check only.

Open items this sheet must answer or watch for:

- `com.nreal.supportDevices` in the artifact lists `XrealLight`/`XrealAir`; if
  `start` reports `unsupported`, the export is missing the Air 2 Ultra/REALITY
  category (rebuild, §1).
- `Initial Input Source = Hands` is a project setting; a Controller export
  reports `unavailable` at start.
- XREAL USB IDs are unknown and fail-closed on a bare phone host.
- Android 16 is warned against by XREAL; record the host build before running.

## 3. Gate 1 — camera capture (not defined for XREAL)
XREAL exposes an RGB camera stream but hides the grayscale tracking cameras. There is no IR/optical question to settle here beyond noting that passthrough RGB is available and tracking cameras are not.

Record:

| Item | Value (user-reported) |
|---|---|
| Passthrough RGB reachable? (yes/no) | |
| Tracking (gray) cameras reachable? (expected: no) | |
| Notes | |

No pass/fail; informational only.

## 4. Gate 3 — Unity-in-Flutter smoke test

Same procedure as the VITURE sheet §4, with the XREAL source. Additionally record `XREALPlugin.GetDeviceType()` raw and normalised names.

Capture logcat:

```bash
adb logcat -v threadtime > pose-xreal-gate3-<YYYYMMDD-HHMMSS>.log
```

Record:

| Item | Value (user-reported) |
|---|---|
| Unity player starts? (yes/no) | |
| `start` command received by C#? | |
| JSON frames arrive in Dart? | |
| Frame rate (Hz) | |
| `GetDeviceType()` raw name | |
| `GetDeviceType()` normalised | |
| Hot restart survives? | |
| Activity recreation recovers? | |
| Pause/resume deadlocks? | |

**Pass for 1.0:** commands round-trip, frames arrive, device name recognised, no deadlock. If the AAR is not linked or the input source is not Hands, record `unavailable` and stop; blocked on the SDK/project-settings gate, not a failure of the sheet.

## 5. Gate 5 — XREAL Air 2 Ultra hand test

**Question:** does the Air 2 Ultra deliver 26 joints with the input source set to Hands, and is a hand tracked while gripping a WMR controller?

Procedure:

1. Start tracking: the Unity `start` handshake fails with `unsupported` unless the glasses are an Air 2 Ultra (the model it reports is not re-surfaced to the app).
2. Start tracking. With the hand empty and visible, log for 60 s.
3. Record joint count and rate, and the raw `GetDeviceType()` name.
4. Repeat with the hand gripping a WMR controller (controller awake, not streaming). Record whether joints still arrive.
5. Record the actual input-source API if one exists (the bridge does not switch it at runtime; if a runtime API is found, note it).
6. Record the permissions the runtime requests beyond `android.permission.CAMERA` (unverified assumption).
7. Stop and dispose; confirm no leak on repeat.

Capture logcat:

```bash
adb logcat -v threadtime > pose-xreal-gate5-<YYYYMMDD-HHMMSS>.log
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
| `GetDeviceType()` raw / normalised | |
| Runtime permissions requested | |
| Runtime input-source API found? | |
| Errors / exceptions | |

**Pass for 1.0:** joints arrive at >0 Hz for an empty hand and the gripping-hand result is recorded. "No" for gripping is a valid recorded result.

## 6. Gate 7 — clock test

Same procedure as the Android XR sheet §6, with the XREAL source. Log controller `receivedAtUs` and tracking host timestamps for 60 s.

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

Same procedure as the Android XR sheet §7, with the XREAL source. Record reported position error vs. physical mark while nodding and walking, with and without the hand anchor.

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

## 8. How to attach recorded pose files

During each gate, capture:

1. `adb logcat -v threadtime > pose-xreal-<gate>-<YYYYMMDD-HHMMSS>.log`
2. Any app-exported JSON/CSV tracking frames, via Share or `adb pull <path>`; name them `pose-xreal-<gate>-<timestamp>.json`.
3. The bridge serial capture as `pose-xreal-serial-<timestamp>.txt`.
4. Photos of the setup and the XREAL input-source setting.

After the sitting:

1. Put all files in a folder `pose-xreal-<YYYYMMDD>/`.
2. Zip: `zip -r pose-xreal-<YYYYMMDD>.zip pose-xreal-<YYYYMMDD>/`.
3. Compute `sha256sum pose-xreal-<YYYYMMDD>.zip`.
4. Attach the zip to the issue/PR thread and record filename + SHA-256 in the run log.
5. If attaching is impossible, paste the logcat excerpt and `STREAM` lines and state which files are missing.

## 9. Result tables (user-reported)

All values filled by the owner after the sitting. None pre-filled.

### Gate 3 — UaaL smoke test

(see §4 record table)

### Gate 5 — hand test

(see §5 record table)

### Gate 7 — clock

(see §6 record table)

### Gate 8 — fallback quality

(see §7 record table)

### Gate 1 — camera (informational)

(see §3 record table)

### Invalid / repeated runs

| Gate | Run id | Reason | Repeated as |
|---|---|---|---|
| | | | |

## 10. Pass/fail criteria for 1.0

- Gate 3: pass (UaaL survives restart/recreation/pause-resume, device name recognised) or blocked on the SDK/project-settings gate (recorded).
- Gate 5: joints arrive at >0 Hz for an empty hand; gripping result recorded.
- Gate 7: pass (offset stable, <1% stale).
- Gate 8: failure of `headRelative` recorded.

XREAL counts as "6DoF supported" for 1.0 only if gates 3 and 5 pass with joints arriving while gripping. Otherwise "head-relative fallback only" (if head pose works) or "not supported". Note the Air 2 Ultra is the only XREAL model that can ever pass gate 5; all other models are recorded as `unsupported` and excluded.

## 11. Paste-back block

1. Every logcat file and exported JSON/CSV from gates 3, 5, 7, 8 (and gate 1 informational), with the run log.
2. The `STREAM ...` block at the start and end of every run and the link lines.
3. Zip filename and SHA-256 per gate.
4. Filled result tables.
5. Any invalid or repeated run with reason.

## 12. What this sheet cannot show

- Behaviour on XREAL models other than Air 2 Ultra (excluded by design).
- Whether the Unity player survives a real production load.
- XREAL vendor SDK internals (black box).
- Whether a gripping hand stays tracked over a long session.
- Any firmware or app change.
