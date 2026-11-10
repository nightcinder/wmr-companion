import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vector_math/vector_math_64.dart' show Vector3;
import 'package:wmr_tracking/wmr_tracking.dart';

import '../debug/debug_providers.dart';

/// At or above this width/height ratio a display is two eye halves side by
/// side, as on the VITURE Pro Neckband and Luma Ultra (3840x1080 is 32:9,
/// ratio 3.56).
const double sbsAspectRatioThreshold = 3.0;

/// Whether [size] is a side-by-side stereo viewport.
bool isSbsViewport(Size size) =>
    size.height > 0 && size.width / size.height >= sbsAspectRatioThreshold;

/// `null` follows the viewport; `true`/`false` is the manual SBS toggle,
/// which lets a tester force mirroring on a phone or turn it off on glasses.
final sbsOverrideProvider = NotifierProvider<SbsOverride, bool?>(
  SbsOverride.new,
);

class SbsOverride extends Notifier<bool?> {
  @override
  bool? build() => null;

  void set(bool enabled) => state = enabled;
}

/// Bounds and gains for the displayless-UaaL head-pose counter-offset.
///
/// SpaceWalker treats a displayless `MainActivity` as head-locked, so the two
/// eye panes have to move against the head. The angles are capped well below
/// a real head turn, and the pixel shift stays inside a fraction of an eye so
/// a stale or wild pose can never slide the UI off screen.
const double stereoSbsMaxHeadYaw = 0.35; // radians, about 20 degrees
const double stereoSbsMaxHeadPitch = 0.26; // radians, about 15 degrees
const double stereoSbsMaxHeadTranslation = 0.30; // metres
const double stereoSbsPixelsPerRadian = 1100;
const double stereoSbsPixelsPerMetre = 900;
const double stereoSbsMaxOffsetFraction = 0.20;

/// Pixel shift applied to each eye pane to counter the head's 6DoF motion.
class StereoHeadOffset {
  const StereoHeadOffset(this.dx, this.dy);

  static const StereoHeadOffset zero = StereoHeadOffset(0, 0);

  final double dx;
  final double dy;

  bool get isZero => dx == 0 && dy == 0;

  @override
  bool operator ==(Object other) =>
      other is StereoHeadOffset && other.dx == dx && other.dy == dy;

  @override
  int get hashCode => Object.hash(dx, dy);

  @override
  String toString() => 'StereoHeadOffset($dx, $dy)';
}

double _wrapAngle(double angle) {
  var wrapped = angle;
  while (wrapped > math.pi) {
    wrapped -= 2 * math.pi;
  }
  while (wrapped < -math.pi) {
    wrapped += 2 * math.pi;
  }
  return wrapped;
}

/// The bounded offset that moves [viewport]'s content against the head pose
/// in [pose], measured from [origin].
///
/// A head turn right moves the pane left; looking up moves it down. Head
/// translation moves it the same way. Identity/zero input, a missing pose or
/// a missing origin all return [StereoHeadOffset.zero], so a source that only
/// reports `(0, 0, 0)` leaves the panes untouched.
StereoHeadOffset stereoSbsCounterOffset({
  required Pose? pose,
  required Pose? origin,
  required Size viewport,
}) {
  if (pose == null ||
      origin == null ||
      viewport.width <= 0 ||
      viewport.height <= 0) {
    return StereoHeadOffset.zero;
  }
  final forward = rotateVector(pose.rotation, Vector3(0, 0, -1));
  final originForward = rotateVector(origin.rotation, Vector3(0, 0, -1));
  final yaw = _wrapAngle(
    math.atan2(forward.x, -forward.z) -
        math.atan2(originForward.x, -originForward.z),
  );
  final pitch =
      math.asin(forward.y.clamp(-1.0, 1.0)) -
      math.asin(originForward.y.clamp(-1.0, 1.0));
  final yawBounded = yaw.clamp(-stereoSbsMaxHeadYaw, stereoSbsMaxHeadYaw);
  final pitchBounded = pitch.clamp(
    -stereoSbsMaxHeadPitch,
    stereoSbsMaxHeadPitch,
  );
  final xMeters = (pose.translation.x - origin.translation.x).clamp(
    -stereoSbsMaxHeadTranslation,
    stereoSbsMaxHeadTranslation,
  );
  final yMeters = (pose.translation.y - origin.translation.y).clamp(
    -stereoSbsMaxHeadTranslation,
    stereoSbsMaxHeadTranslation,
  );
  final maxDx = viewport.width / 2 * stereoSbsMaxOffsetFraction;
  final maxDy = viewport.height * stereoSbsMaxOffsetFraction;
  return StereoHeadOffset(
    (-yawBounded * stereoSbsPixelsPerRadian - xMeters * stereoSbsPixelsPerMetre)
        .clamp(-maxDx, maxDx),
    (pitchBounded * stereoSbsPixelsPerRadian +
            yMeters * stereoSbsPixelsPerMetre)
        .clamp(-maxDy, maxDy),
  );
}

/// Live head pose from the selected tracking source.
///
/// A wrapper with `headTracking: true` watches this for the 6DoF
/// counter-offset; watching [debugTrackingSourceProvider] also starts its
/// auto-detection probe. Wrappers on screens that have not opened a tracking
/// source (Connect) must leave this alone so the app does not start Unity or a
/// vendor player before the Bench or Debug screen opens. Frames without a head
/// pose are dropped and keep the previous value.
final stereoHeadPoseProvider = StreamProvider<Pose?>((ref) {
  final source = ref
      .watch(debugTrackingSourceProvider)
      .attachment
      .value
      ?.source;
  if (source == null) return const Stream<Pose?>.empty();
  return source.frames
      .map((frame) => frame.head?.pose)
      .where((pose) => pose != null);
});

/// The pose the counter-offset is measured from.
///
/// The first live pose becomes the origin so a source whose coordinates start
/// away from zero still opens centered. [StereoHeadOrigin.recenter] moves the
/// origin to the current pose on demand.
final stereoHeadOriginProvider = NotifierProvider<StereoHeadOrigin, Pose?>(
  StereoHeadOrigin.new,
);

class StereoHeadOrigin extends Notifier<Pose?> {
  @override
  Pose? build() {
    // A new tracking source means a new coordinate frame.
    ref.watch(
      debugTrackingSourceProvider.select((s) => s.attachment.value?.source),
    );
    ref.listen(stereoHeadPoseProvider, (previous, next) {
      final pose = next.value;
      if (pose != null && state == null) state = pose;
    });
    return null;
  }

  /// Centers the view on [pose], or on no pose when tracking is unavailable.
  void recenter([Pose? pose]) => state = pose;
}

/// The layout facts the wrapper publishes to the UI it mirrors, so a toggle
/// inside an eye half can still see the real viewport.
class StereoSbsData {
  const StereoSbsData({
    required this.active,
    required this.auto,
    required this.viewport,
  });

  final bool active;
  final bool auto;
  final Size viewport;
}

class StereoSbs extends InheritedWidget {
  const StereoSbs({super.key, required this.data, required super.child});

  final StereoSbsData data;

  static StereoSbsData? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<StereoSbs>()?.data;

  @override
  bool updateShouldNotify(StereoSbs oldWidget) =>
      data.active != oldWidget.data.active ||
      data.auto != oldWidget.data.auto ||
      data.viewport != oldWidget.data.viewport;
}

/// Mirrors [child] into the left and right eye halves of a 32:9 viewport, so
/// both eyes show the same UI instead of a black right half.
///
/// Each half gets its own [MediaQuery] sized to that half, so layouts wrap at
/// the eye width rather than at the full 3840 px. [child] is inflated twice,
/// once per half, so the two halves are two element trees: navigation and
/// Riverpod state are shared, but a screen must keep its D-pad focus nodes,
/// controllers and other mutable state *above* this wrapper so both halves read
/// the same value. [StereoSbsScrollController] does that for scroll offsets.
///
/// A [FocusNode] owned above the wrapper is attached to both halves; Flutter
/// keeps one attachment live but every `Focus` widget listening to the node
/// still paints the focus ring, so both eyes show the highlight.
///
/// Scope: the wrapper only mirrors screens that hoist their mutable state like
/// this — currently Connect and Bench. Pushed screens that still keep local
/// state (debug view, latency, capture, terms) are not wrapped, so they render
/// once at full viewport width. Root overlays built by the app's [Overlay]
/// (popup menu, licence page, dialogs, snackbars) also span the full viewport
/// and are not mirrored.
class StereoSbsWrapper extends ConsumerWidget {
  const StereoSbsWrapper({
    super.key,
    required this.child,
    this.headTracking = true,
  });

  final Widget child;

  /// Whether this screen already started a hand-tracking source.
  ///
  /// When false the wrapper never reads the head pose providers, so a screen
  /// that only mirrors its UI cannot start the auto-detection probe, Unity or
  /// a vendor player. The Connect screen sets this false; the Bench screen
  /// leaves it on and gets the 6DoF counter-offset as soon as its source runs.
  final bool headTracking;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final override = ref.watch(sbsOverrideProvider);
    final headPose = headTracking
        ? ref.watch(stereoHeadPoseProvider).value
        : null;
    final headOrigin = headTracking
        ? ref.watch(stereoHeadOriginProvider)
        : null;
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.hasBoundedWidth || !constraints.hasBoundedHeight) {
          return child;
        }
        final viewport = constraints.biggest;
        final auto = isSbsViewport(viewport);
        final active = override ?? auto;
        final media = MediaQuery.of(context);
        final data = StereoSbsData(
          active: active,
          auto: auto,
          viewport: viewport,
        );
        final eye = Size(viewport.width / 2, viewport.height);
        final offset = active
            ? stereoSbsCounterOffset(
                pose: headPose,
                origin: headOrigin,
                viewport: viewport,
              )
            : StereoHeadOffset.zero;
        Widget pane(Size size, Key key) => ClipRect(
          child: Transform.translate(
            key: key,
            offset: Offset(offset.dx, offset.dy),
            child: MediaQuery(
              data: media.copyWith(size: size),
              child: child,
            ),
          ),
        );
        // One pane when off, two when on. Rebuilding both panes on a toggle
        // gives the shared focus nodes a fresh attachment in the surviving
        // pane; the state that matters lives above the wrapper anyway.
        return StereoSbs(
          data: data,
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Row(
              key: ValueKey(active),
              children: [
                Expanded(
                  child: pane(
                    active ? eye : viewport,
                    const Key('sbs-eye-left'),
                  ),
                ),
                if (active)
                  Expanded(child: pane(eye, const Key('sbs-eye-right'))),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Toggles [StereoSbsWrapper] between automatic viewport detection and a
/// manual override.
class SbsToggleButton extends ConsumerWidget {
  const SbsToggleButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = View.of(context);
    final viewport = view.physicalSize / view.devicePixelRatio;
    final data = StereoSbs.maybeOf(context);
    final auto = data?.auto ?? isSbsViewport(viewport);
    final active = data?.active ?? (ref.watch(sbsOverrideProvider) ?? auto);
    return IconButton(
      key: const Key('toggle-sbs'),
      tooltip: active ? 'Stereo SBS on' : 'Stereo SBS off',
      icon: Icon(
        Icons.vertical_split,
        color: active ? Theme.of(context).colorScheme.primary : null,
      ),
      onPressed: () => ref.read(sbsOverrideProvider.notifier).set(!active),
    );
  }
}

/// Recenters the 6DoF counter-offset on the current head pose.
class SbsRecenterButton extends ConsumerWidget {
  const SbsRecenterButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return IconButton(
      key: const Key('sbs-recenter'),
      tooltip: 'Recenter 6DoF view',
      icon: const Icon(Icons.center_focus_strong),
      onPressed: () {
        final pose = ref.read(stereoHeadPoseProvider).value;
        ref.read(stereoHeadOriginProvider.notifier).recenter(pose);
      },
    );
  }
}

/// A [ScrollController] shared by both eye halves: a D-pad focus change
/// scrolls the pane that owns the focus, so every attached position mirrors
/// its offset to the others and the halves keep showing the same rows.
class StereoSbsScrollController extends ScrollController {
  bool _syncing = false;

  @override
  void attach(ScrollPosition position) {
    super.attach(position);
    position.addListener(() => _mirror(position));
  }

  void _mirror(ScrollPosition source) {
    if (_syncing || !source.hasPixels) return;
    _syncing = true;
    try {
      for (final position in positions) {
        if (identical(position, source) || !position.hasContentDimensions) {
          continue;
        }
        final target = source.pixels.clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        );
        if (position.pixels != target) position.jumpTo(target);
      }
    } finally {
      _syncing = false;
    }
  }
}
