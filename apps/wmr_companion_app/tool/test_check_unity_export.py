#!/usr/bin/env python3
"""Tests for check_unity_export.py.

Builds small synthetic unityLibrary zips so the export checks run without the
272 MB artifact. The real `unity-export-1.0` (stale) and `unity-export-1.1`
(current) were also run by hand; they are not fixtures here because of size.

    python3 -m unittest -v tool/test_check_unity_export.py
"""

from __future__ import annotations

import contextlib
import io
import json
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import check_unity_export as checker  # noqa: E402

COMPLETE_METADATA = b"\x00".join(name.encode() for name in checker.REQUIRED_METADATA)


def build_export(
    directory: Path,
    *,
    metadata: bytes = COMPLETE_METADATA,
    omit: tuple[str, ...] = (),
    extra: dict[str, bytes] | None = None,
    subsystem_version: str = "0.9.0",
) -> Path:
    path = directory / "unityLibrary.zip"
    with zipfile.ZipFile(path, "w") as archive:
        for name in sorted(checker.REQUIRED_FILES):
            if name not in omit:
                archive.writestr(name, b"\x7fELF")
        if checker.METADATA_PATH not in omit:
            archive.writestr(checker.METADATA_PATH, metadata)
        for apk_path, (name, version) in checker.UNITY_SUBSYSTEMS.items():
            path_in_export = f"{checker.EXPORT_ROOT}/src/main/{apk_path}"
            if path_in_export in omit:
                continue
            if name == "VITURE XR Plugin":
                version = subsystem_version
            archive.writestr(
                path_in_export,
                json.dumps({"name": name, "version": version}),
            )
        for name, data in (extra or {}).items():
            archive.writestr(name, data)
    return path


def run_checker(archive: Path) -> tuple[int, str]:
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        code = checker.main(["check_unity_export.py", str(archive)])
    return code, out.getvalue()


class MainTest(unittest.TestCase):
    def test_current_export_passes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            code, output = run_checker(build_export(Path(tmp)))
        self.assertEqual(code, 0, output)
        self.assertIn("RESULT: PASS", output)
        self.assertIn("PASS mono: no `mono` stereo mode literal", output)

    def test_pre_ony_612_export_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            code, output = run_checker(build_export(Path(tmp), metadata=b"\x00StereoMode\x00"))
        self.assertEqual(code, 1, output)
        self.assertIn("stale, missing the ONY-612 stereo path", output)
        self.assertIn("playerHosted", output)

    def test_mono_export_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            code, output = run_checker(
                build_export(Path(tmp), metadata=COMPLETE_METADATA + b"\x04mono")
            )
        self.assertEqual(code, 1, output)
        self.assertIn("still emits the `mono` stereo mode", output)

    def test_missing_vendor_runtime_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            code, output = run_checker(
                build_export(Path(tmp), omit=("unityLibrary/libs/nr_loader.aar",))
            )
        self.assertEqual(code, 1, output)
        self.assertIn("missing export content", output)
        self.assertIn("nr_loader.aar", output)

    def test_missing_viture_runtime_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            code, output = run_checker(
                build_export(Path(tmp), omit=("unityLibrary/libs/VitureUnityXR.aar",))
            )
        self.assertEqual(code, 1, output)
        self.assertIn("VitureUnityXR.aar", output)

    def test_wrong_subsystem_version_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            code, output = run_checker(build_export(Path(tmp), subsystem_version="0.8.0"))
        self.assertEqual(code, 1, output)
        self.assertIn("unexpected subsystem", output)

    def test_second_libunity_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            code, output = run_checker(
                build_export(
                    Path(tmp),
                    extra={"unityLibrary/src/main/jniLibs/x86_64/libunity.so": b"\x7fELF"},
                )
            )
        self.assertEqual(code, 1, output)
        self.assertIn("expected exactly one libunity.so", output)

    def test_missing_path_is_usage_error(self) -> None:
        code, _ = run_checker(Path("/nonexistent/unityLibrary.zip"))
        self.assertEqual(code, 64)


if __name__ == "__main__":
    unittest.main()
