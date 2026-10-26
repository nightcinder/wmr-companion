# wmr_companion_ui

Optional Flutter widgets for a [`wmr_companion`](../wmr_companion/README.md)
host. Nothing in the facade requires this package.

Status: **phase 7**. The widgets are extracted from the reference app's debug
screen; they take plain facade models and have no Riverpod, app or
`wmr_core`-internals dependency. Not published.

## Widgets

| Widget | Input | Shows |
| --- | --- | --- |
| `OrientationView` | `Quaternion` | 3DoF cube with body axes |
| `ControllerPoseView` | `ControllerPose`, optional head `Pose` | Low-poly ring-and-handle controller, orientation, position, trail, floor grid, head marker and position-source badge |
| `LinkStatusView` | `WmrLinkSnapshot` | state, device, MTU, RSSI, interval, PHY, mode, fault |
| `HandStatsView` | `Hand`, `WmrHandStats` | frames/records, rate, sequence gaps, tick loss, dt |
| `GamepadStateView` | `GamepadState` | sticks, triggers, buttons |

```dart
import 'package:wmr_companion_ui/wmr_companion_ui.dart';

SizedBox(
  height: 320,
  child: OrientationView(orientation: update.orientation!),
)
```

The host owns the state layer: pass the latest facade model from whatever
`StreamBuilder`, `ValueListenable` or state-management package it uses.

## Boundaries

- The package imports `package:wmr_companion` for the public models and
  `package:vector_math` for the quaternion. It does not import
  `flutter_riverpod`, `wmr_core` internals or the reference app; CI fails if it
  does.
- No widget starts a scan, connects, or owns a `WmrCompanion`. Lifecycle stays
  in the facade/host.
- The widgets are optional: a host that wants only input can ignore this
  package entirely.

## Tests

```sh
flutter pub get
flutter analyze
flutter test
```

Widget tests cover each view; no hardware or iOS run is involved.
