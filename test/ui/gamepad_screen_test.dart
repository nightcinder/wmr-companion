import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_core/domain/gamepad.dart';
import 'package:wmr_companion/hid/hid_gamepad_transport.dart';
import 'package:wmr_companion/hid/hid_output.dart';
import 'package:wmr_core/protocol/decoded_record.dart';
import 'package:wmr_core/services/controller_service.dart';
import 'package:wmr_companion/ui/debug/debug_providers.dart';
import 'package:wmr_companion/ui/debug/stream_settings.dart';
import 'package:wmr_companion/ui/gamepad/gamepad_providers.dart';
import 'package:wmr_companion/ui/gamepad/gamepad_screen.dart';

import '../hid/fake_hid.dart';
import 'raw_mode_notifier.dart';

void tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(900, 3200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

class _Ff12 extends StreamModeNotifier {
  @override
  StreamMode build() => StreamMode.decoded;
}

bool lamp(WidgetTester tester, String label) =>
    tester.widget<ButtonLamp>(find.widgetWithText(ButtonLamp, label)).on;

void main() {
  testWidgets('shows mapped buttons, sticks and triggers; settings apply', (
    tester,
  ) async {
    tall(tester);
    const inputs = GamepadInputs(
      HandInput(buttons: wmrBtnSqueeze, stick: [0.5, -0.25], trigger: 255),
      HandInput(buttons: wmrBtnMenu, trigger: 100),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          streamModeProvider.overrideWith(_Ff12.new),
          gamepadInputsProvider.overrideWith(
            (ref, source) => Stream.value(inputs),
          ),
        ],
        child: const MaterialApp(home: GamepadScreen()),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('(no data)'), findsNothing);
    expect(lamp(tester, 'L1'), isTrue);
    expect(lamp(tester, 'Start'), isTrue);
    expect(lamp(tester, 'L2'), isTrue);
    expect(lamp(tester, 'R2'), isFalse);
    expect(find.textContaining('x +0.50  y -0.25'), findsOneWidget);
    expect(find.text('trigger 1.00'), findsOneWidget);
    expect(find.textContaining('(no data)'), findsNothing);
    expect(
      find.textContaining('Trigger release (L2/R2) at 0.45'),
      findsOneWidget,
    );

    // 100/255 = 0.39 is below the 0.5 press point; lowering it presses R2.
    final container = ProviderScope.containerOf(
      tester.element(find.byType(GamepadScreen)),
    );
    final n = container.read(gamepadConfigProvider.notifier);
    n.set(
      container
          .read(gamepadConfigProvider)
          .copyWith(triggerPressThreshold: 0.3),
    );
    await tester.pump();
    expect(lamp(tester, 'R2'), isTrue);
  });

  testWidgets('raw mode explains that the decoded stream is needed', (
    tester,
  ) async {
    tall(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          streamModeProvider.overrideWith(RawModeNotifier.new),
          gamepadInputsProvider.overrideWith(
            (ref, source) => const Stream.empty(),
          ),
        ],
        child: const MaterialApp(home: GamepadScreen(source: DebugSource.real)),
      ),
    );
    await tester.pump();
    expect(find.textContaining('Needs the decoded stream'), findsOneWidget);
    expect(find.text('LEFT (no data)'), findsOneWidget);
    expect(find.text('RIGHT (no data)'), findsOneWidget);
  });

  testWidgets('HID panel shows the state and starts the output', (
    tester,
  ) async {
    tall(tester);
    final hid = FakeHid();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          hidTransportProvider.overrideWithValue(hid),
          gamepadInputsProvider.overrideWith(
            (ref, source) => const Stream.empty(),
          ),
        ],
        child: const MaterialApp(home: GamepadScreen()),
      ),
    );
    await tester.pump();
    expect(find.text('Not available on this device'), findsNothing);
    expect(find.byType(HidOutputPanel), findsOneWidget);

    await tester.tap(find.text('Bluetooth HID output'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Start'));
    await tester.pump();
    expect(hid.calls, contains('start'));
    expect(find.text('Stop'), findsOneWidget);
    expect(find.text('PC'), findsOneWidget); // paired host listed

    hid.emit(const HidStatus(HidState.connected, deviceName: 'PC'));
    await tester.pump();
    expect(find.text('Connected to PC'), findsOneWidget);
    expect(find.text('Disconnect'), findsOneWidget);
  });
}
