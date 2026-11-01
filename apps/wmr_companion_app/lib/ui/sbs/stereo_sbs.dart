import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
/// the eye width rather than at the full 3840 px. A single widget tree stays
/// mounted: navigation and Riverpod state are shared, only the painted tree is
/// built twice.
class StereoSbsWrapper extends ConsumerWidget {
  const StereoSbsWrapper({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final override = ref.watch(sbsOverrideProvider);
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
        Widget pane(Size size) => MediaQuery(
          data: media.copyWith(size: size),
          child: child,
        );
        // One pane when off, two when on. The first pane keeps its element
        // across a toggle, so typed text and open decisions survive it.
        return StereoSbs(
          data: data,
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Row(
              children: [
                Expanded(child: pane(active ? eye : viewport)),
                if (active) Expanded(child: pane(eye)),
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
