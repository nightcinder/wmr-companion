import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The end-user licence the VITURE SDK agreement requires us to distribute
/// under (2.3.1): no reverse engineering of the SDK, and an indemnity for
/// VITURE. It ships as `assets/legal/eula.txt` so the same text is in the APK
/// and in the repository.
class TermsScreen extends StatefulWidget {
  const TermsScreen({super.key});

  static const assetPath = 'assets/legal/eula.txt';

  @override
  State<TermsScreen> createState() => _TermsScreenState();
}

class _TermsScreenState extends State<TermsScreen> {
  late final Future<String> _text = rootBundle.loadString(
    TermsScreen.assetPath,
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Terms')),
      body: FutureBuilder<String>(
        future: _text,
        builder: (context, snapshot) {
          final text = snapshot.data;
          if (text == null) {
            return snapshot.hasError
                ? const Center(child: Text('Could not load the terms.'))
                : const Center(child: CircularProgressIndicator());
          }
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: SelectableText(text),
          );
        },
      ),
    );
  }
}
