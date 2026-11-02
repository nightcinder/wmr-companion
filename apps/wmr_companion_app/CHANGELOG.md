# Changelog

## Unreleased

- Fix the VITURE Pro Neckband launch crash on the Vulkan `unity-export-1.1`
  player: start only the hand subsystem when the XR display provider cannot use
  the player's graphics API, and pin future Unity exports to OpenGL ES 3.
- Keep the hosted Unity player out of the Android focus tree so the Neckband
  D-pad and injected touch keep driving the Flutter UI.

## 0.3.11+16

- Detect the connected glasses automatically and remove the manual
  tracking-source dropdown. The app selects VITURE or XREAL from the device
  that is actually connected.
- Fix the XREAL cold-start crash: defer the first `UnitySendMessage` start
  command until the activity and Unity player are ready, and keep the
  XREAL/VITURE JNI classes through R8 minification.
