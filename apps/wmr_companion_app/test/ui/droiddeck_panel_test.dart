import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_core/domain/droiddeck_xr_sink.dart';
import 'package:wmr_companion_app/hid/droiddeck_output.dart';
import 'package:wmr_companion_app/hid/hid_output.dart';
import 'package:wmr_companion_app/services/droiddeck_token_store.dart';
import 'package:wmr_companion_app/ui/gamepad/gamepad_providers.dart';
import 'package:wmr_companion_app/ui/gamepad/gamepad_screen.dart';

import '../hid/fake_hid.dart';
import '../services/memory_secure_token_backend.dart';

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

/// Pumps the gamepad screen with the panel overrides and hands back the
/// scope's own container, so the test can read the token provider.
Future<ProviderContainer> pumpGamepad(
  WidgetTester tester,
  MemorySecureTokenBackend backend,
  Future<DroidDeckXrTransport> Function() open,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        hidTransportProvider.overrideWithValue(FakeHid()),
        gamepadInputsProvider.overrideWith(
          (ref, source) => const Stream.empty(),
        ),
        droidDeckTokenStoreProvider.overrideWithValue(
          DroidDeckTokenStore(backend),
        ),
        droidDeckTransportFactoryProvider.overrideWithValue(open),
      ],
      child: const MaterialApp(home: GamepadScreen()),
    ),
  );
  return ProviderScope.containerOf(tester.element(find.byType(GamepadScreen)));
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

  testWidgets('the token field is obscured and parses a uint32', (
    tester,
  ) async {
    tall(tester);
    final backend = MemorySecureTokenBackend();
    final container = await pumpGamepad(tester, backend, () async {
      return _FakeTransport();
    });
    await tester.tap(find.text('DroidDeck 6DoF streaming'));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(
      find.byKey(const Key('droiddeck-token')),
    );
    expect(field.obscureText, isTrue);

    // The helper names the real token file, names no screen, and disclaims
    // verification instead of promising it.
    final helper = field.decoration!.helperText!;
    expect(helper, contains('droiddeck-ext-xr.token'));
    expect(helper.contains('screen'), isFalse);
    expect(helper, contains('cannot read that file or verify the token'));

    await tester.enterText(
      find.byKey(const Key('droiddeck-token')),
      '4294967295',
    );
    await tester.pump();
    expect(container.read(droidDeckTokenProvider), 4294967295);
    expect(find.text('Not a number from 0 to 4294967295'), findsNothing);

    // Anything a uint32 cannot hold errors the field and clears the token.
    await tester.enterText(
      find.byKey(const Key('droiddeck-token')),
      '4294967296',
    );
    await tester.pump();
    expect(container.read(droidDeckTokenProvider), isNull);
    expect(find.text('Not a number from 0 to 4294967295'), findsOneWidget);
    // Remembering was never opted in, so nothing was stored.
    expect(backend.values, isEmpty);
  });

  testWidgets(
    'remembering saves only when opted in; emptying while on clears',
    (tester) async {
      tall(tester);
      final backend = MemorySecureTokenBackend();
      await pumpGamepad(tester, backend, () async => _FakeTransport());
      await tester.tap(find.text('DroidDeck 6DoF streaming'));
      await tester.pumpAndSettle();

      // Typed with remember off: nothing is written.
      await tester.enterText(find.byKey(const Key('droiddeck-token')), '12345');
      await tester.pump();
      expect(backend.values, isEmpty);

      // Opting in saves what the field already holds.
      await tester.tap(find.byKey(const Key('droiddeck-remember-token')));
      await tester.pump();
      expect(backend.values, {'wmr.droiddeck.token.v1.value': '12345'});

      // Opting out writes nothing: a new value never reaches the store.
      await tester.tap(find.byKey(const Key('droiddeck-remember-token')));
      await tester.pump();
      await tester.enterText(find.byKey(const Key('droiddeck-token')), '67890');
      await tester.pump();
      expect(backend.values, {'wmr.droiddeck.token.v1.value': '12345'});

      // Opting back in syncs the field's current value.
      await tester.tap(find.byKey(const Key('droiddeck-remember-token')));
      await tester.pump();
      expect(backend.values, {'wmr.droiddeck.token.v1.value': '67890'});

      // Emptying the field while remembering is on clears the saved value.
      await tester.enterText(find.byKey(const Key('droiddeck-token')), '');
      await tester.pump();
      expect(backend.values, isEmpty);
    },
  );

  testWidgets('a remembered token reloads into the field and the provider', (
    tester,
  ) async {
    tall(tester);
    final backend = MemorySecureTokenBackend()
      ..values['wmr.droiddeck.token.v1.value'] = '987654321';
    final container = await pumpGamepad(tester, backend, () async {
      return _FakeTransport();
    });
    await tester.tap(find.text('DroidDeck 6DoF streaming'));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(
      find.byKey(const Key('droiddeck-token')),
    );
    expect(field.controller!.text, '987654321');
    expect(
      tester
          .widget<CheckboxListTile>(
            find.byKey(const Key('droiddeck-remember-token')),
          )
          .value,
      isTrue,
    );
    expect(container.read(droidDeckTokenProvider), 987654321);
  });

  testWidgets('a mid-stream token edit does not restart the stream', (
    tester,
  ) async {
    tall(tester);
    final transport = _FakeTransport();
    var opens = 0;
    final container = await pumpGamepad(
      tester,
      MemorySecureTokenBackend(),
      () async {
        opens++;
        return transport;
      },
    );
    await tester.tap(find.text('DroidDeck 6DoF streaming'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('droiddeck-token')), '7');
    await tester.pump();
    await tester.tap(find.text('Start streaming'));
    await tester.pump();
    await tester.pump();
    expect(opens, 1);
    expect(find.text('Streaming to DroidDeck'), findsOneWidget);
    expect(
      find.textContaining('keeps the token it started with'),
      findsOneWidget,
    );

    // The edit is allowed while streaming and reaches only the provider:
    // the field alone restarts nothing.
    await tester.enterText(find.byKey(const Key('droiddeck-token')), '9');
    await tester.pump();
    expect(container.read(droidDeckTokenProvider), 9);
    expect(opens, 1);
    expect(find.text('Stop streaming'), findsOneWidget);

    await tester.tap(find.text('Stop streaming'));
    await tester.pump();
    await tester.pump();
    expect(transport.closed, isTrue);
    expect(
      find.textContaining('keeps the token it started with'),
      findsNothing,
    );
  });
}
