/// Vendor-neutral headset head and hand tracking for 6DoF controller fusion.
///
/// The package owns no vendor SDK. A `TrackingSource` implementation wraps
/// Android XR, XREAL, VITURE or a relay and emits normalised `TrackingFrame`s;
/// `SixDofFuser` combines those frames with the controller IMU orientation
/// from `wmr_core`.
library;

export 'src/clock.dart';
export 'src/codec.dart';
export 'src/fusion.dart';
export 'src/one_euro.dart';
export 'src/pose.dart';
export 'src/profiles.dart';
export 'src/tracking_source.dart';
export 'src/tracking_types.dart';
