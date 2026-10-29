import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'package:wmr_core/protocol/firmware_version.dart';
import 'package:wmr_core/services/controller_service.dart';

import '../ui/bench/bench_tracking.dart';
import '../ui/capture/capture_providers.dart';
import '../ui/connect/connect_providers.dart';
import '../ui/latency/latency_providers.dart';
import 'test_bundle.dart';

/// App and device facts that go into the manifest and diagnostics.
class BundleDeviceInfo {
  const BundleDeviceInfo({
    required this.appVersion,
    required this.phone,
    required this.androidVersion,
  });

  final String appVersion;
  final String phone;
  final String androidVersion;
}

/// Reads the app version and the Android model and release.
///
/// Failures degrade to `unknown` rather than blocking the export: the bundle is
/// still useful without them.
final bundleDeviceInfoProvider = Provider<Future<BundleDeviceInfo> Function()>((
  ref,
) {
  return () async {
    var appVersion = 'unknown';
    try {
      final info = await PackageInfo.fromPlatform();
      appVersion = info.buildNumber.isEmpty
          ? info.version
          : '${info.version}+${info.buildNumber}';
    } catch (_) {}

    var phone = 'unknown';
    var android = 'unknown';
    try {
      if (Platform.isAndroid) {
        final info = await DeviceInfoPlugin().androidInfo;
        final model = '${info.manufacturer} ${info.model}'.trim();
        phone = model.isEmpty ? 'unknown' : model;
        android =
            'Android ${info.version.release} (API ${info.version.sdkInt})';
      } else {
        phone = Platform.localHostname;
        android = Platform.operatingSystemVersion;
      }
    } catch (_) {}
    return BundleDeviceInfo(
      appVersion: appVersion,
      phone: phone,
      androidVersion: android,
    );
  };
});

/// The clock the file name and manifest use. Fixed in tests.
final bundleClockProvider = Provider<DateTime Function()>(
  (ref) => DateTime.now,
);

/// The short git commit the APK was built from. `tool/build_flavor.sh` passes
/// `WMR_APP_COMMIT`; a plain `flutter build` leaves it `unknown`.
final appCommitProvider = Provider<String>(
  (ref) =>
      const String.fromEnvironment('WMR_APP_COMMIT', defaultValue: 'unknown'),
);

/// Where `wmr-ext-<date>.zip` is written before the share sheet opens.
final bundleOutputDirectoryProvider = FutureProvider<Directory>((ref) async {
  final documents = await getApplicationDocumentsDirectory();
  return Directory('${documents.path}${Platform.pathSeparator}exports');
});

/// Builds the bundle input, with an explicit bench run when a wizard ends in
/// the export.
typedef TestBundleInputBuilder = Future<TestBundleInput> Function({
  BenchBundleRun? benchRun,
});

/// Gathers what the app already holds. Runs when the user taps export, so the
/// figures are the ones on screen at that moment.
final testBundleInputProvider = Provider<TestBundleInputBuilder>((ref) {
  return ({BenchBundleRun? benchRun}) async {
    final device = ref.read(realDeviceProvider);
    final service = ref.read(realDeviceProvider.notifier).service;
    final info = await ref.read(bundleDeviceInfoProvider)();
    final kinds = ref.read(bridgeTransportKindsProvider);

    final bridges = <BundleBridge>[];
    try {
      final links = service == null
          ? const <BridgeLinkSnapshot>[]
          : await service.bridgeLinks();
      for (final link in links) {
        bridges.add(
          BundleBridge(
            id: link.bridgeId,
            transport: kinds[link.bridgeId]?.label,
            firmwareVersion: link.protocol?.firmwareVersion,
            firmwareMalformed: link.protocol?.firmwareVersionMalformed ?? false,
            firmwareFeaturePresent:
                link.protocol?.features.firmwareVersion ?? false,
            firmwareUnavailable: link.protocolUnavailable,
            features: [
              for (final feature
                  in link.protocol?.features.offered ??
                      const <WmrBridgeFeature>{})
                feature.name,
            ],
            mtu: link.mtu,
            rssi: link.rssi,
            connectionIntervalUs: link.connectionIntervalUs,
            phy: link.phy,
            linkState: 'connected',
            mode: link.mode.name,
            rateHz: link.rateHz,
            loss: link.loss,
          ),
        );
      }
    } catch (_) {
      // Fall through to the status below; a link read is best effort.
    }
    if (bridges.isEmpty && device.deviceId != null) {
      final id = device.deviceId!;
      bridges.add(
        BundleBridge(
          id: id,
          transport: kinds[id]?.label,
          mtu: device.status.mtu,
          linkState: device.status.phase.name,
          mode: device.mode?.mode.name,
        ),
      );
    }

    final latencyStore = await ref.read(latencyStoreProvider.future);
    final captureStore = await ref.read(captureStoreProvider.future);
    final runs = latencyStore.list();
    final latest = runs.isEmpty ? null : runs.first;
    String? firmwareSha;
    for (final bridge in bridges) {
      if (bridge.firmwareVersion != null) {
        firmwareSha = bridge.firmwareVersion;
        break;
      }
    }

    final run = benchRun ?? ref.read(benchBundleProvider);
    return TestBundleInput(
      now: ref.read(bundleClockProvider)(),
      appVersion: info.appVersion,
      appCommit: ref.read(appCommitProvider),
      phone: info.phone,
      androidVersion: info.androidVersion,
      streamMode: service?.mode.name ?? device.mode?.mode.name ?? 'none',
      streamFault: service?.fault?.message,
      rawStats: _rawStatsJson(service?.stats ?? device.stats),
      decodedStats: _decodedStatsJson(
        service?.decodedStats ?? device.decodedStats,
      ),
      bridges: bridges,
      latencyFiles: latest?.paths ?? const [],
      captureFiles: [for (final capture in captureStore.list()) capture.path],
      benchRun: run,
      poseCaptures: poseCapturesFromRun(run),
      benchRuntime: ref.read(benchHandTrackingProvider).runtime,
      firmwareSha: firmwareSha,
    );
  };
});

/// Opens the system share sheet for the zip.
final shareTestBundleProvider = Provider<Future<void> Function(String path)>((
  ref,
) {
  return (path) async {
    await SharePlus.instance.share(
      ShareParams(files: [XFile(path, mimeType: 'application/zip')]),
    );
  };
});

/// One tap: gather, write the zip, then share it. A bench run is passed in so
/// the manifest records the step results, including the export, before the
/// archive is written.
typedef TestBundleExporter = Future<TestBundle> Function({
  BenchBundleRun? benchRun,
});

final exportTestBundleProvider = Provider<TestBundleExporter>((ref) {
  return ({BenchBundleRun? benchRun}) async {
    final input = await ref.read(testBundleInputProvider)(benchRun: benchRun);
    final directory = await ref.read(bundleOutputDirectoryProvider.future);
    final bundle = await writeTestBundle(input, directory);
    await ref.read(shareTestBundleProvider)(bundle.path);
    return bundle;
  };
});

/// Step results from the guided bench wizard, when the export ends one. The
/// plain Export test bundle action leaves it null and the manifest says so.
final benchBundleProvider =
    NotifierProvider<BenchBundleNotifier, BenchBundleRun?>(
      BenchBundleNotifier.new,
    );

class BenchBundleNotifier extends Notifier<BenchBundleRun?> {
  @override
  BenchBundleRun? build() => null;

  void publish(BenchBundleRun run) => state = run;

  void clear() => state = null;
}

/// Recorded pose files named by the pose step's segment data.
///
/// Shared with the bench tests so the zip they inspect goes through the same
/// selection the app uses.
List<PoseCaptureFile> poseCapturesFromRun(BenchBundleRun? run) {
  if (run == null) return const [];
  final captures = <PoseCaptureFile>[];
  for (final step in run.steps) {
    if (step.id != 'pose_capture') continue;
    final segments = step.data['segments'];
    if (segments is! List) continue;
    for (final segment in segments) {
      if (segment is! Map) continue;
      if (segment['status'] != 'done') continue;
      final path = segment['file'];
      final runtime = segment['runtime'];
      final hand = segment['hand'];
      final name = segment['segment'];
      if (path is! String || runtime is! String) continue;
      if (hand is! String || name is! String) continue;
      captures.add(
        PoseCaptureFile(
          path: path,
          runtime: runtime,
          hand: hand.toLowerCase(),
          segment: name,
        ),
      );
    }
  }
  return captures;
}

Map<String, Object?>? _rawStatsJson(StreamStats? stats) {
  if (stats == null) return null;
  return {
    'frames': [for (final hand in stats.hands) hand.frames],
    'incomplete': [for (final hand in stats.hands) hand.incomplete],
    'gaps': [for (final hand in stats.hands) hand.gaps],
    'out_of_order': [for (final hand in stats.hands) hand.outOfOrder],
    'sequence_loss': [for (final hand in stats.hands) hand.sequenceLoss],
    'reassembly_errors': stats.errors,
  };
}

Map<String, Object?>? _decodedStatsJson(DecodedStats? stats) {
  if (stats == null) return null;
  return {
    'records': [for (final hand in stats.hands) hand.records],
    'rate_hz': [for (final hand in stats.hands) hand.rateHz],
    'sequence_gaps': [for (final hand in stats.hands) hand.sequenceGaps],
    'out_of_order': [for (final hand in stats.hands) hand.outOfOrder],
    'missing_from_ticks': [
      for (final hand in stats.hands) hand.missingFromTicks,
    ],
    'cumulative_loss': [for (final hand in stats.hands) hand.cumulativeLoss],
    'parse_errors': stats.parseErrors,
    'batches': stats.batches,
    'batch_errors': stats.batchErrors,
  };
}
