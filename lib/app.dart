import 'package:flutter/material.dart';

import 'ui/connect/connect_screen.dart';

class WmrCompanionApp extends StatelessWidget {
  const WmrCompanionApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WMR Companion',
      theme: ThemeData(colorSchemeSeed: Colors.indigo),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.dark,
      ),
      home: const ConnectScreen(),
    );
  }
}
