import 'dart:async';

import 'package:flutter/material.dart';

import 'package:wmr_core/ble/ble_transport.dart';
import 'package:wmr_core/protocol/controller_control.dart';
import 'package:wmr_core/services/controller_control_client.dart';

/// Scans for controllers and shows their connection state over FF17
/// (docs/PROTOCOL.md, "Controller scan and status v2"). Every button maps to
/// one console action; the firmware keeps the guards and its result code is
/// shown, never swallowed.
class ControllerPanel extends StatefulWidget {
  const ControllerPanel({
    super.key,
    required this.transport,
    required this.deviceId,
  });

  final BleTransport? transport;
  final String? deviceId;

  @override
  State<ControllerPanel> createState() => _ControllerPanelState();
}

class _ControllerPanelState extends State<ControllerPanel> {
  ControllerStatusV2? _status;
  String? _error;
  bool _busy = false;
  ControllerControlClient? _client;
  StreamSubscription<ControllerStatusV2>? _sub;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void didUpdateWidget(ControllerPanel old) {
    super.didUpdateWidget(old);
    if (old.transport != widget.transport || old.deviceId != widget.deviceId) {
      _sub?.cancel();
      _sub = null;
      _client = null;
      _status = null;
      _error = null;
      _open();
    }
  }

  @override
  void dispose() {
    _generation++;
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _open() async {
    final generation = ++_generation;
    final transport = widget.transport;
    final deviceId = widget.deviceId;
    if (transport == null || deviceId == null) return;
    final client = ControllerControlClient(transport, deviceId);
    try {
      if (!await client.isSupported()) {
        if (mounted && generation == _generation) {
          setState(
            () => _error =
                'This bridge does not expose FF17 (firmware before v0.1.1).',
          );
        }
        return;
      }
      final sub = client.statusStream().listen(
        (status) {
          if (mounted && generation == _generation) {
            setState(() => _status = status);
          }
        },
        onError: (Object error) {
          if (mounted && generation == _generation) {
            setState(() => _error = 'FF17 notifications failed: $error');
          }
        },
      );
      final status = await client.readStatus();
      if (!mounted || generation != _generation) {
        await sub.cancel();
        return;
      }
      setState(() {
        _client = client;
        _sub = sub;
        _status = status;
        _error = null;
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = 'Could not read FF17 status: $error');
      }
    }
  }

  Future<void> _send(ControllerCommand command, {int? hand}) async {
    final client = _client;
    if (client == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final outcome = await client.send(command, hand: hand);
    ControllerStatusV2? status;
    try {
      status = await client.readStatus();
    } catch (_) {
      status = null;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (status != null) _status = status;
      if (!outcome.isOk) {
        final reason =
            outcome.result?.name ?? outcome.error?.toString() ?? 'refused';
        _error = '${_label(command, hand)}: $reason';
      }
    });
  }

  static String _label(ControllerCommand command, int? hand) {
    final side = hand == null ? '' : (hand == 0 ? ' LEFT' : ' RIGHT');
    return '${command.name}$side';
  }

  String _summary(HandControllerStatus hand) {
    if (hand.connecting) return 'connecting...';
    if (!hand.connected) return 'not connected';
    final model = hand.model == ControllerModel.psvr2 ? 'PSVR2' : 'WMR';
    final hid = hand.descriptorReceived ? 'HID ready' : 'no HID descriptor';
    return 'connected - $model - $hid${_source(hand)}';
  }

  String _source(HandControllerStatus hand) {
    switch (hand.addressSource) {
      case ControllerAddressSource.compileOverride:
        return ' - address built in';
      case ControllerAddressSource.stored:
        return hand.hasAddress
            ? ' - stored ${hand.addressTail.map(_hex).join(':')}'
            : ' - stored address (none)';
      case ControllerAddressSource.none:
        return ' - no address';
    }
  }

  static String _hex(int b) => b.toRadixString(16).padLeft(2, '0');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mono = theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace');
    final status = _status;
    final ready = status != null && !_busy;
    final scanning =
        status != null && status.discoveryState != ControllerDiscoveryState.idle;
    final anyBusy =
        status?.hands.any((h) => h.connected || h.connecting) ?? false;
    final anyAddress = status?.hands.any((h) => h.hasAddress) ?? false;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Controller control', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Scan for controllers and connect or disconnect them through the '
          'bridge (FF17). The firmware refuses unsafe actions and reports why.',
          style: theme.textTheme.bodySmall,
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _error!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
        if (scanning)
          Container(
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: theme.colorScheme.secondaryContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              'Scanning (round ${status.discoveryRound})... the controller '
              'stream may stutter while the radio is in inquiry.',
              style: theme.textTheme.bodySmall,
            ),
          ),
        const SizedBox(height: 8),
        for (var hand = 0; hand < 2; hand++)
          _handRow(theme, mono, hand, status?.hands[hand], ready: ready),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.tonal(
              onPressed: ready ? () => _send(ControllerCommand.discover) : null,
              child: const Text('Scan for controllers'),
            ),
            OutlinedButton(
              onPressed: ready && !anyBusy && anyAddress
                  ? () => _send(ControllerCommand.forgetAddresses)
                  : null,
              child: const Text('Forget stored addresses'),
            ),
          ],
        ),
        if (status != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Last FF17 command: '
              '${status.lastCommand?.name ?? 'none'} '
              '(${status.lastResult.name})',
              style: mono,
            ),
          ),
      ],
    );
  }

  Widget _handRow(
    ThemeData theme,
    TextStyle? mono,
    int hand,
    HandControllerStatus? status, {
    required bool ready,
  }) {
    final name = hand == 0 ? 'LEFT' : 'RIGHT';
    final connected = status?.connected ?? false;
    final connecting = status?.connecting ?? false;
    final active = connected || connecting;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(
            Icons.circle,
            size: 10,
            color: connected
                ? theme.colorScheme.primary
                : theme.colorScheme.outline,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('$name  ${status == null ? '...' : _summary(status)}', style: mono),
              ],
            ),
          ),
          TextButton(
            onPressed: ready
                ? () => _send(
                    active
                        ? ControllerCommand.disconnect
                        : ControllerCommand.connect,
                    hand: hand,
                  )
                : null,
            child: Text(active ? 'Disconnect' : 'Connect'),
          ),
          IconButton(
            tooltip: 'Forget bond ($name)',
            icon: const Icon(Icons.link_off),
            onPressed: ready && !active
                ? () => _send(ControllerCommand.forgetBond, hand: hand)
                : null,
          ),
        ],
      ),
    );
  }
}
