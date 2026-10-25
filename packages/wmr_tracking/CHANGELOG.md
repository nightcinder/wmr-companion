# Changelog

## 0.1.0

- Initial framework: `TrackingSource` seam, normalised `TrackingFrame` and
  OpenXR-named hand joints, vendor capability profiles and the JSON relay codec.
- `SourceClockAligner` maps vendor timestamps onto the host monotonic clock.
- `SixDofFuser` combines controller IMU orientation with runtime controller,
  hand-anchor and head-relative position sources.
- `FakeTrackingSource` and `RelayTrackingSource` for hardware-free tests,
  UI development and Unity/native sidecars.
