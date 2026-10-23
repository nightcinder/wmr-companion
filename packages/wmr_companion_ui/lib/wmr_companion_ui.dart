/// Optional Flutter widgets for a `wmr_companion` host.
///
/// This package is deliberately not required by the facade. It takes plain
/// facade models (quaternions, link snapshots, hand stats and gamepad state)
/// and has no Riverpod dependency, so a host can use it with whatever state
/// layer it already has.
library;

export 'src/gamepad_state_view.dart';
export 'src/hand_stats_view.dart';
export 'src/link_status_view.dart';
export 'src/orientation_view.dart';
