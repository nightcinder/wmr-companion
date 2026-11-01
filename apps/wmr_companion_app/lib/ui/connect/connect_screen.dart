import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:wmr_ble/wmr_ble.dart';

import '../../services/test_bundle_export.dart';
import '../bench/bench_screen.dart';
import '../capture/capture_screen.dart';

import 'package:wmr_core/services/controller_service.dart';

import '../debug/debug_providers.dart';
import '../debug/debug_screen.dart';
import '../latency/latency_screen.dart';
import '../legal/terms_screen.dart';
import '../sbs/stereo_sbs.dart';
import 'connect_providers.dart';

class ConnectScreen extends ConsumerStatefulWidget {
  const ConnectScreen({super.key});

  @override
  ConsumerState<ConnectScreen> createState() => _ConnectScreenState();
}

/// Mutable state the Connect screen keeps above [StereoSbsWrapper]: both eye
/// halves inflate their own element tree, so focus nodes, controllers and the
/// scroll offset have to live here to stay identical in both halves.
class ConnectUiState extends ChangeNotifier {
  final FocusNode scanFocus = FocusNode(debugLabel: 'connect-scan');
  final FocusNode disconnectFocus = FocusNode(debugLabel: 'connect-disconnect');
  final FocusNode reconnectFocus = FocusNode(debugLabel: 'connect-reconnect');
  final FocusNode captureFocus = FocusNode(debugLabel: 'connect-capture');
  final FocusNode debugFocus = FocusNode(debugLabel: 'connect-debug');
  final FocusNode latencyFocus = FocusNode(debugLabel: 'connect-latency');
  final FocusNode exportFocus = FocusNode(debugLabel: 'connect-export');
  final FocusNode benchFocus = FocusNode(debugLabel: 'connect-bench');
  final FocusNode wifiConnectFocus = FocusNode(debugLabel: 'wifi-connect');
  final FocusNode hostFocus = FocusNode(debugLabel: 'wifi-host');
  final FocusNode portFocus = FocusNode(debugLabel: 'wifi-port');
  final FocusNode tokenFocus = FocusNode(debugLabel: 'wifi-token');
  final FocusNode secureFocus = FocusNode(debugLabel: 'wifi-secure');

  final TextEditingController host = TextEditingController();
  final TextEditingController port = TextEditingController(text: '8765');
  final TextEditingController token = TextEditingController();

  final ScrollController scroll = StereoSbsScrollController();

  bool secure = false;
  String? wifiError;
  bool exportBusy = false;
  String? exportMessage;
  String? exportError;

  void setSecure(bool value) {
    secure = value;
    notifyListeners();
  }

  void setWifiError(String? value) {
    wifiError = value;
    notifyListeners();
  }

  void setExportBusy(bool value) {
    exportBusy = value;
    if (value) {
      exportMessage = null;
      exportError = null;
    }
    notifyListeners();
  }

  void setExportMessage(String value) {
    exportMessage = value;
    exportError = null;
    notifyListeners();
  }

  void setExportError(String value) {
    exportMessage = null;
    exportError = value;
    notifyListeners();
  }

  @override
  void dispose() {
    for (final node in [
      scanFocus,
      disconnectFocus,
      reconnectFocus,
      captureFocus,
      debugFocus,
      latencyFocus,
      exportFocus,
      benchFocus,
      wifiConnectFocus,
      hostFocus,
      portFocus,
      tokenFocus,
      secureFocus,
    ]) {
      node.dispose();
    }
    host.dispose();
    port.dispose();
    token.dispose();
    scroll.dispose();
    super.dispose();
  }
}

class _ConnectScreenState extends ConsumerState<ConnectScreen> {
  final _ui = ConnectUiState();

  @override
  void dispose() {
    _ui.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StereoSbsWrapper(
      child: Scaffold(
        appBar: AppBar(
          title: const _AppTitle(),
          actions: [
            const SbsToggleButton(),
            PopupMenuButton<String>(
              tooltip: 'About',
              onSelected: (value) {
                switch (value) {
                  case 'terms':
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const TermsScreen(),
                      ),
                    );
                  case 'licences':
                    showLicensePage(
                      context: context,
                      applicationName: 'WMR Companion',
                    );
                }
              },
              itemBuilder: (context) => const [
                PopupMenuItem(value: 'terms', child: Text('Terms')),
                PopupMenuItem(value: 'licences', child: Text('Licences')),
              ],
            ),
          ],
        ),
        body: FocusTraversalGroup(
          key: const Key('connect-focus-order'),
          policy: OrderedTraversalPolicy(),
          child: ListView(
            controller: _ui.scroll,
            padding: const EdgeInsets.all(16),
            children: [RealPanel(ui: _ui)],
          ),
        ),
      ),
    );
  }
}

/// D-pad order for the action row: the primary action is reached first, the
/// rest follow in reading order.
Widget _actionOrder(double order, Widget child) =>
    FocusTraversalOrder(order: NumericFocusOrder(order), child: child);

/// The app name with the running build's version below it, so testers can
/// quote the exact build in a bug report.
class _AppTitle extends ConsumerWidget {
  const _AppTitle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final version = ref.watch(appVersionProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('WMR Companion'),
        Text(
          version.when(
            data: (value) => 'Version $value',
            loading: () => 'Version …',
            error: (_, _) => 'Version unknown',
          ),
          key: const Key('app-version'),
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

class RealPanel extends ConsumerWidget {
  const RealPanel({super.key, required this.ui});

  /// Shared by both eye halves, so the two copies read the same focus, field
  /// and scroll state.
  final ConnectUiState ui;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(realDeviceProvider);
    final controller = ref.read(realDeviceProvider.notifier);
    final theme = Theme.of(context);
    final mono = theme.textTheme.bodyMedium?.copyWith(fontFamily: 'monospace');
    final status = s.status;
    final link = s.activeTransport;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Not verified on hardware. Raw FF11 feeds the Capture screen; '
          'decoded FF12 or batched FF14 feeds the 3D view. The bridge allows '
          'one at a time. FF14 has not been run on hardware.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        SegmentedButton<BridgeTransportKind>(
          segments: const [
            ButtonSegment(
              value: BridgeTransportKind.ble,
              label: Text('Bluetooth'),
              icon: Icon(Icons.bluetooth),
            ),
            ButtonSegment(
              value: BridgeTransportKind.wifi,
              label: Text('Wi-Fi'),
              icon: Icon(Icons.wifi),
            ),
          ],
          selected: {link},
          onSelectionChanged: s.busy
              ? null
              : (selection) => controller.selectTransport(selection.first),
        ),
        const SizedBox(height: 12),
        if (link == BridgeTransportKind.wifi) ...[
          _WifiConnectPanel(controller: controller, busy: s.busy, ui: ui),
          const SizedBox(height: 12),
        ],
        Text(
          'State: ${_describe(status.phase)}${s.connectedDeviceIds.length > 1 ? ' (${s.connectedDeviceIds.length} bridges)' : ''}',
          style: theme.textTheme.titleMedium?.copyWith(
            color: status.isFailure ? theme.colorScheme.error : null,
          ),
        ),
        if (status.message != null) Text(status.message!),
        if (link == BridgeTransportKind.wifi && s.wifiDeviceId != null)
          Text('Endpoint: ${s.wifiDeviceId}', style: mono),
        if (s.connectedDeviceIds.length <= 1) ...[
          Text('MTU (negotiated): ${status.mtu ?? '-'}', style: mono),
          Text(
            'High priority: ${switch (status.priorityRequested) {
              true => 'requested',
              false => 'failed',
              null => 'n/a',
            }}',
            style: mono,
          ),
          for (final w in status.warnings)
            Text('Warning: $w', style: theme.textTheme.bodySmall),
        ] else ...[
          for (final id in s.connectedDeviceIds) ...[
            Builder(
              builder: (context) {
                final devStatus = s.deviceStatuses[id];
                return Text(
                  'Bridge $id: MTU ${devStatus?.mtu ?? '-'}, '
                  'priority: ${devStatus?.priorityRequested == true ? "requested" : "n/a"}',
                  style: mono,
                );
              },
            ),
          ],
        ],
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            if (link == BridgeTransportKind.ble)
              _actionOrder(
                1,
                FilledButton.tonal(
                  key: const Key('connect-scan'),
                  focusNode: ui.scanFocus,
                  autofocus: true,
                  onPressed: s.busy
                      ? null
                      : (s.scanning
                            ? controller.stopScan
                            : controller.startScan),
                  child: Text(s.scanning ? 'Stop scan' : 'Scan'),
                ),
              ),
            if (s.connected || status.phase == BleLinkPhase.connectionLost)
              _actionOrder(
                2,
                FilledButton(
                  focusNode: ui.disconnectFocus,
                  onPressed: controller.disconnect,
                  child: Text(
                    s.connectedDeviceIds.length > 1
                        ? 'Disconnect all'
                        : 'Disconnect',
                  ),
                ),
              ),
            if (status.phase == BleLinkPhase.connectionLost &&
                s.deviceId != null)
              _actionOrder(
                3,
                FilledButton(
                  focusNode: ui.reconnectFocus,
                  onPressed: () => controller.connect(s.deviceId!),
                  child: const Text('Reconnect'),
                ),
              ),
            if (s.connected)
              _actionOrder(
                4,
                FilledButton.tonal(
                  focusNode: ui.captureFocus,
                  onPressed: () => _openCapture(context, controller),
                  child: const Text('Capture'),
                ),
              ),
            if (s.connected)
              _actionOrder(
                5,
                FilledButton.tonal(
                  focusNode: ui.debugFocus,
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          const DebugScreen(source: DebugSource.real),
                    ),
                  ),
                  child: const Text('Open 3D debug view'),
                ),
              ),
            if (s.connected)
              _actionOrder(
                6,
                FilledButton.tonal(
                  focusNode: ui.latencyFocus,
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const LatencyScreen(),
                    ),
                  ),
                  child: const Text('Latency test'),
                ),
              ),
            _actionOrder(7, _ExportBundleButton(ui: ui)),
            // Also without a bridge: the 6DoF-only bench path needs no link.
            _actionOrder(
              8,
              FilledButton.tonal(
                key: const Key('open-guided-bench'),
                focusNode: ui.benchFocus,
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const BenchScreen()),
                ),
                child: const Text('Run guided bench'),
              ),
            ),
          ],
        ),
        if (s.connected && s.mode != null) ...[
          const SizedBox(height: 8),
          StreamModeSelector(
            mode: s.mode!.mode,
            onChanged: controller.setStreamMode,
          ),
          if (s.mode!.fault != null) ...[
            const SizedBox(height: 8),
            ModeFaultBanner(s.mode!.fault!),
          ],
        ],
        const SizedBox(height: 8),
        if (link == BridgeTransportKind.ble) ...[
          if (s.results.isEmpty && s.scanning) const Text('Scanning...'),
          for (final r in s.results)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(r.name ?? '(no name)'),
              subtitle: Text('${r.deviceId}   ${r.rssi ?? '-'} dBm'),
              trailing: s.isDeviceConnected(r.deviceId)
                  ? TextButton(
                      onPressed: () => controller.disconnect(r.deviceId),
                      child: const Text('Disconnect bridge'),
                    )
                  : TextButton(
                      onPressed: s.isDeviceBusy(r.deviceId)
                          ? null
                          : () => controller.connect(r.deviceId),
                      child: const Text('Connect'),
                    ),
            ),
        ],
        if (s.stats != null) ...[
          const SizedBox(height: 16),
          Text('Stream', style: theme.textTheme.titleMedium),
          if (s.mode?.mode.carriesRecords ?? false)
            if (s.decodedStats != null)
              DecodedStreamTable(s.decodedStats!, style: mono)
            else
              Text('Waiting for the decoded stream...', style: mono)
          else
            StatsTable(s.stats!, style: mono),
        ],
      ],
    );
  }

  /// The Capture screen records raw FF11 frames: switch to FF11 first, and
  /// stay here if the bridge refuses.
  Future<void> _openCapture(
    BuildContext context,
    RealDeviceController controller,
  ) async {
    await controller.setStreamMode(StreamMode.raw);
    if (!context.mounted) return;
    if (controller.service?.fault != null) return; // shown by the banner
    await Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const CaptureScreen()));
  }

  /// Entry for a Pi Wi-Fi bridge: host, port and the optional shared token.
  /// No discovery; the user types what the daemon printed at startup.
  ///
  /// This is a separate widget so the fields keep their contents while the
  /// controller rebuilds every 250 ms on stream statistics.
  static String _describe(BleLinkPhase p) => switch (p) {
    BleLinkPhase.idle => 'idle',
    BleLinkPhase.scanning => 'scanning',
    BleLinkPhase.connecting => 'connecting',
    BleLinkPhase.negotiatingMtu => 'negotiating MTU',
    BleLinkPhase.discovering => 'discovering services',
    BleLinkPhase.subscribing => 'enabling notifications',
    BleLinkPhase.ready => 'connected, streaming',
    BleLinkPhase.disconnecting => 'disconnecting',
    BleLinkPhase.disconnected => 'disconnected',
    BleLinkPhase.bluetoothOff => 'Bluetooth is off',
    BleLinkPhase.bluetoothUnavailable => 'Bluetooth unavailable',
    BleLinkPhase.permissionDenied => 'Bluetooth permission denied',
    BleLinkPhase.scanTimeout => 'no bridge found (scan timed out)',
    BleLinkPhase.connectFailed => 'connect failed',
    BleLinkPhase.serviceNotFound => 'bridge service not found',
    BleLinkPhase.connectionLost => 'connection lost',
  };
}

/// Entry for a Pi Wi-Fi bridge: host, port and the optional shared token.
/// No discovery; the user types what the daemon printed at startup.
///
/// The fields and their errors live in [ConnectUiState] so both eye halves
/// show the same values while the controller rebuilds on stream statistics.
class _WifiConnectPanel extends ConsumerWidget {
  const _WifiConnectPanel({
    required this.controller,
    required this.busy,
    required this.ui,
  });

  final RealDeviceController controller;
  final bool busy;
  final ConnectUiState ui;

  Future<void> _connect() async {
    final host = ui.host.text.trim();
    final port = int.tryParse(ui.port.text.trim());
    if (host.isEmpty) {
      ui.setWifiError('Enter the bridge host or IP address.');
      return;
    }
    if (port == null || port < 1 || port > 65535) {
      ui.setWifiError('Port must be a number between 1 and 65535.');
      return;
    }
    ui.setWifiError(null);
    try {
      await controller.connectWifi(
        host: host,
        port: port,
        token: ui.token.text,
        secure: ui.secure,
      );
    } on ArgumentError catch (error) {
      ui.setWifiError('${error.message}');
    } catch (error) {
      ui.setWifiError('$error');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: ui,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Pi Wi-Fi bridge', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            'Host and control port of the wmr_bridge daemon, plus the shared '
            'token when it runs with one. The token is not stored.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('wifi-host'),
            controller: ui.host,
            focusNode: ui.hostFocus,
            enabled: !busy,
            autocorrect: false,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'Host or IP',
              hintText: 'wmr-pi.local',
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('wifi-port'),
            controller: ui.port,
            focusNode: ui.portFocus,
            enabled: !busy,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Port'),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('wifi-token'),
            controller: ui.token,
            focusNode: ui.tokenFocus,
            enabled: !busy,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(labelText: 'Token (optional)'),
          ),
          CheckboxListTile(
            key: const Key('wifi-secure'),
            focusNode: ui.secureFocus,
            contentPadding: EdgeInsets.zero,
            value: ui.secure,
            onChanged: busy ? null : (value) => ui.setSecure(value ?? false),
            title: const Text('TLS (wss)'),
            subtitle: const Text(
              'Only when a TLS proxy fronts the daemon; wmr_bridge itself '
              'serves plain ws://.',
            ),
          ),
          if (!ui.secure)
            Text(
              'The token and the stream cross the network in cleartext over '
              'ws://. Use a trusted LAN, or a TLS proxy with TLS on.',
              style: theme.textTheme.bodySmall,
            ),
          if (ui.wifiError != null) ...[
            const SizedBox(height: 8),
            Text(
              ui.wifiError!,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ],
          const SizedBox(height: 8),
          _actionOrder(
            1,
            FilledButton(
              focusNode: ui.wifiConnectFocus,
              autofocus: true,
              onPressed: busy ? null : _connect,
              child: const Text('Connect over Wi-Fi'),
            ),
          ),
        ],
      ),
    );
  }
}

/// One tap on the Connect screen: zip what the app already holds and open the
/// system share sheet. Available without a connection, so saved captures and
/// latency runs can still be exported.
class _ExportBundleButton extends ConsumerWidget {
  const _ExportBundleButton({required this.ui});

  final ConnectUiState ui;

  Future<void> _export(WidgetRef ref) async {
    ui.setExportBusy(true);
    try {
      final bundle = await ref.read(exportTestBundleProvider)();
      final missing = bundle.missing.length;
      ui.setExportMessage(
        'Shared ${bundle.fileName}'
        '${missing == 0 ? '.' : '. Missing $missing item(s): see README.md.'}',
      );
    } catch (error) {
      ui.setExportError('Export failed: $error');
    } finally {
      ui.setExportBusy(false);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: ui,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FilledButton.tonal(
            key: const Key('export-test-bundle'),
            focusNode: ui.exportFocus,
            onPressed: ui.exportBusy ? null : () => _export(ref),
            child: Text(ui.exportBusy ? 'Exporting...' : 'Export test bundle'),
          ),
          if (ui.exportMessage != null)
            Text(ui.exportMessage!, style: theme.textTheme.bodySmall),
          if (ui.exportError != null)
            Text(
              ui.exportError!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
        ],
      ),
    );
  }
}
