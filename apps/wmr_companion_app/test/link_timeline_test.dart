import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_companion_app/services/test_bundle.dart';
import 'package:wmr_companion_app/ui/debug/debug_screen.dart';

/// Marks of one completed TCP→BLE failover, as the composite transport
/// records them: a stall 100 ms after the last record, a 75 ms failover,
/// and the first BLE record 20 ms after it landed.
const _failoverTimeline = {
  'last_tcp_record_us': 1000000,
  'stall_detected_us': 1100000,
  'failover_begin_us': 1105000,
  'failover_end_us': 1180000,
  'first_ble_record_us': 1200000,
  'upgrade_dial_start_us': null,
  'upgrade_dial_end_us': null,
  'first_tcp_record_us': null,
};

/// Marks of a route that failed over and later upgraded back to TCP: the
/// upgrade (a 105 ms dial, first record 15 ms later) is the later switch,
/// so the row must show it rather than the older failover.
const _upgradeTimeline = {
  'last_tcp_record_us': 900000,
  'stall_detected_us': 950000,
  'failover_begin_us': 100000,
  'failover_end_us': 180000,
  'first_ble_record_us': 200000,
  'upgrade_dial_start_us': 5000000,
  'upgrade_dial_end_us': 5105000,
  'first_tcp_record_us': 5120000,
};

Future<void> _pumpRow(
  WidgetTester tester,
  Map<String, Object?> timeline,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: LinkSwitchRow(timeline: timeline, nowUs: 3500000)),
    ),
  );
}

void main() {
  group('LinkSwitchRow', () {
    testWidgets('renders the last failover from the timeline marks', (
      tester,
    ) async {
      await _pumpRow(tester, _failoverTimeline);

      expect(
        find.textContaining('Last link switch 2.3 s ago  TCP→BLE'),
        findsOneWidget,
      );
      expect(find.textContaining('stall +100.0 ms'), findsOneWidget);
      expect(find.textContaining('failover 75.0 ms'), findsOneWidget);
      expect(find.textContaining('first BLE +20.0 ms'), findsOneWidget);
    });

    testWidgets('renders the upgrade when it is the later switch', (
      tester,
    ) async {
      // The clock sits 8 s after the dial landed.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LinkSwitchRow(timeline: _upgradeTimeline, nowUs: 13105000),
          ),
        ),
      );

      expect(
        find.textContaining('Last link switch 8.0 s ago  BLE→TCP'),
        findsOneWidget,
      );
      expect(find.textContaining('dial 105.0 ms'), findsOneWidget);
      expect(find.textContaining('first TCP +15.0 ms'), findsOneWidget);
    });

    testWidgets('says so while no switch has landed', (tester) async {
      await _pumpRow(tester, const {});

      expect(find.text('Last link switch none yet'), findsOneWidget);
    });
  });

  group('test bundle', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('link_timeline');
    });

    tearDown(() {
      dir.deleteSync(recursive: true);
    });

    test('diagnostics.json round-trips the link timeline fields', () async {
      final bundle = await writeTestBundle(
        TestBundleInput(
          now: DateTime(2026, 11, 19, 12),
          appVersion: '0.3.27+35',
          phone: 'Test Phone',
          androidVersion: 'Android 14 (API 34)',
          streamMode: 'raw',
          linkTimeline: _failoverTimeline,
        ),
        Directory('${dir.path}/out'),
      );

      expect(bundle.present.join('\n'), contains('link-switch timeline'));

      final archive = ZipDecoder().decodeBytes(
        await File(bundle.path).readAsBytes(),
      );
      final diagnostics = jsonDecode(
        _text(archive, 'diagnostics.json'),
      ) as Map<String, Object?>;
      expect(diagnostics['link_timeline'], _failoverTimeline);
    });

    test('omits the timeline when the link has none', () async {
      final bundle = await writeTestBundle(
        TestBundleInput(
          now: DateTime(2026, 11, 19, 12),
          appVersion: '0.3.27+35',
          phone: 'Test Phone',
          androidVersion: 'Android 14 (API 34)',
          streamMode: 'raw',
        ),
        Directory('${dir.path}/out'),
      );

      final archive = ZipDecoder().decodeBytes(
        await File(bundle.path).readAsBytes(),
      );
      final diagnostics = jsonDecode(
        _text(archive, 'diagnostics.json'),
      ) as Map<String, Object?>;
      expect(diagnostics['link_timeline'], isNull);
    });
  });
}

String _text(Archive archive, String name) {
  final file = archive.files.firstWhere((f) => f.name == name);
  return utf8.decode(file.content);
}
