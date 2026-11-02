# Changelog

## 0.3.11+16

- Detect the connected glasses automatically and remove the manual
  tracking-source dropdown. The app selects VITURE or XREAL from the device
  that is actually connected.
- Fix the XREAL cold-start crash: defer the first `UnitySendMessage` start
  command until the activity and Unity player are ready, and keep the
  XREAL/VITURE JNI classes through R8 minification.
