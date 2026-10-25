import 'dart:convert';

import 'tracking_types.dart';

/// JSON contract between a native/Unity adapter and this package.
///
/// A platform plugin or sidecar sends one frame per message:
///
/// ```json
/// {
///   "v": 1,
///   "time_ns": 123456789,
///   "head": {"pose": {"t": [0, 1.6, 0], "q": [0, 0, 0, 1]},
///            "confidence": "high"},
///   "hands": {
///     "right": {
///       "hand": "right",
///       "joints": {
///         "palm": {"pose": {"t": [0.2, 1.2, -0.4],
///                           "q": [0, 0, 0, 1]},
///                  "confidence": "high"}
///       }
///     }
///   }
/// }
/// ```
///
/// Poses are in metres in an OpenXR-style right-handed frame (+X right,
/// +Y up, -Z forward) with quaternions ordered `[x, y, z, w]`. [time_ns] is
/// the adapter's monotonic timestamp; the host aligns it with
/// [SourceClockAligner] before fusion.
class TrackingFrameCodec {
  const TrackingFrameCodec();

  Map<String, Object?> encode(TrackingFrame frame) => frame.toJson();

  TrackingFrame decode(Object? json, {int? hostTimeNs}) =>
      TrackingFrame.fromJson(json, hostTimeNs: hostTimeNs);

  String encodeToString(TrackingFrame frame) => jsonEncode(frame.toJson());

  TrackingFrame decodeString(String source, {int? hostTimeNs}) =>
      TrackingFrame.fromJson(jsonDecode(source), hostTimeNs: hostTimeNs);
}
