# Run sheet: pose validation - XREAL Air 2 Ultra (named 1.0 path)
Status: proposed, not run. The Unity-in-Flutter relay is implemented and host-tested; no Air 2 Ultra run has happened. Result tables are empty.

 selected this as the 6DoF path for 1.0; VITURE is the fallback. The desk pre-flight is in [PREFLIGHT.md](../../tracking/PREFLIGHT.md).

Gates: 3, 5, 7, 8. Gate 1 is informational (no app-visible tracking camera; passthrough RGB only); gate 9 is VITURE-only. See [GATES.md](../../tracking/GATES.md).

## 1. Prerequisites
| Item | Required |
|---|---|
| Glasses | XREAL Air 2 Ultra (the only model with hand tracking). One/OnePro (6DoF head, no hands) and Air/Air2/Air2Pro/Light (3DoF) are rejected and must not be used for gate 5. |
| Host | Beam Pro or Samsung S24/S25 or later. XREAL warns against Android 16 on dev devices. Record model and Android version. |
| App build | Signed v0.3.19 unified APK (versionCode 2024). It carries Android XR, VITURE, and XREAL tracking; no manual export is required. Record the commit. |
| Bridge | One board on `main`, both controllers paired and awake. Record firmware SHA and boot banner. |
| Tooling | `adb`, terminal, logcat capture. |

Download: `https://github.com/nightcinder/wmr-companion/releases/download/v0.3.19/wmr-companion-0.3.19-unified-arm64-v8a.apk`. Install: `adb install -r wmr-companion-0.3.19-unified-arm64-v8a.apk`. The debug overlay shows "Attached xreal tracking" when running with Air 2 Ultra glasses.

## 2. Setup, once per sitting
1. Connect the host phone to the Air 2 Ultra; confirm 6DoF head tracking in the XREAL home.
2. Put the bridge in place, controllers on taped marks ~0.5 m away. Photo the setup.
3. Start the bridge serial monitor and a host logcat capture.
4. Connect the app, select **Batched FF14**, confirm `STREAM` shows `stream=batched`, `sub=1`, live `rate_rx`, and `bridge_hands=0`.
5. Start tracking: a successful `start` means `Air2Ultra`; any other model fails gate 5 with `unsupported (found <model>)`. The handshake model is not re-reported to the app, so do not expect a pre-start `Air2Ultra` read.

Watch for these open items: the manifest lists `XrealLight`/`XrealAir`, so if `start` reports `unsupported`, the export is missing the REALITY category (rebuild with it); a Controller export reports `unavailable`; XREAL USB IDs are unknown and fail-closed on a bare phone; record the host Android build before running.

## 3. Gate 1 - camera capture (informational)
XREAL exposes passthrough RGB but hides the grayscale tracking cameras.

| Item | Value |
|---|---|
| Passthrough RGB reachable? | |
| Tracking (gray) cameras reachable? (expected: no) | |
| Notes | |

No pass/fail.

## 4. Gate 3 - Unity-in-Flutter smoke test
Same procedure as [pose-viture.md](pose-viture.md) section 4, with the XREAL source. Also record `XREALPlugin.GetDeviceType` raw and normalised names.

```bash
adb logcat -v threadtime > pose-xreal-gate3-<YYYYMMDD-HHMMSS>.log
```

| Item | Value |
|---|---|
| Unity player starts? | |
| `start` received by C#? | |
| JSON frames arrive in Dart? | |
| Frame rate (Hz) | |
| `GetDeviceType` raw / normalised | |
| Hot restart survives? | |
| Activity recreation recovers? | |
| Pause/resume deadlocks? | |

Pass: commands round-trip, frames arrive, the device name is recognised, and there is no deadlock. If the AAR is not linked or the input source is not Hands, record `unavailable` and stop; the gate is blocked on the SDK/project settings, not failed.

## 5. Gate 5 - Air 2 Ultra hand test
Question: does the Air 2 Ultra deliver 26 joints with the input source Hands, and is a hand tracked while gripping a WMR controller?

1. Start tracking. The handshake fails with `unsupported` unless the glasses are an Air 2 Ultra.
2. Log 60 s with an empty visible hand; record joint count and rate, and the raw `GetDeviceType` name.
3. Repeat while gripping a WMR controller (awake, not streaming); record whether joints arrive.
4. Record the input-source API if one exists, and any permissions beyond `CAMERA`.
5. Stop and dispose; confirm no leak on repeat.

```bash
adb logcat -v threadtime > pose-xreal-gate5-<YYYYMMDD-HHMMSS>.log
```

| Item | Value |
|---|---|
| Glasses model | |
| Head-pose rate (Hz) | |
| Joint rate, empty hand / gripping (Hz) | |
| Hand tracked while gripping? | |
| Joints present (of 26) | |
| `GetDeviceType` raw / normalised | |
| Runtime permissions requested | |
| Runtime input-source API found? | |
| Errors / exceptions | |

Pass: joints arrive for an empty hand and the gripping result is recorded. "No" for gripping is a valid result.

## 6. Gate 7 - clock test
Same procedure as [pose-androidxr.md](pose-androidxr.md) section 6, with the XREAL source.

| Duration (s) | Offset mean (ms) | Offset std (ms) | Max age (ms) | Frames >100 ms | Rebases |
|---|---|---|---|---|---|
| | | | | | |

Pass: offset std < 5 ms and < 1% stale frames.

## 7. Gate 8 - fallback quality
Same procedure as [pose-androidxr.md](pose-androidxr.md) section 7, with the XREAL source.

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
Run the 6-run pose capture from the guided bench with the Air 2 Ultra connected. The bench guides each segment:

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
Capture per gate: logcat `pose-xreal-<gate>-<timestamp>.log`; exported JSON/CSV; bridge serial `pose-xreal-serial-<timestamp>.txt`; setup and input-source photos. Zip as `pose-xreal-<YYYYMMDD>.zip`, record its SHA-256, and attach it with the filled tables. If a file is missing, say which; do not reconstruct numbers.

## 10. Pass/fail for 1.0
- Gate 3 pass, or blocked on the SDK/project-settings gate and recorded.
- Gate 5: joints arrive for an empty hand; the gripping result is recorded.
- Gate 7 pass.
- Gate 8: failure of `headRelative` recorded.
- Guided speed checks pass (J <= 0.5 mm, J_D <= 0.75 mm, medium and fast lag <= 20 ms).

XREAL counts as "6DoF supported" only if gates 3 and 5 pass with joints arriving while gripping. Otherwise it is "head-relative fallback only" (if head pose works) or "not supported". Air 2 Ultra is the only XREAL model that can pass gate 5; all others are recorded as `unsupported`.
