import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ble/universal_ble_transport.dart';
import '../debug/debug_screen.dart';
import 'connect_providers.dart';

enum _Source { fake, real }

class ConnectScreen extends ConsumerStatefulWidget {
  const ConnectScreen({super.key});

  @override
  ConsumerState<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends ConsumerState<ConnectScreen> {
  _Source _source = _Source.fake;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('WMR Companion')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SegmentedButton<_Source>(
            segments: const [
              ButtonSegment(value: _Source.fake, label: Text('Fake bridge')),
              ButtonSegment(value: _Source.real, label: Text('Real device')),
            ],
            selected: {_source},
            onSelectionChanged: (s) => setState(() => _source = s.first),
          ),
          const SizedBox(height: 16),
          if (_source == _Source.fake)
            const _FakePanel()
          else
            const RealPanel(),
        ],
      ),
    );
  }
}

class _FakePanel extends StatelessWidget {
  const _FakePanel();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Synthetic frames and a synthetic orientation. No Bluetooth needed.',
        ),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: () => Navigator.of(
            context,
          ).push(MaterialPageRoute<void>(builder: (_) => const DebugScreen())),
          child: const Text('Open 3D debug view'),
        ),
      ],
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Not verified on hardware. Shows the raw stream only: there is no '
          'orientation from real data until the decoded characteristic '
          'exists, so the 3D view stays on the fake bridge.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        Text(
          'State: ${_describe(status.phase)}',
          style: theme.textTheme.titleMedium?.copyWith(
            color: status.isFailure ? theme.colorScheme.error : null,
          ),
        ),
        if (status.message != null) Text(status.message!),
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
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            FilledButton.tonal(
              onPressed: s.busy
                  ? null
                  : (s.scanning ? controller.stopScan : controller.startScan),
              child: Text(s.scanning ? 'Stop scan' : 'Scan'),
            ),
            if (s.connected || status.phase == BleLinkPhase.connectionLost)
              FilledButton(
                onPressed: controller.disconnect,
                child: const Text('Disconnect'),
              ),
            if (status.phase == BleLinkPhase.connectionLost &&
                s.deviceId != null)
              FilledButton(
                onPressed: () => controller.connect(s.deviceId!),
                child: const Text('Reconnect'),
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (s.results.isEmpty && s.scanning) const Text('Scanning...'),
        for (final r in s.results)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(r.name ?? '(no name)'),
            subtitle: Text('${r.deviceId}   ${r.rssi ?? '-'} dBm'),
            trailing: TextButton(
              onPressed: s.busy || s.connected
                  ? null
                  : () => controller.connect(r.deviceId),
              child: const Text('Connect'),
            ),
          ),
        if (s.stats != null) ...[
          const SizedBox(height: 16),
          Text('Stream', style: theme.textTheme.titleMedium),
          StatsTable(s.stats!, style: mono),
        ],
      ],
    );
  }

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
