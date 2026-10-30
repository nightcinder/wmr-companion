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
    camera_required: str | None, extra_launcher: bool = False
) -> list[tuple[str, dict[str, str]]]:
    camera = {"name": "android.hardware.camera"}
    if camera_required is not None:
        camera["required"] = camera_required
    elements = [
        ("manifest", {"package": "com.onyxlens.wmr_companion", "versionName": "0.2.1"}),
        ("uses-permission", {"name": "android.permission.CAMERA"}),
        ("uses-permission", {"name": "android.permission.BLUETOOTH_SCAN"}),
        ("uses-permission", {"name": "android.permission.BLUETOOTH_CONNECT"}),
        ("uses-feature", {"name": "android.hardware.bluetooth_le", "required": "true"}),
        ("uses-feature", camera),
        ("uses-feature", {"name": "android.hardware.usb.host", "required": "false"}),
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


def build_apk(
    directory: Path,
    camera_required: str | None,
    display_stub: bool = True,
    extra_launcher: bool = False,
) -> Path:
    path = directory / "unified.apk"
    classes = list(checker.REQUIRED_DEX_CLASSES)
    if display_stub:
        # XREAL's GlassesDisplayPlugEvent AAR ships this as a program class;
        # the release build must keep it (ONY-557).
        classes.append("android/hardware/display/DisplayManager")
    with zipfile.ZipFile(path, "w") as apk:
        apk.writestr(
            "AndroidManifest.xml",
            build_manifest(_manifest_elements(camera_required, extra_launcher)),
        )
        apk.writestr(
            "classes.dex",
            b"\x00".join(name.encode() for name in classes),
        )
        for lib in checker.REQUIRED_LIBS:
            apk.writestr(lib, b"\x7fELF")
        for asset, (name, version) in checker.UNITY_SUBSYSTEMS.items():
            apk.writestr(asset, json.dumps({"name": name, "version": version}))
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
