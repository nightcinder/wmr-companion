# Hand and head tracking gates

Current SDK: VITURE XR SDK 0.9.0 (`Viture.XR.VitureXR`) on Unity 6000.0.27f1. Gate definitions and results are unchanged.

## Gates before calling this 6DoF

The code is a framework, not a hardware result. Run the gates in order. Until gates 1-9 report hardware results, call it "ready for an adapter", not "6DoF supported".

| # | Gate | Sheet |
|---|---|---|
| 1 | Capture one frame per device. VITURE Luma Ultra: stereo grayscale frames with the controller LEDs lit; do the LEDs appear? Android XR: passthrough camera (tracking cameras are unavailable). RayNeo X3 Pro: is the VGA spatial camera reachable outside the ARDK? | [VITURE](../runs/sheets/pose-viture.md), [Android XR](../runs/sheets/pose-androidxr.md) |
| 2 | Android XR smoke test: request permissions, set both modes, log joint and head rates, and record whether a hand holding a WMR controller is tracked. | [Android XR](../runs/sheets/pose-androidxr.md) |
| 3 | Unity-in-Flutter smoke test: one-scene UaaL plugin, `start` via `UnitySendMessage`, JSON frames back in Dart, survives hot restart, activity recreation and pause/resume. | [VITURE](../runs/sheets/pose-viture.md), [XREAL](../runs/sheets/pose-xreal.md) |
| 4 | VITURE Neckband hand test: `VitureXR.HandTracking.Start()`, log `XRHandSubsystem` joints, and record whether a gripping hand is tracked. | [VITURE](../runs/sheets/pose-viture.md) |
| 5 | XREAL Air 2 Ultra hand test: input source Hands, log joints and `XREALPlugin.GetDeviceType()`, record whether a gripping hand is tracked and which permissions the runtime asks for. | [XREAL](../runs/sheets/pose-xreal.md) |
| 6 | RayNeo X3 Pro and Rokid AR Studio presence: RayNeo `Algorithm.GetSlamStatus()` reaching `FFVINS_TRACKING_SUCCESS` and the `HeadTrackedPoseDriver.OnPostUpdate` rate; Rokid UXR gestures and whether joint data is reachable. | [Android XR](../runs/sheets/pose-androidxr.md) |
| 7 | Clock test: log controller `receivedAtUs` and tracking host timestamps for a minute. Offset std < 5 ms and fewer than 1% of frames older than 100 ms. | [Android XR](../runs/sheets/pose-androidxr.md) |
| 8 | Fallback quality test: compare `headRelative` against a known physical position while nodding and walking. It must fail as positional tracking. | [Android XR](../runs/sheets/pose-androidxr.md) |
| 9 | VITURE C path: run `get_gl_pose_carina` on an Android phone with Luma Ultra; measure pose rate, status and USB permission behaviour. | [VITURE](../runs/sheets/pose-viture.md) |

## Gate 7 replay

From `packages/wmr_tracking`:

```sh
dart run tool/gate7_clock_replay.dart --fixture tool/fixtures/gate7/stable_offset.json
```

Exit 0 when the offset standard deviation is under 5 ms and fewer than 1% of frames are older than 100 ms. `drift.json`, `gap.json` and `out_of_window.json` must exit 1 with `offset_drift`, `controller_gap` and `frame_out_of_window`. A real headset run is still the validation.

## Gate 8 replay

```sh
dart run tool/gate8_fallback_quality.dart
```

Writes `build/gate8/fallback_quality.json`. Exit 0 when the nod/walk trace drifts by at least 5 cm RMSE and 10 cm max (verdict `EXPECTED-FAIL`) and the rigid control stays under 1 um RMSE and max (verdict `PASS`). A real headset run is still the validation.

## Host-side coverage for gates 2 and 3

From `packages/wmr_tracking`:

```sh
dart run tool/xr_contract_harness.dart
```

Replays deterministic head poses and 26-joint hands through the native plugin JSON (OpenXR axes) and the Unity relay JSON (left-handed Unity axes), decodes the golden fixtures, logs head and hand rates, and exits non-zero on contract drift or a malformed frame. Passing a valid frame as `--malformed` must fail. A green run proves the wire contract and rate accounting; it does not replace the permission, session, hot-restart or gripping-hand checks.

## Open questions

- Does a hand stay tracked while gripping a WMR controller on Android XR, XREAL or VITURE Neckband?
- Are VITURE Luma Ultra's stereo cameras sensitive to 850/940 nm LEDs, and what are their intrinsics/extrinsics?
- Can XREAL XR Hands expose joints outside Unity through a native plugin in SDK 3.x?
- Can RayNeo ARDK expose hand joints, or is gesture coverage secondary-source only?
- Can Rokid UXR expose joint poses, or only gesture events?
- Does UaaL run on the VITURE Pro Neckband and Rokid Station alongside their XR runtimes, and does hand tracking stay alive while the Unity view is hidden?
- Does Android XR allow a long-running background session while the phone handles BLE?
- Is `HEAD_TRACKING` needed for `DeviceTrackingMode.SPATIAL` on wired XR glasses?
