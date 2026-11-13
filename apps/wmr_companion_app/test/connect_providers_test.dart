import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_ble/testing.dart';
import 'package:wmr_ble/wmr_ble.dart';
import 'package:wmr_companion/wmr_companion.dart';
import 'package:wmr_companion_app/services/app_installer.dart';
import 'package:wmr_companion_app/services/app_release_checker.dart';
import 'package:wmr_companion_app/services/bridge_update_settings_store.dart';
import 'package:wmr_companion_app/ui/connect/connect_providers.dart';
import 'package:wmr_companion_app/ui/debug/stream_settings.dart';
import 'package:wmr_core/ble/ble_transport.dart';
import 'package:wmr_core/ble/fake_transport.dart';
import 'package:wmr_core/protocol/gatt.dart';
import 'package:wmr_ws/wmr_ws.dart';

import 'ui/raw_mode_notifier.dart';

Future<void> _waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 2),
  String? reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail(reason ?? 'condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ProviderContainer makeContainer({
    BleTransport Function(WmrWsEndpoint)? wifiFactory,
    WifiLink Function(WmrWsEndpoint)? compositeFactory,
    BleTransport Function(BleTransport)? bleHandoffFactory,
    Future<List<WmrWsEndpoint>> Function()? discovery,
    FakeBleAdapter? adapter,
    ReconnectPolicy? reconnectPolicy,
  }) {
    final ble = UniversalBleTransport(
      adapter: adapter ?? FakeBleAdapter(),
      scanTimeout: const Duration(minutes: 5),
    );
    final container = ProviderContainer(
      overrides: [
        realTransportProvider.overrideWithValue(ble),
        wifiTransportFactoryProvider.overrideWithValue(
          wifiFactory ?? (_) => FakeTransport(),
        ),
        compositeWifiTransportFactoryProvider.overrideWithValue(
          compositeFactory ?? (_) => WifiLink(FakeTransport()),
        ),
        if (bleHandoffFactory != null)
          bleHandoffTransportFactoryProvider.overrideWithValue(
            bleHandoffFactory,
          ),
        lanDiscoveryProvider.overrideWithValue(
          discovery ?? () async => const [],
        ),
        if (reconnectPolicy != null)
          reconnectPolicyProvider.overrideWithValue(reconnectPolicy),
        streamModeProvider.overrideWith(RawModeNotifier.new),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  FakeTransport wifiWithDevice(String id) =>
      FakeTransport(devices: [FakeDevice(id: id, mtu: 4096)]);

  test('a direct Wi-Fi connect does not build the composite', () async {
    var compositeBuilds = 0;
    final container = makeContainer(
      wifiFactory: (_) => wifiWithDevice('pi.local:8765'),
      compositeFactory: (_) {
        compositeBuilds++;
        return WifiLink(FakeTransport());
      },
    );

    await container
        .read(realDeviceProvider.notifier)
        .connectWifi(host: 'pi.local', port: 8765, bleFallback: false);

    final state = container.read(realDeviceProvider);
    expect(state.connected, isTrue);
    expect(state.activeTransport, BridgeTransportKind.wifi);
    expect(state.wifiFallback, isFalse);
    expect(state.wifiLeg, isNull);
    expect(compositeBuilds, 0);
  });

  test('a Wi-Fi connect defaults to the BLE fallback composite', () async {
    var compositeBuilds = 0;
    final container = makeContainer(
      wifiFactory: (_) => throw StateError('direct Wi-Fi factory must not run'),
      compositeFactory: (_) {
        compositeBuilds++;
        return WifiLink(
          wifiWithDevice('pi.local:8765'),
          activeLeg: () => WifiLinkLeg.tcp,
        );
      },
    );

    await container
        .read(realDeviceProvider.notifier)
        .connectWifi(host: 'pi.local', port: 8765);

    final state = container.read(realDeviceProvider);
    expect(state.connected, isTrue);
    expect(state.wifiFallback, isTrue);
    expect(compositeBuilds, 1);
  });

  test(
    'the Bluetooth tab connects through the BLE handoff transport',
    () async {
      const bleId = 'ble-pi-1';
      var handoffBuilds = 0;
      final container = makeContainer(
        bleHandoffFactory: (ble) {
          handoffBuilds++;
          return ble;
        },
      );

      await container.read(realDeviceProvider.notifier).connect(bleId);

      expect(handoffBuilds, 1);
      expect(container.read(realDeviceProvider).connected, isTrue);
    },
  );

  test('a generic BLE connect failure is reported, not swallowed', () async {
    final container = makeContainer(bleHandoffFactory: (_) => _RefusingBle());
    final controller = container.read(realDeviceProvider.notifier);

    await controller.connect('ble-pi-1');

    final state = container.read(realDeviceProvider);
    expect(state.status.phase, BleLinkPhase.connectFailed);
    expect(state.status.deviceId, 'ble-pi-1');
    expect(state.status.message, contains('the link went away'));
    expect(state.connectingDeviceIds, isEmpty);
  });

  test(
    'switching to the Wi-Fi tab turns BLE streams off but keeps the link',
    () async {
      const bleDeviceId = 'ble-pi-1';
      final adapter = FakeBleAdapter();
      final container = makeContainer(adapter: adapter);
      final controller = container.read(realDeviceProvider.notifier);

      await controller.connect(bleDeviceId);
      await _waitFor(
        () => adapter.ccc.contains('on ff11'),
        reason: 'the raw stream CCCD was never enabled',
      );

      await controller.selectTransport(BridgeTransportKind.wifi);

      expect(adapter.ccc, ['on ff11', 'off ff11']);
      expect(
        adapter.calls,
        isNot(contains('disconnect')),
        reason: 'the bonded BLE link must survive the tab switch',
      );
      expect(
        await container
            .read(realTransportProvider)
            .connectionState(bleDeviceId)
            .first,
        BleConnectionState.connected,
      );
      final state = container.read(realDeviceProvider);
      expect(state.activeTransport, BridgeTransportKind.wifi);
      expect(state.connected, isFalse);
      expect(state.status.phase, BleLinkPhase.idle);
    },
  );

  test('connecting Wi-Fi turns BLE streams off but keeps the link', () async {
    const bleDeviceId = 'ble-pi-1';
    final adapter = FakeBleAdapter();
    final container = makeContainer(
      adapter: adapter,
      compositeFactory: (_) => WifiLink(
        wifiWithDevice('pi.local:8765'),
        activeLeg: () => WifiLinkLeg.tcp,
      ),
    );
    final controller = container.read(realDeviceProvider.notifier);

    await controller.connect(bleDeviceId);
    await _waitFor(
      () => adapter.ccc.contains('on ff11'),
      reason: 'the raw stream CCCD was never enabled',
    );

    await controller.connectWifi(host: 'pi.local', port: 8765);

    expect(adapter.ccc, ['on ff11', 'off ff11']);
    expect(
      adapter.calls,
      isNot(contains('disconnect')),
      reason: 'the bonded BLE link must survive the Wi-Fi connect',
    );
    expect(
      await container
          .read(realTransportProvider)
          .connectionState(bleDeviceId)
          .first,
      BleConnectionState.connected,
    );
    final state = container.read(realDeviceProvider);
    expect(state.activeTransport, BridgeTransportKind.wifi);
    expect(state.connected, isTrue);
  });

  test('switching back to Bluetooth resumes the same BLE link', () async {
    const bleDeviceId = 'ble-pi-1';
    final adapter = FakeBleAdapter();
    final container = makeContainer(adapter: adapter);
    final controller = container.read(realDeviceProvider.notifier);

    await controller.connect(bleDeviceId);
    await _waitFor(() => adapter.ccc.contains('on ff11'));
    await controller.selectTransport(BridgeTransportKind.wifi);
    expect(adapter.ccc.last, 'off ff11');

    await controller.selectTransport(BridgeTransportKind.ble);
    await controller.connect(bleDeviceId);
    await _waitFor(
      () => adapter.ccc.where((c) => c == 'on ff11').length == 2,
      reason: 'the stream was not re-enabled on the kept link',
    );

    expect(
      adapter.calls.where((c) => c == 'connect'),
      hasLength(1),
      reason: 'resuming must reuse the bonded link, not dial it again',
    );
    expect(container.read(realDeviceProvider).connected, isTrue);
  });

  test('an explicit disconnect drops the link parked for Wi-Fi', () async {
    const bleDeviceId = 'ble-pi-1';
    final adapter = FakeBleAdapter();
    final container = makeContainer(
      adapter: adapter,
      compositeFactory: (_) => WifiLink(
        wifiWithDevice('pi.local:8765'),
        activeLeg: () => WifiLinkLeg.tcp,
      ),
    );
    final controller = container.read(realDeviceProvider.notifier);

    await controller.connect(bleDeviceId);
    await _waitFor(() => adapter.ccc.contains('on ff11'));
    await controller.connectWifi(host: 'pi.local', port: 8765);
    expect(adapter.calls, isNot(contains('disconnect')));

    await controller.disconnect();

    expect(adapter.calls, contains('disconnect'));
    expect(
      await container
          .read(realTransportProvider)
          .connectionState(bleDeviceId)
          .first,
      BleConnectionState.disconnected,
    );
  });

  test('a raw BLE drop after the handoff keeps the TCP session', () async {
    const bridgeId = 'pi-1';
    const bleDeviceId = 'ble-pi-1';
    const lanDeviceId = '192.168.1.42:8765';
    // The same radio serves the raw status stream and the composite's BLE
    // leg. Its FF16 read names the LAN host, so the handoff goes to TCP.
    final adapter = _EndpointAdapter(bridgeId: bridgeId);
    final tcp = _ScriptedTcp(
      FakeTransport(devices: const [FakeDevice(id: lanDeviceId, mtu: 4096)]),
    );
    addTearDown(tcp.dispose);
    late CompositeBleTransport composite;
    final container = makeContainer(
      adapter: adapter,
      bleHandoffFactory: (ble) => composite = CompositeBleTransport(
        tcp: tcp,
        ble: ble,
        upgradeInterval: const Duration(hours: 1),
      ),
    );

    await container.read(realDeviceProvider.notifier).connect(bleDeviceId);
    await _waitFor(
      () => composite.activeLegFor(bleDeviceId) == CompositeLeg.tcp,
      reason: 'the FF16 LAN host was not dialled',
    );
    expect(container.read(realDeviceProvider).connected, isTrue);

    // The GATT link is now only the fallback. Losing it must not tear down
    // the TCP session or clear the connected state.
    adapter.dropLink(deviceId: bleDeviceId);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(container.read(realDeviceProvider).connected, isTrue);
    expect(composite.activeLegFor(bleDeviceId), CompositeLeg.tcp);
  });

  test('losing both legs ends the BLE-mode session', () async {
    const bridgeId = 'pi-1';
    const bleDeviceId = 'ble-pi-1';
    const lanDeviceId = '192.168.1.42:8765';
    final adapter = _EndpointAdapter(bridgeId: bridgeId);
    final tcp = _ScriptedTcp(
      FakeTransport(devices: const [FakeDevice(id: lanDeviceId, mtu: 4096)]),
    );
    addTearDown(tcp.dispose);
    late CompositeBleTransport composite;
    final container = makeContainer(
      adapter: adapter,
      bleHandoffFactory: (ble) => composite = CompositeBleTransport(
        tcp: tcp,
        ble: ble,
        upgradeInterval: const Duration(hours: 1),
      ),
    );

    await container.read(realDeviceProvider.notifier).connect(bleDeviceId);
    await _waitFor(
      () => composite.activeLegFor(bleDeviceId) == CompositeLeg.tcp,
      reason: 'the FF16 LAN host was not dialled',
    );

    // The radio goes first, while TCP carries the session: that loss is
    // ignored. The composite cannot redial the gone radio when TCP drops too,
    // so it reports the loss on its own stream; the controller must follow it
    // instead of keeping a dead session marked connected.
    adapter.connectFailureCount = 1;
    adapter.dropLink(deviceId: bleDeviceId);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(container.read(realDeviceProvider).connected, isTrue);

    await tcp.inner.disconnect(lanDeviceId);
    await _waitFor(
      () => !container.read(realDeviceProvider).connected,
      reason: 'both legs were gone but the UI still showed a live session',
    );
    expect(composite.activeLegFor(bleDeviceId), isNull);
  });

  test('LAN discovery publishes the endpoints it finds', () async {
    final endpoint = WmrWsEndpoint(
      host: '192.168.1.42',
      port: 8765,
      bridgeId: 'pi-1',
      name: 'LAN Bridge',
    );
    final container = makeContainer(discovery: () async => [endpoint]);

    await container.read(realDeviceProvider.notifier).discoverLan();

    final state = container.read(realDeviceProvider);
    expect(state.lanEndpoints, [endpoint]);
    expect(state.discoveringLan, isFalse);
    expect(state.lanError, isNull);
  });

  test('mobile data and tunnels do not count as a LAN interface', () async {
    expect(isLanInterfaceName('wlan0'), isTrue);
    expect(isLanInterfaceName('en0'), isTrue);
    expect(isLanInterfaceName('eth0'), isTrue);
    expect(isLanInterfaceName('rmnet_data0'), isFalse);
    expect(isLanInterfaceName('pdp_ip0'), isFalse);
    expect(isLanInterfaceName('utun3'), isFalse);
    expect(isLanInterfaceName('ppp0'), isFalse);

    expect(await hasLanInterface(), isA<bool>());
  });

  test('the Wi-Fi fallback composite consults the LAN probe', () async {
    var probes = 0;
    final container = ProviderContainer(
      overrides: [
        realTransportProvider.overrideWithValue(
          UniversalBleTransport(adapter: FakeBleAdapter()),
        ),
        lanInterfaceProbeProvider.overrideWithValue(() async {
          probes++;
          return false;
        }),
        streamModeProvider.overrideWith(RawModeNotifier.new),
      ],
    );
    addTearDown(container.dispose);

    final link = container.read(compositeWifiTransportFactoryProvider)(
      WmrWsEndpoint(host: '192.168.1.42', port: 8765, bridgeId: 'pi-1'),
    );
    addTearDown(link.transport.dispose);

    final composite = link.transport as CompositeBleTransport;
    expect(await composite.lanAvailable!(), isFalse);
    expect(probes, 1);
    expect(
      composite.tcpProbeBudget,
      lessThanOrEqualTo(const Duration(seconds: 3)),
    );
  });

  test(
    'fallback connects through the composite and reports its active leg',
    () async {
      var compositeBuilds = 0;
      var leg = WifiLinkLeg.tcp;
      final container = makeContainer(
        wifiFactory: (_) =>
            throw StateError('direct Wi-Fi factory must not run'),
        compositeFactory: (_) {
          compositeBuilds++;
          return WifiLink(
            wifiWithDevice('192.168.1.42:8765'),
            activeLeg: () => leg,
          );
        },
      );

      await container
          .read(realDeviceProvider.notifier)
          .connectWifi(
            host: '192.168.1.42',
            port: 8765,
            bridgeId: 'pi-1',
            bleFallback: true,
          );

      var state = container.read(realDeviceProvider);
      expect(compositeBuilds, 1);
      expect(state.connected, isTrue);
      expect(state.wifiFallback, isTrue);
      expect(state.wifiLeg, WifiLinkLeg.tcp);

      // A failover keeps the connection state `connected`; a later update must
      // pick up the new leg.
      leg = WifiLinkLeg.ble;
      await container.read(realDeviceProvider.notifier).discoverLan();
      state = container.read(realDeviceProvider);
      expect(state.wifiLeg, WifiLinkLeg.ble);
    },
  );

  test('fallback scans and switches a real composite to its BLE leg', () async {
    const bridgeId = 'pi-1';
    const bleDeviceId = 'ble-pi-1';
    final endpoint = WmrWsEndpoint(
      host: '192.168.1.42',
      port: 8765,
      bridgeId: bridgeId,
    );
    final tcp = _FailingTcp(endpoint);
    final ble = FakeTransport(
      devices: const [
        FakeDevice(id: bleDeviceId, name: 'WMR Bridge', mtu: 244),
      ],
    );
    ble.onRead = (deviceId, characteristic) {
      if (characteristic == wmrBridgeVersionCharUuid) {
        return Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'type': 'wmr_ble_endpoint',
              'protocol': 1,
              'bridge_id': bridgeId,
              'name': 'WMR Bridge',
              'version': '0.2.4',
              'hosts': ['192.168.1.42'],
              'port': 8765,
              'path': '/wmr',
              'authRequired': false,
            }),
          ),
        );
      }
      throw StateError('unexpected read $characteristic');
    };
    final composite = CompositeBleTransport(
      tcp: tcp,
      ble: ble,
      upgradeInterval: Duration.zero,
      bleScanWait: const Duration(seconds: 2),
    );
    addTearDown(composite.dispose);

    final container = makeContainer(
      compositeFactory: (_) => WifiLink(
        composite,
        activeLeg: () =>
            switch (composite.activeLegFor(endpoint.resolvedDeviceId)) {
              CompositeLeg.tcp => WifiLinkLeg.tcp,
              CompositeLeg.ble => WifiLinkLeg.ble,
              null => null,
            },
      ),
    );

    await container
        .read(realDeviceProvider.notifier)
        .connectWifi(
          host: endpoint.host,
          port: endpoint.port,
          bridgeId: bridgeId,
          bleFallback: true,
        );

    final state = container.read(realDeviceProvider);
    expect(state.connected, isTrue);
    expect(state.wifiFallback, isTrue);
    expect(state.wifiLeg, WifiLinkLeg.ble);
    expect(composite.activeLegFor(endpoint.resolvedDeviceId), CompositeLeg.ble);
    expect(
      await ble.connectionState(bleDeviceId).first,
      BleConnectionState.connected,
    );
  });

  test('publishes the protocol the service read after connect', () async {
    const id = 'pi.local:8765';
    final transport = FakeTransport(
      devices: const [
        FakeDevice(
          id: id,
          services: [
            BleServiceInfo(
              uuid: wmrBridgeServiceUuid,
              characteristicUuids: [wmrBridgeVersionCharUuid],
            ),
          ],
        ),
      ],
    );
    transport.onRead = (_, characteristic) {
      if (characteristic.toLowerCase() != wmrBridgeVersionCharUuid) {
        throw StateError('unexpected read $characteristic');
      }
      return Uint8List.fromList(utf8.encode('0.3.19'));
    };
    final container = makeContainer(wifiFactory: (_) => transport);
    final read = Completer<String?>();
    container.listen(realDeviceProvider, (_, next) {
      if (!read.isCompleted && next.protocol != null) {
        read.complete(next.protocol!.firmwareVersion);
      }
    });

    await container
        .read(realDeviceProvider.notifier)
        .connectWifi(host: 'pi.local', port: 8765, bleFallback: false);

    expect(await read.future.timeout(const Duration(seconds: 2)), '0.3.19');
    expect(container.read(realDeviceProvider).protocolUnavailable, isFalse);
  });

  test(
    'publishes protocolUnavailable when discovery finds no bridge',
    () async {
      const id = 'pi.local:8765';
      final transport = FakeTransport(devices: const [FakeDevice(id: id)]);
      final container = makeContainer(wifiFactory: (_) => transport);
      final unavailable = Completer<void>();
      container.listen(realDeviceProvider, (_, next) {
        if (!unavailable.isCompleted && next.protocolUnavailable) {
          unavailable.complete();
        }
      });

      await container
          .read(realDeviceProvider.notifier)
          .connectWifi(host: 'pi.local', port: 8765, bleFallback: false);

      await unavailable.future.timeout(const Duration(seconds: 2));
      final state = container.read(realDeviceProvider);
      expect(state.protocol, isNull);
      expect(state.protocolUnavailable, isTrue);
    },
  );

  test(
    'requestBridgeUpgrade surfaces started and reconnects after the restart',
    () async {
      const id = 'pi.local:8765';
      final inner = FakeTransport(devices: const [FakeDevice(id: id)]);
      final transport = _ScriptedTcp(
        inner,
        hello: WmrWsHello(
          protocol: 1,
          transport: 'wifi',
          device: 'wmr-pi',
          version: '0.3.23',
          hostname: 'pi',
          authRequired: false,
          upgradeCapable: true,
          streams: const {'raw', 'decoded', 'batched'},
          recordSize: 56,
          batchMax: 9,
          fragmentCapacity: 244,
        ),
      );
      final container = makeContainer(
        wifiFactory: (_) => transport,
        reconnectPolicy: const ReconnectPolicy(
          baseDelay: Duration(milliseconds: 5),
          maxDelay: Duration(milliseconds: 10),
          maxAttempts: 2,
        ),
      );
      final controller = container.read(realDeviceProvider.notifier);
      await controller.connectWifi(
        host: 'pi.local',
        port: 8765,
        bleFallback: false,
      );
      expect(container.read(realDeviceProvider).bridgeUpgradeCapable, isTrue);

      await controller.requestBridgeUpgrade();

      expect(transport.upgradeRequests, [id]);
      var state = container.read(realDeviceProvider);
      expect(state.bridgeUpgrade.phase, BridgeUpgradePhase.restarting);
      expect(state.bridgeUpgrade.message, contains('restart'));

      // The daemon restarts for the install and the socket drops. The retry
      // campaign must not stop at the normal six-attempt budget.
      await inner.disconnect(id);
      await _waitFor(
        () =>
            container.read(realDeviceProvider).bridgeUpgrade.phase ==
            BridgeUpgradePhase.idle,
        reason: 'the upgrade phase never completed after the reconnect',
      );
      await _waitFor(
        () => container.read(realDeviceProvider).connected,
        reason: 'the bridge did not reconnect after the simulated restart',
      );
      state = container.read(realDeviceProvider);
      expect(state.bridgeUpgrade.phase, BridgeUpgradePhase.idle);
      expect(state.bridgeUpgradeCapable, isTrue);
    },
  );

  test('requestBridgeUpgrade surfaces busy and token refusals', () async {
    const id = 'pi.local:8765';
    final inner = FakeTransport(devices: const [FakeDevice(id: id)]);
    final transport = _ScriptedTcp(
      inner,
      hello: WmrWsHello(
        protocol: 1,
        transport: 'wifi',
        device: 'wmr-pi',
        version: '0.3.23',
        hostname: 'pi',
        authRequired: false,
        upgradeCapable: true,
        streams: const {'raw'},
        recordSize: 56,
        batchMax: 9,
        fragmentCapacity: 244,
      ),
    );
    final container = makeContainer(wifiFactory: (_) => transport);
    final controller = container.read(realDeviceProvider.notifier);
    await controller.connectWifi(
      host: 'pi.local',
      port: 8765,
      bleFallback: false,
    );

    transport.upgradeState = WmrWsUpgradeState.busy;
    await controller.requestBridgeUpgrade();
    expect(
      container.read(realDeviceProvider).bridgeUpgrade.phase,
      BridgeUpgradePhase.busy,
    );

    transport.upgradeError = const WmrWsControlException(
      'auth_failed',
      'no token',
    );
    await controller.requestBridgeUpgrade();
    final failed = container.read(realDeviceProvider).bridgeUpgrade;
    expect(failed.phase, BridgeUpgradePhase.failed);
    expect(failed.message, contains('token'));
  });

  group('BridgeReleaseChecker', () {
    test('prefers a newer pre-release when the opt-in is on', () async {
      final urls = <Uri>[];
      final now = DateTime(2026, 11, 10, 12);
      final checker = BridgeReleaseChecker(
        fetch: (uri) async {
          urls.add(uri);
          return jsonEncode([
            {'tag_name': 'v0.3.26', 'draft': false, 'prerelease': false},
            {'tag_name': 'v0.3.27-rc.2', 'draft': false, 'prerelease': true},
            {'tag_name': 'v0.3.27-rc.1', 'draft': false, 'prerelease': true},
          ]);
        },
        clock: () => now,
      );

      final release = await checker.lookup(includePreReleases: true);
      expect(release.version?.toString(), '0.3.27-rc.2');
      expect(release.isPreRelease, isTrue);
      expect(release.error, isNull);
      expect(release.checkedAt, now);
      expect(urls, [Uri.parse(bridgeReleasesUrl)]);
    });

    test(
      'asks releases/latest and stays stable when the opt-in is off',
      () async {
        final urls = <Uri>[];
        final checker = BridgeReleaseChecker(
          fetch: (uri) async {
            urls.add(uri);
            return '{"tag_name":"v0.3.26"}';
          },
        );

        final release = await checker.lookup();
        expect(release.version?.toString(), '0.3.26');
        expect(release.isPreRelease, isFalse);
        expect(release.error, isNull);
        expect(urls, [Uri.parse(bridgeLatestReleaseUrl)]);
      },
    );

    test('skips drafts and tags that are not versions', () async {
      final checker = BridgeReleaseChecker(
        fetch: (_) async => jsonEncode([
          {'tag_name': 'v0.4.0', 'draft': true},
          {'tag_name': 'nightly', 'draft': false},
          {'tag_name': 'v0.3.25', 'draft': false},
          {'tag_name': 'v0.3.26', 'draft': false},
        ]),
      );

      final release = await checker.lookup(includePreReleases: true);
      expect(release.version?.toString(), '0.3.26');
      expect(release.isPreRelease, isFalse);
    });

    test('caches a successful lookup for the session', () async {
      var fetches = 0;
      var now = DateTime(2026, 11, 10, 12);
      final checker = BridgeReleaseChecker(
        fetch: (_) async {
          fetches++;
          return '{"tag_name":"v0.3.20"}';
        },
        clock: () => now,
      );

      expect((await checker.lookup()).version!.toString(), '0.3.20');
      expect((await checker.lookup()).version!.toString(), '0.3.20');
      expect(fetches, 1, reason: 'the second read is served from the cache');

      now = now.add(const Duration(hours: 2));
      expect((await checker.lookup()).version!.toString(), '0.3.20');
      expect(fetches, 2, reason: 'the cache expires after an hour');
    });

    test('reports a failure in error instead of a null version', () async {
      final now = DateTime(2026, 11, 10, 12);

      final offline = BridgeReleaseChecker(
        fetch: (_) async => throw StateError('offline'),
        clock: () => now,
      );
      final offlineResult = await offline.lookup();
      expect(offlineResult.version, isNull);
      expect(offlineResult.error, BridgeReleaseChecker.unreachableError);
      expect(offlineResult.checkedAt, now);

      final refused = BridgeReleaseChecker(fetch: (_) async => null);
      expect(
        (await refused.lookup()).error,
        BridgeReleaseChecker.unreachableError,
      );

      final malformed = BridgeReleaseChecker(
        fetch: (_) async => '{"tag_name":24}',
      );
      expect(
        (await malformed.lookup()).error,
        BridgeReleaseChecker.unexpectedResponseError,
      );

      final timedOut = BridgeReleaseChecker(
        fetch: (_) => Completer<String?>().future,
        requestTimeout: const Duration(milliseconds: 20),
      );
      expect(
        (await timedOut.lookup()).error,
        BridgeReleaseChecker.unreachableError,
      );

      expect(BridgeReleaseChecker.parseLatestRelease('not json'), isNull);
      expect(BridgeReleaseChecker.parseLatestRelease('[]'), isNull);
      expect(
        BridgeReleaseChecker.parseLatestRelease('{"tag_name":"v0.3.21"}')
            ?.toString(),
        '0.3.21',
      );
      expect(BridgeReleaseChecker.parseReleaseList('not json'), isNull);
      expect(BridgeReleaseChecker.parseReleaseList('{}'), isNull);
    });

    test('checkNow bypasses the cache, at most once per 30 seconds', () async {
      var fetches = 0;
      var now = DateTime(2026, 11, 10, 12);
      final checker = BridgeReleaseChecker(
        fetch: (_) async {
          fetches++;
          return '{"tag_name":"v0.3.20"}';
        },
        clock: () => now,
      );

      await checker.lookup();
      expect(fetches, 1);

      await checker.checkNow();
      expect(fetches, 2, reason: 'a forced check skips the cache');

      await checker.checkNow();
      expect(fetches, 2, reason: 'forced checks are debounced for 30 seconds');

      now = now.add(const Duration(seconds: 31));
      await checker.checkNow();
      expect(fetches, 3);
      await checker.lookup();
      expect(fetches, 3, reason: 'the forced result refreshed the cache');
    });

    test('a failed forced check is also debounced for 30 seconds', () async {
      var fetches = 0;
      var now = DateTime(2026, 11, 10, 12);
      final checker = BridgeReleaseChecker(
        fetch: (_) async {
          fetches++;
          throw StateError('offline');
        },
        clock: () => now,
      );

      final first = await checker.checkNow();
      expect(first.error, BridgeReleaseChecker.unreachableError);
      expect(fetches, 1);

      final retry = await checker.checkNow();
      expect(retry.error, BridgeReleaseChecker.unreachableError);
      expect(retry.checkedAt, first.checkedAt);
      expect(
        fetches,
        1,
        reason: 'a retry inside the floor reuses the failed forced result',
      );

      now = now.add(const Duration(seconds: 31));
      await checker.checkNow();
      expect(fetches, 2, reason: 'after the floor a new request is allowed');
    });

    test('concurrent forced checks share one in-flight request', () async {
      var fetches = 0;
      final gate = Completer<void>();
      final checker = BridgeReleaseChecker(
        fetch: (_) async {
          fetches++;
          await gate.future;
          return '{"tag_name":"v0.3.20"}';
        },
      );

      final first = checker.checkNow();
      final second = checker.checkNow();
      gate.complete();

      expect((await first).version?.toString(), '0.3.20');
      expect((await second).version?.toString(), '0.3.20');
      expect(fetches, 1, reason: 'the second tap joins the first request');
    });
  });

  group('BridgeUpdateSettings', () {
    test('defaults to stable-only and restores the saved opt-in', () async {
      final dir = await Directory.systemTemp.createTemp('bridge-update');
      addTearDown(() => dir.delete(recursive: true));

      ProviderContainer container() => ProviderContainer(
        overrides: [
          bridgeUpdateSettingsStoreProvider.overrideWithValue(
            FileBridgeUpdateSettingsStore(dir),
          ),
        ],
      );

      final first = container();
      addTearDown(first.dispose);
      final settings = first.read(bridgeUpdateSettingsProvider.notifier);
      await settings.ready;
      expect(first.read(bridgeUpdateSettingsProvider), isFalse);

      await settings.setIncludePreReleases(true);
      expect(first.read(bridgeUpdateSettingsProvider), isTrue);

      final second = container();
      addTearDown(second.dispose);
      await second.read(bridgeUpdateSettingsProvider.notifier).ready;
      expect(second.read(bridgeUpdateSettingsProvider), isTrue);
    });

    test('stays stable-only when the store cannot be read', () async {
      final container = ProviderContainer(
        overrides: [
          bridgeUpdateSettingsStoreProvider.overrideWithValue(
            _ThrowingSettingsStore(),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container.read(bridgeUpdateSettingsProvider.notifier).ready;
      expect(container.read(bridgeUpdateSettingsProvider), isFalse);
    });
  });

  group('AppUpdateController', () {
    const apkName = 'wmr-companion-0.3.26-unified-arm64-v8a.apk';
    const tag = 'v0.3.26';
    const sumsUrl =
        'https://github.com/nightcinder/wmr-companion/releases/download/'
        '$tag/SHA256SUMS';
    const apkUrl =
        'https://github.com/nightcinder/wmr-companion/releases/download/'
        '$tag/$apkName';

    late Directory temp;
    late Uint8List apkBytes;
    late Map<String, String?> responses;
    late _FakeAppInstaller installer;

    String releaseDocument({String tagName = tag}) => jsonEncode({
      'tag_name': tagName,
      'assets': [
        {'name': apkName, 'browser_download_url': apkUrl},
        {'name': 'SHA256SUMS', 'browser_download_url': sumsUrl},
      ],
    });

    ProviderContainer makeUpdateContainer({
      String running = '0.3.25+30',
      bool allowed = true,
    }) {
      installer = _FakeAppInstaller()..allowed = allowed;
      return ProviderContainer(
        overrides: [
          appVersionProvider.overrideWith((ref) async => running),
          appReleaseCheckerProvider.overrideWithValue(
            AppReleaseChecker(
              fetch: (uri) async => responses[uri.toString()],
              download: (uri, destination) async =>
                  destination.writeAsBytes(apkBytes),
              tempDirectory: () async => temp,
              clock: () => DateTime.utc(2026, 11, 13, 12),
            ),
          ),
          appInstallerProvider.overrideWithValue(installer),
        ],
      );
    }

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('app_update_controller');
      apkBytes = Uint8List.fromList(List.generate(1024, (i) => i % 251));
      installer = _FakeAppInstaller();
      responses = {
        appLatestReleaseUrl: releaseDocument(),
        sumsUrl: '${sha256.convert(apkBytes)}  $apkName\n',
      };
    });

    tearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });

    test('a manual check offers a newer release', () async {
      final container = makeUpdateContainer(running: '0.3.24+29');
      addTearDown(container.dispose);

      await container.read(appUpdateProvider.notifier).check();

      final state = container.read(appUpdateProvider);
      expect(state.phase, AppUpdatePhase.available);
      expect(state.release?.version.toString(), '0.3.26');
      expect(state.message, contains('0.3.26'));
    });

    test('a manual check reports the running release as latest', () async {
      responses[appLatestReleaseUrl] = releaseDocument(tagName: 'v0.3.25');
      final container = makeUpdateContainer();
      addTearDown(container.dispose);

      await container.read(appUpdateProvider.notifier).check();

      final state = container.read(appUpdateProvider);
      expect(state.phase, AppUpdatePhase.upToDate);
      expect(state.message, contains('0.3.25'));
    });

    test('a manual check fails loudly when GitHub is unreachable', () async {
      responses[appLatestReleaseUrl] = null;
      final container = makeUpdateContainer();
      addTearDown(container.dispose);

      await container.read(appUpdateProvider.notifier).check();

      expect(container.read(appUpdateProvider).phase, AppUpdatePhase.failed);
      expect(container.read(appUpdateProvider).message, contains('GitHub'));
    });

    test('without install permission it opens Settings instead', () async {
      final container = makeUpdateContainer(allowed: false);
      addTearDown(container.dispose);

      await container.read(appUpdateProvider.notifier).installLatest();

      final state = container.read(appUpdateProvider);
      expect(state.phase, AppUpdatePhase.permissionRequired);
      expect(state.release?.version.toString(), '0.3.26');
      expect(installer.settingsOpened, isTrue);
      expect(installer.installed, isEmpty);
    });

    test(
      'a settings screen that will not open is not an unhandled error',
      () async {
        final container = makeUpdateContainer(allowed: false);
        addTearDown(container.dispose);
        installer.settingsError = PlatformException(
          code: 'settings_unavailable',
        );

        await container.read(appUpdateProvider.notifier).installLatest();

        final state = container.read(appUpdateProvider);
        expect(state.phase, AppUpdatePhase.permissionRequired);
        expect(state.release?.version.toString(), '0.3.26');
        expect(installer.settingsOpened, isTrue);
        expect(installer.installed, isEmpty);
      },
    );

    test('a platform without an installer refuses the install', () async {
      final container = makeUpdateContainer();
      addTearDown(container.dispose);
      installer.selfInstallSupported = false;

      await container.read(appUpdateProvider.notifier).installLatest();

      final state = container.read(appUpdateProvider);
      expect(state.phase, AppUpdatePhase.failed);
      expect(state.message, contains('Android'));
      expect(installer.settingsOpened, isFalse);
      expect(installer.installed, isEmpty);
    });

    test('a double tap starts one install', () async {
      final container = makeUpdateContainer();
      addTearDown(container.dispose);
      installer.canInstallGate = Completer<void>();
      final controller = container.read(appUpdateProvider.notifier);

      final first = controller.installLatest();
      final second = controller.installLatest();
      installer.canInstallGate!.complete();
      await Future.wait([first, second]);

      expect(installer.installed, hasLength(1));
      expect(container.read(appUpdateProvider).phase, AppUpdatePhase.installed);
    });

    test('a verified APK is handed to the system installer', () async {
      final container = makeUpdateContainer();
      addTearDown(container.dispose);

      await container.read(appUpdateProvider.notifier).installLatest();

      final state = container.read(appUpdateProvider);
      expect(state.phase, AppUpdatePhase.installed);
      expect(installer.installed, hasLength(1));
      expect(installer.installed.single, endsWith(apkName));
    });

    test('a digest mismatch never reaches the installer', () async {
      responses[sumsUrl] = '${'0' * 64}  $apkName\n';
      final container = makeUpdateContainer();
      addTearDown(container.dispose);

      await container.read(appUpdateProvider.notifier).installLatest();

      final state = container.read(appUpdateProvider);
      expect(state.phase, AppUpdatePhase.failed);
      expect(state.message, contains('SHA-256'));
      expect(installer.installed, isEmpty);
    });
  });
}

/// Records what the platform installer was asked to do.
class _FakeAppInstaller extends AppInstaller {
  bool allowed = true;
  bool selfInstallSupported = true;
  bool settingsOpened = false;
  PlatformException? settingsError;
  Completer<void>? canInstallGate;
  final List<String> installed = [];

  @override
  bool get supportsSelfInstall => selfInstallSupported;

  @override
  Future<bool> canRequestPackageInstalls() async {
    final gate = canInstallGate;
    if (gate != null) await gate.future;
    return allowed;
  }

  @override
  Future<void> openUnknownSourcesSettings() async {
    settingsOpened = true;
    final error = settingsError;
    if (error != null) throw error;
  }

  @override
  Future<void> installApk(String path) async {
    installed.add(path);
  }
}

/// A BLE leg whose dial fails with a plain error, not a
/// [BleTransportException], like the composite when both of its legs refuse.
class _RefusingBle extends FakeTransport {
  _RefusingBle() : super(devices: const [FakeDevice(id: 'ble-pi-1')]);

  @override
  Future<void> connect(String deviceId) async =>
      throw StateError('the link went away');
}

/// A Wi-Fi leg that is reachable but refuses every dial, so the composite has
/// to use its BLE fallback.
class _FailingTcp extends WmrWsTransport {
  _FailingTcp(WmrWsEndpoint endpoint) : super(endpoints: [endpoint]);

  @override
  Future<void> connect(String deviceId) async =>
      throw StateError('tcp refused');
}

/// Replays the bridge's GATT table and answers FF16 with a valid endpoint
/// document, so a composite reading it learns the LAN host.
class _EndpointAdapter extends FakeBleAdapter {
  _EndpointAdapter({required this.bridgeId});

  final String bridgeId;

  @override
  Future<Uint8List> read(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
  ) async {
    if (characteristicUuid.toLowerCase() == wmrBridgeVersionCharUuid) {
      return Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'type': 'wmr_ble_endpoint',
            'protocol': 1,
            'bridge_id': bridgeId,
            'name': 'WMR Bridge',
            'version': '0.2.4',
            'hosts': ['192.168.1.42'],
            'port': 8765,
            'path': '/wmr',
            'authRequired': false,
          }),
        ),
      );
    }
    return super.read(deviceId, serviceUuid, characteristicUuid);
  }
}

/// A [WmrWsTransport] over a [FakeTransport], for a composite that must reach
/// its TCP leg without opening a socket.
class _ScriptedTcp extends WmrWsTransport {
  _ScriptedTcp(this.inner, {this.hello}) : super(endpoints: const []);

  final FakeTransport inner;

  /// Fallback hello for transports whose endpoint was not registered.
  final WmrWsHello? hello;
  final List<String> upgradeRequests = [];
  WmrWsUpgradeState upgradeState = WmrWsUpgradeState.started;
  String? upgradeCode;
  Object? upgradeError;
  final Map<String, WmrWsEndpoint> endpoints = {};
  final Map<String, WmrWsHello> hellos = {};

  @override
  Stream<BleScanResult> scan({List<String> withServices = const []}) =>
      inner.scan(withServices: withServices);

  @override
  Future<void> stopScan() => inner.stopScan();

  @override
  Future<void> connect(String deviceId) => inner.connect(deviceId);

  @override
  Future<void> disconnect(String deviceId) => inner.disconnect(deviceId);

  @override
  Stream<BleConnectionState> connectionState(String deviceId) =>
      inner.connectionState(deviceId);

  @override
  Future<List<BleServiceInfo>> discoverServices(String deviceId) =>
      inner.discoverServices(deviceId);

  @override
  Stream<BleNotification> subscribe(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
  ) => inner.subscribe(deviceId, serviceUuid, characteristicUuid);

  @override
  Future<void> unsubscribe(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
  ) => inner.unsubscribe(deviceId, serviceUuid, characteristicUuid);

  @override
  Future<Uint8List> read(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
  ) => inner.read(deviceId, serviceUuid, characteristicUuid);

  @override
  Future<void> write(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
    Uint8List value, {
    bool withoutResponse = false,
  }) => inner.write(
    deviceId,
    serviceUuid,
    characteristicUuid,
    value,
    withoutResponse: withoutResponse,
  );

  @override
  Future<BleConnectionInfo> connectionInfo(String deviceId) =>
      inner.connectionInfo(deviceId);

  @override
  Future<void> dispose() => inner.dispose();

  @override
  WmrWsEndpoint? endpointFor(String deviceId) => endpoints[deviceId];

  @override
  WmrWsHello? helloFor(String deviceId) => hellos[deviceId] ?? hello;

  @override
  Future<WmrWsUpgradeStatus> requestUpgrade(String deviceId) async {
    upgradeRequests.add(deviceId);
    final failure = upgradeError;
    if (failure != null) throw failure;
    return WmrWsUpgradeStatus(state: upgradeState, code: upgradeCode);
  }

  @override
  void registerEndpoint(WmrWsEndpoint endpoint) {
    endpoints[endpoint.resolvedDeviceId] = endpoint;
    hellos[endpoint.resolvedDeviceId] = WmrWsHello(
      protocol: 1,
      transport: 'wifi',
      device: 'wmr-pi',
      version: '0.2.4',
      hostname: 'pi',
      bridgeId: endpoint.bridgeId ?? '',
      authRequired: false,
      streams: const {'raw', 'decoded', 'batched'},
      recordSize: 56,
      batchMax: 9,
      fragmentCapacity: 244,
    );
  }
}

class _ThrowingSettingsStore implements BridgeUpdateSettingsStore {
  @override
  Future<bool> load() async => throw const FileSystemException('no storage');

  @override
  Future<void> save(bool includePreReleases) async {}
}
