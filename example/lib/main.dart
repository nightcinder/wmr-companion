import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wmr_companion/testing.dart';
import 'package:wmr_companion/wmr_companion.dart';

void main() => runApp(const WmrExampleApp());

/// The smallest useful host: create one facade, connect, and render the
/// gamepad stream. Swap [FakeTransport] for `UniversalBleTransport` from
/// `wmr_ble` to drive real controllers; the rest of this file does not change.
class WmrExampleApp extends StatefulWidget {
  const WmrExampleApp({super.key});

  @override
  State<WmrExampleApp> createState() => _WmrExampleAppState();
}

class _WmrExampleAppState extends State<WmrExampleApp> {
  late final FakeTransport _transport;
  late final FakeWmrBridge _bridge;
  late final WmrCompanion _wmr;
  StreamSubscription<WmrConnectionState>? _connectionSub;
  WmrConnectionState _state = WmrConnectionState.idle;
  String? _error;

  @override
  void initState() {
    super.initState();
    _transport = FakeTransport(devices: const [fakeBridgeDevice]);
    // Construct and start the fake bridge here, not lazily: a `late` field
    // that is only read in dispose() would never emit a sample.
    _bridge = FakeWmrBridge(_transport)..start();
    _wmr = WmrCompanion(ble: _transport);
    _connectionSub = _wmr.connection.listen((state) {
      if (mounted) setState(() => _state = state);
    });
    unawaited(_connect());
  }

  Future<void> _connect() async {
    try {
      await _wmr.initialize();
      await _wmr.connect(
        const WmrBridgeDevice(id: fakeBridgeDeviceId, name: 'WMR Bridge'),
      );
    } on WmrException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    _connectionSub?.cancel();
    _bridge.stop();
    unawaited(_wmr.dispose().then((_) => _transport.dispose()));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('wmr_companion example')),
        body: Center(
          child: StreamBuilder<GamepadState>(
            stream: _wmr.gamepad,
            builder: (context, snapshot) {
              final pad = snapshot.data;
              return Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('Connection: ${_state.name}'),
                  if (_error != null)
                    Text(
                      'Error: $_error',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  const SizedBox(height: 12),
                  Text(
                    'Sticks: L ${pad?.leftStick ?? '-'}  '
                    'R ${pad?.rightStick ?? '-'}',
                  ),
                  Text(
                    'Triggers: L ${pad?.leftTrigger.toStringAsFixed(2) ?? '-'}  '
                    'R ${pad?.rightTrigger.toStringAsFixed(2) ?? '-'}',
                  ),
                  Text('Buttons: ${pad?.buttons.join(', ') ?? '-'}'),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
