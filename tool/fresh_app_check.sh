#!/usr/bin/env bash
# Prove a brand-new Flutter app can consume the packages and read gamepad
# state. Creates a throwaway app in a temp directory, depends on the packages
# by path (they are not on pub.dev yet), and runs one test.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

flutter_bin="${FLUTTER:-flutter}"
if ! command -v "$flutter_bin" >/dev/null 2>&1; then
  if [ -n "${FLUTTER_ROOT:-}" ] && [ -x "$FLUTTER_ROOT/bin/flutter" ]; then
    flutter_bin="$FLUTTER_ROOT/bin/flutter"
  elif [ -x /tmp/flutter-sdk/flutter/bin/flutter ]; then
    flutter_bin=/tmp/flutter-sdk/flutter/bin/flutter
  fi
fi

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
app="$stage/fresh_host"

"$flutter_bin" create --template=app --project-name wmr_fresh_host "$app" \
  >/dev/null

python3 - "$app/pubspec.yaml" "$root" <<'PY'
import pathlib
import sys

pubspec = pathlib.Path(sys.argv[1])
root = pathlib.Path(sys.argv[2])
text = pubspec.read_text()
anchor = "  cupertino_icons: ^1.0.8"
if anchor not in text:
    raise SystemExit("unexpected generated pubspec: no cupertino_icons line")
host = (
    "wmr_companion",
    "wmr_ble",
    "wmr_ws",
    "wmr_companion_ui",
    "wmr_companion_hid_android",
)
deps = "\n".join(
    f"  {name}:\n    path: {root}/packages/{name}" for name in host
)
# The packages depend on each other by hosted constraints, which are not on
# pub.dev yet. A host using them by path must override the whole internal
# closure, because dependency overrides are not transitive.
closure = host + ("wmr_core", "wmr_fusion", "wmr_tracking")
overrides = "dependency_overrides:\n" + "\n".join(
    f"  {name}:\n    path: {root}/packages/{name}" for name in closure
)
pubspec.write_text(
    text.replace(anchor, anchor + "\n" + deps + "\n" + overrides)
)
PY

rm -f "$app/test/widget_test.dart"
cat > "$app/test/fresh_host_test.dart" <<'DART'
import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_ble/wmr_ble.dart';
import 'package:wmr_companion/testing.dart';
import 'package:wmr_companion/wmr_companion.dart';
import 'package:wmr_companion_hid_android/wmr_companion_hid_android.dart';
import 'package:wmr_companion_ui/wmr_companion_ui.dart';
import 'package:wmr_ws/wmr_ws.dart';

void main() {
  test('a fresh host reads gamepad state from the facade', () async {
    final transport = FakeTransport(devices: const [fakeBridgeDevice]);
    final bridge = FakeWmrBridge(transport)..start();
    addTearDown(() async {
      bridge.stop();
      await transport.dispose();
    });

    final wmr = WmrCompanion(ble: transport);
    addTearDown(wmr.dispose);

    await wmr.connect(
      const WmrBridgeDevice(id: fakeBridgeDeviceId, name: 'WMR Bridge'),
    );
    final state = await wmr.gamepad
        .firstWhere((s) => s.leftConnected && s.rightConnected)
        .timeout(const Duration(seconds: 2));

    expect(state.buttons, isA<Set<GamepadButton>>());
    expect(wmr.link, isA<Stream<WmrLinkSnapshot>>());

    // Every published package resolves in a fresh app, including the optional
    // ones the host is not required to use.
    const publicTypes = [
      UniversalBleAdapter,
      WmrWsTransport,
      OrientationView,
      HidGamepadTransport,
    ];
    expect(publicTypes, hasLength(4));
  });
}
DART

cd "$app"
"$flutter_bin" pub get >/dev/null
"$flutter_bin" test --reporter=expanded
