#!/usr/bin/env python3
"""Tests for check_unified_apk.py.

Builds synthetic binary Android XML and throwaway APKs so the parser and the
camera gate can be exercised without the Android SDK or a real artifact.

    python3 -m unittest -v tool/test_check_unified_apk.py
"""

from __future__ import annotations

import contextlib
import io
import json
import struct
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import check_unified_apk as checker  # noqa: E402

HEADER = 0x0003
STRING_POOL = 0x0001
START_ELEMENT = 0x0102


def _length(value: int) -> bytes:
    """UTF-8 pool length: one byte below 0x80, otherwise two (high bit tagged)."""
    if value < 0x80:
        return bytes([value])
    return bytes([0x80 | (value >> 8), value & 0xFF])


class _Pool:
    def __init__(self) -> None:
        self.strings: list[str] = []
        self.index: dict[str, int] = {}

    def add(self, value: str) -> int:
        if value not in self.index:
            self.index[value] = len(self.strings)
            self.strings.append(value)
        return self.index[value]


def _string_pool(strings: list[str], utf8: bool) -> bytes:
    offsets: list[int] = []
    payload = b""
    for value in strings:
        offsets.append(len(payload))
        if utf8:
            raw = value.encode("utf-8")
            payload += _length(len(value)) + _length(len(raw)) + raw + b"\0"
        else:
            raw = value.encode("utf-16-le")
            payload += struct.pack("<H", len(value)) + raw + b"\0\0"
    while len(payload) % 4:
        payload += b"\0"
    start = 28 + 4 * len(strings)
    body = struct.pack("<IIIII", len(strings), 0, 0x100 if utf8 else 0, start, 0)
    body += b"".join(struct.pack("<I", offset) for offset in offsets)
    body += payload
    return struct.pack("<HHI", STRING_POOL, 28, 8 + len(body)) + body


def _start_element(name: int, attrs: list[tuple[int, int]]) -> bytes:
    # ResXMLTree_node (16) + ResXMLTree_attrExt (20) + 20 bytes per attribute.
    size = 16 + 20 + 20 * len(attrs)
    body = struct.pack("<II", 0, 0xFFFFFFFF)  # lineNumber, comment
    body += struct.pack("<IIHHHHHH", 0xFFFFFFFF, name, 20, 20, len(attrs), 0, 0, 0)
    for attr_name, attr_value in attrs:
        body += struct.pack("<IIIHBBI", 0xFFFFFFFF, attr_name, attr_value, 8, 0, 0x03, attr_value)
    return struct.pack("<HHI", START_ELEMENT, 16, size) + body


def build_manifest(elements: list[tuple[str, dict[str, str]]], utf8: bool = False) -> bytes:
    pool = _Pool()
    chunks = []
    for element, attrs in elements:
        name = pool.add(element)
        encoded = [(pool.add(key), pool.add(value)) for key, value in attrs.items()]
        chunks.append((name, encoded))
    body = b"".join(_start_element(name, attrs) for name, attrs in chunks)
    return (
        struct.pack("<HHI", HEADER, 8, 8) + _string_pool(pool.strings, utf8) + body
    )


def _manifest_elements(
    camera_required: str | None,
    extra_launcher: bool = False,
    xr_permissions: bool = True,
    scene_fine: bool = False,
    usb_required: str | None = "false",
) -> list[tuple[str, dict[str, str]]]:
    camera = {"name": "android.hardware.camera"}
    if camera_required is not None:
        camera["required"] = camera_required
    usb = {"name": "android.hardware.usb.host"}
    if usb_required is not None:
        usb["required"] = usb_required
    elements = [
        ("manifest", {"package": "com.onyxlens.wmr_companion", "versionName": "0.2.1"}),
        ("uses-permission", {"name": "android.permission.CAMERA"}),
        ("uses-permission", {"name": "android.permission.BLUETOOTH_SCAN"}),
        ("uses-permission", {"name": "android.permission.BLUETOOTH_CONNECT"}),
    ]
    if xr_permissions:
        elements += [
            ("uses-permission", {"name": "android.permission.SCENE_UNDERSTANDING_COARSE"}),
            ("uses-permission", {"name": "android.permission.HAND_TRACKING"}),
            ("uses-permission", {"name": "android.permission.HEAD_TRACKING"}),
        ]
    if scene_fine:
        elements.append(
            ("uses-permission", {"name": "android.permission.SCENE_UNDERSTANDING_FINE"})
        )
    elements += [
        ("uses-feature", {"name": "android.hardware.bluetooth_le", "required": "true"}),
        ("uses-feature", camera),
        ("uses-feature", usb),
        ("application", {"name": "android.app.Application"}),
        ("meta-data", {"name": "com.viture.xr.sdk_version", "value": "0.9.0"}),
        ("meta-data", {"name": "com.viture.xr.dof", "value": "6dof"}),
        ("meta-data", {"name": "com.nreal.supportDevices", "value": "1|XrealLight|2|XrealAir"}),
        ("activity", {"name": "com.onyxlens.wmr_companion.MainActivity"}),
        ("intent-filter", {}),
        ("action", {"name": "android.intent.action.MAIN"}),
        ("category", {"name": "android.intent.category.LAUNCHER"}),
        ("activity", {"name": "com.unity3d.player.UnityPlayerActivity"}),
        ("activity", {"name": "ai.nreal.activitylife.NRXRActivity"}),
    ]
    if extra_launcher:
        elements += [
            ("intent-filter", {}),
            ("action", {"name": "android.intent.action.MAIN"}),
            ("category", {"name": "android.intent.category.LAUNCHER"}),
            ("category", {"name": "android.intent.category.LEANBACK_LAUNCHER"}),
        ]
    return elements


def _uleb128(value: int) -> bytes:
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            out.append(byte | 0x80)
        else:
            out.append(byte)
            return bytes(out)


NO_INDEX = 0xFFFFFFFF
DEX_HEADER_SIZE = 112


class DexBuilder:
    """Builds a minimal DEX with the tables check_unified_apk.Dex reads.

    The output is well formed for class descriptors, interfaces, protos and
    method names; code items and checksums are omitted because the checker does
    not read them (it runs before signing on the dex R8 produced).
    """

    def __init__(self) -> None:
        # (descriptor, interfaces, [(name, [param descriptors], return)])
        self._classes: list[tuple[str, list[str], list[tuple[str, list[str], str]]]] = []

    def add_class(
        self,
        descriptor: str,
        interfaces: list[str] | None = None,
        methods: list[tuple[str, list[str], str]] | None = None,
    ) -> "DexBuilder":
        self._classes.append((descriptor, list(interfaces or []), list(methods or [])))
        return self

    def build(self) -> bytes:
        strings: list[str] = []
        string_index: dict[str, int] = {}
        types: list[int] = []
        type_index: dict[str, int] = {}
        protos: list[tuple[int, list[int]]] = []
        proto_index: dict[tuple[tuple[str, ...], str], int] = {}
        methods: list[tuple[int, int, int]] = []

        def intern(value: str) -> int:
            if value not in string_index:
                string_index[value] = len(strings)
                strings.append(value)
            return string_index[value]

        def type_of(descriptor: str) -> int:
            if descriptor not in type_index:
                type_index[descriptor] = len(types)
                types.append(intern(descriptor))
            return type_index[descriptor]

        def proto_of(params: list[str], returns: str) -> int:
            key = (tuple(params), returns)
            if key not in proto_index:
                proto_index[key] = len(protos)
                protos.append((type_of(returns), [type_of(p) for p in params]))
            return proto_index[key]

        class_rows = []
        for descriptor, interfaces, class_methods in self._classes:
            class_idx = type_of(descriptor)
            interface_indices = [type_of(name) for name in interfaces]
            method_indices = []
            for name, params, returns in class_methods:
                method_indices.append((len(methods), proto_of(params, returns), intern(name)))
                methods.append((class_idx, proto_of(params, returns), intern(name)))
            class_rows.append((class_idx, interface_indices, method_indices))

        count_strings = len(strings)
        count_types = len(types)
        count_protos = len(protos)
        count_methods = len(methods)
        count_classes = len(class_rows)

        string_ids_off = DEX_HEADER_SIZE
        type_ids_off = string_ids_off + 4 * count_strings
        proto_ids_off = type_ids_off + 4 * count_types
        method_ids_off = proto_ids_off + 12 * count_protos
        class_defs_off = method_ids_off + 8 * count_methods
        data_off = class_defs_off + 32 * count_classes

        data = bytearray()

        def add_data(blob: bytes) -> int:
            while len(data) % 4:
                data.append(0)
            offset = data_off + len(data)
            data.extend(blob)
            return offset

        def type_list(indices: list[int]) -> bytes:
            return struct.pack("<I", len(indices)) + b"".join(struct.pack("<H", i) for i in indices)

        string_offsets = [
            add_data(_uleb128(len(value)) + value.encode("utf-8") + b"\0") for value in strings
        ]
        proto_params = [add_data(type_list(params)) if params else 0 for _, params in protos]
        class_data_offsets = []
        for _, _, method_indices in class_rows:
            body = _uleb128(0) + _uleb128(0) + _uleb128(len(method_indices)) + _uleb128(0)
            previous = 0
            for method_index, _, _ in method_indices:
                body += _uleb128(method_index - previous) + _uleb128(0x1) + _uleb128(0)
                previous = method_index
            class_data_offsets.append(add_data(body) if method_indices else 0)

        class_defs = b""
        for (class_idx, interface_indices, _), class_data_off in zip(class_rows, class_data_offsets):
            interfaces_off = add_data(type_list(interface_indices)) if interface_indices else 0
            class_defs += struct.pack(
                "<IIIIIIII",
                class_idx,
                0x1,
                NO_INDEX,
                interfaces_off,
                NO_INDEX,
                0,
                class_data_off,
                0,
            )

        header = bytearray(DEX_HEADER_SIZE)
        header[0:8] = b"dex\n035\0"
        struct.pack_into("<I", header, 0x38, count_strings)
        struct.pack_into("<I", header, 0x3C, string_ids_off)
        struct.pack_into("<I", header, 0x40, count_types)
        struct.pack_into("<I", header, 0x44, type_ids_off)
        struct.pack_into("<I", header, 0x48, count_protos)
        struct.pack_into("<I", header, 0x4C, proto_ids_off)
        struct.pack_into("<I", header, 0x58, count_methods)
        struct.pack_into("<I", header, 0x5C, method_ids_off)
        struct.pack_into("<I", header, 0x60, count_classes)
        struct.pack_into("<I", header, 0x64, class_defs_off)
        struct.pack_into("<I", header, 0x68, len(data))
        struct.pack_into("<I", header, 0x6C, data_off)

        string_ids = b"".join(struct.pack("<I", offset) for offset in string_offsets)
        type_ids = b"".join(struct.pack("<I", index) for index in types)
        proto_ids = b"".join(
            struct.pack("<III", 0, returns, proto_params[slot])
            for slot, (returns, _) in enumerate(protos)
        )
        method_ids = b"".join(
            struct.pack("<HHI", class_idx, proto_idx, name_idx)
            for class_idx, proto_idx, name_idx in methods
        )
        return bytes(header) + string_ids + type_ids + proto_ids + method_ids + class_defs + bytes(data)


def build_apk(
    directory: Path,
    camera_required: str | None,
    display_stub: bool = True,
    extra_launcher: bool = False,
    stereo_stages: bool = True,
    monado_key: bytes | None = b"\0" * checker.MONADO_KEY_SIZE,
    xr_permissions: bool = True,
    scene_fine: bool = False,
    usb_required: str | None = "false",
    unified_dispatch: bool = True,
    consumer_accept: bool = True,
    consumer_classes: int = 1,
    r8_keep: bool = True,
) -> Path:
    path = directory / "unified.apk"
    dex = DexBuilder()
    for name in checker.REQUIRED_DEX_CLASSES:
        dex.add_class(f"Lcom/onyxlens/wmr_tracking/{name};")
    if r8_keep:
        for name in checker.R8_REQUIRED_CLASSES:
            dex.add_class(name)
        for name, callbacks in checker.R8_JNI_CALLBACKS.items():
            dex.add_class(
                name,
                methods=[(method, list(params), returns) for method, params, returns in callbacks],
            )
    if display_stub:
        # XREAL's GlassesDisplayPlugEvent AAR ships this as a program class;
        # the release build must keep it (ONY-557).
        dex.add_class("Landroid/hardware/display/DisplayManager;")
    for index in range(consumer_classes):
        # androidx.xr registers these with the device's XrExtensions; R8 must
        # keep the callback methods (ONY-758).
        dex.add_class(
            f"Landroidx/xr/scenecore/spatial/core/ActivitySpaceImpl$consumer${index};",
            interfaces=[checker.XR_REQUIRED_CALLBACK],
            methods=[("accept", ["Ljava/lang/Object;"], "V")] if consumer_accept else [],
        )
    dex.add_class(
        "Lcom/google/imp/splitengine/extensions/RequestCallback$1;",
        interfaces=["Lcom/android/extensions/xr/splitengine/RequestCallback;"],
        methods=[("onResult", ["[B"], "V")],
    )
    dex.add_class(
        "Lcom/google/imp/splitengine/extensions/MessageGroupCallback$1;",
        interfaces=["Lcom/android/extensions/xr/splitengine/MessageGroupCallback;"],
        methods=[("onMessageGroupComplete", ["I"], "V")],
    )
    with zipfile.ZipFile(path, "w") as apk:
        apk.writestr(
            "AndroidManifest.xml",
            build_manifest(
                _manifest_elements(
                    camera_required,
                    extra_launcher,
                    xr_permissions,
                    scene_fine,
                    usb_required,
                )
            ),
        )
        apk.writestr(
            "classes.dex",
            dex.build(),
        )
        for lib in checker.REQUIRED_LIBS:
            apk.writestr(lib, b"\x7fELF")
        for asset, (name, version) in checker.UNITY_SUBSYSTEMS.items():
            apk.writestr(asset, json.dumps({"name": name, "version": version}))
        stages = (
            checker.REQUIRED_STEREO_LITERALS + checker.REQUIRED_METADATA_LITERALS
            if stereo_stages
            else ("playerHosted",)
        )
        if not unified_dispatch:
            stages = checker.REQUIRED_STEREO_LITERALS
        apk.writestr(
            checker.UNITY_METADATA,
            b"\x00".join(stage.encode() for stage in stages),
        )
        if monado_key is not None:
            apk.writestr(checker.MONADO_KEY_ASSET, monado_key)
    return path


def run_checker(apk: Path) -> tuple[int, str]:
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        code = checker.main(["check_unified_apk.py", str(apk)])
    return code, out.getvalue()


class AxmlTest(unittest.TestCase):
    def test_utf16_pool_decodes_attributes(self) -> None:
        xml = build_manifest(_manifest_elements("false"))
        manifest = checker.Axml(xml)
        self.assertEqual(manifest.first("manifest")["package"], "com.onyxlens.wmr_companion")
        self.assertEqual(manifest.first("manifest")["versionName"], "0.2.1")

    def test_utf8_pool_decodes_short_and_long_strings(self) -> None:
        long_name = "android.permission." + "X" * 200
        elements = [
            ("manifest", {"package": "com.onyxlens.wmr_companion"}),
            ("uses-permission", {"name": long_name}),
        ]
        manifest = checker.Axml(build_manifest(elements, utf8=True))
        self.assertEqual(manifest.first("manifest")["package"], "com.onyxlens.wmr_companion")
        self.assertEqual(manifest.of("uses-permission")[0]["name"], long_name)


class DexTest(unittest.TestCase):
    def test_reads_descriptors_interfaces_and_methods(self) -> None:
        dex = checker.Dex(
            DexBuilder()
            .add_class(
                "Lcom/example/Impl;",
                interfaces=[checker.XR_REQUIRED_CALLBACK],
                methods=[("accept", ["Ljava/lang/Object;"], "V")],
            )
            .build()
        )
        self.assertEqual(
            dex.classes(),
            [("Lcom/example/Impl;", [checker.XR_REQUIRED_CALLBACK], {("accept", "(Ljava/lang/Object;)V")})],
        )

    def test_callback_without_its_method_is_reported(self) -> None:
        blob = (
            DexBuilder()
            .add_class("Lcom/example/Impl;", interfaces=[checker.XR_REQUIRED_CALLBACK])
            .build()
        )
        failures = checker.xr_callback_failures([blob])
        self.assertEqual(len(failures), 1)
        self.assertIn("without accept(Ljava/lang/Object;)V", failures[0])

    def test_split_engine_callback_without_its_method_is_reported(self) -> None:
        blob = (
            DexBuilder()
            .add_class(
                "Lcom/example/Impl;",
                interfaces=[checker.XR_REQUIRED_CALLBACK],
                methods=[("accept", ["Ljava/lang/Object;"], "V")],
            )
            .add_class(
                "Lcom/example/Split;",
                interfaces=["Lcom/android/extensions/xr/splitengine/RequestCallback;"],
            )
            .build()
        )
        failures = checker.xr_callback_failures([blob])
        self.assertEqual(len(failures), 1)
        self.assertIn("without onResult([B)V", failures[0])

    def test_missing_consumer_implementor_is_reported(self) -> None:
        blob = DexBuilder().add_class("Lcom/example/Other;").build()
        failures = checker.xr_callback_failures([blob])
        self.assertEqual(len(failures), 1)
        self.assertIn("no class implements", failures[0])


class RequiredFlagTest(unittest.TestCase):
    def test_missing_required_attribute_is_required(self) -> None:
        self.assertTrue(checker.is_required(None))

    def test_explicit_true_and_false(self) -> None:
        self.assertTrue(checker.is_required("true"))
        self.assertFalse(checker.is_required("false"))


class MainTest(unittest.TestCase):
    def test_fully_featured_apk_passes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            code, output = run_checker(build_apk(Path(tmp), "false"))
        self.assertEqual(code, 0, output)
        self.assertIn("RESULT: PASS", output)
        self.assertIn(
            "INFO dex (release may rename): PendingStartGate=renamed/inlined, "
            "SharedUnityRuntime=renamed/inlined",
            output,
        )
        self.assertIn(
            f"PASS Monado key: {checker.MONADO_KEY_ASSET} "
            f"({checker.MONADO_KEY_SIZE} bytes)",
            output,
        )
        self.assertIn("android.permission.SCENE_UNDERSTANDING_COARSE", output)
        self.assertIn("android.permission.HAND_TRACKING", output)
        self.assertIn("android.permission.HEAD_TRACKING", output)
        self.assertIn("PASS dex: Android XR callbacks keep their methods", output)
        self.assertIn(
            "PASS dex: vendor/Unity classes and plugin JNI callbacks kept",
            output,
        )

    def test_missing_r8_kept_plugin_class_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            code, output = run_checker(build_apk(Path(tmp), "false", r8_keep=False))
        self.assertEqual(code, 1, output)
        self.assertIn("WmrTrackingXrealPlugin", output)
        self.assertIn("renamed or removed by R8", output)
        self.assertIn("RESULT: FAIL", output)

    def test_consumer_without_accept_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            code, output = run_checker(build_apk(Path(tmp), "false", consumer_accept=False))
        self.assertEqual(code, 1, output)
        self.assertIn("without accept(Ljava/lang/Object;)V", output)
        self.assertIn("RESULT: FAIL", output)

    def test_missing_consumer_implementor_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            code, output = run_checker(build_apk(Path(tmp), "false", consumer_classes=0))
        self.assertEqual(code, 1, output)
        self.assertIn("no class implements", output)
        self.assertIn("RESULT: FAIL", output)

    def test_require_lib_rejects_an_apk_without_the_viture_sdk(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            apk = build_apk(Path(tmp), "false")
            code, output = run_checker(apk)
            self.assertEqual(code, 0, output)
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                code = checker.main(
                    [
                        "check_unified_apk.py",
                        str(apk),
                        "--require-lib",
                        "lib/arm64-v8a/libglasses.so",
                    ]
                )
            output = out.getvalue()
        self.assertEqual(code, 1, output)
        self.assertIn("missing native libraries:", output)
        self.assertIn("lib/arm64-v8a/libglasses.so", output)
        self.assertIn("RESULT: FAIL", output)

    def test_missing_xr_permissions_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            code, output = run_checker(
                build_apk(Path(tmp), "false", xr_permissions=False)
            )
        self.assertEqual(code, 1, output)
        self.assertIn("missing permissions:", output)
        for permission in (
            "android.permission.SCENE_UNDERSTANDING_COARSE",
            "android.permission.HAND_TRACKING",
            "android.permission.HEAD_TRACKING",
        ):
            self.assertIn(permission, output)

    def test_scene_understanding_fine_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            code, output = run_checker(build_apk(Path(tmp), "false", scene_fine=True))
        self.assertEqual(code, 1, output)
        self.assertIn("forbidden permissions present:", output)
        self.assertIn("android.permission.SCENE_UNDERSTANDING_FINE", output)

    def test_missing_monado_key_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            code, output = run_checker(build_apk(Path(tmp), "false", monado_key=None))
        self.assertEqual(code, 1, output)
        self.assertIn("missing Monado config key", output)
        self.assertIn(checker.MONADO_KEY_ASSET, output)
        self.assertIn("APK monado entries: []", output)

    def test_wrong_size_monado_key_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            code, output = run_checker(
                build_apk(Path(tmp), "false", monado_key=b"\0" * 16)
            )
        self.assertEqual(code, 1, output)
        self.assertIn("is 16 bytes, expected 1024", output)

    def test_stale_unity_metadata_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            code, output = run_checker(build_apk(Path(tmp), "false", stereo_stages=False))
        self.assertEqual(code, 1, output)
        self.assertIn("stale", output)
        self.assertIn("loaderStarted", output)

    def test_missing_unified_dispatch_metadata_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            code, output = run_checker(
                build_apk(Path(tmp), "false", unified_dispatch=False)
            )
        self.assertEqual(code, 1, output)
        self.assertIn("WmrTrackingUnifiedBridge", output)
        self.assertIn("VendorLoaderGate", output)

    def test_usb_host_required_by_default_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            code, output = run_checker(
                build_apk(Path(tmp), "false", usb_required=None)
            )
        self.assertEqual(code, 1, output)
        self.assertIn("android.hardware.usb.host is required", output)

    def test_usb_host_explicitly_required_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            code, output = run_checker(
                build_apk(Path(tmp), "false", usb_required="true")
            )
        self.assertEqual(code, 1, output)
        self.assertIn("android.hardware.usb.host is required", output)

    def test_missing_xreal_display_stub_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            code, output = run_checker(build_apk(Path(tmp), "false", display_stub=False))
        self.assertEqual(code, 1, output)
        self.assertIn("XREAL display stub is missing", output)

    def test_camera_required_by_default_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            code, output = run_checker(build_apk(Path(tmp), None))
        self.assertEqual(code, 1, output)
        self.assertIn("android.hardware.camera is required", output)

    def test_camera_explicitly_required_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            code, output = run_checker(build_apk(Path(tmp), "true"))
        self.assertEqual(code, 1, output)
        self.assertIn("android.hardware.camera is required", output)

    def test_second_launcher_activity_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            code, output = run_checker(build_apk(Path(tmp), "false", extra_launcher=True))
        self.assertEqual(code, 1, output)
        self.assertIn("launcher activities:", output)
        self.assertIn("ai.nreal.activitylife.NRXRActivity", output)


if __name__ == "__main__":
    unittest.main()
