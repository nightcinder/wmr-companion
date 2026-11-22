import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wmr_companion/wmr_companion.dart';

import 'services/bench_receipt_log.dart';
import 'ui/connect/connect_providers.dart';

import 'ui/connect/connect_screen.dart';
import 'ui/input/neckband_buttons.dart';

class WmrCompanionApp extends ConsumerStatefulWidget {
  const WmrCompanionApp({super.key, this.receiptLog});

  final BenchReceiptLog? receiptLog;

  @override
  ConsumerState<WmrCompanionApp> createState() => _WmrCompanionAppState();
}

class _WmrCompanionAppState extends ConsumerState<WmrCompanionApp> {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  late final BenchReceiptLog _receiptLog =
      widget.receiptLog ?? BenchReceiptLog();
  ProviderSubscription<BleTransport>? _transportSub;
  StreamSubscription<String>? _receiptSub;
  BleTransport? _boundTransport;

  @override
  void initState() {
    super.initState();
    // Debug builds only: log TCP receipts as soon as the composite stamps them.
    if (_receiptLog.enabled) {
      _transportSub = ref.listenManual(
        realLinkTransportProvider,
        (_, next) => _bindReceipts(next),
        fireImmediately: true,
      );
    }
  }

  @override
  void dispose() {
    unawaited(_receiptSub?.cancel());
    _receiptSub = null;
    _boundTransport = null;
    _transportSub?.close();
    _transportSub = null;
    super.dispose();
  }

  void _bindReceipts(BleTransport transport) {
    if (identical(_boundTransport, transport)) return;
    _boundTransport = transport;
    unawaited(_receiptSub?.cancel());
    _receiptSub = null;
    if (transport is! CompositeBleTransport) return;
    _receiptSub = transport.tcpReceipts.listen(
      (deviceId) =>
          unawaited(_receiptLog.report(transport.linkTimelineFor(deviceId))),
    );
    final deviceId = ref.read(realDeviceProvider).deviceId;
    if (deviceId != null) {
      unawaited(_receiptLog.report(transport.linkTimelineFor(deviceId)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WMR Companion',
      navigatorKey: _navigatorKey,
      theme: ThemeData(colorSchemeSeed: Colors.indigo),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.dark,
      ),
      builder: (context, child) => NeckbandButtonNavigator(
        navigatorKey: _navigatorKey,
        child: child ?? const SizedBox.shrink(),
      ),
      home: const ConnectScreen(),
    );
  }
}
