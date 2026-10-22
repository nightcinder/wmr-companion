# Gamepad mapping

Status: in-app mapping layer and debug screen built; **not run on hardware**. Nothing leaves the app: no other app, OS or device sees a gamepad yet. The options for that are at the end and need a decision.

## Where it sits

```
FF12/FF14 record -> HandPipeline (timing, fusion, stick centre + dead zone)
                 -> HandInput (latest per hand)
                 -> mapGamepad(left, right, GamepadConfig) -> GamepadState
```

- `lib/domain/gamepad.dart`: pure Dart, stateless (`mapGamepad`, `triggerValue`, `trackpadButtons`, `tiltStick`). The same inputs and config always give the same state, so it can move to an isolate or a native hot path later.
- `lib/ui/gamepad/`: providers (latest input per hand from `ControllerService.decodedSamples`, about 30 Hz) and the Gamepad screen, opened from the debug screen's app bar (gamepad icon). Needs FF12 or FF14 mode; FF11 carries no decoded inputs.
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
| Trigger press (L2/R2) | 0.5 | Analog value after the dead zone. No hysteresis yet |
| Trackpad centre radius | 0.3 | A click nearer the centre presses nothing |
| Trackpad role per hand | LEFT d-pad, RIGHT ABXY | Or off |
| Invert stick Y, invert trackpad Y | off | For when the wire's y grows downwards |
| Tilt target, hand, full deflection, dead zone, invert X/Y | off, RIGHT, 35°, 3°, off | Signs follow the view frame; the vertical-axis sign of the axis table is itself unverified |

Settings are not saved between app runs yet.

## To check on hardware (not yet run)

1. FF12 mode, open the Gamepad screen, press each button on each hand: the matching lamp lights and nothing else.
2. Push each stick up: y goes positive. If not, toggle "Invert stick Y" and report it.
3. Pull each trigger slowly: note the highest "trigger" value at full pull (sets the full scale) and where L2/R2 light.
4. Click the trackpad top, bottom, left, right: Up/Down/Left/Right on LEFT, Y/A/X/B on RIGHT. If up and down swap, toggle "Invert trackpad Y".
5. Tilt to the right stick: lean the ring top right gives +x, tip it away gives +y.

## Making it a real gamepad (decision needed, not built)

The in-app layer is the common first step for every option below; each one only adds an output stage that sends `GamepadState` somewhere.

| Option | What it is | Reaches | Needs | Main risks |
|---|---|---|---|---|
| A. Phone as Bluetooth HID gamepad | Android `BluetoothHidDevice` API (Android 9+): the phone registers as a Classic Bluetooth HID device with a gamepad report descriptor and pairs with a host | PC (Windows, Linux, macOS), Android TV, other phones/tablets: anything that takes a generic HID gamepad. Not PlayStation/Switch/Xbox consoles | A small Kotlin plugin (platform channel), Bluetooth connect/advertise permissions, a report descriptor | Not every phone vendor enables the profile; the phone runs a Classic link to the host and a BLE link to the bridge at once (shared radio on the phone side, not on the ESP32); one host at a time |
| B. Wi-Fi to a PC companion | The phone sends state over UDP; on the PC either a virtual controller driver (Windows: ViGEm-style virtual Xbox pad; Linux: `uinput`) or the DSU ("cemuhook") protocol | PC games through the virtual pad; DSU also carries gyro/accel, which emulators (Dolphin, Cemu and others) use for motion | A PC-side program or driver (DSU needs only the emulator) | Extra hop and Wi-Fi jitter; PC software to install and maintain; ViGEmBus is no longer developed |
| C. Games on the phone itself | Inject a virtual gamepad into Android with `/dev/uinput` | Android games on the same phone | Root, or a shell-level helper such as Shizuku; normal apps cannot inject input (`INJECT_EVENTS` is a system permission) | Not possible on a stock unrooted phone without the helper; fragile across Android versions |
| D. ESP32 as the gamepad | The bridge itself presents a BLE HID (HOGP) gamepad to the host; the phone is not needed | Any BLE HID host | Firmware work in WMR_Bridge; mapping and fusion would move to the ESP32 | Competes for the same radio that is already losing reports from the controllers; a protocol and firmware change (ask first) |

Recommendation: **A** if the goal is "use the controllers as a gamepad on a PC or another device without extra software"; it fits the existing phone-in-the-middle design and needs only an Android plugin. **B with DSU** is the better pick if the main use is emulators that want motion. C and D are not recommended for now.
