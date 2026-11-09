#!/usr/bin/env python3
"""Tests for tool/mobsf_scan.py; no network and no MobSF are needed.

Synthetic APKs are built as plain zip archives with the ``lib/<abi>/*.so``
layout Android uses, so the inventory and diff logic run without an SDK.
"""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import mobsf_scan  # noqa: E402


def make_apk(path: Path, entries: dict[str, bytes]) -> Path:
    with zipfile.ZipFile(path, "w") as archive:
        for name, payload in entries.items():
            archive.writestr(name, payload)
    return path


class ReadNativeLibsTest(unittest.TestCase):
    def test_reads_only_shared_objects_under_lib(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            apk = make_apk(
                Path(tmp) / "app.apk",
                {
                    "AndroidManifest.xml": b"binary xml",
                    "lib/arm64-v8a/libapp.so": b"app",
                    "lib/arm64-v8a/libflutter.so": b"flutter",
                    "assets/plugin.so": b"not a jni lib",
                    "classes.dex": b"dex",
                },
            )
            libs = mobsf_scan.read_native_libs(apk)

        self.assertEqual(
            [lib.path for lib in libs],
            ["lib/arm64-v8a/libapp.so", "lib/arm64-v8a/libflutter.so"],
        )
        self.assertEqual({lib.abi for lib in libs}, {"arm64-v8a"})
        self.assertEqual(libs[0].size, 3)
        self.assertEqual(len(libs[0].sha256), 64)

    def test_hash_changes_with_content_at_the_same_size(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            first = mobsf_scan.read_native_libs(
                make_apk(Path(tmp) / "a.apk", {"lib/arm64-v8a/libx.so": b"aaaa"})
            )[0]
            second = mobsf_scan.read_native_libs(
                make_apk(Path(tmp) / "b.apk", {"lib/arm64-v8a/libx.so": b"bbbb"})
            )[0]

        self.assertEqual(first.size, second.size)
        self.assertNotEqual(first.sha256, second.sha256)

    def test_sorted_by_path_across_abis(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            apk = make_apk(
                Path(tmp) / "app.apk",
                {
                    "lib/x86/libtwo.so": b"2",
                    "lib/arm64-v8a/libone.so": b"1",
                },
            )
            libs = mobsf_scan.read_native_libs(apk)

        self.assertEqual(
            [lib.abi for lib in libs], ["arm64-v8a", "x86"]
        )


class InventoryRoundTripTest(unittest.TestCase):
    def test_write_then_load(self) -> None:
        libs = [
            mobsf_scan.NativeLib("lib/arm64-v8a/liba.so", "arm64-v8a", 3, "a" * 64),
            mobsf_scan.NativeLib("lib/arm64-v8a/libb.so", "arm64-v8a", 4, "b" * 64),
        ]
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "native-libs.json"
            mobsf_scan.write_inventory(libs, path)
            payload = json.loads(path.read_text())
            loaded = mobsf_scan.load_inventory(path)

        self.assertEqual(payload["schema"], mobsf_scan.INVENTORY_SCHEMA)
        self.assertEqual(loaded, libs)

    def test_unknown_schema_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "native-libs.json"
            path.write_text(json.dumps({"schema": 99, "libraries": []}))
            with self.assertRaises(SystemExit):
                mobsf_scan.load_inventory(path)


class DiffTest(unittest.TestCase):
    base = [
        mobsf_scan.NativeLib("lib/arm64-v8a/keep.so", "arm64-v8a", 1, "1" * 64),
        mobsf_scan.NativeLib("lib/arm64-v8a/gone.so", "arm64-v8a", 2, "2" * 64),
        mobsf_scan.NativeLib("lib/arm64-v8a/moved.so", "arm64-v8a", 3, "3" * 64),
    ]

    def test_classifies_added_removed_and_changed(self) -> None:
        current = [
            mobsf_scan.NativeLib("lib/arm64-v8a/keep.so", "arm64-v8a", 1, "1" * 64),
            mobsf_scan.NativeLib("lib/arm64-v8a/new.so", "arm64-v8a", 5, "5" * 64),
            mobsf_scan.NativeLib("lib/arm64-v8a/moved.so", "arm64-v8a", 4, "4" * 64),
        ]
        diff = mobsf_scan.diff_inventories(self.base, current)

        self.assertEqual([lib.path for lib in diff.added], ["lib/arm64-v8a/new.so"])
        self.assertEqual([lib.path for lib in diff.removed], ["lib/arm64-v8a/gone.so"])
        self.assertEqual(len(diff.changed), 1)
        old, new = diff.changed[0]
        self.assertEqual(old.sha256, "3" * 64)
        self.assertEqual(new.sha256, "4" * 64)
        self.assertFalse(diff.is_empty)
        self.assertTrue(diff.has_new_content)

    def test_identical_inventories_are_empty(self) -> None:
        diff = mobsf_scan.diff_inventories(self.base, list(self.base))
        self.assertTrue(diff.is_empty)
        self.assertFalse(diff.has_new_content)

    def test_removal_alone_is_not_new_content(self) -> None:
        remaining = [lib for lib in self.base if not lib.path.endswith("gone.so")]
        diff = mobsf_scan.diff_inventories(self.base, remaining)

        self.assertEqual(len(diff.removed), 1)
        self.assertFalse(diff.is_empty)
        self.assertFalse(diff.has_new_content)

    def test_move_between_abis_is_not_new_content(self) -> None:
        current = [
            mobsf_scan.NativeLib("lib/arm64-v8a/keep.so", "arm64-v8a", 1, "1" * 64),
            mobsf_scan.NativeLib("lib/x86_64/moved.so", "x86_64", 3, "3" * 64),
        ]
        diff = mobsf_scan.diff_inventories(self.base, current)

        self.assertEqual([lib.path for lib in diff.added], ["lib/x86_64/moved.so"])
        self.assertEqual(
            [lib.path for lib in diff.removed],
            ["lib/arm64-v8a/gone.so", "lib/arm64-v8a/moved.so"],
        )
        self.assertFalse(diff.is_empty)
        self.assertFalse(diff.has_new_content)

    def test_render_lists_each_change(self) -> None:
        current = [
            mobsf_scan.NativeLib("lib/arm64-v8a/keep.so", "arm64-v8a", 1, "1" * 64),
            mobsf_scan.NativeLib("lib/arm64-v8a/new.so", "arm64-v8a", 5, "5" * 64),
        ]
        report = mobsf_scan.render_diff(
            mobsf_scan.diff_inventories(self.base, current), "v1.0.0", "v1.1.0"
        )

        self.assertIn("v1.0.0 -> v1.1.0", report)
        self.assertIn("Added 1, removed 2, changed 0.", report)
        self.assertIn("`lib/arm64-v8a/new.so`", report)

    def test_render_says_identical(self) -> None:
        report = mobsf_scan.render_diff(
            mobsf_scan.diff_inventories(self.base, list(self.base)), "v1", "v2"
        )
        self.assertIn("Identical inventory", report)


class CommandLineTest(unittest.TestCase):
    def _apk(self, tmp: Path) -> Path:
        return make_apk(
            tmp / "release.apk",
            {
                "lib/arm64-v8a/libapp.so": b"app",
                "lib/arm64-v8a/libunity.so": b"unity",
            },
        )

    def test_skip_scan_writes_inventory_without_network(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            out = tmp_path / "out"
            code = mobsf_scan.main(
                [
                    "--apk",
                    str(self._apk(tmp_path)),
                    "--out-dir",
                    str(out),
                    "--skip-scan",
                ]
            )

            self.assertEqual(code, 0)
            inventory = json.loads((out / "native-libs.json").read_text())
            self.assertEqual(len(inventory["libraries"]), 2)
            self.assertFalse((out / "native-libs-diff.md").exists())

    def test_baseline_diff_is_written(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            out = tmp_path / "out"
            baseline = tmp_path / "baseline.json"
            baseline.write_text(
                json.dumps(
                    {
                        "schema": mobsf_scan.INVENTORY_SCHEMA,
                        "libraries": [
                            {
                                "path": "lib/arm64-v8a/libapp.so",
                                "abi": "arm64-v8a",
                                "size": 3,
                                "sha256": "0" * 64,
                            }
                        ],
                    }
                )
            )
            code = mobsf_scan.main(
                [
                    "--apk",
                    str(self._apk(tmp_path)),
                    "--out-dir",
                    str(out),
                    "--skip-scan",
                    "--baseline",
                    str(baseline),
                    "--baseline-tag",
                    "v0.3.17",
                    "--tag",
                    "v0.3.18",
                ]
            )

            self.assertEqual(code, 0)
            diff = (out / "native-libs-diff.md").read_text()
            self.assertIn("v0.3.17 -> v0.3.18", diff)
            self.assertIn("Changed", diff)  # libapp.so hash differs
            self.assertIn("Added", diff)  # libunity.so is new

    def test_fail_on_change_only_fires_on_new_content(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            out = tmp_path / "out"
            baseline = tmp_path / "baseline.json"
            mobsf_scan.write_inventory(
                [
                    mobsf_scan.NativeLib("lib/arm64-v8a/libapp.so", "arm64-v8a", 3, "0" * 64),
                    mobsf_scan.NativeLib("lib/arm64-v8a/libunity.so", "arm64-v8a", 5, "1" * 64),
                ],
                baseline,
            )
            # Same set, both hashes differ -> new content -> exit 3.
            code = mobsf_scan.main(
                [
                    "--apk",
                    str(self._apk(tmp_path)),
                    "--out-dir",
                    str(out),
                    "--skip-scan",
                    "--baseline",
                    str(baseline),
                    "--fail-on-change",
                ]
            )
            self.assertEqual(code, 3)

    def test_missing_apk_is_a_clean_failure(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            code = mobsf_scan.main(
                [
                    "--apk",
                    str(Path(tmp) / "absent.apk"),
                    "--out-dir",
                    str(Path(tmp) / "out"),
                    "--skip-scan",
                ]
            )
        self.assertEqual(code, 2)

    def test_scan_without_a_key_refuses_to_guess(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            code = mobsf_scan.main(
                [
                    "--apk",
                    str(self._apk(tmp_path)),
                    "--out-dir",
                    str(tmp_path / "out"),
                    "--api-key",
                    "",
                ]
            )
        self.assertEqual(code, 64)


if __name__ == "__main__":
    unittest.main()
