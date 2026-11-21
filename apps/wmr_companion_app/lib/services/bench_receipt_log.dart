import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Writes one Android log line per TCP receipt the link timeline recorded, so
/// the `wlan-cycle` bench can read it with
/// `adb logcat -v raw -s WmrBenchReceipt:I`.
///
/// The host activity owns the platform side (`MainActivity.kt`), which logs
/// only when the app is debuggable. Release builds, other platforms and a
/// disabled logger emit nothing.
class BenchReceiptLog {
  BenchReceiptLog({MethodChannel? methods, bool? enabled})
    : _methods = methods ?? const MethodChannel(channelName),
      enabled = enabled ?? kDebugMode;

  static const channelName = 'com.onyxlens.wmr_companion/bench_log';
  static const tag = 'WmrBenchReceipt';

  final MethodChannel _methods;
  final bool enabled;
  final Set<String> _logged = {};

  /// Logs every receipt in [timeline] (a `linkTimelineFor` snapshot: the
  /// top-level marks plus the finished `episodes`) not logged before. Returns
  /// the lines sent.
  Future<List<String>> report(Map<String, Object?>? timeline) async {
    if (!enabled || timeline == null) return const [];
    final sent = <String>[];
    final episodes = timeline['episodes'];
    for (final marks in [
      if (episodes is List) ...episodes.whereType<Map<Object?, Object?>>(),
      timeline,
    ]) {
      final session = marks['first_tcp_record_session'];
      final us = marks['first_tcp_record_us'];
      if (session is! String || us is! int) continue;
      if (!_logged.add('$session|$us')) continue;
      final line =
          'session=$session first_tcp_record_us=$us '
          'first_tcp_record_wall_us=${marks['first_tcp_record_wall_us']}';
      try {
        await _methods.invokeMethod<void>('log', {'tag': tag, 'message': line});
        sent.add(line);
      } on MissingPluginException {
        // No Android host: nothing to log to.
      }
    }
    return sent;
  }
}
