import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:wmr_tracking_dispatch/wmr_tracking_dispatch.dart';

import 'debug_providers.dart';

/// Human-readable state of the automatically detected tracking source.
///
/// A failed source keeps its [TrackingException] details, including the typed
/// `unavailable` case when a Unity relay is not linked in the build.
String trackingSourceStatusText(DebugTrackingSelection selection) {
  final choice = selection.choice;
  if (choice == DebugTrackingSource.none) {
    return 'Off: 3DoF orientation only';
  }
  return selection.attachment.when(
    loading: () => choice == DebugTrackingSource.auto
        ? 'Detecting glasses...'
        : 'Starting ${choice.label}...',
    error: (error, _) => 'TrackingException(unavailable): $error',
    data: (value) {
      if (value.disabled) {
        return '${choice.label} is off: rebuild with '
            '--dart-define=${choice.buildFlag}=true';
      }
      final error = value.error;
      if (error != null) {
        return 'TrackingException(${error.kind.name}): ${error.message}';
      }
      final message = value.message;
      if (message != null) {
        return message;
      }
      if (value.running) {
        return choice == DebugTrackingSource.simulated
            ? 'FakeTrackingSource trajectory (no hardware)'
            : '${choice.label} tracking attached';
      }
      return 'Off: 3DoF orientation only';
    },
  );
}

String? _detectionSummary(GlassesDetection? detection) {
  if (detection == null || !detection.hasVendor) return null;
  final vendor = switch (detection.vendor) {
    GlassesVendor.viture => 'VITURE',
    GlassesVendor.xreal => 'XREAL',
    GlassesVendor.androidXr => 'Android XR',
    GlassesVendor.none => null,
  };
  if (vendor == null) return null;
  final host = switch (detection.host) {
    GlassesHost.neckband => 'VITURE Neckband',
    GlassesHost.beamPro => 'XREAL Beam Pro',
    GlassesHost.phone => 'phone',
    GlassesHost.unknown => 'this host',
  };
  final usb = detection.usbPermissionGranted
      ? 'USB ready'
      : 'USB permission not granted';
  return 'Detected $vendor on $host · $usb';
}

/// Read-only glasses status shared by the debug and bench screens.
///
/// The vendor is detected from the host and USB; there is no manual dropdown.
/// [redetect] re-runs detection after the tester connects glasses, and the
/// Simulated switch is the fallback when nothing is detected or both vendor
/// USB IDs are present, so a tester can still exercise 6DoF.
class TrackingSourceBanner extends ConsumerWidget {
  const TrackingSourceBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final selection = ref.watch(debugTrackingSourceProvider);
    final attachment = selection.attachment.value;
    final detection = attachment?.detection;
    final loading = selection.attachment.isLoading;
    final canDetect = ref.watch(debugTrackingSelectorProvider).flags.any;
    final simulated = selection.choice == DebugTrackingSource.simulated;
    // Auto stays selected with no source when nothing matched or both vendors
    // are attached; that is the 0DoF state where Simulated is the fallback.
    // A flag-off build has no vendor source to fall back from, so keep the
    // banner compact there.
    final fallback =
        canDetect &&
        selection.choice == DebugTrackingSource.auto &&
        !loading &&
        !(detection?.hasVendor ?? false);

    return Material(
      key: const Key('tracking-source-banner'),
      color: theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.visibility_outlined, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _detectionSummary(detection) ?? 'Glasses detection',
                    style: theme.textTheme.labelLarge,
                  ),
                ),
                TextButton.icon(
                  key: const Key('tracking-source-redetect'),
                  onPressed: loading || !canDetect
                      ? null
                      : () => ref
                            .read(debugTrackingSourceProvider.notifier)
                            .redetect(),
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('Re-detect'),
                ),
              ],
            ),
            Text(
              trackingSourceStatusText(selection),
              key: const Key('tracking-source-status'),
              style: theme.textTheme.bodySmall,
            ),
            if (fallback || simulated)
              SwitchListTile.adaptive(
                key: const Key('tracking-source-simulated'),
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: simulated,
                title: const Text('Simulated tracking'),
                subtitle: Text(
                  simulated
                      ? 'Fake 6DoF trajectory, no glasses needed'
                      : 'No glasses detected; use the simulated 6DoF source',
                ),
                onChanged: (value) {
                  final notifier = ref.read(
                    debugTrackingSourceProvider.notifier,
                  );
                  if (value) {
                    notifier.set(DebugTrackingSource.simulated);
                  } else {
                    notifier.redetect();
                  }
                },
              ),
          ],
        ),
      ),
    );
  }
}
