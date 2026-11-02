# Changelog

## Unreleased

- VITURE Pro Neckband in embedded UaaL: the Unity bridge is hand-only, so the
  display provider can no longer take over the Flutter host activity, and the
  unshaded marker cubes are gone (ONY-840). Shipped through the pinned
  `unity-export-1.3`.

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
