import 'package:wmr_core/services/controller_service.dart';
import 'package:wmr_companion/ui/debug/stream_settings.dart';

/// Starts the stream-mode provider on raw FF11 for tests written before FF14
/// became the app default.
class RawModeNotifier extends StreamModeNotifier {
  @override
  StreamMode build() => StreamMode.raw;
}
