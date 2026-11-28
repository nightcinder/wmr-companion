#!/usr/bin/env bash
# Host-side adb preflight, logcat start, and evidence collection helper for the
# Aura combined sitting (docs/runs/sheets/pose-androidxr.md).
#
# Adb-only: performs no installs, no tap/keyevent injection, and no device
# writes beyond what `adb logcat` needs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEFAULT_SHEET="$REPO_ROOT/docs/runs/sheets/pose-androidxr.md"
COMPANION_PACKAGE="com.onyxlens.wmr_companion"

usage() {
  cat <<'EOF'
Usage: tool/aura_sitting_kit.sh <command> [options]

Commands:
  preflight   Check single connected adb device, build fingerprint, pinned
              com.onyxlens.wmr_companion versionName/versionCode from §1 of the
              run sheet, and DroidDeck pm path / dumpsys package lines from §11.2.
  start       Start `adb logcat -v threadtime` in the background into
              aura-sitting-<YYYYMMDD>.log.
  collect     Stop logcat (if running), gather §9/§11.6 evidence files from
              the named directory, write a SHA-256 manifest, zip them as
              pose-androidxr-<YYYYMMDD>.zip, and list any missing expected files.

Common options:
  --sheet <path>              Run sheet markdown path (default: docs/runs/sheets/pose-androidxr.md)
  -h, --help                  Show this help message

Preflight options:
  --droiddeck-package <pkg>   DroidDeck Android package name (auto-detected if omitted)

Start options:
  --dir <dir>                 Directory for logcat output and PID file (default: .)
  --date <YYYYMMDD>           Override date stamp (default: today's YYYYMMDD)

Collect options:
  --dir <dir>                 Directory containing sitting evidence files (default: .)
  --out-dir <dir>             Directory to write zip and manifest (default: same as --dir)
  --date <YYYYMMDD>           Override date stamp (default: today's YYYYMMDD)
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found on PATH: $1"
}

# Resolve exactly one connected adb device in 'device' state.
# Prints the device serial to stdout; exits non-zero on 0 or >1 devices.
resolve_single_device() {
  local raw
  raw="$(adb devices 2>&1)" || die "adb devices failed: $raw"

  local -a ready=()
  local -a other=()
  local line serial state
  while IFS= read -r line; do
    line="${line//$'\r'/}"
    [[ -z "$line" ]] && continue
    [[ "$line" == "List of devices attached"* ]] && continue
    [[ "$line" == \** ]] && continue
    serial="${line%%[[:space:]]*}"
    state="${line#"$serial"}"
    state="${state#"${state%%[![:space:]]*}"}"
    state="${state%%[[:space:]]*}"
    if [[ "$state" == "device" ]]; then
      ready+=("$serial")
    elif [[ -n "$serial" ]]; then
      other+=("$serial ($state)")
    fi
  done <<< "$raw"

  if [[ ${#ready[@]} -eq 0 ]]; then
    if [[ ${#other[@]} -gt 0 ]]; then
      die "No ready adb device attached (found non-ready: ${other[*]})"
    fi
    die "No adb device attached"
  fi

  if [[ ${#ready[@]} -gt 1 ]]; then
    die "More than one adb device attached (expected 1, found ${#ready[@]}): ${ready[*]}"
  fi

  printf '%s\n' "${ready[0]}"
}

# Parse pinned versionCode and versionName for com.onyxlens.wmr_companion from
# §1 Prerequisites table in the run sheet. Prints "<versionCode>\t<versionName>".
parse_sheet_app_pin() {
  local sheet_path="$1"
  [[ -f "$sheet_path" ]] || die "Run sheet not found: $sheet_path"

  python3 - "$sheet_path" "$COMPANION_PACKAGE" <<'PY'
import re
import sys

sheet_path, pkg = sys.argv[1], sys.argv[2]
with open(sheet_path, "r", encoding="utf-8") as f:
    text = f.read()

sec1 = re.search(r"^##\s+1\.\s+Prerequisites\b(.*?)(?=^##\s+|\Z)", text, re.M | re.S)
if not sec1:
    sys.stderr.write(f"ERROR: Could not find '## 1. Prerequisites' in {sheet_path}\n")
    sys.exit(1)

app_row = None
for line in sec1.group(1).splitlines():
    if re.match(r"^\|\s*App\s*\|", line):
        app_row = line
        break

if not app_row:
    sys.stderr.write(f"ERROR: Could not find '| App |' row in §1 of {sheet_path}\n")
    sys.exit(1)

if pkg not in app_row:
    sys.stderr.write(f"ERROR: Package '{pkg}' not found in §1 App row of {sheet_path}\n")
    sys.exit(1)

vc_match = re.search(r"`versionCode`\s+(\d+)", app_row)
vn_match = re.search(r"`versionName`\s+([0-9A-Za-z._-]+)", app_row)
if not vc_match or not vn_match:
    sys.stderr.write(f"ERROR: Could not parse versionCode/versionName from §1 App row: {app_row}\n")
    sys.exit(1)

print(f"{vc_match.group(1)}\t{vn_match.group(1)}")
PY
}

cmd_preflight() {
  local sheet="$DEFAULT_SHEET"
  local droiddeck_pkg="${DROIDDECK_PACKAGE:-}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --sheet)
        [[ $# -ge 2 ]] || die "--sheet requires a path"
        sheet="$2"
        shift 2
        ;;
      --droiddeck-package)
        [[ $# -ge 2 ]] || die "--droiddeck-package requires a package name"
        droiddeck_pkg="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown option for preflight: $1"
        ;;
    esac
  done

  require_cmd adb
  require_cmd python3

  local serial
  serial="$(resolve_single_device)"

  local fingerprint
  fingerprint="$(adb -s "$serial" shell getprop ro.build.fingerprint 2>&1 | tr -d '\r')" || die "Failed to read ro.build.fingerprint"
  echo "Device: $serial"
  echo "Build fingerprint: ${fingerprint:-<empty>}"

  local pinned pinned_vc pinned_vn
  pinned="$(parse_sheet_app_pin "$sheet")"
  pinned_vc="${pinned%%$'\t'*}"
  pinned_vn="${pinned#*$'\t'}"
  echo "Sheet pin ($COMPANION_PACKAGE): versionName=$pinned_vn versionCode=$pinned_vc"

  local dumpsys_out
  dumpsys_out="$(adb -s "$serial" shell dumpsys package "$COMPANION_PACKAGE" 2>&1 | tr -d '\r')" || true

  local actual_vc actual_vn
  actual_vc="$(printf '%s\n' "$dumpsys_out" | sed -n 's/.*versionCode=\([0-9][0-9]*\).*/\1/p' | head -n 1)"
  actual_vn="$(printf '%s\n' "$dumpsys_out" | sed -n 's/.*versionName=\([^[:space:]]*\).*/\1/p' | head -n 1)"

  if [[ -z "$actual_vc" || -z "$actual_vn" ]]; then
    die "$COMPANION_PACKAGE is not installed on device $serial"
  fi

  local failed=0
  if [[ "$actual_vc" != "$pinned_vc" ]]; then
    echo "MISMATCH: $COMPANION_PACKAGE versionCode expected $pinned_vc (from $sheet), got $actual_vc" >&2
    failed=1
  fi
  if [[ "$actual_vn" != "$pinned_vn" ]]; then
    echo "MISMATCH: $COMPANION_PACKAGE versionName expected $pinned_vn (from $sheet), got $actual_vn" >&2
    failed=1
  fi
  if [[ "$failed" -ne 0 ]]; then
    exit 1
  fi
  echo "Companion app OK: $COMPANION_PACKAGE versionName=$actual_vn versionCode=$actual_vc"

  # DroidDeck check (§11.2)
  if [[ -z "$droiddeck_pkg" ]]; then
    local pkg_list
    pkg_list="$(adb -s "$serial" shell pm list packages 2>&1 | tr -d '\r')" || true
    droiddeck_pkg="$(printf '%s\n' "$pkg_list" | grep -i 'droiddeck' | head -n 1 | sed 's/^package://' || true)"
    if [[ -z "$droiddeck_pkg" ]]; then
      die "DroidDeck package missing: no installed package matching 'droiddeck' found on $serial"
    fi
  fi

  local dd_path
  dd_path="$(adb -s "$serial" shell pm path "$droiddeck_pkg" 2>&1 | tr -d '\r')" || true
  if [[ -z "$dd_path" ]] || ! printf '%s\n' "$dd_path" | grep -q '^package:'; then
    die "DroidDeck package missing: $droiddeck_pkg is not installed on $serial"
  fi

  echo "DroidDeck package: $droiddeck_pkg"
  echo "DroidDeck pm path:"
  printf '%s\n' "$dd_path"

  local dd_dumpsys dd_lines
  dd_dumpsys="$(adb -s "$serial" shell dumpsys package "$droiddeck_pkg" 2>&1 | tr -d '\r')" || true
  dd_lines="$(printf '%s\n' "$dd_dumpsys" | grep -E 'versionName|lastUpdateTime|versionCode' || true)"
  if [[ -z "$dd_lines" ]]; then
    die "DroidDeck dumpsys package returned no version lines for $droiddeck_pkg"
  fi
  echo "DroidDeck dumpsys package:"
  printf '%s\n' "$dd_lines"
}

cmd_start() {
  local dir="."
  local date_stamp
  date_stamp="$(date +%Y%m%d)"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dir)
        [[ $# -ge 2 ]] || die "--dir requires a directory"
        dir="$2"
        shift 2
        ;;
      --date)
        [[ $# -ge 2 ]] || die "--date requires YYYYMMDD"
        date_stamp="$2"
        shift 2
        ;;
      --sheet)
        [[ $# -ge 2 ]] || die "--sheet requires a path"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown option for start: $1"
        ;;
    esac
  done

  require_cmd adb
  mkdir -p "$dir"
  dir="$(cd "$dir" && pwd)"

  local pid_file="$dir/.aura-sitting-logcat.pid"
  if [[ -f "$pid_file" ]]; then
    local existing_pid
    existing_pid="$(cat "$pid_file" 2>/dev/null || true)"
    if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
      die "logcat is already running (pid $existing_pid)"
    fi
    rm -f "$pid_file"
  fi

  local serial
  serial="$(resolve_single_device)"

  local log_file="$dir/aura-sitting-${date_stamp}.log"
  adb -s "$serial" logcat -v threadtime >"$log_file" 2>&1 &
  local pid=$!
  echo "$pid" >"$pid_file"

  if ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$pid_file"
    die "adb logcat exited immediately"
  fi

  echo "Started logcat (pid $pid, device $serial) -> $log_file"
}

cmd_collect() {
  local dir="."
  local out_dir=""
  local date_stamp
  date_stamp="$(date +%Y%m%d)"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dir)
        [[ $# -ge 2 ]] || die "--dir requires a directory"
        dir="$2"
        shift 2
        ;;
      --out-dir)
        [[ $# -ge 2 ]] || die "--out-dir requires a directory"
        out_dir="$2"
        shift 2
        ;;
      --date)
        [[ $# -ge 2 ]] || die "--date requires YYYYMMDD"
        date_stamp="$2"
        shift 2
        ;;
      --sheet)
        [[ $# -ge 2 ]] || die "--sheet requires a path"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        if [[ "$dir" == "." && ! "$1" == -* ]]; then
          dir="$1"
          shift
        else
          die "Unknown option for collect: $1"
        fi
        ;;
    esac
  done

  require_cmd python3
  [[ -d "$dir" ]] || die "Evidence directory does not exist: $dir"
  dir="$(cd "$dir" && pwd)"
  if [[ -z "$out_dir" ]]; then
    out_dir="$dir"
  else
    mkdir -p "$out_dir"
    out_dir="$(cd "$out_dir" && pwd)"
  fi

  # Stop logcat if running
  local pid_file="$dir/.aura-sitting-logcat.pid"
  if [[ -f "$pid_file" ]]; then
    local pid
    pid="$(cat "$pid_file" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      local i=0
      while kill -0 "$pid" 2>/dev/null && [[ $i -lt 20 ]]; do
        sleep 0.1
        i=$((i + 1))
      done
      if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null || true
      fi
      wait "$pid" 2>/dev/null || true
      echo "Stopped logcat (pid $pid)"
    else
      echo "Logcat pid file present, process not running"
    fi
    rm -f "$pid_file"
  else
    echo "No active logcat pid file in $dir; continuing collection"
  fi

  local zip_name="pose-androidxr-${date_stamp}.zip"
  local zip_path="$out_dir/$zip_name"
  local manifest_path="$out_dir/SHA256SUMS.txt"

  python3 - "$dir" "$zip_path" "$manifest_path" <<'PY'
import hashlib
import os
import re
import sys
import zipfile

src_dir, zip_path, manifest_path = sys.argv[1], sys.argv[2], sys.argv[3]
zip_basename = os.path.basename(zip_path)
manifest_basename = os.path.basename(manifest_path)

# Gather all regular files in src_dir (excluding hidden files, previous
# output zip/manifest, and unrelated files).
all_files = []
for root, dirs, files in os.walk(src_dir):
    dirs[:] = [d for d in sorted(dirs) if not d.startswith(".")]
    for name in sorted(files):
        if name.startswith("."):
            continue
        full = os.path.join(root, name)
        rel = os.path.relpath(full, src_dir)
        if os.path.abspath(full) in (os.path.abspath(zip_path), os.path.abspath(manifest_path)):
            continue
        if re.match(r"^pose-androidxr-\d{8}\.zip$", name):
            continue
        if name == "SHA256SUMS.txt":
            continue
        all_files.append((rel, full))

# Expected evidence categories from §9 and §11.6 of pose-androidxr.md
expected = [
    ("Sitting logcat (aura-sitting-<YYYYMMDD>.log)",
     lambda rel: bool(re.match(r"^aura-sitting-.*\.log$", os.path.basename(rel)))),
    ("Per-gate logcat (pose-androidxr-<gate>-<timestamp>.log)",
     lambda rel: bool(re.match(r"^pose-androidxr-(?!serial-).*\.log$", os.path.basename(rel)))),
    ("Exported TestBundle zip or JSON/CSV",
     lambda rel: os.path.basename(rel).lower().endswith((".json", ".csv"))
                 or ("testbundle" in os.path.basename(rel).lower() and os.path.basename(rel).lower().endswith(".zip"))),
    ("Bridge serial / boot banner (pose-androidxr-serial-<timestamp>.txt)",
     lambda rel: bool(re.match(r"^pose-androidxr-serial-.*\.txt$", os.path.basename(rel)))
                 or ("boot" in os.path.basename(rel).lower() and os.path.basename(rel).lower().endswith(".txt"))
                 or ("serial" in os.path.basename(rel).lower() and os.path.basename(rel).lower().endswith(".txt"))),
    ("Setup / permission-dialog / Gate 1 photos or videos",
     lambda rel: os.path.basename(rel).lower().endswith((".jpg", ".jpeg", ".png", ".mp4"))),
]

missing = []
for label, pred in expected:
    if not any(pred(rel) for rel, _ in all_files):
        missing.append(label)

manifest_lines = []
for rel, full in all_files:
    h = hashlib.sha256()
    with open(full, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    manifest_lines.append(f"{h.hexdigest()}  {rel}")

with open(manifest_path, "w", encoding="utf-8") as mf:
    mf.write("\n".join(manifest_lines) + ("\n" if manifest_lines else ""))

with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
    for rel, full in all_files:
        zf.write(full, arcname=rel)
    zf.write(manifest_path, arcname=manifest_basename)

zh = hashlib.sha256()
with open(zip_path, "rb") as f:
    for chunk in iter(lambda: f.read(65536), b""):
        zh.update(chunk)

print(f"Collected {len(all_files)} file(s) -> {zip_path}")
print(f"Archive SHA-256: {zh.hexdigest()}")
print(f"Manifest written: {manifest_path}")
if missing:
    print("Missing expected evidence files:")
    for item in missing:
        print(f"  MISSING: {item}")
else:
    print("All expected evidence categories present.")
PY
}

main() {
  if [[ $# -eq 0 ]]; then
    usage
    exit 1
  fi

  local subcmd="$1"
  shift
  case "$subcmd" in
    preflight)
      cmd_preflight "$@"
      ;;
    start)
      cmd_start "$@"
      ;;
    collect)
      cmd_collect "$@"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown subcommand: $subcmd"
      ;;
  esac
}

main "$@"
