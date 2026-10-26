# Changelog

## 0.2.0

- Version aligned with the v0.2.0 release; no breaking public API change.

## 0.1.0

- Initial release of optional Flutter UI widgets for `wmr_companion` hosts.
- `OrientationView` and `OrientationPainter`: 3D visualizer rendering a reference cube rotated by 3DoF orientation quaternions using active body-to-view matrix transforms.
- `ControllerPoseView` and `ControllerPosePainter`: low-poly WMR controller pose viewer with depth-sorted ring-and-handle mesh, floor grid, head marker, position trail and a labelled `ControllerPoseSource` badge.
- `LinkStatusView`: Displays connection state, device name, ATT MTU, RSSI, connection interval, stream mode, and active fault status from `WmrLinkSnapshot`.
- `HandStatsView`: Displays per-hand decoded telemetry including sample rate, sequence gap rate, tick loss, and cumulative drop counts, with fail-soft display (`-`) for unmeasured raw fields.
- `GamepadStateView`: Displays button bit states, analog trigger values, and 2D thumbstick coordinates from `GamepadState`.
- Framework-agnostic UI layer: depends only on Flutter SDK, `vector_math`, and `wmr_companion` facade models (free of Riverpod or host application dependencies).
