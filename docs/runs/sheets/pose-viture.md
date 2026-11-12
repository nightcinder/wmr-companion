# Run sheet: pose validation - VITURE (Pro Neckband + Luma Ultra)
Status: proposed, not run. The Unity-in-Flutter relay is implemented and host-tested; no Neckband run has happened. Result tables are empty. Code targets VITURE XR SDK 0.9.0 (`Viture.XR.VitureXR`) on Unity 6000.0.27f1.

Gates: 1, 3, 4, 7, 8, 9. See [GATES.md](../../tracking/GATES.md). The guided bench in v0.3.24 runs these gates.

The VITURE Pro Neckband has no physical D-pad. Valid controls are Power, Volume Up and Down, Settings, the air-mouse pointer, hand gestures, the Neckband Remote app, or a paired Bluetooth controller.
## 1. Prerequisites
| Item | Required |
|---|---|
| Glasses | VITURE Luma Ultra (6DoF + stereo cameras) for gates 1/4/9. 3DoF models (One, OneLite, Pro, Pro2, Luma, LumaPro, LumaCyber, Beast) are rejected for hand tracking. |
| Host | VITURE Pro Neckband (Android, wireless ADB) for gates 3/4/7/8. Gate 9 needs an Android phone with USB host. |
| App | Signed v0.3.24 unified APK (versionCode 2029, with v0.3.21 or newer required). It carries VITURE and XREAL, `WMR_VITURE_CARINA_DIAG=true`, and `libglasses.so` (SDK 2.4.1). No export or debug flags are needed. Record version, export SHA and firmware SHA. |
| Bridge | One board on `main`, both controllers paired and awake. |
| Tooling | `adb` (wireless for the Neckband), terminal, logcat, screenshots. |
| Checkerboard | Gate 1: flat, rigid, at least 8x6 inner corners, known square size. |

## 2. Setup, once per sitting
1. Power the Neckband, enable wireless ADB, confirm `adb connect <ip>:5555`.
2. Put the bridge in place, controllers on taped marks ~0.5 m away. Photo the setup.
3. Start the bridge serial monitor and a Neckband logcat capture.
4. Connect the app, select **Batched FF14**, confirm `STREAM` shows `stream=batched`, `sub=1`, live `rate_rx`, and `bridge_hands=0`.
5. Confirm the glasses model is `LumaUltra` before gate 4; a 3DoF model fails gate 4 with `unsupported`.
6. From the debug overlay record `playerHosted`, `stereoMode` and `stage`. Healthy: `playerHosted` then `loaderStarted` then `firstFrame`, with `stereoMode` one of `multiPass`/`singlePass`/`singlePassInstanced`. If `stereoMode` is `unknown` or the stage stops early, record it and stop; the loader is not rendering stereo 3D (SpaceWalker).

If the app drops to 0DoF with **6DoF only** greyed out, check the status line. 6DoF needs the VITURE source running in stereo 3D; a 2D/mono player fails closed with `unavailable`. Record the line and capture logcat filtered on `0DoF|6DoF|spacewalker|running in 2d`. Use the controls listed at the top, not ADB touches.
## 3. Gate 1 - LED visibility and checkerboard
`carinaLeds` runs 12 captures: 4 distances (0.3, 0.5, 0.8, 1.0 m) x 3 orientations (front, rotated, tilted), 12 s each. Each capture walks an exposure ladder (0.1, 0.3, 1.0, 3.0 ms) at gain 6, about 3 s and ~75 frames per rung at 25 Hz. It writes one PGM per channel per rung plus `carina-diagnostics.json`, and retains 16 stills per capture.

1. Power both controllers (LEDs active). Dim the room.
2. Connect the Luma Ultra over USB and accept the permission prompt.
3. Run `carinaLeds`. Hold one orientation per capture; the rung advances by time, so mixing orientations confounds exposure with pose.

| Item | 0.3 m | 0.5 m | 0.8 m | 1.0 m |
|---|---|---|---|---|
| Frames per rung / total | | | | |
| FPS observed | | | | |
| Width x height | | | | |
| Retained stills (48 per distance) | | | | |
| LEDs visible? | | | | |
| Approx. LED blobs per still | | | | |
| Distance at which LEDs disappear | | | | |

Pass: at least 5 LED blobs in at least 90% of frames at 0.8 m. The tester returns the raw PGMs and telemetry;  counts blobs.

Checkerboard (`carinaCheckerboard`): 10 captures, 2 distances (0.5, 0.8 m) x 5 angles (fronto-parallel, left, right, up, down), 4 s each. Power the controllers off so their blobs do not confuse the corner detector. Record the square size (mm), inner corners and distances; return the images with pose labels.
## 4. Gate 3 - Unity-in-Flutter smoke test
1. From the debug overlay tap **Start tracking (VITURE)**.
2. Confirm the Unity player starts and C# receives `start` via `UnitySendMessage`.
3. Confirm poses arrive in Dart as `TrackingFrameCodec` JSON; record the frame rate for 60 s.
4. Hot restart (`r`), force activity recreation, then background for 30 s and foreground: tracking must stop and restart without a crash, report `unavailable` on recreation and recover, and never deadlock.

| Item | Value |
|---|---|
| Unity player starts? | |
| `start` received by C#? | |
| JSON frames arrive in Dart? | |
| Frame rate (Hz) | |
| Hot restart survives? | |
| Activity recreation recovers? | |
| Pause/resume deadlocks? | |
| Unity->OpenXR within 1e-6? | |
| `playerHosted` / `stereoMode` / highest stage | |

Pass: commands round-trip, frames arrive, no deadlock. If the AAR is not linked, record `unavailable` and stop; the gate is blocked on the SDK, not failed.
## 5. Gate 4 - hand tracking while gripping
The bench runs `handEmpty` and `handGrip`, 60 s each. Grip dropout is the share of the run with no hand joints while gripping.

| Item | Value |
|---|---|
| Glasses model | |
| Head-pose rate (Hz) | |
| Joint rate, empty hand (Hz) | |
| Joint rate, gripping (Hz) | |
| Hand tracked while gripping? | |
| Joints present (of 26) | |
| Grip dropout (%) | |
| Recenter works? | |
| Errors / exceptions | |

Pass: dropout under 5%. Marginal: 5-15%. Fail: over 15%. Joints must arrive for an empty hand.

### Pro Neckband hand-tracking disambiguation

The Pro Neckband uses three distinct hand-tracking layers:
- SpaceWalker OS hand pointer: SpaceWalker displays an optical hand pointer. The pointer disappears when `VitureHandTracking.Start` runs, because the camera enters exclusive mode. In release 0.3.21 and later, the app starts Unity only after you open the Bench screen or the Debug screen.
- In-app optical hand skeleton: Unity runs the 26-joint optical hand skeleton in the app. The bare hand skeleton appears in the HUD on the Bench screen during the `handEmpty` step.
- SixDofFuser controller anchor: `SixDofFuser` fuses controller IMU orientation with optical hand anchor pose data. When a controller covers fingers during `handGrip`, optical tracking drops out. The pose then falls back to head-relative tracking.

The VITURE Pro Neckband has no physical D-pad. Use only these valid controls:
- Physical Volume Up and Volume Down buttons. Short press moves focus. Long press Volume Down selects. Long press Volume Up navigates back.
- Settings button together with Power button to turn on headgaze navigation.
- Phone Neckband Remote application.
- Paired Bluetooth controller or mouse.

Follow this disambiguation checklist when hand-tracking issues occur:
1. Connect screen test: on release 0.3.21 and later, make sure that the SpaceWalker OS hand pointer works before you open Bench or Debug.
2. Empty hand test: during `handEmpty` on the Bench screen, make sure that the 26-joint skeleton appears in the HUD.
3. Controller grip test: during `handGrip` on the Bench screen, observe whether tracking drops out when you hold a controller.

Capture diagnostic logs and display layers over wireless ADB:
1. Connect to the Neckband:
   ```bash
   adb connect <neckband-ip>:5555
   ```
2. Clear the logcat buffer and start capture:
   ```bash
   adb logcat -c && adb logcat -v threadtime > pose-viture-hand-diag-<timestamp>.log
   ```
3. Filter hand tracking and relay log messages:
   ```bash
   grep -E "WmrTrackingUnitySmoke|VitureXR|WmrTrackingUnity|WmrTrackingViture" pose-viture-hand-diag-<timestamp>.log
   ```
   `WmrTrackingUnitySmoke` reports frame count, payload size, and whether `hasHands` is true. In release 0.3.24 and later, the exported test bundle records frame rate and gap metrics in `hand_tracking_diagnostics.effective_hz` and `hand_tracking_diagnostics.max_gap_ms`.
4. Capture SurfaceFlinger and display layers while the Bench screen is visible:
   ```bash
   adb shell dumpsys SurfaceFlinger > pose-viture-surfaceflinger.txt
   adb shell dumpsys display > pose-viture-display.txt
   ```
   Make sure that `MainActivity` appears on `layerStack=3` with `coveredRegion=[0, 0, 0, 0]`.

## 6. Gate 7 - clock test
Same procedure as [pose-androidxr.md](pose-androidxr.md) section 6, with the VITURE source.

| Duration (s) | Offset mean (ms) | Offset std (ms) | Max age (ms) | Frames >100 ms | Rebases |
|---|---|---|---|---|---|
| | | | | | |

Pass: offset std < 5 ms and < 1% of frames older than 100 ms.
## 7. Gate 8 - fallback quality
Same procedure as [pose-androidxr.md](pose-androidxr.md) section 7, with the VITURE source.

Record the six motions from that section: static at arm's length, nod +/-20 deg, walk 2 m and back, turn 90 deg in place, then static and nod while gripping (headRelative).

Pass: the test is run and the failure of `headRelative` as positional tracking is recorded.
## 8. Gate 9 - VITURE C path (optional, phone)
1. Connect a Luma Ultra to an Android phone with USB host (OTG) and accept the permission prompt.
2. Run `carinaPose`: one 60 s capture polling `xr_device_provider_get_gl_pose_carina` every 10 ms.
3. Record pose rate, status flag, USB permission behaviour, and whether `set_dof_type_carina` (3DoF/6DoF) is required.

| Pose rate (Hz) | Successes / polls | Status flag | Pose valid? | USB prompt? | 6DoF selectable? | Errors |
|---|---|---|---|---|---|---|
| | | | | | | |

Pass: at least 30 Hz sustained for 60 s with a valid pose. Fail: no pose or no USB.
## 9. Send
Capture per gate: logcat `pose-viture-<gate>-<timestamp>.log` using wireless ADB for the Neckband. Include the debug overlay screenshot showing `playerHosted`, `stereoMode` and `stage`. Include exported JSON and CSV files, bridge serial logs, Unity logs, and setup photos. Include `pose-viture-surfaceflinger.txt` and `pose-viture-display.txt` for Neckband runs. Zip all files as `pose-viture-<YYYYMMDD>.zip`. Record the SHA-256 checksum and attach the archive with the completed tables. If a file is missing, state the missing file name. Do not reconstruct numbers from memory.
## 10. Pass/fail for 1.0
- Gate 1 recorded.
- Gate 3 pass, or blocked on the SDK gate and recorded.
- Gate 4: joints arrive for an empty hand; the gripping result is recorded.
- Gate 7 pass.
- Gate 8: failure of `headRelative` recorded.

VITURE counts as "6DoF supported" only if gates 3 and 4 pass with joints arriving while gripping. Otherwise it is "head-relative fallback only" (if head pose works) or "not supported".
