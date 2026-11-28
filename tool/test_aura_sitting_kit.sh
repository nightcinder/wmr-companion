#!/usr/bin/env bash
# Test suite for tool/aura_sitting_kit.sh using a fake `adb` on PATH.
# Covers: correct build, wrong versionCode, app not installed, no device,
# two devices, DroidDeck missing, start+collect, and missing evidence file in collect.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KIT="$SCRIPT_DIR/aura_sitting_kit.sh"
REAL_SHEET="$REPO_ROOT/docs/runs/sheets/pose-androidxr.md"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fake_bin="$tmp/bin"
mkdir -p "$fake_bin"
export FAKE_ADB_STATE_DIR="$tmp/state"
mkdir -p "$FAKE_ADB_STATE_DIR"

cat >"$fake_bin/adb" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

state_dir="${FAKE_ADB_STATE_DIR:?}"
scenario="$(cat "$state_dir/scenario")"

# Strip optional -s <serial>
if [[ "${1:-}" == "-s" ]]; then
  shift 2
fi

cmd="${1:-}"
shift || true

case "$cmd" in
  devices)
    case "$scenario" in
      no_device)
        echo "List of devices attached"
        echo ""
        ;;
      two_devices)
        echo "List of devices attached"
        echo -e "aura-001\tdevice"
        echo -e "aura-002\tdevice"
        ;;
      *)
        echo "List of devices attached"
        echo -e "aura-001\tdevice"
        ;;
    esac
    ;;
  logcat)
    echo "01-01 12:00:00.000  1000  1000 I WmrTracking: fake logcat line"
    # Stay alive until killed by collect
    while true; do
      sleep 0.1
    done
    ;;
  shell)
    sub="$*"
    case "$sub" in
      "getprop ro.build.fingerprint")
        echo "google/aura/aura:14/AP2A.240905.003/123456:user/release-keys"
        ;;
      "dumpsys package com.onyxlens.wmr_companion")
        case "$scenario" in
          wrong_version_code)
            echo "Package [com.onyxlens.wmr_companion] (1234):"
            echo "  versionCode=9999 minSdk=29 targetSdk=35"
            echo "  versionName=0.3.27"
            ;;
          app_not_installed)
            echo "Unable to find package: com.onyxlens.wmr_companion"
            ;;
          *)
            echo "Package [com.onyxlens.wmr_companion] (1234):"
            echo "  versionCode=2035 minSdk=29 targetSdk=35"
            echo "  versionName=0.3.27"
            ;;
        esac
        ;;
      "pm list packages")
        if [[ "$scenario" == "droiddeck_missing" ]]; then
          echo "package:com.onyxlens.wmr_companion"
        else
          echo "package:com.onyxlens.wmr_companion"
          echo "package:org.droiddeck.vr"
        fi
        ;;
      "pm path org.droiddeck.vr")
        if [[ "$scenario" == "droiddeck_missing" ]]; then
          echo ""
        else
          echo "package:/data/app/~~abc==/org.droiddeck.vr-xyz==/base.apk"
        fi
        ;;
      "dumpsys package org.droiddeck.vr")
        if [[ "$scenario" == "droiddeck_missing" ]]; then
          echo "Unable to find package: org.droiddeck.vr"
        else
          echo "Package [org.droiddeck.vr] (5678):"
          echo "  versionCode=42 minSdk=29 targetSdk=35"
          echo "  versionName=1.2.3-eb03e88"
          echo "  lastUpdateTime=2026-11-28 10:15:00"
        fi
        ;;
      *)
        echo "Unhandled fake adb shell command: $sub" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    echo "Unhandled fake adb command: $cmd" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$fake_bin/adb"
unset BASH_ENV
export PATH="$fake_bin:$PATH"

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  if ! printf '%s\n' "$haystack" | grep -Fq "$needle"; then
    echo "FAIL ($label): expected output to contain '$needle'" >&2
    echo "--- output ---" >&2
    printf '%s\n' "$haystack" >&2
    exit 1
  fi
}

run_expect_fail() {
  local label="$1"
  shift
  local out status=0
  out="$("$@" 2>&1)" || status=$?
  if [[ "$status" -eq 0 ]]; then
    echo "FAIL ($label): expected non-zero exit, got 0" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
  printf '%s' "$out"
}

echo "=== 1. preflight: correct build ==="
echo "correct_build" >"$FAKE_ADB_STATE_DIR/scenario"
out="$("$KIT" preflight --sheet "$REAL_SHEET" 2>&1)"
assert_contains "$out" "aura-001" "correct_build device"
assert_contains "$out" "google/aura/aura:14/AP2A.240905.003/123456:user/release-keys" "correct_build fingerprint"
assert_contains "$out" "Companion app OK: com.onyxlens.wmr_companion versionName=0.3.27 versionCode=2035" "correct_build app"
assert_contains "$out" "package:/data/app/~~abc==/org.droiddeck.vr-xyz==/base.apk" "correct_build droiddeck path"
assert_contains "$out" "versionName=1.2.3-eb03e88" "correct_build droiddeck versionName"
assert_contains "$out" "lastUpdateTime=2026-11-28 10:15:00" "correct_build droiddeck lastUpdateTime"

echo "=== 2. preflight: sheet-driven pin (not hardcoded) ==="
alt_sheet="$tmp/alt-sheet.md"
sed 's/`versionCode` 2035/`versionCode` 2099/' "$REAL_SHEET" >"$alt_sheet"
out="$(run_expect_fail "sheet_pin" "$KIT" preflight --sheet "$alt_sheet")"
assert_contains "$out" "expected 2099" "sheet_pin uses sheet value"

echo "=== 3. preflight: wrong versionCode ==="
echo "wrong_version_code" >"$FAKE_ADB_STATE_DIR/scenario"
out="$(run_expect_fail "wrong_version_code" "$KIT" preflight --sheet "$REAL_SHEET")"
assert_contains "$out" "versionCode expected 2035" "wrong_version_code message"
assert_contains "$out" "got 9999" "wrong_version_code actual"

echo "=== 4. preflight: app not installed ==="
echo "app_not_installed" >"$FAKE_ADB_STATE_DIR/scenario"
out="$(run_expect_fail "app_not_installed" "$KIT" preflight --sheet "$REAL_SHEET")"
assert_contains "$out" "com.onyxlens.wmr_companion is not installed" "app_not_installed message"

echo "=== 5. preflight: no device ==="
echo "no_device" >"$FAKE_ADB_STATE_DIR/scenario"
out="$(run_expect_fail "no_device" "$KIT" preflight --sheet "$REAL_SHEET")"
assert_contains "$out" "No adb device attached" "no_device message"

echo "=== 6. preflight: two devices ==="
echo "two_devices" >"$FAKE_ADB_STATE_DIR/scenario"
out="$(run_expect_fail "two_devices" "$KIT" preflight --sheet "$REAL_SHEET")"
assert_contains "$out" "More than one adb device attached" "two_devices message"

echo "=== 7. preflight: DroidDeck missing ==="
echo "droiddeck_missing" >"$FAKE_ADB_STATE_DIR/scenario"
out="$(run_expect_fail "droiddeck_missing" "$KIT" preflight --sheet "$REAL_SHEET")"
assert_contains "$out" "DroidDeck package missing" "droiddeck_missing message"

echo "=== 8. start + collect: complete evidence ==="
echo "correct_build" >"$FAKE_ADB_STATE_DIR/scenario"
ev_full="$tmp/ev_full"
mkdir -p "$ev_full"
out="$("$KIT" start --dir "$ev_full" --date 20261129 2>&1)"
assert_contains "$out" "Started logcat" "start logcat"
sleep 0.2

touch "$ev_full/pose-androidxr-gate2-20261129-120000.log"
echo '{"ok":true}' >"$ev_full/TestBundle-20261129.json"
echo "boot banner 0.3.28" >"$ev_full/pose-androidxr-serial-20261129-120000.txt"
echo "jpg" >"$ev_full/pose-androidxr-gate1-0.5m-front.jpg"

out="$("$KIT" collect --dir "$ev_full" --date 20261129 2>&1)"
assert_contains "$out" "Stopped logcat" "collect stopped logcat"
assert_contains "$out" "pose-androidxr-20261129.zip" "collect zip name"
assert_contains "$out" "All expected evidence categories present." "collect all present"

[[ -f "$ev_full/pose-androidxr-20261129.zip" ]] || { echo "FAIL: zip not created" >&2; exit 1; }
[[ -f "$ev_full/SHA256SUMS.txt" ]] || { echo "FAIL: manifest not created" >&2; exit 1; }
[[ ! -f "$ev_full/.aura-sitting-logcat.pid" ]] || { echo "FAIL: pid file not removed" >&2; exit 1; }
(cd "$ev_full" && sha256sum -c SHA256SUMS.txt >/dev/null)

echo "=== 9. collect: missing evidence file ==="
ev_missing="$tmp/ev_missing"
mkdir -p "$ev_missing"
echo "sitting log" >"$ev_missing/aura-sitting-20261129.log"
out="$("$KIT" collect --dir "$ev_missing" --date 20261129 2>&1)"
assert_contains "$out" "MISSING: Bridge serial / boot banner" "collect lists missing serial"
assert_contains "$out" "MISSING: Setup / permission-dialog / Gate 1 photos or videos" "collect lists missing photos"
[[ -f "$ev_missing/pose-androidxr-20261129.zip" ]] || { echo "FAIL: zip not created on missing evidence" >&2; exit 1; }

echo "PASS: all aura_sitting_kit tests passed"
