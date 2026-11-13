# Gamepad mapping

Status: The mapping layer, debug screen, and Bluetooth HID output are built, but none of this code has run on hardware or on a phone. The trigger ranges, trackpad ranges, and vertical axis directions remain unmeasured. CI only builds and unit-tests this code.

This document describes the gamepad mapping layer, Bluetooth output modes, and external XR input integration.

## Architecture

The gamepad mapping sits after packet decoding and hand pipeline fusion.

```
FF12/FF14 record -> HandPipeline (timing, fusion, stick center, dead zone)
                 -> HandInput (latest per hand)
                 -> mapGamepad(left, right, GamepadConfig) -> GamepadState
```

The mapping layer uses these components:

- `packages/wmr_core/lib/domain/gamepad.dart`: pure Dart functions that map hand inputs to a gamepad state. The same inputs and configuration always produce the same state.
- `apps/wmr_companion_app/lib/ui/gamepad/`: state providers and the Gamepad screen. The providers sample controller state at approximately 30 Hz.
- The Gamepad screen requires FF12 or FF14 mode. Mode FF11 carries no decoded inputs.

## Default mapping

The default configuration combines two controllers into one two-stick gamepad. Sticks and triggers provide analog values. Positive Y points up.

| Controller input | Left controller | Right controller |
|---|---|---|
| Thumbstick | Left thumbstick | Right thumbstick |
| Trigger (analog) | Left trigger, L2 past the press threshold | Right trigger, R2 past the press threshold |
| Squeeze (grip) | L1 button | R1 button |
| Thumbstick click | L3 button | R3 button |
| Menu | Select button | Start button |
| Home (Windows) | Guide button | Guide button |
| Trackpad click | D-pad in eight sectors | A, B, X, Y buttons (Up Y, Right B, Down A, Left X) |
| Trackpad touch alone | Not mapped | Not mapped |
| Bluetooth pairing button | Not mapped | Not mapped |
| Tilt (optional, off by default) | Roll to X, pitch to Y on selected stick | Same |

If tilt and the physical stick both move an axis, the larger magnitude wins.

## Settings

You can adjust mapping settings on the Gamepad screen. Every number is an estimate. The trigger and trackpad ranges have not been measured on hardware, and vertical axis directions on the wire have not been verified.

| Setting | Default | Description |
|---|---|---|
| Stick dead zone, learned rest center | 0.05, on | Applied by `StickConfig` before mapping |
| Trigger full scale (raw) | 255 | Lower this value if a trigger never reaches 255 |
| Trigger dead zone | 0.05 | Fraction of full scale rescaled to 0.0 through 1.0 |
| Trigger press (L2/R2) | 0.55 | Value at or above which L2 or R2 activates |
| Trigger release (L2/R2) | 0.45 | Value at or below which L2 or R2 releases |
| Trackpad center radius | 0.3 | Clicks inside this radius trigger no button |
| Trackpad role per hand | Left D-pad, Right ABXY | Button assignment or off |
| Invert stick Y, invert trackpad Y | Off | Inverts the vertical axis |
| Tilt configuration | Off, Right, 35 deg, 3 deg, off | Target stick, hand, full deflection, dead zone, inversion |

The application saves mapping configuration to `gamepad_settings.json` in the app documents directory. The application saves stick settings to `stick_settings.json`. If a configuration file is missing or corrupt, settings return to defaults.

## Hardware test steps (not yet run on hardware)

To test controller mapping on hardware:

1. Connect controllers in FF12 mode.
2. Open the Gamepad screen.
3. Press each button on each controller and make sure that the matching indicator lights.
4. Push each stick forward and make sure that Y moves positive.
5. If Y moves negative, turn on Invert stick Y.
6. Pull each trigger slowly to make sure that full scale and threshold activation work.
7. Click each trackpad quadrant and make sure that the correct buttons trigger.

## Bluetooth HID output mode

The phone can act as a Bluetooth HID gamepad peripheral for a remote host.

- `packages/wmr_companion_hid_android/lib/src/hid_report.dart`: encodes the 9-byte HID gamepad report.
- `packages/wmr_companion_hid_android/lib/src/hid_gamepad_transport.dart`: platform channel interface for `BluetoothHidDevice`.
- `apps/wmr_companion_app/lib/hid/hid_output.dart`: listens to decoded samples and sends HID reports when state changes.
- `packages/wmr_companion_hid_android/android/src/main/kotlin/com/onyxlens/wmr_companion_hid_android/WmrCompanionHidPlugin.kt`: registers the Android Bluetooth HID peripheral profile with `WmrCompanionHidPlugin`.

### Operational limits

The Bluetooth HID output mode has four constraints:

1. Reports go out only while the application stays open and active in the foreground because no background service exists.
2. If you reconnect the controller bridge, you must stop and start HID output again.
3. The phone connects to only one host at a time.
4. Button naming and layout depend on the host operating system.

### Hardware test steps (not yet run on hardware)

To test Bluetooth HID output on a phone and host:

1. Start HID output on the Gamepad screen.
2. Make the phone discoverable.
3. Pair the remote host to the phone.
4. Make sure that input responses appear on the host gamepad tester.

## Output options and coexistence

The project supports multiple output destinations.

| Option | Transport | Target | Notes |
|---|---|---|---|
| A. Phone Bluetooth HID | Classic Bluetooth peripheral (`BluetoothHidDevice`) | Remote PC or console | Phone presents a gamepad peripheral to a remote device |
| B. Wi-Fi companion | UDP to PC driver or DSU protocol | PC games or emulators | Sends gamepad and motion data over local Wi-Fi |
| C. Android uinput | Local `/dev/uinput` injection | Local Android games | Requires root or system permissions |
| D. Bridge BLE HOGP | Direct BLE HID (`0x1812`) from bridge | Any Bluetooth host | ESP32 or Raspberry Pi presents standard gamepad |
| E. DroidDeck External XR | Local Unix socket or loopback UDP | Local DroidDeck SteamVR | Streams 6DoF poses, analog controls, and haptics |

Output modes require specific coexistence rules:

- If you use Option E (DroidDeck External XR), turn off Option A (Phone Bluetooth HID). Android Bluetooth HID peripheral mode disrupts local Bluetooth host connections.
- If you use Option D (Bridge BLE HOGP), keep Option A turned off to avoid conflicts in the Android Bluetooth stack.
- When Option D connects to the phone, Android binds the bridge as an `InputDevice`. To stop duplicate gamepad events in DroidDeck, Option E sends a claim packet.

## DroidDeck External 6DoF input API

DroidDeck provides an experimental v0 interface for external 6DoF controller input. External producers send controller poses, buttons, and axes to DroidDeck. DroidDeck forwards controller data to SteamVR and returns haptic pulses.

The binary interface source of truth is `tools/vr/src/ext_xr_input.h` in the [nightcinder/DroidDeck](https://github.com/nightcinder/DroidDeck/tree/eb03e880a06b13b4afaadd1aa87b25537569b559) repository at commit [`eb03e88`](https://github.com/nightcinder/DroidDeck/commit/eb03e880a06b13b4afaadd1aa87b25537569b559). The interface is also documented in [`docs/EXTERNAL_XR_INPUT.md`](https://github.com/nightcinder/DroidDeck/blob/eb03e880a06b13b4afaadd1aa87b25537569b559/docs/EXTERNAL_XR_INPUT.md). The binary interface freezes only when contributors submit the feature to upstream DroidDeck.

### Transports

The API supports two local transports:

1. Primary transport: abstract Unix domain sequential packet socket (`SOCK_SEQPACKET`) at `droiddeck-ext-xr`. Peer authentication uses `SO_PEERCRED`. The host approves `com.onyxlens.wmr_companion` and `com.onyxlens.wmr_companion.debug` by default. Other apps require explicit approval.
2. Fallback transport: localhost UDP on `127.0.0.1:29842`. Every datagram requires the 32-bit session pairing token at byte offset 32. DroidDeck writes the token to `droiddeck-ext-xr.token` in its runtime directory.

The companion uses the abstract socket only. The UDP pairing token sits in DroidDeck's private files directory, which the companion's UID cannot read, and DroidDeck has no UI that displays it. `openDroidDeckXrTransport` therefore has no UDP path: if the abstract socket cannot be opened it throws `DroidDeckXrTransportException` naming the socket and the expected `applicationId`, rather than falling back.

### Enabling it in the companion app

The stream is live in the reference app, not only in the packages:

1. Connect to a bridge and switch the stream to FF12 or FF14 on the debug screen. Raw (FF11) mode carries no samples, so nothing is sent.
2. Open the Gamepad screen and expand **DroidDeck 6DoF streaming**, then press **Start streaming**.
3. Start DroidDeck on the same device. The panel shows the packet and error counts and, per hand, whether the last packet carried a position (`6DoF`) or not (`3DoF`).

Starting the stream disables the phone's Bluetooth HID peripheral role (Option A), and stopping it restores the role only if this session turned it off. Pressing **Start** on the Bluetooth HID panel during a stream stops the stream instead, because Android's HID peripheral mode breaks the local Bluetooth host link DroidDeck needs (ONY-1235).

Position comes from the live 6DoF fuser: attach a tracking source on the debug screen and both hands are sent with tracked positions. With no tracking source the pipeline is orientation only, and the packet carries zero positions and a valid rotation; SteamVR still tracks rotation for that hand. The companion sends no PadBridge claim packet: the flat gamepad it would exclude is its own HID role, which is off during the stream. Excluding a bridge that Android binds as an `InputDevice` (Option D) needs that device's vendor and product ids, which the app cannot read without a new platform call, and is still open.

### Building a testable APK

No DroidDeck rebuild is needed for the companion side: the sink speaks the `v0` interface of the `nightcinder/DroidDeck` `android-xr` fork at `eb03e88`, which has to be installed on the same device.

```
cd apps/wmr_companion_app
tool/build_flavor.sh unified --debug
```

The debug APK is `com.onyxlens.wmr_companion.debug`, which DroidDeck approves by default, so it can be installed beside a release build. A release APK (`tool/build_flavor.sh unified --release`) keeps `com.onyxlens.wmr_companion` and needs the signing keys described in `docs/RELEASE_SIGNING.md`. A different `applicationId` is refused by `SO_PEERCRED` and the panel reports the connect failure.

### Header layout

Every packet begins with a 40-byte header.

| Offset | Type | Field | Description |
|---|---|---|---|
| 0 | uint32 | magic | Magic number `0x52584544` (ASCII `DEXR`) |
| 4 | uint32 | version | Protocol version (`0` for experimental v0) |
| 8 | uint32 | sequence | Packet sequence counter on wire |
| 12 | uint32 | header_size | Header size in bytes (`40`) |
| 16 | uint32 | flags | Bit 0: focused, Bit 1: claim packet |
| 20 | uint32 | source_id | Producer source identifier |
| 24 | int64 | time_ns | Sample timestamp in nanoseconds (`CLOCK_MONOTONIC`) |
| 32 | uint32 | token | Pairing token for UDP, zero on Unix socket |
| 36 | uint32 | reserved | Reserved padding, set to zero |

The producer must set `DROIDDECK_EXT_XR_FOCUSED` (`1 << 0`). If this flag is clear, DroidDeck drops the packet. The timestamp must use `CLOCK_MONOTONIC`. If the sample timestamp differs from host time by more than 500,000,000 nanoseconds, DroidDeck drops the packet.

### 6DoF input packet

An input packet contains 264 bytes. The packet holds the 40-byte header and two 112-byte hand structures.

Left hand data starts at offset 40. Right hand data starts at offset 152.

| Hand offset | Packet offset (Left) | Packet offset (Right) | Type | Field | Description |
|---|---|---|---|---|---|
| 0 | 40 | 152 | uint32 | flags | Hand state flags |
| 4 | 44 | 156 | uint32 | buttons | Button click bitmask |
| 8 | 48 | 160 | uint32 | touches | Button touch bitmask |
| 12 | 52 | 164 | uint32 | reserved | Reserved padding |
| 16 | 56 | 168 | float[3] | position | Position in meters (X, Y, Z) |
| 28 | 68 | 180 | float[4] | orientation | Unit quaternion (X, Y, Z, W) |
| 44 | 84 | 196 | float[3] | linear_velocity | Linear velocity in meters per second |
| 56 | 96 | 208 | float[3] | angular_velocity | Angular velocity in radians per second |
| 68 | 108 | 220 | float | trigger | Analog trigger (0.0 to 1.0) |
| 72 | 112 | 224 | float | squeeze | Analog grip squeeze (0.0 to 1.0) |
| 76 | 116 | 228 | float[2] | stick | Analog thumbstick (X, Y in -1.0 to 1.0) |
| 84 | 124 | 236 | float[2] | trackpad | Analog trackpad (X, Y in -1.0 to 1.0) |
| 92 | 132 | 244 | float | battery | Battery level (0.0 to 1.0, negative if unknown) |
| 96 | 136 | 248 | int64 | sample_time_ns | Sample timestamp in nanoseconds |
| 104 | 144 | 256 | uint32 | recenter | Recenter counter |
| 108 | 148 | 260 | uint32 | reserved2 | Reserved padding |

Position uses the right-handed OpenXR coordinate system: positive X points right, positive Y points up, and negative Z points forward.

### PadBridge claim packet and timeout rules

A producer sends a 184-byte claim packet to exclude its devices from PadBridge. The header flags must include `DROIDDECK_EXT_XR_PACKET_CLAIM` (`1 << 1`).

| Offset | Type | Field | Description |
|---|---|---|---|
| 0 | uint8[40] | header | Header with `DROIDDECK_EXT_XR_PACKET_CLAIM` set |
| 40 | uint32 | vendor_id | USB or Bluetooth vendor identifier |
| 44 | uint32 | product_id | USB or Bluetooth product identifier |
| 48 | uint32 | flags | Claim flags |
| 52 | uint32 | reserved | Reserved padding |
| 56 | char[64] | descriptor | Android device descriptor string |
| 120 | char[64] | name | Fallback device name string |

The server matches the vendor identifier and product identifier. If provided, the server matches the device descriptor string. The server checks the device name as a fallback.

A claim packet refreshes the producer session timer. If no packet arrives for 1000 milliseconds, the session times out. When a session times out, DroidDeck releases the claim and returns the device to PadBridge.

### Haptic reply packet

DroidDeck sends 64-byte haptic feedback replies to active producers.

| Offset | Type | Field | Description |
|---|---|---|---|
| 0 | uint32 | magic | Magic number `0x52584544` |
| 4 | uint32 | version | Protocol version (`0`) |
| 8 | uint32 | header_size | Header size in bytes (`64`, reply packet is all header) |
| 12 | uint32 | hand | Target hand (`0` for left, `1` for right) |
| 16 | float | amplitude | Vibration intensity (0.0 to 1.0) |
| 20 | float | frequency | Vibration frequency in Hertz |
| 24 | uint32 | duration_ms | Pulse duration in milliseconds |
| 28 | uint32 | reserved | Reserved padding |
| 32 | int64 | time_ns | Timestamp in nanoseconds (`CLOCK_MONOTONIC`) |
| 40 | uint64[3] | reserved2 | Reserved padding |

The host polls for haptic events every 8 milliseconds. DroidDeck sends replies through the connected Unix socket or back to the UDP sender address.
