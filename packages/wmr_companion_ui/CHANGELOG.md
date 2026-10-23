## 0.1.0

- First frozen line (pre-1.0). Optional Flutter widgets for `wmr_companion`
  hosts, extracted from the app's debug screen:
  - `OrientationView`/`OrientationPainter` for the 3DoF orientation cube.
  - `LinkStatusView`, `HandStatsView` and `GamepadStateView`.
- Takes facade models only: no Riverpod, app or `wmr_core`-internal imports.
- Not published to pub.dev yet; see `docs/PUBLISHING.md`.
