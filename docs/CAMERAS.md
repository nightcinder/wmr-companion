# Headset camera access for controller fusion (research, 2026-10-22)

> For the tracking (head/hand pose) side and the framework that consumes it, see [TRACKING.md](TRACKING.md). This page stays scoped to raw camera access.

Question: can the app fuse the controllers' IMU with a headset's cameras to get 6DoF (the long-term goal)? Devices looked at: Xreal Aura, URXR One, Xreal One Pro + Eye, Viture Luma Ultra. This is desk research from a handful of searches; most vendor docs are thin and the sources were read through tool summaries, so details can be incomplete. Nothing here was tested on a device. Saved from the artifact `CEnR6zMhVKcqq5eFChk111`.

## Short answer

None of the four clearly gives an app raw, timestamped, IR-capable tracking-camera frames, which LED constellation tracking needs. What is documented is RGB or passthrough video. The tracking cameras are either hidden (Android XR) or undocumented (Viture, URXR). Optical LED tracking is unproven on all four. The BLE and IMU work stays valuable: the headset's own 6DoF pose plus the controller IMU is a workable fallback.

## Comparison

Tags: **documented**, **partial/likely**, **blocked/doubtful**, **not found / guess**.

| | Xreal Aura | URXR One | Xreal One Pro + Eye | Viture Luma Ultra |
|---|---|---|---|---|
| Platform | documented: Android XR, runs apps itself (user note: has an SDK) | partial: tethered over USB-C DisplayPort to a laptop, phone, tablet or handheld; no battery or onboard computer; not shipped yet, specs are the company's | documented: display glasses driven by a phone or PC; XREAL SDK (Unity); Eye is a clip-on camera | documented: display glasses driven by a host; Viture C SDK for Linux, macOS, Windows, Android |
| App camera access | likely: Android XR headsets let apps request Camera permission for the outward passthrough camera (ID 0); Aura itself not confirmed | not found: no SDK or camera API in what was found | documented: RGB Eye frames through the XREAL SDK as YUV_420_888 textures (Eye on One series only) | partial: UVC passthrough camera via `viture_camera_provider.h`; per-frame API not described |
| Tracking cameras | blocked on headsets: Android XR says apps cannot use "non-standard" cameras, which includes the tracking cameras; likely the same on Aura (guess) | not found: four forward cameras, 2328x1728 at 90 fps passthrough (claim); tracking runs on a chip in the glasses | no: Eye is a single RGB camera; no mono, global-shutter or IR feed documented | unclear: a stereo camera for VIO is listed, how to read it is not documented |
| Resolution / fps | not found | claim: 2328x1728 at 90 fps, passthrough | documented: video 1600x1200, 30 fps default, 60 optional, 12 MP sensor | not found |
| IR sensitivity | unknown | unknown | doubtful (guess): RGB cameras normally carry an IR-cut filter | unknown |
| Frame timestamps / exposure | not found (Camera2 normally exposes sensor timestamps and manual exposure if the device allows it) | not found | not documented (the page covers pixel format only) | not found |
| Headset pose | likely: Android XR provides head tracking to apps (guess for Aura) | not found: 6DoF is computed on the glasses; whether it reaches an app is unknown | partial: One Pro is 3DoF, Eye is marketed as adding 6DoF; pose API not checked | documented: pose via `get_gl_pose_carina`, described as 3/6DoF |
| Where fusion runs | on the glasses or puck (Android XR app) | on the tethered phone or PC; pose will have to cross USB-C | on the host phone or PC | on the host (Android app via the SDK, or desktop) |
| Restrictions | user permission prompt; likely an in-use indicator | shipping mid-Oct 2026 to backers; unreviewed | one series only; Eye is an accessory | Luma Ultra not supported in the browser SDK |

## What this means for the plan

- **The blocker is IR, not permission.** WMR controller LEDs are, as far as known, near-IR and are seen by monochrome headset cameras. Passthrough or RGB feeds probably cannot see them. Confirm with one captured frame per device before building anything.
- **Fallback that works on all four:** take the headset's 6DoF pose where the SDK exposes it and fuse it with the controller IMU orientation plus a hand-held anchor (grip offset or a user-calibrated pose). That gives drift-limited controller position without LED tracking.
- **The phone is the fusion host** for URXR One, Xreal and Viture. Only Aura can host it on the glasses. That keeps the BLE link on the phone, which matches this app.
- **Camera and IMU must share a clock.** Camera timestamps come from the host OS; the controller IMU arrives with `rx_time_us` at the transport. The monotonic `Stopwatch` at the transport boundary is the right place to take host time. This is why the raw timestamped FF12/FF14 stream and its loss and latency matter ([STATUS.md](STATUS.md)).

## Common camera abstraction (sketch, not built)

Mirror `BleTransport`: one interface, one implementation per device, plus a fake for tests.

```dart
abstract class TrackingCamera {
  Stream<CameraFrame> frames;   // gray8 or YUV Y plane, host-monotonic ts in ns
  CameraInfo get info;          // width, height, fps, intrinsics, distortion, IR?: bool
  Future<void> setExposure({int? us, int? gain});  // may be unsupported
}
abstract class HeadPoseSource {
  Stream<HeadPose> poses;       // 6DoF (or 3DoF), same clock as frames
}
// Impls: AndroidXrCamera, XrealEyeCamera, VitureUvcCamera, UrxrCamera (unknown), FakeCamera
// The fusion core sees only frames + head poses + controller IMU records.
```

Capability flags (`info.ir`, exposure supported, timestamp quality) let the app choose optical fusion, headset-pose fallback, or IMU-only per device.

## Reusable open source

- **Monado** has a constellation controller tracking branch for WMR controllers ([dev-constellation-controller-tracking](https://gitlab.freedesktop.org/thaytan/monado/-/commits/dev-constellation-controller-tracking)). It matches LED blobs to a controller model, fuses with IMU and rejects stray lights. It is C, runs on Linux, expects WMR headset cameras, and its PnP refinement is disabled because OpenCV RANSAC PnP "frequently produces really wrong answers". A reference for the LED model and fusion design, not a drop-in for Android XR. Not tested.
- The FOSDEM 2026 Monado slides can describe progress since. They were not read.

## Gaps to close

- Whether Aura exposes any camera beyond passthrough, and its Camera2 capabilities (timestamps, exposure, IR).
- Whether URXR One has any developer SDK at all.
- Whether the Viture stereo camera can be read by an app, and its format.
- Whether the controller LEDs are visible in each device's feed (one captured frame settles it).

## Sources

[Android Authority on Android XR camera access](https://androidauthority.com/android-xr-camera-access-3526531), [iDevice on URXR One](https://idevice.com/a-93-gram-tethered-headset-just-raised-1-29-million-on-kickstarter), XREAL RGB camera docs (docs.xreal.com, "Camera/Access RGB Camera"), [XREAL Eye specs](https://tutorials.xreal.com/docs/accessories/eye/spec), [VITURE glasses SDK](https://www.viture.com/developer/glasses-sdk/glasses).
