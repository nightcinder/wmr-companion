#!/usr/bin/env python3
"""Scan a published release APK with MobSF and record its native libraries.

This produces two deliberately separate outputs.

``native-libs.json`` is the part this repository owns. MobSF's report describes
one APK; it cannot say whether a shared object came from our own build, from the
pinned Unity export, or from a vendor SDK, and it cannot compare two releases.
Hashing every ``lib//*.so`` out of the archive gives a stable baseline a later
release can be diffed against, which is the only way an unexpected blob becomes
visible.

``mobsf-report.json`` / ``mobsf-report.pdf`` is everything MobSF finds: manifest
and ``appsec`` findings, exported components, secrets, network security config,
trackers and per-library hardening (NX, PIE, stack canary, RELRO, RPATH).

The inventory is written before the scan runs, so a MobSF outage still leaves a
diffable record of what shipped.

    python3 tool/mobsf_scan.py --apk wmr-companion-0.3.18-unified-arm64-v8a.apk \
        --out-dir "$RUNNER_TEMP/mobsf" --tag v0.3.18 \
        --baseline previous-native-libs.json --baseline-tag v0.3.17

The MobSF URL defaults to ``http://mobsf:8000`` (the container on the runner's
docker network) and is overridden by ``--url`` or ``MOBSF_URL``. The API key
comes from ``--api-key`` or ``MOBSF_API_KEY``.

Exit codes: 0 = done, 1 = MobSF failed, 2 = APK missing or unreadable,
3 = the inventory changed and ``--fail-on-change`` was given, 64 = bad usage.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
import zipfile
from dataclasses import dataclass
from pathlib import Path

DEFAULT_URL = "http://mobsf:8000"
INVENTORY_SCHEMA = 1
CHUNK = 1024 * 1024


@dataclass(frozen=True)
class NativeLib:
    """One shared object inside the APK, identified by content."""

    path: str  # lib/arm64-v8a/libapp.so
    abi: str  # arm64-v8a
    size: int
    sha256: str


def read_native_libs(apk: Path) -> list[NativeLib]:
    """Every ``lib/<abi>/*.so`` entry in the APK, sorted by path.

    Hashes the decompressed bytes, so a rebuild that changes a library is
    visible even when the file name and size stay the same.
    """
    libs: list[NativeLib] = []
    with zipfile.ZipFile(apk) as archive:
        for info in archive.infolist():
            if info.is_dir() or not info.filename.endswith(".so"):
                continue
            parts = info.filename.split("/")
            if len(parts) < 3 or parts[0] != "lib":
                continue
            digest = hashlib.sha256()
            with archive.open(info) as handle:
                while chunk := handle.read(CHUNK):
                    digest.update(chunk)
            libs.append(
                NativeLib(
                    path=info.filename,
                    abi=parts[1],
                    size=info.file_size,
                    sha256=digest.hexdigest(),
                )
            )
    return sorted(libs, key=lambda lib: lib.path)


def inventory_payload(libs: list[NativeLib]) -> dict:
    return {
        "schema": INVENTORY_SCHEMA,
        "libraries": [
            {"path": lib.path, "abi": lib.abi, "size": lib.size, "sha256": lib.sha256}
            for lib in libs
        ],
    }


def load_inventory(path: Path) -> list[NativeLib]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if payload.get("schema") != INVENTORY_SCHEMA:
        raise SystemExit(
            f"{path} has inventory schema {payload.get('schema')!r}, "
            f"expected {INVENTORY_SCHEMA}"
        )
    return [
        NativeLib(
            path=entry["path"],
            abi=entry["abi"],
            size=int(entry["size"]),
            sha256=entry["sha256"],
        )
        for entry in payload["libraries"]
    ]


def write_inventory(libs: list[NativeLib], path: Path) -> None:
    path.write_text(
        json.dumps(inventory_payload(libs), indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


@dataclass(frozen=True)
class InventoryDiff:
    added: list[NativeLib]
    removed: list[NativeLib]
    changed: list[tuple[NativeLib, NativeLib]]  # (baseline, current)

    @property
    def is_empty(self) -> bool:
        return not (self.added or self.removed or self.changed)

    @property
    def has_new_content(self) -> bool:
        """True when something shipped that the baseline did not have.

        A removal is not new code, and a library that merely moved ABI is the
        same bytes in a different directory, so neither counts here.
        """
        return bool(self.added or self.changed)


def diff_inventories(
    baseline: list[NativeLib], current: list[NativeLib]
) -> InventoryDiff:
    before = {lib.path: lib for lib in baseline}
    after = {lib.path: lib for lib in current}
    added = [after[path] for path in sorted(after.keys() - before.keys())]
    removed = [before[path] for path in sorted(before.keys() - after.keys())]
    changed = [
        (before[path], after[path])
        for path in sorted(before.keys() & after.keys())
        if before[path].sha256 != after[path].sha256
    ]
    return InventoryDiff(added=added, removed=removed, changed=changed)


def _short(digest: str) -> str:
    return digest[:12]


def render_diff(diff: InventoryDiff, baseline_tag: str, tag: str) -> str:
    """Markdown for the job summary and the ``native-libs-diff.md`` artifact."""
    lines = [f"## Native libraries: {baseline_tag} -> {tag}", ""]
    if diff.is_empty:
        lines.append("Identical inventory: no library was added, removed or changed.")
        return "\n".join(lines) + "\n"

    def size(count: int) -> str:
        return f"{count} librar{'y' if count == 1 else 'ies'}"

    lines.append(
        f"Added {len(diff.added)}, removed {len(diff.removed)}, "
        f"changed {len(diff.changed)}."
    )
    if diff.added:
        lines += ["", f"### Added ({size(len(diff.added))})", ""]
        lines += [
            f"- `{lib.path}` ({_short(lib.sha256)}, {lib.size:,} bytes)"
            for lib in diff.added
        ]
    if diff.changed:
        lines += ["", f"### Changed ({size(len(diff.changed))})", ""]
        for old, new in diff.changed:
            lines.append(
                f"- `{new.path}` {_short(old.sha256)} -> {_short(new.sha256)} "
                f"({old.size:,} -> {new.size:,} bytes)"
            )
    if diff.removed:
        lines += ["", f"### Removed ({size(len(diff.removed))})", ""]
        lines += [f"- `{lib.path}` ({_short(lib.sha256)})" for lib in diff.removed]
    return "\n".join(lines) + "\n"


def _curl(args: list[str]) -> bytes:
    """Run curl and return stdout, keeping large bodies off the Python heap."""
    completed = subprocess.run(
        ["curl", "--silent", "--show-error", "--fail-with-body", *args],
        capture_output=True,
        check=False,
    )
    if completed.returncode != 0:
        detail = completed.stderr.decode("utf-8", "replace").strip()
        raise RuntimeError(f"curl exited {completed.returncode}: {detail[:400]}")
    return completed.stdout


class MobSF:
    """The subset of the MobSF REST API this script needs.

    Scanning is two steps and the report call is POST: ``/api/v1/upload``
    returns the md5 the scan is keyed by, ``/api/v1/scan`` blocks until the
    analysis is done, and ``/api/v1/report_json`` / ``/api/v1/download_pdf``
    both take that hash as a form field.
    """

    def __init__(self, url: str, api_key: str) -> None:
        self.url = url.rstrip("/")
        self.api_key = api_key

    def _auth(self) -> list[str]:
        return ["--header", f"Authorization: {self.api_key}"]

    def upload(self, apk: Path, timeout: int = 600) -> str:
        body = _curl(
            [
                *self._auth(),
                "--max-time",
                str(timeout),
                "--form",
                f"file=@{apk}",
                f"{self.url}/api/v1/upload",
            ]
        )
        payload = json.loads(body)
        if payload.get("status") != "success" or not payload.get("hash"):
            raise RuntimeError(f"upload did not return a hash: {body[:300]!r}")
        return payload["hash"]

    def scan(self, checksum: str, timeout: int = 1800) -> dict:
        body = _curl(
            [
                *self._auth(),
                "--max-time",
                str(timeout),
                "--data-urlencode",
                f"hash={checksum}",
                "--data-urlencode",
                "scan_type=apk",
                f"{self.url}/api/v1/scan",
            ]
        )
        payload = json.loads(body)
        if payload.get("error"):
            raise RuntimeError(f"scan failed: {payload['error']}")
        return payload

    def report_json(self, checksum: str, timeout: int = 600) -> bytes:
        return _curl(
            [
                *self._auth(),
                "--max-time",
                str(timeout),
                "--data-urlencode",
                f"hash={checksum}",
                f"{self.url}/api/v1/report_json",
            ]
        )

    def pdf(self, checksum: str, timeout: int = 600) -> bytes:
        return _curl(
            [
                *self._auth(),
                "--max-time",
                str(timeout),
                "--data-urlencode",
                f"hash={checksum}",
                f"{self.url}/api/v1/download_pdf",
            ]
        )


def _summary(line: str) -> None:
    """Print to stdout and to the Actions job summary when running in CI."""
    print(line)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write(line + "\n")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Scan a release APK with MobSF and record its native libraries."
    )
    parser.add_argument("--apk", required=True, type=Path, help="release APK to scan")
    parser.add_argument("--out-dir", required=True, type=Path, help="writes reports here")
    parser.add_argument(
        "--url", default=os.environ.get("MOBSF_URL", DEFAULT_URL), help="MobSF base URL"
    )
    parser.add_argument(
        "--api-key",
        default=os.environ.get("MOBSF_API_KEY", ""),
        help="MobSF API key (or set MOBSF_API_KEY)",
    )
    parser.add_argument("--tag", default="", help="tag being released, for headers")
    parser.add_argument(
        "--baseline", type=Path, help="previous release's native-libs.json"
    )
    parser.add_argument(
        "--baseline-tag", default="previous", help="tag the baseline came from"
    )
    parser.add_argument(
        "--skip-scan",
        action="store_true",
        help="record the inventory only, without calling MobSF",
    )
    parser.add_argument(
        "--fail-on-change",
        action="store_true",
        help="exit 3 when a library was added or changed",
    )
    args = parser.parse_args(argv)

    if not args.apk.is_file():
        print(f"error: {args.apk} does not exist", file=sys.stderr)
        return 2
    args.out_dir.mkdir(parents=True, exist_ok=True)

    try:
        libs = read_native_libs(args.apk)
    except (zipfile.BadZipFile, OSError) as error:
        print(f"error: {args.apk} is not a readable APK: {error}", file=sys.stderr)
        return 2
    inventory_path = args.out_dir / "native-libs.json"
    write_inventory(libs, inventory_path)

    abis = sorted({lib.abi for lib in libs})
    print(
        f"{args.apk.name}: {len(libs)} native libraries "
        f"across {', '.join(abis) if abis else 'no ABI'}"
    )

    changed = False
    if args.baseline:
        if not args.baseline.is_file():
            print(f"no baseline at {args.baseline}; nothing to diff")
        else:
            diff = diff_inventories(load_inventory(args.baseline), libs)
            report = render_diff(diff, args.baseline_tag, args.tag or "this release")
            (args.out_dir / "native-libs-diff.md").write_text(report, encoding="utf-8")
            _summary(report)
            changed = diff.has_new_content

    if args.skip_scan:
        return 3 if (changed and args.fail_on_change) else 0

    if not args.api_key:
        print(
            "error: no API key; pass --api-key or set MOBSF_API_KEY "
            "(the key is the MOBSF_API_KEY stack variable)",
            file=sys.stderr,
        )
        return 64

    client = MobSF(args.url, args.api_key)
    try:
        checksum = client.upload(args.apk)
        print(f"uploaded as {checksum}")
        summary = client.scan(checksum)
        (args.out_dir / "mobsf-report.json").write_bytes(client.report_json(checksum))
        (args.out_dir / "mobsf-report.pdf").write_bytes(client.pdf(checksum))
    except (RuntimeError, json.JSONDecodeError) as error:
        print(f"error: MobSF scan failed: {error}", file=sys.stderr)
        print(f"is the stack up? curl -s -o /dev/null -w '%{{http_code}}' {args.url}/")
        return 1

    appsec = summary.get("appsec") or {}
    if isinstance(appsec, dict):
        score = appsec.get("security_score")
        high = appsec.get("high")
        warning = appsec.get("warning")
        if score is not None:
            _summary(
                f"MobSF security score {score}; "
                f"high {len(high) if isinstance(high, list) else high}, "
                f"warning {len(warning) if isinstance(warning, list) else warning}."
            )

    return 3 if (changed and args.fail_on_change) else 0


if __name__ == "__main__":
    sys.exit(main())
