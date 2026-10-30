#!/usr/bin/env python3
"""Host-side content check for the pinned unified Unity UaaL export.

The release job downloads one 272 MB `unityLibrary.zip` from a release tag and
builds the signed unified APK from it. The SHA-256 pin proves the bytes are the
approved ones, but a tag or digest edited by mistake can still point at an
older export that builds a different app. This check refuses such a zip before
the 120-minute release build:

  - it is a UaaL export with exactly one libunity.so;
  - both vendor runtimes are present (VITURE and XREAL, native libs and Unity
    subsystem manifests);
  - the IL2CPP metadata carries the ONY-612 stereo path: WmrStereoCameraRig,
    StereoStage, StereoMode, its three stage names and its three stereo modes;
  - StereoMode no longer emits `mono`, so an export built from the mono source
    is rejected even if the rest matches.

`unity-export-1.0` (the ONY-354 export) predates the rig and fails on the stage
names; the pinned `unity-export-1.1` passes. The script reads only the zip
central directory plus `global-metadata.dat`, so it costs seconds.

    python3 tool/check_unity_export.py path/to/unityLibrary.zip

Exit codes: 0 = all checks pass, 1 = a required check failed, 64 = bad usage.
"""

from __future__ import annotations

import json
import sys
import zipfile
from pathlib import Path

# The vendor manifest names/versions are the same contract the built APK is
# checked against, so reuse them rather than keeping a second copy in sync.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from check_unified_apk import REQUIRED_STEREO_LITERALS, UNITY_SUBSYSTEMS  # noqa: E402

EXPORT_ROOT = "unityLibrary"
METADATA_PATH = f"{EXPORT_ROOT}/src/main/assets/bin/Data/Managed/Metadata/global-metadata.dat"

# The export's own layout, before install_unity_export.sh flattens the paths.
REQUIRED_FILES = {
    f"{EXPORT_ROOT}/build.gradle",
    f"{EXPORT_ROOT}/src/main/jniLibs/arm64-v8a/libunity.so",
    f"{EXPORT_ROOT}/src/main/jniLibs/arm64-v8a/libXREALXRPlugin.so",
    f"{EXPORT_ROOT}/libs/VitureUnityXR.aar",
    f"{EXPORT_ROOT}/libs/nr_loader.aar",
    f"{EXPORT_ROOT}/libs/nr_common.aar",
}
# ONY-612's scene scripts and the wire names Kotlin reads back. A pre-ONY-612
# export carries none of them; requiring the modes also rejects one built from
# the mono StereoMode source.
REQUIRED_METADATA = (
    "WmrStereoCameraRig",
    "StereoStage",
    "StereoMode",
    *REQUIRED_STEREO_LITERALS,
    "multiPass",
    "singlePass",
    "singlePassInstanced",
)
# IL2CPP stores C# string literals length-prefixed in global-metadata.dat: the
# 7-bit length 4 followed by `mono`. The ONY-612 source has no such literal.
MONO_LITERAL = b"\x04mono"


def fail(message: str) -> None:
    print(f"FAIL: {message}")


def check_subsystems(archive: zipfile.ZipFile, names: set[str]) -> int:
    failures = 0
    for apk_path, (plugin_name, version) in UNITY_SUBSYSTEMS.items():
        path = f"{EXPORT_ROOT}/src/main/{apk_path}"
        if path not in names:
            fail(f"missing Unity subsystem: {path}")
            failures += 1
            continue
        manifest = json.loads(archive.read(path))
        if manifest.get("name") != plugin_name or manifest.get("version") != version:
            fail(f"unexpected subsystem {path}: {manifest.get('name')} {manifest.get('version')}")
            failures += 1
        else:
            print(f"PASS Unity: {plugin_name} {version}")
    return failures


def check_metadata(archive: zipfile.ZipFile, names: set[str]) -> int:
    if METADATA_PATH not in names:
        fail(f"missing IL2CPP metadata: {METADATA_PATH}")
        return 1
    metadata = archive.read(METADATA_PATH)
    missing = [name for name in REQUIRED_METADATA if name.encode() not in metadata]
    if missing:
        fail(f"IL2CPP metadata is stale, missing the ONY-612 stereo path: {missing}")
        return 1
    print(
        "PASS stereo path: WmrStereoCameraRig, StereoStage/StereoMode, "
        + ", ".join(REQUIRED_METADATA[3:])
    )
    if MONO_LITERAL in metadata:
        fail("IL2CPP metadata still emits the `mono` stereo mode")
        return 1
    print("PASS mono: no `mono` stereo mode literal")
    return 0


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__.strip().splitlines()[0], file=sys.stderr)
        return 64
    zip_path = Path(argv[1])
    if not zip_path.is_file():
        print(f"FAIL: not found: {zip_path}", file=sys.stderr)
        return 64

    print(f"Export: {zip_path.name} ({zip_path.stat().st_size} bytes)")
    failures = 0
    with zipfile.ZipFile(zip_path) as archive:
        names = set(archive.namelist())

        missing = REQUIRED_FILES - names
        if missing:
            fail(f"missing export content: {sorted(missing)}")
            failures += 1
        else:
            print("PASS export: both vendor runtimes, native libs and build.gradle")

        libunity = [name for name in names if name.endswith("/libunity.so")]
        if len(libunity) != 1:
            fail(f"expected exactly one libunity.so, found {len(libunity)}: {sorted(libunity)}")
            failures += 1

        failures += check_subsystems(archive, names)
        failures += check_metadata(archive, names)

    print("RESULT:", "PASS" if failures == 0 else f"FAIL ({failures} check(s))")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
