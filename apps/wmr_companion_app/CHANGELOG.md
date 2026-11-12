# Changelog

## 0.3.24+29

- With Wi-Fi off, a Bluetooth connect no longer waits on a LAN address that can
  only time out. The transport skips the TCP probe when no LAN interface is up
  and caps the probe at three seconds in total, so the BLE leg opens at once
  (ONY-1309).
- A GATT notification setup that Android refuses with `WRITE_REQUEST_BUSY` is
  retried twice after a short settle, an enable on a session that already holds
  the subscription shares it, and a link whose CCCD write still reports busy is
  dropped and reconnected with a fresh session instead of looping (ONY-1309).
- The companion saves the FF13 bridge token in platform secure storage and
  remembers the authenticated FF16 endpoint, so the next launch reconnects over
  Wi-Fi by default and authenticates with Bluetooth off (ONY-1291).
- An exported test bundle carries the relay's hand-tracking diagnostics
  (ONY-1315).

## 0.3.23+28

- The Connect screen's update banner can start a Pi bridge upgrade over the
  connected Wi-Fi daemon. The app sends `{"type":"upgrade"}`, reports the
  daemon's `started`, `busy` or `error` result, and extends the reconnect
  campaign past its six attempts, bounded by a five-minute watchdog, so it
  comes back after the package install and daemon restart. A daemon that
  cannot upgrade, or is unreachable, gets the one-line
  `install.sh | sudo bash` command instead (ONY-1224).
- Returning to the app after Android backgrounded it reconnects a bridge whose
  retry budget ran out. Disconnecting one bridge no longer suppresses the
  redial of another that drops, while an explicit disconnect and a manual scan
  still stay down on resume (ONY-1271).
- The in-app bridge upgrade needs a WMR_Bridge build that advertises
  `upgradeCapable` (the Pi upgrade command, ONY-1223); an older bridge keeps
  the manual command.

## 0.3.22+27

- LAN discovery reports a multi-interface bridge once: replies that share a
  `bridgeId` collapse into a single entry whose host list still carries every
  address, and the transport tries each candidate in turn (ONY-1259).
- A Bluetooth session with a Pi bridge upgrades to Wi-Fi when the bridge
  answers the FF16 handoff with its LAN endpoint. The BLE leg stays open as the
  fallback, and a radio drop no longer tears the session down while TCP carries
  it (ONY-1260).
- The Connect screen remembers the last bridge and auto-connects over the LAN
  on launch, to that bridge when it answers or to the only one a scan finds,
  and falls back to the stored hosts when discovery is blocked. A manual scan,
  a transport switch or a disconnect suppresses the automatic dial, and the
  remembered bridge can be forgotten (ONY-1261).
- Paired with WMR_Bridge `v0.3.23`.

## 0.3.21+26

- The Unity player no longer blacks out on the Pro Neckband: the window drops
  `windowIsTranslucent`, the embedded `SurfaceView`s stay on the application
  layer, and they no longer take focus, so Flutter keeps the key events
  (ONY-1203).
- Unity and hand tracking start only when the Bench or Debug screen opens; the
  Connect screen no longer runs the tracking probe on launch, and the recenter
  control moved to the Bench screen (ONY-1209).
- The external-test-user sheet warns against Device Mirroring and pins the
  `scrcpy --display-id=3` capture command (ONY-1204).
- Paired with WMR_Bridge `v0.3.19`.

## 0.3.20+25

- The guided bench shows live speed feedback during each pose capture: the
  active hand turns green inside the section 8 band and red outside it, with
  the measured speed and target band on screen, so a cell can be corrected
  while recording instead of only after it is saved (ONY-1176). A saved cell
  can be scored with the section 8 speed-gate validator (ONY-1138).
- The Connect screen discovers Pi bridges on the LAN with `WmrWsDiscovery`
  and offers an opt-in `CompositeBleTransport` link (TCP first, BLE GATT
  fallback) with an active-leg indicator (ONY-1143). Diagnostic bundles and
  the Debug and Latency screens record the composite active leg and stick
  settings (ONY-1170).
- Diagnostic bundles include a USB, display and XR device environment snapshot
  (ONY-1137).
- CI adds Kotlin unit tests for the HID plugin (ONY-1171) and makes the
  gitleaks, Semgrep and OSV scans blocking (ONY-1136); the release dex check
  runs as its own workflow.
- Paired with WMR_Bridge `v0.3.17`.

## 0.3.19+24

- `wmr_ws` discovers the Pi bridge on the LAN with a UDP probe and mDNS, and
  `CompositeBleTransport` keeps one logical connection: TCP first, BLE GATT as
  fallback, and a retry every 2 seconds to move back to TCP (ONY-1071,
  ONY-1072). The fallback is opt-in for library hosts; the reference app still
  connects through the WebSocket transport directly. It is not yet tested on
  hardware; that test is waiting on ONY-1070.
- `docs/LIBRARY.md` and `packages/wmr_ws/README.md` document the Pi TCP/BLE
  fallback contract and library discovery (ONY-1073).
- The native visionOS app is scaffolded with an ARKit tracking seam, a SwiftUI
  dashboard and a 6DoF scene, and its architecture, permissions and signing
  are documented (ONY-1039, ONY-1040, ONY-1041).
- The GATT latency probe is retired; its tool and release packaging are
  removed (ONY-1012).
- CI adds CodeQL and OSV dependency scanning with SARIF to code scanning
  (ONY-1079), and scans the published APK with MobSF plus a native-library
  inventory diff against the previous release (ONY-1085).
- Paired with WMR_Bridge `v0.3.15`, which adds the Pi bridge, the 5 GHz
  preference and keep-alive.

## 0.3.18+23

- The Debug screen names the connected bridge's FF16 firmware version and
  shows the FF11-FF17 feature bits, including FF17 controller control
  (ONY-907, ONY-910).
- `WmrCompanion` exposes FF17 controller control alongside FF13/FF15 and
  reconnects with a backoff instead of failing the session (ONY-909).
- The app depends on the `0.3.0` Dart packages (ONY-911).
- A Nintendo Switch hand is named as a Switch from its FF17 model, and its
  FF13 factory calibration and `0x30` burst timing are decoded so the debug
  panels no longer show it as WMR (ONY-948).
- The release workflow now also publishes `wmr-gatt-probe-<version>.apk`,
  the standalone GATT latency probe, on every release tag (ONY-932). It is
  signed with the project release key, so later probes update in place
  (ONY-961).

## 0.3.17+22

- The guided-bench still, drifting and pan/flick prompts now say to brace a
  forearm on a table, move at 10-50 cm/s, and keep the body still, matching the
  6-run protocol that WMR_Bridge triage expects (ONY-502).
- The device summary no longer reports "up to 0 Hz" when a runtime does not
  declare a hand rate; it says the rate is not declared and records 0 (ONY-502).
- The first two complete 6-run Android XR pose corpora are committed with the
  rev 4 tuning harness. Neither the 2026-11-03 nor the 2026-11-05 corpus has a
  passing grid point, so the filter constants remain the published defaults
  (ONY-502).
- Semgrep, gitleaks and Dependabot scan the repository; both scanners are
  report-only (ONY-890).

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
