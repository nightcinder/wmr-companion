#!/usr/bin/env python3
"""Host-side pre-flight check for a unified (VITURE + XREAL) companion APK.

Validates what can be proved without a device: the binary Android manifest is
merged from the app and both vendor SDK manifests, both Unity XR runtimes are
present with their hand-tracking libraries, the Monado config key is packaged,
the Dart/Kotlin plugin entry classes are in the dex, and the permission/session
contract the run sheet relies on is declared: BLE, camera and the Android XR
scene-understanding-coarse, hand-tracking and head-tracking permissions, with
no request for precise (fine) scene understanding. It does not prove that a vendor
runtime starts, that permissions are granted, or that hands are tracked; those
stay on the hardware gates.

    python3 tool/check_unified_apk.py path/to/wmr-companion-0.2.1-unified-debug.apk

No Android SDK, Unity or third-party Python package needed. Exit codes:
0 = all checks pass, 1 = a required check failed, 64 = bad usage.
"""

from __future__ import annotations

import hashlib
import json
import struct
import sys
import zipfile
from pathlib import Path

REQUIRED_PERMISSIONS = {
    "android.permission.BLUETOOTH_SCAN",
    "android.permission.BLUETOOTH_CONNECT",
    "android.permission.CAMERA",
    # Android XR: coarse scene understanding plus head and hand tracking are
    # what the tracking source reads (ONY-614).
    "android.permission.SCENE_UNDERSTANDING_COARSE",
    "android.permission.HAND_TRACKING",
    "android.permission.HEAD_TRACKING",
}
FORBIDDEN_PERMISSIONS = {
    # This source reads poses only; requesting precise scene geometry would
    # prompt the user for data the app never uses (ONY-614).
    "android.permission.SCENE_UNDERSTANDING_FINE",
}
REQUIRED_FEATURES = {
    "android.hardware.bluetooth_le",
    "android.hardware.camera",
    "android.hardware.usb.host",
}
REQUIRED_LIBS = {
    "lib/arm64-v8a/libunity.so",
    "lib/arm64-v8a/libVitureUnityXR.so",
    "lib/arm64-v8a/libXREALXRPlugin.so",
}
# Flutter packages every declared pubspec asset under assets/flutter_assets/,
# so `assets/monado/` lands at assets/flutter_assets/assets/monado/. The bare
# pubspec path is not an APK entry. The key is fetched by CI before the build
# and is exactly 1024 bytes (see tool/monado_key.dart).
MONADO_KEY_ASSET = "assets/flutter_assets/assets/monado/wmr_config_key.bin"
MONADO_KEY_SIZE = 1024
REQUIRED_DEX_CLASSES = {
    "WmrTrackingXrealPlugin",
    "WmrTrackingViturePlugin",
    "WmrTrackingDispatchPlugin",
}
# R8 in a `--release` build may rename or inline these, so they are reported
# but not required: only the Flutter-registered plugin entry classes survive.
OPTIONAL_DEX_CLASSES = {
    "SharedUnityRuntime",
    "PendingStartGate",
}
UNITY_SUBSYSTEMS = {
    "assets/bin/Data/UnitySubsystems/VitureUnityXR/UnitySubsystemsManifest.json": ("VITURE XR Plugin", "0.9.0"),
    "assets/bin/Data/UnitySubsystems/XREALXRPlugin/UnitySubsystemsManifest.json": ("XREAL XR Plugin", "3.1.0"),
}
# ONY-612's WmrStereoCameraRig reports these stage names through
# WmrTrackingViturePlugin.onUnityStage. An APK built from the pre-ONY-612
# export carries none of them, so their absence proves the release artifact
# does not hold the current bridge.
REQUIRED_STEREO_LITERALS = ("playerHosted", "loaderStarted", "firstFrame")
UNITY_METADATA = "assets/bin/Data/Managed/Metadata/global-metadata.dat"


class Axml:
    """Minimal binary-XML reader: enough for element names and attributes."""

    def __init__(self, data: bytes) -> None:
        if struct.unpack_from("<H", data, 0)[0] != 0x0003:
            raise ValueError("not an Android binary manifest")
        self.data = data
        self.strings: list[str] = []
        self.elements: list[tuple[str, dict[str, str]]] = []
        self._parse()

    def _parse(self) -> None:
        data = self.data
        pos = 8
        while pos + 8 <= len(data):
            chunk_type, _, size = struct.unpack_from("<HHI", data, pos)
            if size == 0:
                raise ValueError("zero-sized chunk")
            if chunk_type == 0x0001:
                self._string_pool(pos)
            elif chunk_type == 0x0102:
                self._start_element(pos)
            pos += size

    def _length(self, at: int) -> tuple[int, int]:
        """ResStringPool length: one byte, or two when the high bit is set."""
        first = self.data[at]
        if first & 0x80:
            return ((first & 0x7F) << 8) | self.data[at + 1], 2
        return first, 1

    def _string_pool(self, pos: int) -> None:
        count, _, flags, strings_start, _ = struct.unpack_from("<IIIII", self.data, pos + 8)
        offsets = struct.unpack_from(f"<{count}I", self.data, pos + 28)
        base = pos + strings_start
        for offset in offsets:
            at = base + offset
            if flags & 0x100:  # UTF-8 pool: [u16 len][u8 len][bytes][NUL]
                _, width = self._length(at)
                at += width
                length, width = self._length(at)
                at += width
                self.strings.append(self.data[at : at + length].decode("utf-8", "replace"))
            else:
                length = struct.unpack_from("<H", self.data, at)[0]
                at += 2
                self.strings.append(self.data[at : at + length * 2].decode("utf-16-le", "replace"))

    def _start_element(self, pos: int) -> None:
        name_index = struct.unpack_from("<I", self.data, pos + 20)[0]
        attr_start, attr_size, attr_count = struct.unpack_from("<HHH", self.data, pos + 24)
        attrs: dict[str, str] = {}
        for index in range(attr_count):
            at = pos + 16 + attr_start + index * attr_size
            _, attr_name, raw, _, _, value_type, value = struct.unpack_from("<IIIHBBI", self.data, at)
            key = self.strings[attr_name] if attr_name < len(self.strings) else f"#{attr_name}"
            if raw != 0xFFFFFFFF and raw < len(self.strings):
                attrs[key] = self.strings[raw]
            elif value_type == 0x03 and value < len(self.strings):
                attrs[key] = self.strings[value]
            elif value_type == 0x12:
                attrs[key] = "true" if value else "false"
            elif value_type in (0x10, 0x11):
                attrs[key] = str(value)
        name = self.strings[name_index] if name_index < len(self.strings) else f"#{name_index}"
        self.elements.append((name, attrs))

    def of(self, element: str) -> list[dict[str, str]]:
        return [attrs for name, attrs in self.elements if name == element]

    def first(self, element: str) -> dict[str, str]:
        found = self.of(element)
        return found[0] if found else {}

    def launcher_activities(self) -> list[str]:
        """Activities with a MAIN + LAUNCHER/LEANBACK intent filter.

        The Android binary XML reader keeps a flat element list, so this walks
        it in document order and treats each component element as the owner of
        the intent filters that follow it until the next component.
        """
        launcher_categories = {
            "android.intent.category.LAUNCHER",
            "android.intent.category.LEANBACK_LAUNCHER",
        }
        found: list[str] = []
        current: str | None = None
        has_main = False
        has_launcher = False
        for name, attrs in self.elements:
            if name in (
                "activity",
                "activity-alias",
                "receiver",
                "service",
                "provider",
            ):
                if current is not None and has_main and has_launcher:
                    found.append(current)
                current = attrs.get("name") if name in ("activity", "activity-alias") else None
                has_main = False
                has_launcher = False
            elif current is not None and name == "action":
                if attrs.get("name") == "android.intent.action.MAIN":
                    has_main = True
            elif current is not None and name == "category":
                if attrs.get("name") in launcher_categories:
                    has_launcher = True
        if current is not None and has_main and has_launcher:
            found.append(current)
        return found


def fail(message: str) -> None:
    print(f"FAIL: {message}")


def is_required(value: str | None) -> bool:
    """Android defaults android:required to true when the attribute is absent."""
    return value != "false"


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__.strip().splitlines()[0], file=sys.stderr)
        return 64
    apk_path = Path(argv[1])
    if not apk_path.is_file():
        print(f"FAIL: not found: {apk_path}", file=sys.stderr)
        return 64

    digest = hashlib.sha256(apk_path.read_bytes()).hexdigest()
    print(f"APK:   {apk_path.name} ({apk_path.stat().st_size} bytes)")
    print(f"SHA256 {digest}")

    failures = 0
    with zipfile.ZipFile(apk_path) as apk:
        names = set(apk.namelist())
        manifest = Axml(apk.read("AndroidManifest.xml"))

        package = manifest.first("manifest").get("package", "")
        version = manifest.first("manifest").get("versionName", "")
        print(f"PASS manifest: {package} {version}")
        if package != "com.onyxlens.wmr_companion":
            fail(f"unexpected package: {package}")
            failures += 1

        permissions = {row.get("name") for row in manifest.of("uses-permission")}
        missing = REQUIRED_PERMISSIONS - permissions
        if missing:
            fail(f"missing permissions: {sorted(missing)}")
            failures += 1
        else:
            print(f"PASS permissions: {sorted(REQUIRED_PERMISSIONS)}")
        forbidden = FORBIDDEN_PERMISSIONS & permissions
        if forbidden:
            fail(f"forbidden permissions present: {sorted(forbidden)}")
            failures += 1

        features = {row.get("name"): row.get("required") for row in manifest.of("uses-feature") if row.get("name")}
        missing = REQUIRED_FEATURES - set(features)
        if missing:
            fail(f"missing features: {sorted(missing)}")
            failures += 1
        else:
            camera_required = features.get("android.hardware.camera")
            if is_required(camera_required):
                fail("android.hardware.camera is required (explicitly or by default); it would filter devices")
                failures += 1
            else:
                print("PASS features: bluetooth_le, camera(required=false), usb.host")

        missing_libs = REQUIRED_LIBS - names
        if missing_libs:
            fail(f"missing native libraries: {sorted(missing_libs)}")
            failures += 1
        else:
            print(f"PASS native: {sorted(REQUIRED_LIBS)}")
        abis = sorted({name.split("/")[1] for name in names if name.startswith("lib/") and name.count("/") == 2})
        print(f"INFO ABIs: {abis}")

        if MONADO_KEY_ASSET not in names:
            monado = sorted(name for name in names if "monado" in name.lower())
            fail(f"missing Monado config key: {MONADO_KEY_ASSET}; APK monado entries: {monado}")
            failures += 1
        elif apk.getinfo(MONADO_KEY_ASSET).file_size != MONADO_KEY_SIZE:
            size = apk.getinfo(MONADO_KEY_ASSET).file_size
            fail(f"Monado config key is {size} bytes, expected {MONADO_KEY_SIZE}: {MONADO_KEY_ASSET}")
            failures += 1
        else:
            print(f"PASS Monado key: {MONADO_KEY_ASSET} ({MONADO_KEY_SIZE} bytes)")

        if UNITY_METADATA not in names:
            fail(f"missing IL2CPP metadata: {UNITY_METADATA}")
            failures += 1
        else:
            metadata = apk.read(UNITY_METADATA)
            missing_stages = [name for name in REQUIRED_STEREO_LITERALS if name.encode() not in metadata]
            if missing_stages:
                fail(f"IL2CPP metadata is from the pre-ONY-612 export, missing stereo stages: {missing_stages}")
                failures += 1
            else:
                print(f"PASS stereo stages: {list(REQUIRED_STEREO_LITERALS)}")

        dex = b"".join(apk.read(name) for name in names if name.startswith("classes") and name.endswith(".dex"))
        missing_classes = {name for name in REQUIRED_DEX_CLASSES if name.encode() not in dex}
        if missing_classes:
            fail(f"missing tracking classes: {sorted(missing_classes)}")
            failures += 1
        else:
            print(f"PASS dex: {sorted(REQUIRED_DEX_CLASSES)}")
        optional = ", ".join(
            f"{name}={'present' if name.encode() in dex else 'renamed/inlined'}"
            for name in sorted(OPTIONAL_DEX_CLASSES)
        )
        print(f"INFO dex (release may rename): {optional}")

        # XREAL's glasses AAR bundles android.hardware.display.DisplayManager
        # as a stub. R8 must keep it: when it is shrunk, R8 rewrites the SDK's
        # `(DisplayManager) getSystemService("display")` cast into an
        # unconditional ClassCastException and GlassesInitProvider kills the
        # process before the launcher activity runs (ONY-557). A shrunk stub
        # leaves no type string in the dex.
        display_stub = "android/hardware/display/DisplayManager"
        if display_stub.encode() not in dex:
            fail(
                "XREAL display stub is missing from the dex; "
                "GlassesInitProvider will crash on launch (ONY-557)"
            )
            failures += 1
        else:
            print("PASS dex: XREAL display stub kept for GlassesInitProvider")

        for path, (plugin_name, version_expected) in UNITY_SUBSYSTEMS.items():
            if path not in names:
                fail(f"missing Unity subsystem: {path}")
                failures += 1
                continue
            subsystem = json.loads(apk.read(path))
            if subsystem.get("name") != plugin_name or subsystem.get("version") != version_expected:
                fail(f"unexpected subsystem {path}: {subsystem.get('name')} {subsystem.get('version')}")
                failures += 1
            else:
                print(f"PASS Unity: {plugin_name} {version_expected}")

        application = manifest.first("application")
        metadata: dict[str, str] = {}
        for row in manifest.of("meta-data"):
            name = row.get("name")
            if name:
                metadata[name] = row.get("value", "")
        if metadata.get("com.viture.xr.sdk_version") != "0.9.0" or metadata.get("com.viture.xr.dof") != "6dof":
            fail("VITURE SDK metadata is missing or not 6dof")
            failures += 1
        else:
            print("PASS VITURE metadata: sdk 0.9.0, dof 6dof")
        support = metadata.get("com.nreal.supportDevices", "")
        if not support:
            fail("XREAL supportDevices metadata is missing")
            failures += 1
        else:
            print(f"INFO XREAL supportDevices: {support} (confirm Air 2 Ultra coverage on device)")

        activities = {row.get("name") for row in manifest.of("activity")}
        required_activities = (
            "com.onyxlens.wmr_companion.MainActivity",
            "com.unity3d.player.UnityPlayerActivity",
            "ai.nreal.activitylife.NRXRActivity",
        )
        missing_activities = [name for name in required_activities if name not in activities]
        if missing_activities:
            fail(f"missing activities: {missing_activities}")
            failures += 1
        else:
            print("PASS sessions: Flutter MainActivity + UnityPlayerActivity + XREAL NREAL activities")

        # Only the Flutter activity may appear on the home screen. XREAL's
        # NRXRActivity ships a launcher filter for standalone Unity apps; if it
        # survives merging, the APK installs two icons and the extra one opens
        # a black Unity scene (ONY-561).
        launchers = manifest.launcher_activities()
        expected_launcher = "com.onyxlens.wmr_companion.MainActivity"
        if launchers != [expected_launcher]:
            fail(f"launcher activities: {launchers}; expected only {expected_launcher}")
            failures += 1
        else:
            print(f"PASS launcher: only {expected_launcher}")

        if not application.get("name"):
            fail("application element has no name")
            failures += 1

    print("RESULT:", "PASS" if failures == 0 else f"FAIL ({failures} check(s))")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
