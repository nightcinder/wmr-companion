# Gamepad mapping

Status: in-app mapping layer, debug screen and a Bluetooth HID output (option A below, chosen by the project owner) are built; **none of it has been run on hardware or on a phone**. CI only builds and unit-tests it.

## Where it sits

```
FF12/FF14 record -> HandPipeline (timing, fusion, stick centre + dead zone)
                 -> HandInput (latest per hand)
                 -> mapGamepad(left, right, GamepadConfig) -> GamepadState
```

- `packages/wmr_core/lib/domain/gamepad.dart`: pure Dart, stateless (`mapGamepad`, `triggerValue`, `trackpadButtons`, `tiltStick`). The same inputs and config always give the same state, so it can move to an isolate or a native hot path later.
- `apps/wmr_companion_app/lib/ui/gamepad/`: providers (latest input per hand from `ControllerService.decodedSamples`, about 30 Hz) and the Gamepad screen, opened from the debug screen's app bar (gamepad icon). Needs FF12 or FF14 mode; FF11 carries no decoded inputs.
- The parser, the subscription code and `ControllerService` are unchanged.

## Model and default mapping

One two-stick gamepad from both controllers. Sticks and triggers are analog; y is positive up.

| Controller input | LEFT | RIGHT |
|---|---|---|
| Thumbstick | Left stick | Right stick |
| Trigger (analog) | Left trigger, L2 past the press threshold | Right trigger, R2 past the press threshold |
| Squeeze (grip) | L1 | R1 |
| Thumbstick click | L3 | R3 |
| Menu | Select | Start |
| Home (Windows) | Guide | Guide |
| Trackpad click | D-pad, 8 sectors | A/B/X/Y: up Y, right B, down A, left X |
| Trackpad touch alone | nothing | nothing |
| BT pairing | not mapped | not mapped |
| Tilt (optional, off by default) | roll to x, pitch to y of a chosen stick; yaw is not used because it drifts | same |

Where tilt and the physical stick both move an axis, the larger magnitude wins.

## Settings (all live on the Gamepad screen)

Every number is a guess. The trigger and trackpad ranges have not been measured (WMR_Bridge `docs/DECODING.md`, "Unknown"), and the y directions of the stick and trackpad on the wire have not been checked.

| Setting | Default | Notes |
|---|---|---|
| Stick dead zone, learned rest centre | 0.05, on | Existing `StickConfig` on the debug screen, applied before the mapper |
| Trigger full scale (raw) | 255 | Lower it if a trigger never reaches 255 |
| Trigger dead zone | 0.05 | Fraction of full scale, output rescaled to 0..1 |
| Trigger press (L2/R2) | 0.55 | Analog value after the dead zone: at or above this L2/R2 press |
| Trigger release (L2/R2) | 0.45 | At or below this they release; the band between the two is the hysteresis that stops a resting finger from flickering L2/R2 |
| Trackpad centre radius | 0.3 | A click nearer the centre presses nothing |
| Trackpad role per hand | LEFT d-pad, RIGHT ABXY | Or off |
| Invert stick Y, invert trackpad Y | off | For when the wire's y grows downwards |
| Tilt target, hand, full deflection, dead zone, invert X/Y | off, RIGHT, 35°, 3°, off | Signs follow the view frame; the vertical-axis sign of the axis table is itself unverified |

The mapping settings are saved to `gamepad_settings.json` in the app documents directory (about 0.4 s after the last change) and loaded at startup; values outside the slider ranges are clamped and unknown ones fall back to the defaults. The stick dead zone, learn toggle and learned rest centre of each hand are saved the same way to `stick_settings.json`, so a calibration survives an app restart; a corrupt or missing file falls back to the defaults. The HID output state is not saved.

## To check on hardware (not yet run)

1. FF12 mode, open the Gamepad screen, press each button on each hand: the matching lamp lights and nothing else.
2. Push each stick up: y goes positive. If not, toggle "Invert stick Y" and report it.
3. Pull each trigger slowly: note the highest "trigger" value at full pull (sets the full scale) and where L2/R2 light.
4. Click the trackpad top, bottom, left, right: Up/Down/Left/Right on LEFT, Y/A/X/B on RIGHT. If up and down swap, toggle "Invert trackpad Y".
5. Tilt to the right stick: lean the ring top right gives +x, tip it away gives +y.

## Bluetooth HID output (option A, built, untested)

The phone registers as a Bluetooth HID gamepad with Android's `BluetoothHidDevice` (Android 9+) and sends one input report whenever the mapped state changes.

- `lib/hid/hid_report.dart` (pure Dart): report descriptor and `encodeHidReport`. Report ID 1, 9 bytes: 16 button bits in Android/Linux HID slot order (`hidButtonOrder`: A, B, C, X, Y, Z, L1, R1, L2, R2, Select, Start, Mode, L3, R3; C and Z are reserved and stay clear), hat switch from the d-pad (0..7 clockwise from up, 15 centred), left stick X/Y and right stick X/Y as signed -127..127 (HID Y is positive down, so the model's y is negated), left/right trigger as Brake/Accelerator 0..255.
- `lib/hid/hid_gamepad_transport.dart`: `HidGamepadTransport` interface and the method/event-channel implementation. Without the Android plugin it reports `unsupported`.
- `lib/hid/hid_output.dart`: `HidOutput` subscribes to the service's decoded samples (not the 30 Hz screen provider), maps both hands with the live settings and sends when the encoded bytes change. A new host gets the current state on connect.
- `android/.../HidGamepadPlugin.kt`: permission request (BLUETOOTH_CONNECT), profile proxy, `registerApp`, connection state, `sendReport`, paired devices, discoverable request. `MainActivity` wires it up.
- UI: "Bluetooth HID output" section on the Gamepad screen: Start/Stop, Make discoverable, paired devices with Connect, Disconnect, reports sent / errors.

Limits: reports go out only while the app is open and started (no background service); after reconnecting to the bridge, Stop and Start again; one host at a time; button naming depends on the host.

To check on a phone and host (not yet run):
1. Start; Android asks for the Bluetooth permission. If it says the HID profile is unavailable, that phone does not support it (some vendors do not).
2. Make discoverable, pair from the host's Bluetooth settings, or tap Connect on an already paired host. The status line shows "Connected to <host>".
3. On the host open a gamepad tester: press each controller button, move sticks, pull triggers, click the trackpad. Note which host button each one lands on, and report stick directions that are inverted.
4. Check the latency by feel and report whether input stalls while the app is in the foreground.

## Options considered

All options share the in-app layer; each only adds an output stage that sends `GamepadState` somewhere. Option A was built for the Companion app (`BluetoothHidDevice`). Option D (ESP32 BLE HOGP) was built in WMR_Bridge firmware v0.3.0+ (`docs/HID_GAMEPAD.md`); options B and C are not built.

| Option | What it is | Reaches | Needs | Main risks |
|---|---|---|---|---|
| A. Phone as Bluetooth HID gamepad | Android `BluetoothHidDevice` API (Android 9+): the phone registers as a Classic Bluetooth HID device with a gamepad report descriptor and pairs with a host | PC (Windows, Linux, macOS), Android TV, other phones/tablets: anything that takes a generic HID gamepad. Not PlayStation/Switch/Xbox consoles | A small Kotlin plugin (platform channel), Bluetooth connect/advertise permissions, a report descriptor | Not every phone vendor enables the profile; the phone runs a Classic link to the host and a BLE link to the bridge at once (shared radio on the phone side, not on the ESP32); one host at a time |
| B. Wi-Fi to a PC companion | The phone sends state over UDP; on the PC either a virtual controller driver (Windows: ViGEm-style virtual Xbox pad; Linux: `uinput`) or the DSU ("cemuhook") protocol | PC games through the virtual pad; DSU also carries gyro/accel, which emulators (Dolphin, Cemu and others) use for motion | A PC-side program or driver (DSU needs only the emulator) | Extra hop and Wi-Fi jitter; PC software to install and maintain; ViGEmBus is no longer developed |
| C. Games on the phone itself | Inject a virtual gamepad into Android with `/dev/uinput` | Android games on the same phone | Root, or a shell-level helper such as Shizuku; normal apps cannot inject input (`INJECT_EVENTS` is a system permission) | Not possible on a stock unrooted phone without the helper; fragile across Android versions |
| D. ESP32 as the gamepad | The bridge itself presents a BLE HID (HOGP) gamepad to the host; the phone is not needed | Any BLE HID host | Implemented in WMR_Bridge v0.3.0+ (service `0x1812` concurrent with `FF10`); mapping on ESP32 | BLE and Classic radio contention on the ESP32; disables Android HID Host if phone also enables Option A |

Recommendation: **A** when using the phone as a Bluetooth gamepad peripheral for an external PC or console without bridge firmware HID. If using firmware BLE HOGP (**D**), keep Option A disabled to avoid disabling Android's HID Host service. **B with DSU** remains the better pick if the main use is emulators that want motion. C is not recommended for now.
