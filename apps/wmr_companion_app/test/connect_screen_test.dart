import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_ble/testing.dart';
import 'package:wmr_ble/wmr_ble.dart';
import 'package:wmr_companion_app/services/app_release_checker.dart';
import 'package:wmr_companion_app/services/bridge_token_store.dart';
import 'package:wmr_companion_app/services/bridge_update_settings_store.dart';
import 'package:wmr_companion_app/ui/connect/connect_providers.dart';
import 'package:wmr_companion_app/ui/connect/connect_screen.dart';
import 'package:wmr_companion_app/ui/debug/stream_settings.dart';
import 'package:wmr_core/ble/fake_transport.dart';
import 'package:wmr_core/protocol/firmware_version.dart';
import 'package:wmr_ws/wmr_ws.dart';

import 'services/memory_secure_token_backend.dart';
import 'ui/raw_mode_notifier.dart';

void main() {
  testWidgets(
    'discovers a LAN bridge and connects over the default BLE fallback',
    (tester) async {
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final wifi = FakeTransport(
        devices: const [FakeDevice(id: '192.168.1.42:8765', mtu: 4096)],
      );
      var compositeBuilds = 0;
      WmrWsEndpoint? builtEndpoint;
      final ble = UniversalBleTransport(
        adapter: FakeBleAdapter(),
        scanTimeout: const Duration(minutes: 5),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            realTransportProvider.overrideWithValue(ble),
            streamModeProvider.overrideWith(RawModeNotifier.new),
            launchAutoConnectEnabledProvider.overrideWithValue(false),
            lanDiscoveryProvider.overrideWithValue(
              () async => [
                WmrWsEndpoint(
                  host: '192.168.1.42',
                  port: 8765,
                  bridgeId: 'pi-1',
                  name: 'LAN Bridge',
                  candidateHosts: ['192.168.1.43'],
                ),
              ],
            ),
            compositeWifiTransportFactoryProvider.overrideWithValue((endpoint) {
              compositeBuilds++;
              builtEndpoint = endpoint;
              return WifiLink(wifi, activeLeg: () => WifiLinkLeg.tcp);
            }),
            wifiTransportFactoryProvider.overrideWithValue(
              (_) => throw StateError('the direct Wi-Fi factory must not run'),
            ),
            bridgeTokenStoreProvider.overrideWithValue(
              BridgeTokenStore(MemorySecureTokenBackend()),
            ),
          ],
          child: const MaterialApp(home: ConnectScreen()),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('Wi-Fi'));
      await tester.pump();
      expect(find.byKey(const Key('wifi-discover')), findsOneWidget);
      expect(find.byKey(const Key('wifi-ble-fallback')), findsOneWidget);

      await tester.ensureVisible(find.byKey(const Key('wifi-discover')));
      await tester.tap(find.byKey(const Key('wifi-discover')));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      expect(find.text('LAN Bridge'), findsOneWidget);

      final fallback = find.byKey(const Key('wifi-ble-fallback'));
      await tester.ensureVisible(fallback);
      expect(tester.widget<CheckboxListTile>(fallback).value, isTrue);

      final connect = find.byKey(
        const Key('wifi-lan-connect-192.168.1.42:8765'),
      );
      await tester.ensureVisible(connect);
      await tester.tap(connect);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();

      expect(compositeBuilds, 1);
      // The discovered bridge's other interface reaches the transport, so a
      // failed primary host can fall back instead of the user losing the row.
      expect(builtEndpoint?.hosts, ['192.168.1.42', '192.168.1.43']);
      expect(find.text('State: connected, streaming'), findsOneWidget);
      expect(find.text('Endpoint: 192.168.1.42:8765'), findsOneWidget);
      expect(find.text('Active leg: TCP'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets(
    'shows a neutral active leg once the fallback link is disconnected',
    (tester) async {
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final ble = UniversalBleTransport(
        adapter: FakeBleAdapter(),
        scanTimeout: const Duration(minutes: 5),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            realTransportProvider.overrideWithValue(ble),
            streamModeProvider.overrideWith(RawModeNotifier.new),
            realDeviceProvider.overrideWith(_DisconnectedFallback.new),
          ],
          child: const MaterialApp(home: ConnectScreen()),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('Wi-Fi'));
      await tester.pump();
      expect(find.text('Active leg: -'), findsOneWidget);
      expect(find.text('Active leg: connecting'), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets('shows the connected bridge version and a newer-release banner', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          streamModeProvider.overrideWith(RawModeNotifier.new),
          realDeviceProvider.overrideWith(_ConnectedBridge.new),
          bridgeReleaseLookupProvider.overrideWith(
            (ref) async => _bridgeLookup('0.3.20'),
          ),
        ],
        child: const MaterialApp(home: ConnectScreen()),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Bridge version: 0.3.19'), findsOneWidget);
    expect(find.byKey(const Key('bridge-update-banner')), findsOneWidget);
    expect(find.textContaining('0.3.20'), findsOneWidget);
    expect(find.byKey(const Key('bridge-upgrade-command')), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('tapping Upgrade Pi Bridge asks the controller to upgrade', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final bridge = _UpgradeableBridge();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          streamModeProvider.overrideWith(RawModeNotifier.new),
          realDeviceProvider.overrideWith(() => bridge),
          bridgeReleaseLookupProvider.overrideWith(
            (ref) async => _bridgeLookup('0.3.20'),
          ),
        ],
        child: const MaterialApp(home: ConnectScreen()),
      ),
    );
    await tester.pump();
    await tester.pump();

    final upgrade = find.byKey(const Key('bridge-upgrade'));
    expect(upgrade, findsOneWidget);
    await tester.ensureVisible(upgrade);
    await tester.tap(upgrade);
    await tester.pump();

    expect(bridge.requested, isTrue);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('shows upgrade progress while the bridge restarts', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final bridge = _UpgradeableBridge(
      upgrade: const BridgeUpgradeState(
        BridgeUpgradePhase.restarting,
        message: 'Upgrade started. Waiting for the bridge to restart…',
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          streamModeProvider.overrideWith(RawModeNotifier.new),
          realDeviceProvider.overrideWith(() => bridge),
          bridgeReleaseLookupProvider.overrideWith(
            (ref) async => _bridgeLookup('0.3.20'),
          ),
        ],
        child: const MaterialApp(home: ConnectScreen()),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('bridge-upgrade-status')), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.byKey(const Key('bridge-upgrade')),
    );
    expect(button.onPressed, isNull);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('shows the failed upgrade result after the bridge stays down', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final bridge = _UpgradeableBridge(
      wifiConnected: false,
      upgrade: const BridgeUpgradeState(
        BridgeUpgradePhase.failed,
        message: 'The bridge did not come back after the upgrade.',
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          streamModeProvider.overrideWith(RawModeNotifier.new),
          realDeviceProvider.overrideWith(() => bridge),
          bridgeReleaseLookupProvider.overrideWith(
            (ref) async => _bridgeLookup('0.3.20'),
          ),
        ],
        child: const MaterialApp(home: ConnectScreen()),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(
      find.text('The bridge did not come back after the upgrade.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('bridge-upgrade')), findsNothing);
    expect(find.byKey(const Key('bridge-upgrade-command')), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('hides the update banner when the bridge is current', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          streamModeProvider.overrideWith(RawModeNotifier.new),
          realDeviceProvider.overrideWith(_ConnectedBridge.new),
          bridgeReleaseLookupProvider.overrideWith(
            (ref) async => _bridgeLookup('0.3.19'),
          ),
        ],
        child: const MaterialApp(home: ConnectScreen()),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Bridge version: 0.3.19'), findsOneWidget);
    expect(find.byKey(const Key('bridge-update-banner')), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
  testWidgets('shows the app update banner for a newer release', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            streamModeProvider.overrideWith(RawModeNotifier.new),
            realDeviceProvider.overrideWith(_DisconnectedFallback.new),
            runningAppVersionProvider.overrideWith(
              (ref) async => const WmrSemanticVersion(0, 3, 25),
            ),
            latestAppReleaseProvider.overrideWith(
              (ref) async => _appRelease('0.3.26'),
            ),
          ],
          child: const MaterialApp(home: ConnectScreen()),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const Key('app-update-banner')), findsOneWidget);
      expect(find.textContaining('0.3.26'), findsOneWidget);
      expect(find.byKey(const Key('app-upgrade')), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('hides the app update banner when the app is current', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          streamModeProvider.overrideWith(RawModeNotifier.new),
          realDeviceProvider.overrideWith(_DisconnectedFallback.new),
          runningAppVersionProvider.overrideWith(
            (ref) async => const WmrSemanticVersion(0, 3, 25),
          ),
          latestAppReleaseProvider.overrideWith(
            (ref) async => _appRelease('0.3.25'),
          ),
        ],
        child: const MaterialApp(home: ConnectScreen()),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('app-update-banner')), findsNothing);
    expect(find.byKey(const Key('app-upgrade')), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('offers no Android-only install on other platforms', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            streamModeProvider.overrideWith(RawModeNotifier.new),
            realDeviceProvider.overrideWith(_DisconnectedFallback.new),
            runningAppVersionProvider.overrideWith(
              (ref) async => const WmrSemanticVersion(0, 3, 25),
            ),
            latestAppReleaseProvider.overrideWith(
              (ref) async => _appRelease('0.3.26'),
            ),
          ],
          child: const MaterialApp(home: ConnectScreen()),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const Key('app-update-banner')), findsOneWidget);
      expect(find.byKey(const Key('app-update-platform')), findsOneWidget);
      expect(find.byKey(const Key('app-upgrade')), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Check for updates in the app bar runs a manual check', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final update = _FakeAppUpdate(const AppUpdateState.idle());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          streamModeProvider.overrideWith(RawModeNotifier.new),
          realDeviceProvider.overrideWith(_DisconnectedFallback.new),
          appUpdateProvider.overrideWith(() => update),
          latestAppReleaseProvider.overrideWith((ref) async => null),
          runningAppVersionProvider.overrideWith(
            (ref) async => const WmrSemanticVersion(0, 3, 25),
          ),
        ],
        child: const MaterialApp(home: ConnectScreen()),
      ),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('About'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('app-check-update')), findsOneWidget);
    expect(find.text('Check for updates'), findsOneWidget);

    await tester.tap(find.byKey(const Key('app-check-update')));
    await tester.pump();

    expect(update.checked, isTrue);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('shows the unknown-sources fallback and retries the install', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final update = _FakeAppUpdate(
        AppUpdateState(
          AppUpdatePhase.permissionRequired,
          release: _appRelease('0.3.26'),
          message:
              'Allow installs from WMR Companion in Settings, '
              'then tap Install again.',
        ),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            streamModeProvider.overrideWith(RawModeNotifier.new),
            realDeviceProvider.overrideWith(_DisconnectedFallback.new),
            appUpdateProvider.overrideWith(() => update),
            latestAppReleaseProvider.overrideWith((ref) async => null),
            runningAppVersionProvider.overrideWith(
              (ref) async => const WmrSemanticVersion(0, 3, 25),
            ),
          ],
          child: const MaterialApp(home: ConnectScreen()),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const Key('app-update-banner')), findsOneWidget);
      expect(find.byKey(const Key('app-update-status')), findsOneWidget);
      expect(find.text('Allow installs'), findsOneWidget);

      final upgrade = find.byKey(const Key('app-upgrade'));
      await tester.ensureVisible(upgrade);
      await tester.tap(upgrade);
      await tester.pump();
      expect(update.installed, isTrue);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('labels a protocol that will never arrive as unavailable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    Future<void> pump({required bool unavailable}) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            streamModeProvider.overrideWith(RawModeNotifier.new),
            realDeviceProvider.overrideWith(
              () => _BridgeWithoutProtocol(unavailable: unavailable),
            ),
          ],
          child: const MaterialApp(home: ConnectScreen()),
        ),
      );
      await tester.pump();
    }

    await pump(unavailable: false);
    expect(find.text('Bridge version: reading…'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await pump(unavailable: true);
    expect(
      find.text('Bridge version: unavailable (discovery failed)'),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('manual bridge check shows a spinner then the update', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final gate = Completer<String?>();
    var fetches = 0;
    final checker = BridgeReleaseChecker(
      fetch: (_) async {
        fetches++;
        return gate.future;
      },
      clock: () => DateTime(2026, 11, 13, 14, 32),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          streamModeProvider.overrideWith(RawModeNotifier.new),
          realDeviceProvider.overrideWith(_ConnectedBridge.new),
          bridgeReleaseCheckerProvider.overrideWithValue(checker),
          bridgeReleaseLookupProvider.overrideWith(
            (ref) async => _bridgeLookup('0.3.19'),
          ),
        ],
        child: const MaterialApp(home: ConnectScreen()),
      ),
    );
    await tester.pump();
    await tester.pump();

    final button = find.byKey(const Key('bridge-check-updates'));
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pump();

    expect(fetches, 1);
    expect(find.text('Checking…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    gate.complete('{"tag_name":"v0.3.20"}');
    await tester.pump();
    await tester.pump();

    expect(
      find.byKey(const Key('bridge-check-update-available')),
      findsOneWidget,
    );
    expect(find.textContaining('0.3.19 → 0.3.20'), findsOneWidget);
    expect(find.textContaining('Checked at 14:32'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('manual bridge check reports the bridge is current', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final checker = BridgeReleaseChecker(
      fetch: (_) async => '{"tag_name":"v0.3.19"}',
      clock: () => DateTime(2026, 11, 13, 14, 32),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          streamModeProvider.overrideWith(RawModeNotifier.new),
          realDeviceProvider.overrideWith(_ConnectedBridge.new),
          bridgeReleaseCheckerProvider.overrideWithValue(checker),
          bridgeReleaseLookupProvider.overrideWith(
            (ref) async => _bridgeLookup('0.3.19'),
          ),
        ],
        child: const MaterialApp(home: ConnectScreen()),
      ),
    );
    await tester.pump();
    await tester.pump();

    final button = find.byKey(const Key('bridge-check-updates'));
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('bridge-check-up-to-date')), findsOneWidget);
    expect(find.textContaining('newest stable build'), findsOneWidget);
    expect(find.textContaining('Checked at 14:32'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets(
    'manual bridge check reports a bridge ahead of the newest release',
    (tester) async {
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final checker = BridgeReleaseChecker(
        fetch: (_) async => '{"tag_name":"v0.3.18"}',
        clock: () => DateTime(2026, 11, 13, 14, 32),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            streamModeProvider.overrideWith(RawModeNotifier.new),
            realDeviceProvider.overrideWith(_ConnectedBridge.new),
            bridgeReleaseCheckerProvider.overrideWithValue(checker),
          ],
          child: const MaterialApp(home: ConnectScreen()),
        ),
      );
      await tester.pump();
      await tester.pump();

      final button = find.byKey(const Key('bridge-check-updates'));
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const Key('bridge-check-up-to-date')), findsOneWidget);
      expect(
        find.textContaining('No stable bridge release newer than 0.3.19'),
        findsOneWidget,
      );
      expect(find.textContaining('newest stable build'), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets('opting out mid-check drops the pre-release answer', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = _MemoryUpdateSettingsStore(value: true);
    final gate = Completer<String?>();
    var releaseListFetches = 0;
    const releases = [
      {'tag_name': 'v0.3.19', 'draft': false, 'prerelease': false},
      {'tag_name': 'v0.3.27-rc.2', 'draft': false, 'prerelease': true},
    ];
    final checker = BridgeReleaseChecker(
      fetch: (uri) async {
        if (uri.path.endsWith('/latest')) return '{"tag_name":"v0.3.19"}';
        releaseListFetches++;
        if (releaseListFetches == 1) return jsonEncode(releases);
        return gate.future;
      },
      clock: () => DateTime(2026, 11, 13, 14, 32),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          streamModeProvider.overrideWith(RawModeNotifier.new),
          realDeviceProvider.overrideWith(_UpgradeableBridge.new),
          bridgeUpdateSettingsStoreProvider.overrideWithValue(store),
          bridgeReleaseCheckerProvider.overrideWithValue(checker),
        ],
        child: const MaterialApp(home: ConnectScreen()),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Bridge pre-release available'), findsOneWidget);

    final button = find.byKey(const Key('bridge-check-updates'));
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pump();

    final optIn = find.byKey(const Key('bridge-prerelease-opt-in'));
    await tester.ensureVisible(optIn);
    await tester.tap(optIn);
    await tester.pump();
    await tester.pump();
    expect(store.value, isFalse);

    // The request that started before the toggle answers with the channel the
    // user just left; the screen must not show it.
    gate.complete(jsonEncode(releases));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('Bridge pre-release available'), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const Key('bridge-update-banner')),
        matching: find.textContaining('0.3.27-rc.2'),
      ),
      findsNothing,
    );
    expect(find.byKey(const Key('bridge-upgrade-command')), findsNothing);
    expect(find.textContaining('Bridge is up to date: 0.3.19'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('manual bridge check reports a timestamped failure', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final checker = BridgeReleaseChecker(
      fetch: (_) async => throw StateError('offline'),
      clock: () => DateTime(2026, 11, 13, 14, 32),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          streamModeProvider.overrideWith(RawModeNotifier.new),
          realDeviceProvider.overrideWith(_ConnectedBridge.new),
          bridgeReleaseCheckerProvider.overrideWithValue(checker),
          bridgeReleaseLookupProvider.overrideWith(
            (ref) async => _bridgeLookup('0.3.19'),
          ),
        ],
        child: const MaterialApp(home: ConnectScreen()),
      ),
    );
    await tester.pump();
    await tester.pump();

    final button = find.byKey(const Key('bridge-check-updates'));
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('bridge-check-error')), findsOneWidget);
    expect(
      find.textContaining(
        '${BridgeReleaseChecker.unreachableError} Checked at 14:32.',
      ),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('pre-release opt-in persists and pins the banner command', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = _MemoryUpdateSettingsStore();
    final checker = BridgeReleaseChecker(
      fetch: (uri) async => uri.path.endsWith('/latest')
          ? '{"tag_name":"v0.3.19"}'
          : jsonEncode([
              {'tag_name': 'v0.3.19', 'draft': false, 'prerelease': false},
              {'tag_name': 'v0.3.27-rc.2', 'draft': false, 'prerelease': true},
            ]),
    );

    Future<void> pumpScreen() async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            streamModeProvider.overrideWith(RawModeNotifier.new),
            realDeviceProvider.overrideWith(_UpgradeableBridge.new),
            bridgeUpdateSettingsStoreProvider.overrideWithValue(store),
            bridgeReleaseCheckerProvider.overrideWithValue(checker),
          ],
          child: const MaterialApp(home: ConnectScreen()),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    await pumpScreen();
    final optIn = find.byKey(const Key('bridge-prerelease-opt-in'));
    expect(tester.widget<CheckboxListTile>(optIn).value, isFalse);
    expect(find.byKey(const Key('bridge-update-banner')), findsNothing);

    await tester.ensureVisible(optIn);
    await tester.tap(optIn);
    await tester.pump();
    await tester.pump();

    expect(store.value, isTrue);
    expect(find.byKey(const Key('bridge-update-banner')), findsOneWidget);
    expect(find.textContaining('pre-release available'), findsOneWidget);
    expect(find.textContaining('0.3.27-rc.2'), findsWidgets);
    expect(find.byKey(const Key('bridge-upgrade')), findsNothing);
    final command = tester.widget<SelectableText>(
      find.byKey(const Key('bridge-upgrade-command')),
    );
    expect(command.data, contains('/download/v0.3.27-rc.2/install.sh'));

    // A fresh screen restores the saved opt-in.
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await pumpScreen();
    expect(tester.widget<CheckboxListTile>(optIn).value, isTrue);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}

/// A release lookup for widget tests, with the pre-release flag derived the
/// same way the checker derives it.
BridgeReleaseLookup _bridgeLookup(String version, {DateTime? checkedAt}) {
  final parsed = WmrSemanticVersion.tryParse(version)!;
  return BridgeReleaseLookup(
    version: parsed,
    isPreRelease: parsed.isPreRelease,
    checkedAt: checkedAt,
  );
}

/// Keeps the opt-in in memory so a widget test can check it persists.
class _MemoryUpdateSettingsStore implements BridgeUpdateSettingsStore {
  _MemoryUpdateSettingsStore({this.value = false});

  bool value;

  @override
  Future<bool> load() async => value;

  @override
  Future<void> save(bool includePreReleases) async {
    value = includePreReleases;
  }
}

/// A connected bridge whose protocol read has not landed, or never will.
class _BridgeWithoutProtocol extends RealDeviceController {
  _BridgeWithoutProtocol({required this.unavailable});

  final bool unavailable;

  @override
  RealDeviceState build() => RealDeviceState(
    status: const BleLinkStatus(BleLinkPhase.ready, deviceId: 'bridge-1'),
    deviceId: 'bridge-1',
    connectedDeviceIds: const {'bridge-1'},
    protocolUnavailable: unavailable,
  );
}

/// A connected bridge that has already reported its FF16 version.
class _ConnectedBridge extends RealDeviceController {
  @override
  RealDeviceState build() => const RealDeviceState(
    status: BleLinkStatus(BleLinkPhase.ready, deviceId: 'bridge-1'),
    deviceId: 'bridge-1',
    connectedDeviceIds: {'bridge-1'},
    protocol: WmrProtocolVersion(
      features: WmrBridgeFeatures.none,
      firmwareVersion: '0.3.19',
    ),
  );
}

/// A connected Wi-Fi bridge whose daemon advertises the root upgrade unit.
class _UpgradeableBridge extends RealDeviceController {
  _UpgradeableBridge({
    this.upgrade = const BridgeUpgradeState.idle(),
    this.wifiConnected = true,
  });

  final BridgeUpgradeState upgrade;
  final bool wifiConnected;
  bool requested = false;

  @override
  RealDeviceState build() => RealDeviceState(
    status: BleLinkStatus(
      wifiConnected ? BleLinkPhase.ready : BleLinkPhase.connectionLost,
      deviceId: '192.168.1.42:8765',
    ),
    deviceId: '192.168.1.42:8765',
    connectedDeviceIds: wifiConnected ? const {'192.168.1.42:8765'} : const {},
    activeTransport: BridgeTransportKind.wifi,
    wifiDeviceId: '192.168.1.42:8765',
    protocol: wifiConnected
        ? const WmrProtocolVersion(
            features: WmrBridgeFeatures.none,
            firmwareVersion: '0.3.19',
          )
        : null,
    bridgeUpgradeCapable: true,
    bridgeUpgrade: upgrade,
  );

  @override
  Future<void> requestBridgeUpgrade() async {
    requested = true;
  }
}

/// A Wi-Fi fallback link that is no longer connected, as it is after the user
/// taps Disconnect.
class _DisconnectedFallback extends RealDeviceController {
  @override
  RealDeviceState build() => const RealDeviceState(
    activeTransport: BridgeTransportKind.wifi,
    wifiDeviceId: '192.168.1.42:8765',
    wifiFallback: true,
  );
}

/// A release as `AppRelease.parse` would build it from a GitHub response.
AppRelease _appRelease(String version) {
  final apkName = 'wmr-companion-$version-unified-arm64-v8a.apk';
  final base =
      'https://github.com/nightcinder/wmr-companion/releases/download/'
      'v$version';
  return AppRelease(
    version: WmrSemanticVersion.tryParse(version)!,
    tagName: 'v$version',
    apkName: apkName,
    apkUrl: Uri.parse('$base/$apkName'),
    checksumUrl: Uri.parse('$base/SHA256SUMS'),
  );
}

/// Records the manual update actions the Connect screen starts.
class _FakeAppUpdate extends AppUpdateController {
  _FakeAppUpdate(this.initial);

  final AppUpdateState initial;
  bool checked = false;
  bool installed = false;

  @override
  AppUpdateState build() => initial;

  @override
  Future<void> check() async {
    checked = true;
  }

  @override
  Future<void> installLatest() async {
    installed = true;
  }
}
