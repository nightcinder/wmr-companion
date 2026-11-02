import 'package:flutter/material.dart';

import 'ui/connect/connect_screen.dart';
import 'ui/input/neckband_buttons.dart';

class WmrCompanionApp extends StatefulWidget {
  const WmrCompanionApp({super.key});

  @override
  State<WmrCompanionApp> createState() => _WmrCompanionAppState();
}

class _WmrCompanionAppState extends State<WmrCompanionApp> {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

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
