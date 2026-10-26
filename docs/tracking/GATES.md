# Headset hand and head tracking — gates and open questions

## Gates before calling this 6DoF

The code is a framework, not a hardware result. In order:

1. **Capture one frame per device.** For VITURE Luma Ultra, capture the stereo grayscale frames with the WMR controller LEDs lit and check whether the LEDs appear. For Android XR, capture the passthrough camera (not the tracking cameras, which are unavailable). For RayNeo X3 Pro, check whether the VGA spatial camera feed is reachable outside the ARDK. This settles the IR question before any optical work.
2. **Android XR plugin smoke test.** Request permissions, configure both modes, and log joint/head rates on a real headset. Confirm whether a hand holding a WMR controller is tracked at all; if not, the hand-anchor path is unusable while gripping. The frame JSON contract, 26-joint decode and head/hand rate accounting are host-tested by the harness below, so this gate is now the plugin and device run.
3. **Unity-in-Flutter smoke test.** Build a one-scene UaaL plugin, send `start` with `UnitySendMessage`, receive JSON frames back, and log them in Dart. Check the plugin survives Flutter hot restart, activity recreation and Unity pause/resume. This is the gate for VITURE Neckband, XREAL, RayNeo and Rokid. The Unity→OpenXR frame contract and rate accounting are host-tested by the harness below, so this gate is now the on-device plugin lifecycle run.
4. **VITURE Neckband hand test.** On a Pro Neckband + Luma Ultra, run `VitureXR.HandTracking.Start()`, log `XRHandSubsystem` joints and confirm whether a hand gripping a WMR controller is tracked. This is the only VITURE path that can beat `headRelative`.
5. **XREAL Air 2 Ultra hand test.** On a Beam Pro or S24/S25 with the Air 2 Ultra, set the XREAL input source to Hands, log `XRHandSubsystem` joints and the reported `XREALPlugin.GetDeviceType()` name, and confirm whether a hand gripping a WMR controller is tracked. Also record the actual input-source API, if one exists, and the permissions the runtime requests.
6. **RayNeo and Rokid presence test.** On an X3 Pro, confirm `Algorithm.GetSlamStatus()` reaches `FFVINS_TRACKING_SUCCESS` and capture `HeadTrackedPoseDriver.OnPostUpdate` rate. On Rokid AR Studio, confirm which gestures the UXR `InputManager` emits and whether any joint data is reachable from C#; if it is gesture-only, record that the anchor path is unavailable.
7. **Clock test.** Log controller `receivedAtUs` and tracking host timestamps together for a minute; check the aligner offset is stable and frames stay within the 100 ms window.
8. **Fallback quality test.** Compare `headRelative` against a known physical position while nodding and walking. Expect it to fail as positional tracking; record the failure so it is not sold as 6DoF.
9. **VITURE C path.** Run `get_gl_pose_carina` on an Android phone with Luma Ultra, measure pose rate/status and USB permission behaviour. If it works, it is the lowest-friction phone-only head-pose source.

**Host-side coverage for gates 2 and 3.** From `packages/wmr_tracking`, `dart run tool/xr_contract_harness.dart` replays deterministic head poses and 26-joint hands through both adapter contracts — native plugin JSON in OpenXR axes and Unity relay JSON in left-handed Unity axes — decodes the paired golden fixtures, logs the achieved head and hand rates, and exits non-zero if either contract drifts or a malformed frame is accepted. Passing a valid frame as `--malformed` must fail, which is how the rejection check is verified. A green run proves the wire contract and rate accounting in CI; it does not replace the permission, session-lifecycle, Unity hot-restart or "hand gripping a controller" checks in gates 2 and 3.

Until 1–9 produce reported hardware results, describe the framework as "ready for an adapter", not "6DoF supported".


## Open questions

- Does a WMR controller's hand remain trackable while gripping it on Android XR, XREAL or VITURE Neckband? Desk research cannot answer this.
- Are VITURE Luma Ultra's stereo cameras sensitive enough to 850/940 nm LEDs, and what are their intrinsics/extrinsics?
- Can XREAL's XR Hands subsystem expose joints outside Unity through a native plugin in SDK 3.x? Not documented.
- Can RayNeo's ARDK expose hand joints, or is the gesture coverage in secondary sources only? The current public docs list no hand API.
- Can Rokid UXR expose joint poses on AR Studio, or only gesture events? The public input docs show gesture interaction, not skeletons.
- Does Unity as a Library run on the VITURE Pro Neckband and Rokid Station alongside their XR runtimes, and does it keep hand tracking alive while the Unity view is hidden? Needs the Unity-in-Flutter smoke test.
- Does Android XR allow a long-running background session while the phone handles BLE, or must the companion move onto the headset?
- Is the `HEAD_TRACKING` permission needed for `DeviceTrackingMode.SPATIAL` on wired XR glasses as well as immersive headsets? The docs say immersive devices; glasses are untested.

