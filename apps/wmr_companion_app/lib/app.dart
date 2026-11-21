import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wmr_companion/wmr_companion.dart';

import 'services/bench_receipt_log.dart';
import 'ui/connect/connect_providers.dart';

import 'ui/connect/connect_screen.dart';
import 'ui/input/neckband_buttons.dart';

class WmrCompanionApp extends ConsumerStatefulWidget {
  const WmrCompanionApp({super.key});

  @override
  ConsumerState<WmrCompanionApp> createState() => _WmrCompanionAppState();
}

class _WmrCompanionAppState extends ConsumerState<WmrCompanionApp> {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  final BenchReceiptLog _receiptLog = BenchReceiptLog();
  Timer? _receiptTimer;

  @override
  void initState() {
    super.initState();
    // Debug builds only: sample the link timeline for new TCP receipts.
    if (_receiptLog.enabled) {
      _receiptTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => _logReceipts(),
      );
    }
  }

  @override
  void dispose() {
    _receiptTimer?.cancel();
    super.dispose();
  }

  void _logReceipts() {
    final transport = ref.read(realLinkTransportProvider);
    final deviceId = ref.read(realDeviceProvider).deviceId;
    if (transport is! CompositeBleTransport || deviceId == null) return;
    unawaited(_receiptLog.report(transport.linkTimelineFor(deviceId)));
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
