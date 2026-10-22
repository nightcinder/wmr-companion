import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/axis_mapping.dart';
import '../../domain/hand_pipeline.dart';
import '../../services/controller_service.dart';

/// Which bridge stream the app wants. Applied to the service when it is
/// created and on change; the Capture screen needs [StreamMode.raw].
final streamModeProvider = NotifierProvider<StreamModeNotifier, StreamMode>(
  StreamModeNotifier.new,
);

class StreamModeNotifier extends Notifier<StreamMode> {
  @override
  StreamMode build() => StreamMode.raw;

  void set(StreamMode mode) => state = mode;
}

/// The hand whose orientation the debug view shows.
final selectedHandProvider = NotifierProvider<SelectedHand, int>(
  SelectedHand.new,
);

class SelectedHand extends Notifier<int> {
  @override
  int build() => 0;

  void set(int hand) => state = hand;
}

/// The sensor-to-view axis table, with the debug panel's flip toggles.
final axisMappingProvider = NotifierProvider<AxisMappingNotifier, AxisMapping>(
  AxisMappingNotifier.new,
);

class AxisMappingNotifier extends Notifier<AxisMapping> {
  @override
  AxisMapping build() => AxisMapping.defaultMapping;

  void setFlip(int viewAxis, bool value) =>
      state = state.withFlip(viewAxis, value);

  void setGyroFlip(int viewAxis, bool value) =>
      state = state.withGyroFlip(viewAxis, value);

  void reset() => state = AxisMapping.defaultMapping;
}

final filterKindProvider = NotifierProvider<FilterKindNotifier, FilterKind>(
  FilterKindNotifier.new,
);

class FilterKindNotifier extends Notifier<FilterKind> {
  @override
  FilterKind build() => FilterKind.madgwick;

  void set(FilterKind kind) => state = kind;
}
