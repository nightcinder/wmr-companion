# Changelog

## 0.3.16+21

- Detect an Android XR host before USB IDs and host markers, and refuse to
  construct the vendor Unity player on one. The Google Aura launch no longer
  reaches VITURE's plugin and dies with
  `NoClassDefFoundError: android.viture.xr.XRManager` (ONY-879).

## 0.3.15+20

- The guided bench now runs the 6-run pose capture by default: one run per
  scored motion class plus one diagnostic occlusion run, alternating hands,
  for 98 s of recording. The full 42-run section 8 schedule stays available
  for lab captures (ONY-869).
- Pose-filter and external-tester run sheets document the 6-run sequence and
  its 15-20 s per-run durations (ONY-871).
- Capture bundles from the 6-run protocol pass the WMR_Bridge triage floor of
  14 s per scored run (ONY-870).

## 0.3.14+19

- VITURE Pro Neckband in embedded UaaL: the displayless gate now starts
  `XRInputSubsystem` alongside the hand subsystem, so `Camera.main` receives
  6DoF head poses instead of (0,0,0) (ONY-856). Reaches devices only through
  the new pinned `unity-export-1.4`, which the export gate requires.
- The Bench screen shows the live hand-joint skeleton and a 6DoF head-pose
  travel indicator; a Neckband with hand tracking selects 6DoF only
  automatically once the startup tracking probe settles (ONY-857).
- Stereo side-by-side panes shift opposite live 6DoF head motion, with a
  recenter action and a zero-pose fallback (ONY-858).

## 0.3.13+18

- VITURE Pro Neckband in embedded UaaL: the Unity bridge is hand-only, so the
  display provider can no longer take over the Flutter host activity, and the
  unshaded marker cubes are gone (ONY-840). Shipped through the pinned
  `unity-export-1.3`.
- Unity and vendor player activities are no longer exported, so after a crash
  the Neckband launcher starts WMR Companion instead of the bare Unity scene
  (ONY-842).

## 0.3.12+17

- Keep the hosted Unity player out of the Android focus tree so the Flutter
  UI keeps its own focus.
- Add a Neckband control path that needs no D-pad and no ADB: short Volume
  Up/Down presses move focus, holding Volume Down selects, and holding Volume
  Up goes back. With headgaze on, the system keeps Volume Down for select and
  Volume Up for back.
- VITURE Pro Neckband hand tracking: the Unity source now starts only the hand
  subsystem when the player's graphics API cannot host VITURE's GLES-only
  display provider, and the export configuration pins OpenGL ES 3. The pinned
  `unity-export-1.2` is built from the ONY-802 merge commit with that pin, so its
  player starts the display normally; the hand-only path is the fallback for a
  player that is not GLES3.

## 0.3.11+16

- Detect the connected glasses automatically and remove the manual
  tracking-source dropdown. The app selects VITURE or XREAL from the device
  that is actually connected.
- Fix the XREAL cold-start crash: defer the first `UnitySendMessage` start
  command until the activity and Unity player are ready, and keep the
  XREAL/VITURE JNI classes through R8 minification.
