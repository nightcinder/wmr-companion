import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_core/domain/droiddeck_xr_sink.dart';
import 'package:wmr_companion_app/hid/droiddeck_output.dart';
import 'package:wmr_companion_app/hid/hid_output.dart';
import 'package:wmr_companion_app/ui/gamepad/gamepad_providers.dart';
import 'package:wmr_companion_app/ui/gamepad/gamepad_screen.dart';

import '../hid/fake_hid.dart';

class _FakeTransport implements DroidDeckXrTransport {
  final sent = <Uint8List>[];
  bool closed = false;

  @override
  Future<void> send(Uint8List packet) async => sent.add(packet);

  @override
  Future<void> close() async => closed = true;
}

void tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(900, 3200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('DroidDeck panel starts and stops the stream, HID gives way', (
    tester,
  ) async {
    tall(tester);
    final transport = _FakeTransport();
    final hid = FakeHid();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          hidTransportProvider.overrideWithValue(hid),
          gamepadInputsProvider.overrideWith(
            (ref, source) => const Stream.empty(),
          ),
          droidDeckTransportFactoryProvider.overrideWithValue(
            () async => transport,
          ),
        ],
        child: const MaterialApp(home: GamepadScreen()),
      ),
    );
    await tester.pump();

    expect(
      find.descendant(
        of: find.byType(DroidDeckPanel),
        matching: find.text('Off'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('DroidDeck 6DoF streaming'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start streaming'));
    await tester.pump();
    await tester.pump();

    expect(find.text('Streaming to DroidDeck'), findsOneWidget);
    expect(find.text('Stop streaming'), findsOneWidget);

    // The flat gamepad cannot be started while the stream owns the link.
    await tester.tap(find.text('Bluetooth HID output'));
    await tester.pumpAndSettle();
    final start = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Start'),
    );
    expect(start.onPressed, isNull);

    await tester.tap(find.text('Stop streaming'));
    await tester.pump();
    await tester.pump();
    expect(transport.closed, isTrue);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Start'))
          .onPressed,
      isNotNull,
    );
  });
}
