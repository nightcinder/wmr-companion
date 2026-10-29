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
import 'connect_providers.dart';

class ConnectScreen extends StatelessWidget {
  const ConnectScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('WMR Companion')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: const [RealPanel()],
      ),
    );
  }
}

class RealPanel extends ConsumerWidget {
  const RealPanel({super.key});

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
          _WifiConnectPanel(controller: controller, busy: s.busy),
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
              FilledButton.tonal(
                onPressed: s.busy
                    ? null
                    : (s.scanning ? controller.stopScan : controller.startScan),
                child: Text(s.scanning ? 'Stop scan' : 'Scan'),
              ),
            if (s.connected || status.phase == BleLinkPhase.connectionLost)
              FilledButton(
                onPressed: controller.disconnect,
                child: Text(
                  s.connectedDeviceIds.length > 1
                      ? 'Disconnect all'
                      : 'Disconnect',
                ),
              ),
            if (status.phase == BleLinkPhase.connectionLost &&
                s.deviceId != null)
              FilledButton(
                onPressed: () => controller.connect(s.deviceId!),
                child: const Text('Reconnect'),
              ),
            if (s.connected)
              FilledButton.tonal(
                onPressed: () => _openCapture(context, controller),
                child: const Text('Capture'),
              ),
            if (s.connected)
              FilledButton.tonal(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const DebugScreen(source: DebugSource.real),
                  ),
                ),
                child: const Text('Open 3D debug view'),
              ),
            if (s.connected)
              FilledButton.tonal(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const LatencyScreen(),
                  ),
                ),
                child: const Text('Latency test'),
              ),
            const _ExportBundleButton(),
            if (s.connected)
              FilledButton.tonal(
                key: const Key('open-guided-bench'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const BenchScreen()),
                ),
                child: const Text('Run guided bench'),
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
/// This is a separate widget so the fields keep their contents while the
/// controller rebuilds on stream statistics.
class _WifiConnectPanel extends ConsumerStatefulWidget {
  const _WifiConnectPanel({required this.controller, required this.busy});

  final RealDeviceController controller;
  final bool busy;

  @override
  ConsumerState<_WifiConnectPanel> createState() => _WifiConnectPanelState();
}

class _WifiConnectPanelState extends ConsumerState<_WifiConnectPanel> {
  final _host = TextEditingController();
  final _port = TextEditingController(text: '8765');
  final _token = TextEditingController();
  bool _secure = false;
  String? _error;

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final host = _host.text.trim();
    final port = int.tryParse(_port.text.trim());
    if (host.isEmpty) {
      setState(() => _error = 'Enter the bridge host or IP address.');
      return;
    }
    if (port == null || port < 1 || port > 65535) {
      setState(() => _error = 'Port must be a number between 1 and 65535.');
      return;
    }
    setState(() => _error = null);
    try {
      await widget.controller.connectWifi(
        host: host,
        port: port,
        token: _token.text,
        secure: _secure,
      );
    } on ArgumentError catch (error) {
      if (mounted) setState(() => _error = '${error.message}');
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
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
          controller: _host,
          enabled: !widget.busy,
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
          controller: _port,
          enabled: !widget.busy,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Port'),
        ),
        const SizedBox(height: 8),
        TextField(
          key: const Key('wifi-token'),
          controller: _token,
          enabled: !widget.busy,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(labelText: 'Token (optional)'),
        ),
        CheckboxListTile(
          key: const Key('wifi-secure'),
          contentPadding: EdgeInsets.zero,
          value: _secure,
          onChanged: widget.busy
              ? null
              : (value) => setState(() => _secure = value ?? false),
          title: const Text('TLS (wss)'),
          subtitle: const Text(
            'Only when a TLS proxy fronts the daemon; wmr_bridge itself '
            'serves plain ws://.',
          ),
        ),
        if (!_secure)
          Text(
            'The token and the stream cross the network in cleartext over '
            'ws://. Use a trusted LAN, or a TLS proxy with TLS on.',
            style: theme.textTheme.bodySmall,
          ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
        ],
        const SizedBox(height: 8),
        FilledButton(
          onPressed: widget.busy ? null : _connect,
          child: const Text('Connect over Wi-Fi'),
        ),
      ],
    );
  }
}

/// One tap on the Connect screen: zip what the app already holds and open the
/// system share sheet. Available without a connection, so saved captures and
/// latency runs can still be exported.
class _ExportBundleButton extends ConsumerStatefulWidget {
  const _ExportBundleButton();

  @override
  ConsumerState<_ExportBundleButton> createState() =>
      _ExportBundleButtonState();
}

class _ExportBundleButtonState extends ConsumerState<_ExportBundleButton> {
  bool _busy = false;
  String? _message;
  String? _error;

  Future<void> _export() async {
    setState(() {
      _busy = true;
      _message = null;
      _error = null;
    });
    try {
      final bundle = await ref.read(exportTestBundleProvider)();
      if (!mounted) return;
      final missing = bundle.missing.length;
      setState(() {
        _message =
            'Shared ${bundle.fileName}'
            '${missing == 0 ? '.' : '. Missing $missing item(s): see README.md.'}';
      });
    } catch (error) {
      if (mounted) setState(() => _error = 'Export failed: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FilledButton.tonal(
          key: const Key('export-test-bundle'),
          onPressed: _busy ? null : _export,
          child: Text(_busy ? 'Exporting...' : 'Export test bundle'),
        ),
        if (_message != null) Text(_message!, style: theme.textTheme.bodySmall),
        if (_error != null)
          Text(
            _error!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
      ],
    );
  }
}
