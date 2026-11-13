# Changelog

All notable changes to the WMR Companion Dart packages. Each package also
keeps its own changelog; this file records the release as a whole.

## Unreleased

- The Gamepad screen streams the mapped controllers to DroidDeck as
  experimental `v0` external 6DoF input, over the local `droiddeck-ext-xr`
  socket. Starting the stream disables the Bluetooth HID peripheral role and
  stopping it restores the role, because Android HID peripheral mode breaks the
  local Bluetooth link DroidDeck needs. Position comes from the live 6DoF fuser
  when a tracking source is attached; hands without a tracked position are sent
  rotation-only (ONY-1351).
- `docs/GAMEPAD.md` documents enabling the stream, the 3DoF fallback, the
  missing PadBridge claim, and how to build a testable APK (ONY-1351).

## 0.3.25+30

Release candidate for the Pixel + Pi simultaneous BLE gamepad and Wi-Fi check
(ONY-1322).

- Connecting Wi-Fi, or switching to the Wi-Fi tab, no longer drops the bonded
  Bluetooth link. The app turns the FF11/FF12/FF14 notifications off and parks
  the session instead of calling `disconnect()`, so a later Bluetooth connect
  re-subscribes over the same link (ONY-1321).
- The run sheets document the Pro Neckband hand-tracking modes and the paired
  capture commands (ONY-1317).

## 0.3.24+29

WMR Companion release.

- With Wi-Fi off, a Bluetooth connect no longer waits on a LAN address that can
  only time out. The transport skips the TCP probe when no LAN interface is up
  and caps the probe at three seconds in total, sharing what is left across the
  candidate addresses, so the BLE leg opens at once (ONY-1309).
- A GATT notification setup that Android refuses with `WRITE_REQUEST_BUSY` is
  retried twice after a short settle, and an enable on a session that already
  holds the subscription shares it instead of queueing another CCCD write. A
  link whose CCCD write still reports busy is dropped and reconnected with a
  fresh session rather than looping, and a disconnect queues behind the GATT
  step in flight (ONY-1309).
- The companion saves the FF13 bridge token in platform secure storage and
  remembers the authenticated FF16 endpoint, so the next launch reconnects over
  Wi-Fi by default, authenticates with Bluetooth off, and redials a dropped
  link without a restart (ONY-1291).
- An exported test bundle carries the relay's hand-tracking diagnostics:
  effective rate, longest frame gap, per-hand presence and viewer pose sources
  (ONY-1315).

## 0.3.23+28

WMR Companion release. The in-app bridge upgrade needs a WMR_Bridge build that
advertises `upgradeCapable` (the Pi upgrade command); an older bridge
keeps the manual command.

- The Connect screen's update banner can start a Pi bridge upgrade over the
  connected Wi-Fi daemon. The app sends `{"type":"upgrade"}`, reports the
  daemon's `started`, `busy` or `error` result, and extends the reconnect
  campaign past its six attempts, bounded by a five-minute watchdog, so it
  comes back after the package install and daemon restart. A daemon that
  cannot upgrade, or is unreachable, gets the one-line
  `install.sh | sudo bash` command instead.
- Returning to the app after Android backgrounded it reconnects a bridge whose
  retry budget ran out. Disconnecting one bridge no longer suppresses the
  redial of another that drops, while an explicit disconnect and a manual scan
  still stay down on resume.

## 0.3.22+27

WMR Companion release, paired with WMR_Bridge `v0.3.23`.

- LAN discovery reports a multi-interface bridge once. Replies that share a
  `bridgeId` collapse into a single entry whose host list still carries every
  address, and the transport tries each candidate in turn.
- A Bluetooth session with a Pi bridge upgrades to Wi-Fi when the bridge
  answers the FF16 handoff with its LAN endpoint. The BLE leg stays open as the
  fallback, and a radio drop no longer tears the session down while TCP carries
  it.
- The Connect screen remembers the last bridge and auto-connects over the LAN
  on launch, to that bridge when it answers or to the only one a scan finds,
  and falls back to the stored hosts when discovery is blocked. A manual scan,
  a transport switch or a disconnect suppresses the automatic dial, and the
  remembered bridge can be forgotten.

## 0.3.21+26

WMR Companion release, paired with WMR_Bridge `v0.3.19`.

- The Unity SurfaceView no longer blacks out the player on the Pro Neckband.
  The window drops `windowIsTranslucent`, the embedded `SurfaceView`s stay on
  the application layer, and they no longer take focus, so Flutter keeps the
  key events.
- Unity and hand tracking start only when the Bench or Debug screen opens. The
  Connect screen no longer runs the tracking probe on launch, and the recenter
  control moved to the Bench screen.
- The external-test-user sheet warns against Device Mirroring and pins the
  `scrcpy --display-id=3` capture command.

## 0.3.20+25

WMR Companion release, paired with WMR_Bridge `v0.3.17`.

- The guided bench checks a pose capture's speed live: the active hand turns
  green inside the section 8 band and red outside it, with the measured speed
  and the band shown during the run. A separate validator scores a
  saved cell against the section 8 speed gate.
- The reference app scans the LAN for Pi bridges with `WmrWsDiscovery` and
  can opt into `CompositeBleTransport`: TCP first, BLE GATT as fallback, with
  the active leg shown on the Connect screen. The active leg and
  composite stick settings are recorded in diagnostic bundles and shown in the
  Debug and Latency screens.
- Diagnostic bundles include a USB, display and XR device environment snapshot
- CI adds Kotlin unit tests for the HID plugin, splits the release
  dex check into its own workflow, and makes the gitleaks, Semgrep and OSV
  scans blocking.

## 0.3.19+24

WMR Companion release, paired with WMR_Bridge `v0.3.15`.

- `wmr_ws` adds pure-Dart LAN discovery (UDP probe and mDNS), and
  `wmr_companion` adds `CompositeBleTransport`, which prefers the Pi's TCP
  link and falls back to BLE GATT, retrying TCP every 2 seconds. The fallback
  is opt-in for library hosts; the reference app still connects through the
  WebSocket transport directly. It is not yet tested on hardware.
- The Pi TCP/BLE fallback contract and LAN discovery are documented in
  `docs/LIBRARY.md` and `packages/wmr_ws/README.md`.
- A native visionOS app is scaffolded with an ARKit tracking seam, a SwiftUI
  dashboard and a 6DoF scene, with architecture, permissions and signing
  documented.
- The GATT latency probe is retired, and its tool and release packaging are
  removed.
- CI adds CodeQL and OSV dependency scanning to code scanning, and scans the
  published APK with MobSF plus a native-library inventory diff.

## 0.3.0

The first release since 0.2.2. All twelve packages move to 0.3.0 and their
inter-package constraints to `^0.3.0`. The reference app stays on its own
release line (`0.3.19+24`).

- FF16 protocol version and feature-matrix reporting in `wmr_core` and
  `wmr_companion` (`WmrProtocolVersion`, `WmrBridgeFeatures`).
- FF17 controller control in `wmr_core` (`ControllerControlClient`,
  `ControllerCommand`, `ControllerResult`, `ControllerStatusV2`) and the
  `WmrCompanion` facade, plus a reconnect backoff.
- Android XR head and hand tracking in `wmr_tracking` and
  `wmr_tracking_android_xr`, with dispatch across Android XR, VITURE and
  XREAL.
- VITURE and XREAL backends start when the glasses model has not been reported
  yet; the VITURE export requires stereo 3D (SpaceWalker).
- `wmr_ble` scans also list system-connected devices, so a bridge held as a
  HID gamepad is still discovered.
- `wmr_companion_hid_android` packs HID buttons in Android/Linux slot order,
  matching WMR Bridge firmware 0.3.3 and later.
- Android plugins migrate to AGP 9 built-in Kotlin and require Flutter 3.44 or
  later.

See `packages/*/CHANGELOG.md` for per-package detail.
