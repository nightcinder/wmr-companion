# Companion as a Flutter library

Status: **phases 1–3 implemented.** `packages/wmr_core` holds the pure-Dart
protocol, domain, `BleTransport` interface, controller service and the pure
services; `packages/wmr_companion` is the public facade (`WmrCompanion`,
config, models, typed errors) with an API README and tests; and
`packages/wmr_ble` owns the `universal_ble` adapter/transport and the app
lifecycle hook. The app depends on all three by path and drives its real
connection through the facade. The UI package, Android HID add-on and
publishing are still targets; the current app remains the reference consumer.

Related: [PLAN.md](PLAN.md) (current architecture), [STATUS.md](STATUS.md)
(current state), [GAMEPAD.md](GAMEPAD.md) (mapping and output options),
[PROTOCOL.md](PROTOCOL.md) (wire format, app-side decisions), and
[IOS.md](IOS.md) with the native `WMRCompanionKit` from ONY-38 (PR #37).

## 1. Decision in one page

Turn the app into a **federated set of Flutter packages** whose public surface
is an in-process controller API, not an app and not a system-wide gamepad.

- **Android and iOS are both in scope from the first release.** This is a
  cross-platform Flutter library, not an Android app with an iOS follow-up. The
  first version must build and run on both; desktop and web are out of scope.
  Where the platforms differ (HID availability, MTU/interval control), the
  difference is documented and hidden behind the facade.
- **Core value is the pipeline, not the screens.** Scan, connect, FF11/FF12/FF14
  parsing, FF13 calibration, FF15 echo, loss/latency statistics, 3DoF fusion,
  gamepad mapping and multi-bridge coordination are reusable. The Connect,
  Debug, Capture, Latency and Gamepad screens are a reference/diagnostic app
  built on top.
- **On iOS, distribute behavior instead of pretending to be a gamepad.** iOS
  gives third-party apps no public way to register a system-wide virtual
  controller or a Bluetooth HID device. The workable answer is for the *host
  app* to link this library and consume `GamepadState`/`WmrControllerUpdate`
  inside its own process. That is the "bypass": no OS-level injection is
  needed, so the missing iOS HID API stops being a blocker. Android can keep
  the existing Bluetooth HID output as an **optional Android-only plugin
  package** for hosts that want the phone to appear as a system HID gamepad
  (for example to a PC or console); it is still a Flutter plugin, so its
  consumers are Flutter apps on Android, and it is no longer the primary
  delivery mechanism.
- **One Dart pipeline, platform-specific transports.** Keep protocol parsing and
  fusion in Dart so there is one implementation and one set of golden tests.
  Put the platform difference behind the existing `BleTransport` seam:
  `universal_ble` first on Android and iOS, a native CoreBluetooth transport
  (reusing the transport half of `WMRCompanionKit`) when iOS latency,
  background behavior or MTU visibility demand it.
- **Ship in phases, never a big-bang rewrite.** Extract pure Dart first, keep
  the app compiling through path dependencies, then extract Flutter/BLE, then
  the UI kit. Each phase is a small PR with the app as its first consumer.

## 2. Why a library, and what "bypassing iOS" means

Today the app is the only way to use the pipeline. Anyone who wants WMR
controller input in a game, emulator, XR shell or prototype must either use the
whole app (Android, system HID) or reimplement the protocol. A library changes
that:

| Consumer | Today | With the library |
| --- | --- | --- |
| Flutter game/app on Android | Use the app's HID output, if the vendor enables the profile | Import the package, read `GamepadState`/orientation directly |
| Flutter app on iOS | Not possible: no virtual gamepad/HID API | Import the package, read state in-process |
| Unity/Unreal/native app | Reimplement FF10–FF15 | Out of scope for v1; native kits (iOS `WMRCompanionKit`, Android probe) are the seam later |
| Diagnostics/QA | The companion app | Same app, rebuilt on the packages |

The iOS constraint, stated precisely:

- iOS has no public API equivalent to Android's `BluetoothHidDevice`. A normal
  app cannot make the phone appear as a Bluetooth HID gamepad to a PC or console.
- `GameController`/`GCController` is for *reading* controllers the system
  already knows about, not for publishing a virtual one.
- System-wide input injection is not available to App Store apps.
- Therefore the only general iOS path is **in-app consumption**: the app that
  wants the input embeds the pipeline. A Flutter library is exactly that, and
  it also removes the phone-as-middleman HID link from the latency budget.

The library therefore targets **Android and iOS together**: iOS is a first-class
platform from v1, not a later port. Android keeps a better system-wide story
(HID output, optional package) but that is an add-on, not the core promise.

This is an architectural bypass, not a platform or security bypass. It also
means the target audience is Flutter apps (games, emulators, XR/visionOS
shells, prototypes), not arbitrary iOS apps or consoles. For a system-wide
gamepad on iOS the only remaining route is firmware/hardware (the parked
"ESP32 as HID gamepad" idea, `GAMEPAD.md` option D), which is outside this
framework.

## 3. What is reusable today

Inventory as it stood before phase 1 (imports checked; see
`grep '^import .package:' lib`). Protocol, domain, `BleTransport`, the controller
service and the pure services have since moved to `packages/wmr_core/`; the
paths below are the original ones, quoted in the rest of the document where the
plan was written:

| Layer | Files | Dependencies | Reuse |
| --- | --- | --- | --- |
| Protocol | `lib/protocol/` (GATT ids, FF11 fragments, FF12/FF14 records and batches, FF13 block, FF15 echo, bridge status) | pure Dart | **Direct.** Golden-vector tests already exist |
| Domain | `lib/domain/` (tick timing, gyro bias, axis mapping, hand pipeline, orientation, stick centre, gamepad mapping) | pure Dart + `vector_math` | **Direct.** `gamepad.dart` is already stateless |
| Fusion | `packages/wmr_fusion/` | pure Dart, own vector/quaternion types | **Direct.** Optional; see math-type note in §9 |
| Service | `lib/services/controller_service.dart` | `dart:async` + domain/protocol | **Direct**, after a small transport-injection pass |
| File services | capture/latency/settings stores | `dart:io`, injectable directories; `config_key_store` uses Flutter assets | Move file IO behind injected `Directory`/asset loader |
| BLE | `lib/ble/ble_transport.dart`, `universal_ble_*`, fakes | Flutter plugin (`universal_ble`) | **Seam stays**; implementation becomes a package |
| HID | `lib/hid/` | Flutter services, Riverpod, Kotlin plugin | **Optional add-on**, not core |
| UI | `lib/ui/` | Flutter + Riverpod | **Optional UI package**; never required by consumers |
| App shell | `lib/main.dart`, `lib/app.dart` | Flutter | Becomes the example/reference app |

The important property already present: `BleTransport` is an interface, the
protocol is pure Dart, and the fake transport/bridge drive tests without
hardware. The extraction is mostly movement and dependency injection, not a
rewrite.

## 4. Target package topology

```
apps/wmr_companion_app                  reference app: Connect, Debug, Capture,
  |                                     Latency, Gamepad; hardware QA target
  +-- wmr_companion_ui (optional)       reusable widgets (3D view, link panel)
  +-- wmr_companion                     umbrella Flutter package, public API
  |     +-- wmr_core                    pure Dart: protocol + domain + services
  |     |     +-- wmr_fusion            pure Dart: Madgwick/Mahony
  |     +-- wmr_ble                     Flutter plugin: universal_ble + native
  +-- wmr_companion_hid_android         optional: phone-as-HID-gamepad output
```

| Package | Kind | Publishes | Responsibility | Must not import |
| --- | --- | --- | --- | --- |
| `wmr_core` | Dart | yes (after API freeze) | GATT ids, parsers, reassembler, config decode, echo, hand pipeline, loss/latency maths, gamepad mapping, `BleTransport` interface, `ControllerService` | Flutter, Riverpod, plugins, `dart:ui` |
| `wmr_fusion` | Dart | yes | 3DoF filters only | Flutter |
| `wmr_ble` | Flutter plugin | yes | `UniversalBleTransport`, native iOS/Android transports, permissions, adapter-state and app-lifecycle handling | UI, Riverpod, app settings |
| `wmr_companion` | Dart (Flutter once the BLE plugin lands) | yes | Facade (`WmrCompanion`), models/DTOs, defaults, lifecycle, capture/latency recorders with injected sinks | UI widgets, Riverpod |
| `wmr_companion_ui` | Flutter | optional | Debug 3D view, stats panel, gamepad tester | Core internals; talks to the facade |
| `wmr_companion_hid_android` | Flutter plugin | optional | Existing `BluetoothHidDevice` output | Core internals |
| `apps/wmr_companion_app` | Flutter app | no | The current app; dogfoods every package | — |

Use Dart pub workspaces (SDK is already `^3.13.5`) rather than adding Melos.
Path dependencies during migration; version constraints when published. Keep
the package names unpretentious and stable: `wmr_core`, `wmr_ble`,
`wmr_companion`, `wmr_companion_ui`, `wmr_companion_hid_android`.

Why not a single package with everything? Because a consumer that only wants
protocol/fusion should not inherit a BLE plugin, file plugins and Riverpod, and
because the pure-Dart core is the part most worth testing on the host without a
device. The split also keeps `wmr_companion_ui` optional, which matters for app
size and for non-Flutter-rendered consumers.

## 5. Public API

The facade is the only required import. It is deliberately **not** Riverpod:
Riverpod is an app-state choice, so the library exposes `Stream`s,
`ValueListenable`s and plain immutable models that any state layer can adapt.
No singletons (unlike the native kit's `WMRCompanionClient.shared`) so tests
and two independent sessions in one process stay possible.

```dart
import 'package:wmr_companion/wmr_companion.dart';

final wmr = WmrCompanion(
  ble: transport,                            // any BleTransport
  config: WmrCompanionConfig(
    streamMode: StreamMode.batched,          // FF14
    fusion: FusionConfig.madgwick(beta: 0.05),
  ),
);

await wmr.initialize();                      // adapter state, permissions (wmr_ble)
await wmr.startScan();
await for (final devices in wmr.bridges) {   // Stream<List<WmrBridgeDevice>>
  WmrBridgeDevice? bridge;
  for (final device in devices) {
    if (device.name == 'WMR Bridge') {
      bridge = device;
      break;
    }
  }
  if (bridge == null) continue;
  await wmr.connect(bridge);
  break;
}
await wmr.setStreamMode(StreamMode.batched); // FF14

// One stream per concern; all hot paths are broadcast.
final subs = [
  wmr.controllers.listen((WmrControllerUpdate u) {
    // u.hand, u.receivedAtUs, u.frame (FF11), u.decoded (FF12/FF14),
    // u.orientation (quaternion), u.input, u.stats
  }),
  wmr.gamepad.listen((GamepadState s) {
    // Buttons, sticks, triggers, optional tilt; ready to drive a game.
  }),
  wmr.link.listen((WmrLinkSnapshot s) {
    // MTU, RSSI, rate, gaps, tick-loss.
  }),
];

await wmr.dispose();
```

The example above is the one in `packages/wmr_companion/README.md`, and
`packages/wmr_companion/test/readme_example_test.dart` runs it against the fake
bridge.

Supporting shapes as frozen in phase 2:

```dart
enum Hand { left, right }
enum WmrConnectionState { idle, scanning, connecting, ready, reconnecting, failed }

class WmrBridgeDevice { final String id; final String? name; final int? rssi; }

class WmrControllerUpdate {
  final Hand hand;
  final int receivedAtUs;          // monotonic, stamped at transport boundary
  final WmrFrame? frame;           // raw FF11
  final DecodedRecord? decoded;    // FF12/FF14
  final Quaternion? orientation;   // fused, null until seeded
  final HandInput? input;          // buttons, stick, trackpad, trigger; null on FF11
  final WmrHandStats stats;        // rate, gaps, tick loss, dt
}

class WmrCompanionConfig {
  final StreamMode streamMode;     // none | raw | decoded | batched
  final FusionConfig fusion;       // filter kind + gains
  final AxisMapping axisMapping;
  final GamepadConfig gamepad;
  final StickConfig sticks;
  final bool autoReconnect;        // one retry after an unexpected drop
}
```

`requestedMtu` and `requestHighPriority` are deliberately **not** in the
phase-2 config: `BleTransport` has no request call, and a config field that
does nothing would be a lie. `wmr_ble` requests MTU 517 and high priority on
every connect; exposing them through the facade is a later API decision.

API rules:

- **Lifecycle is explicit.** `initialize` → `startScan`/`connect` →
  `setStreamMode` → `dispose`. No work starts in a constructor. Reconnect is a
  first-class state, not an exception.
- **Errors are typed and terminal/non-terminal is visible.** E.g.
  `WmrConnectionException`, `WmrStreamModeException` (ATT 0x80, MTU too small),
  `WmrTransportException`, `WmrConfigException` (CRC, missing Monado key). No
  raw platform exceptions leak.
- **Timestamps at the boundary.** The transport stamps arrival with a monotonic
  clock before any parsing, as `PLAN.md` requires. For FF12/FF14, `dt` still
  comes from device ticks, never the phone clock.
- **No hidden globals or static state.** Two bridges/sessions in one process
  must work; multi-bridge is already a product direction (PR #34).
- **Inputs are injectable.** `BleTransport`, fusion filter, `AxisMapping`,
  `GamepadConfig`, clock and file sink are constructor/config arguments.
- **Optional features fail soft.** Capture/latency recorders are not started
  unless asked; a missing Monado key is a status, not an exception; HID output
  is a separate package that can report `unsupported`.
- **Public surface is tested.** A small API test compiles the README example
  and refuses accidental exports from `lib/src/`.

## 6. Platform strategy: one seam, two transports

**Android and iOS are both v1 targets.** The transport sequence below is about
implementation order inside v1, not platform scope: both platforms ship in the
first public version.

```
WmrCompanion
  -> ControllerService -> parsers + fusion + gamepad mapping   (Dart, shared)
  -> BleTransport                                              (interface)
       +-- UniversalBleTransport   Android + iOS, phase 1
       +-- NativeIosTransport      CoreBluetooth via WMRCompanionKit, phase 2
       +-- NativeAndroidTransport  optional, if the M7 baseline demands it
       +-- FakeTransport           tests, replay, UI development
```

`BleTransport` already has the right shape: scan, connect, discover,
subscribe → `Stream<Uint8List>` with arrival timestamp, write, disconnect, plus
MTU/RSSI/connection info. The native transports implement the same interface;
nothing above knows which one is in use.

**Phase 1 (lowest risk): `universal_ble` on both platforms.** The Dart pipeline
already runs on Android at ~200 Hz per hand. On iOS, `universal_ble` uses
CoreBluetooth; the open questions are latency and jitter, MTU visibility, and
background behavior. This is the cheapest way to get a real iOS library build
and measure it.

**Phase 2 (when measurements justify it): native iOS transport.** ONY-38 (PR
#37) already built `packages/WMRCompanionKit`: CoreBluetooth central,
FF11–FF15 parsing, fusion, multi-bridge and a Combine/async facade, with a
SwiftUI probe. For the Flutter library, reuse its **transport** and, if needed,
its native pipeline behind a platform channel or FFI. Two viable shapes:

| Shape | Native side does | Dart side does | Trade-off |
| --- | --- | --- | --- |
| A. Native transport only | Scan/connect/MTU/RSSI, emits `(bytes, uptimeNs)` | Parsing, fusion, mapping, public API | One protocol implementation; best for consistency; channel overhead per notification (~200/s/hand) must be measured |
| B. Native pipeline | Full pipeline, emits decoded states | Thin typed bridge + facade | Lowest iOS latency and works in background; duplicates protocol/fusion logic already in Swift; parity risk |

Recommendation: **A first**, because the public contract is then identical on
both platforms and golden vectors stay in one language. Keep B as the escape
hatch if channel overhead or background execution becomes the limiting factor.
Either way, do not create a third protocol implementation: the Swift kit is the
iOS reference, Dart is the library reference, and both consume the same golden
fixtures.

Platform notes to encode in the package docs:

- **Android:** `BLUETOOTH_SCAN` (`neverForLocation`) and `BLUETOOTH_CONNECT`;
  legacy `ACCESS_FINE_LOCATION` with `maxSdkVersion=30`. Request MTU 517 and
  high connection priority after every connect (best effort; Android 14+ may
  ignore MTU). The plugin merges permissions; the host app still describes why.
- **iOS:** `NSBluetoothAlwaysUsageDescription` (and the older peripheral key if
  the host targets it), `bluetooth-central` background mode if background
  operation is claimed. iOS picks MTU and connection interval; do not promise
  either. `universal_ble` needs the host's `Info.plist` entries; the package
  cannot add them.
- **visionOS:** the same CoreBluetooth path as iOS where the OS permits it; the
  in-process API is the natural fit for XR shells that already render their own
  content. Treat it as supported-by-construction, verified later.
- **Desktop/web:** out of scope for v1. `BleTransport` leaves room, but no
  claim is made.

## 7. Data flow after extraction

```
host app
  |  imports package:wmr_companion
  v
WmrCompanion facade
  |  config, lifecycle, public streams
  v
ControllerService  --(per hand)-->  HandPipeline
  |                                   | tick timing, gyro bias,
  |                                   | axis mapping, fusion, stick centre
  |                                   v
  |                                WmrControllerUpdate / GamepadState
  v
BleTransport (wmr_ble)
  |  universal_ble or CoreBluetooth/GATT
  v
WMR Bridge (ESP32)  -- BLE FF10/FF11..FF15 -->  WMR controllers
```

The app-only concerns — screens, Riverpod providers, file pickers, share
sheets, HID output, debug painters — sit above or beside this line and are not
imported by `wmr_core` or `wmr_companion`.

## 8. Repository layout after extraction

```
wmr-companion/
  apps/wmr_companion_app/        # current app, moved in phase 4; CI builds the APK here
  packages/
    wmr_core/                    # phase 1: pure Dart (landed)
    wmr_fusion/                  # existing, kept pure Dart (landed)
    wmr_ble/                     # phase 3: universal_ble transport, link status, lifecycle hook (landed)
    wmr_companion/               # phase 2: umbrella facade (landed)
    wmr_companion_ui/            # phase 7: optional widgets
    wmr_companion_hid_android/   # phase 7: optional HID output
    WMRCompanionKit/             # native Swift kit (ONY-38, PR #37)
  docs/                          # unchanged, plus this file
  tool/                          # capture/analysis, probes
```

Moving the app into `apps/` is phase 4; during extraction it stays at the repo
root and depends on the packages by path. Its pubspec package name is already
`wmr_companion_app` (phase 2) so the facade can own the `wmr_companion` name;
the directory move changes paths, not imports. That keeps CI and the debug-APK
artifact stable while the boundary settles.

## 9. Compatibility, publishing and licensing

- **Semantic versioning** per package. `wmr_core` and `wmr_fusion` can reach
  1.0 first; `wmr_companion` follows once the facade is stable.
- **Protocol compatibility is explicit.** Export a `WmrProtocolVersion` and a
  documented bridge-firmware matrix (FF11/FF12 always; FF14 needs bridge
  firmware with batching; FF13/FF15 optional). Unknown fields/records must be
  skipped, not fatal, so a newer bridge does not crash an older app.
- **Publish on pub.dev** only after the API freeze, with `publish_to: none`
  until then. Keep the app's `publish_to: none`.
- **License:** MIT for the Dart packages and app. The Monado XOR key table is
  fetched, never committed (`HANDOFF.md` §3); the library accepts key bytes
  from the host and documents the BSL-1.0 notice. Do not bundle the key in a
  published package.
- **Firmware license is separate:** `WMR_Bridge` is BTstack-derived and
  non-commercial. The library talks to it over BLE and does not redistribute
  firmware; say so in the README so consumers are not surprised.
- **Math types:** `lib/domain` uses `vector_math` while `wmr_fusion` has its own
  `Vector3`/`Quaternion`. Freeze one public math vocabulary in `wmr_core`
  (recommend `vector_math`'s `Quaternion`/`Vector3`), and keep the conversion at
  the fusion boundary. Do not leak two quaternion types to consumers.
- **Minimum platforms:** Android `minSdk` per `universal_ble`; iOS 18 is the
  floor, as decided by the owner on ONY-38. Revisit only if it blocks a specific
  target; a library with a high floor is an adoption tax.
- **No plugin leakage:** `path_provider`, `share_plus` and `permission_handler`
  stay in the app or in optional packages. Core services take a `Directory` or
  a sink; the facade does not require file plugins.

## 10. Migration plan

Each phase is a PR-sized change, reviewed with the app as the first consumer.
A phase is done only when `dart format`, `flutter analyze`, `flutter test`,
package tests and the debug APK are green, and no behavior changed unless the
phase says so.

| # | Phase | Work | Acceptance |
| --- | --- | --- | --- |
| 0 | Framework (this doc) | Record the decision, package map, API and phases | Owner agrees on package names, iOS approach and scope |
| 1 | Pure-Dart core | Move `protocol/`, `domain/`, `controller_service` and pure services into `packages/wmr_core`; app depends by path; move tests and golden fixtures | App and core tests green; `wmr_core` has no Flutter/Riverpod import (CI grep) |
| 2 | Public facade | Add `WmrCompanion`, config, models, typed errors, `FakeTransport` example, API README; app uses the facade through a thin adapter | App works unchanged; README example compiles as a test; no `package:flutter` in `wmr_companion`'s public exports except the plugin type (met: the phase-2 facade has no Flutter dependency at all) |
| 3 | BLE package | Move `lib/ble/` into `wmr_ble`; keep `UniversalBleTransport` and fakes; add permission/adapter-state docs; inject app lifecycle | Android debug APK connects and streams on hardware (user-reported); fake tests green |
| 4 | Reference app | Keep the current app as `apps/wmr_companion_app` (or root app during transition); move UI/Riverpod/HID there; add an `example/` mini-app showing 20 lines to gamepad state | CI builds app; example builds; no UI code in core/facade |
| 5 | iOS in v1 | Ship iOS in the same first release: add iOS to the BLE package, `Info.plist`/Podfile docs, macOS CI compile; measure `universal_ble` latency with the existing probe/decision rule; decide native transport | iOS example builds and connects on a device (user-reported); Android and iOS both pass the example app; latency decision recorded in `LATENCY.md` |
| 6 | Native iOS transport (conditional) | Platform channel to `WMRCompanionKit`'s transport; same `BleTransport` contract; parity tests on shared fixtures | iOS latency/background requirement met or explicitly declined with numbers |
| 7 | Optional packages | `wmr_companion_ui` (3D view/stats), `wmr_companion_hid_android` (existing HID output) | App consumes the UI kit; HID package tested as before; neither is required by the facade |
| 8 | Publish | API freeze, docs, CHANGELOG, pub.dev, deprecation policy, example gallery | `dart pub publish --dry-run` clean; a fresh app can add the package and read gamepad state |

Phase 1 landed in #39 (`packages/wmr_core`) and phase 2 in the facade PR
(`packages/wmr_companion`); the remaining rows are still ahead.

Sequencing notes:

- Phases 1–5 are v1. Phase 6 is a transport upgrade, not the iOS launch: if
  measurements say `universal_ble` is good enough, iOS still ships in v1 and
  phase 6 never runs.
- Phase 1 must not change behavior. Do not "fix" the protocol while moving it.
- Phase 2 is where the API becomes a contract; freeze names and error types
  before phase 3.
- Phase 4 can be deferred if moving the app is disruptive; the root app can
  keep depending on path packages for several PRs.
- Phase 5 is the first real iOS evidence. Until then, iOS is design-only and
  must be labelled as such.

## 11. Testing and CI

- **Golden vectors** for FF11/FF12/FF14/FF13/FF15 already exist; keep them as
  the cross-language contract. Add the same fixtures as JSON so Dart and Swift
  tests read identical bytes.
- **Pure-Dart tests** run with `dart test` in `wmr_core`/`wmr_fusion` (no
  emulator). `FakeTransport` replays recorded captures, so the facade is
  testable without a phone.
- **Boundary checks in CI:** fail if `wmr_core` imports Flutter, Riverpod or a
  plugin; fail if `wmr_companion` exports `lib/src/`; fail if a public API
  symbol is removed without a major version bump (optional, later).
- **Platform CI:** Linux format/analyze/test for packages and app; Android
  debug APK; macOS `swift test` for `WMRCompanionKit` and
  `flutter build ios --config-only --no-codesign` (already added by ONY-38).
- **Hardware checks stay with the owner.** The library README must say what was
  and was not run on hardware, and keep the existing "user-reported" rule.
- **Latency decision rule:** reuse `docs/LATENCY.md` / the M7.2 run sheet to
  decide Flutter vs native transport; do not switch on vibes.

## 12. Risks and mitigations

| Risk | Why it matters | Mitigation |
| --- | --- | --- |
| iOS `universal_ble` latency/jitter or background limits | Could make the Dart pipeline unusable for real-time input | Measure early (phase 5); keep native transport seam; fall back to native pipeline only if numbers demand |
| Two implementations drift (Dart + Swift kit) | Different bytes, different bugs on the two platforms | One golden-fixture corpus; protocol version; native transport-only shape A preferred |
| API churn before adoption | A published package is a promise | Freeze facade in phase 2; semver; `publish_to: none` until 1.0 |
| Plugin leakage (file/share/permission plugins) | Consumers inherit permissions and platform code they do not want | Injected sinks; optional packages; CI import boundary |
| Riverpod/UI coupling | Library unusable outside this app | Facade exposes streams/models; UI package optional |
| Hidden singleton/state | Two sessions, tests and multi-bridge break | Constructor injection; no static mutable state |
| Monado key licensing | Cannot redistribute the table | Host supplies key; docs and notice; never commit |
| Firmware license surprise | BTstack non-commercial terms | Separate firmware repo; README states the library does not include firmware |
| Scope creep into system-wide gamepad | Reopens the iOS dead end | State the boundary: in-process input; HID only optional on Android; hardware path separate |
| Loss/latency remains unsolved upstream | A clean API over a lossy link still disappoints | Keep link stats in the public surface; do not market it as lossless |

## 13. Open decisions for the owner

1. **Package names and publishing:** are `wmr_core`, `wmr_ble`,
   `wmr_companion` (and optional `wmr_companion_ui`,
   `wmr_companion_hid_android`) the names to freeze, and is publishing to
   pub.dev intended, or private/path-only for now?
2. **iOS phase 1 transport:** accept `universal_ble` first and measure, or go
   straight to the ONY-38 `WMRCompanionKit` transport on iOS?
3. **App placement:** move the app to `apps/` (cleaner boundary) or keep it at
   the repo root during extraction (less churn)?
4. **Android HID:** keep the HID output as a supported optional package, or
   park it once the in-process API exists?
5. **Audience:** is the first consumer a Flutter game/emulator/XR app, or do we
   also need a non-Flutter SDK (then the native kits become products too)?

Settled: **iOS 18 is the minimum** (owner, ONY-38). **Android and iOS are both
in v1 scope** (owner, 2026-10-23 on ONY-41).

## 14. What this framework does not claim

- Phases 1–3 are implemented; the rest of the package tree and API is still a
  target, not a fact.
- It is not an iOS virtual gamepad and cannot make one appear.
- It does not promise iOS background operation, MTU, or connection interval.
- It does not fix the upstream controller-to-ESP32 report loss
  (WMR_Bridge issue #18); it exposes the statistics needed to see it.
- Nothing here has been run on iOS hardware. ONY-38's Swift kit is unit-tested
  and CI-compiled; hardware behavior is still unverified.
