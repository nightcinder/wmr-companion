#!/usr/bin/env bash
# Prove the ONY-271/ONY-355 Unity include path, flavor isolation and the
# mutual exclusion guard. Creates throwaway `unityLibrary` stubs in the
# gitignored locations, builds flavors, then removes them. Needs an Android SDK
# with aapt; no Unity or vendor SDK is required.
#
#   tool/test_flavor_wiring.sh
set -euo pipefail

app_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
unity_root="$app_dir/android/unity"
build_root="$app_dir/build"

viture_permission="com.onyxlens.wmr.UNITY_STUB_VITURE"
xreal_permission="com.onyxlens.wmr.UNITY_STUB_XREAL"
unified_permission="com.onyxlens.wmr.UNITY_STUB_UNIFIED"

aapt=""
for candidate in "${ANDROID_HOME:-}"/build-tools/*/aapt "${ANDROID_SDK_ROOT:-}"/build-tools/*/aapt; do
  if [ -x "$candidate" ]; then
    aapt="$candidate"
  fi
done
if [ -z "$aapt" ]; then
  echo "FAIL: aapt not found under ANDROID_HOME/build-tools" >&2
  exit 1
fi

# A developer may have a real (proprietary, gitignored) VITURE/XREAL/unified
# export at these paths. Move any such directory aside before writing stubs and
# put it back on exit; only remove directories this script created itself.
backup_root=""
restored_vendors=()
created_vendors=()

cleanup() {
  local vendor
  for vendor in "${created_vendors[@]+"${created_vendors[@]}"}"; do
    rm -rf "$unity_root/$vendor"
  done
  if [ -n "$backup_root" ]; then
    for vendor in "${restored_vendors[@]+"${restored_vendors[@]}"}"; do
      mv "$backup_root/$vendor" "$unity_root/$vendor"
    done
    rmdir "$backup_root"
  fi
}
trap cleanup EXIT

for vendor in viture xreal unified; do
  if [ -e "$unity_root/$vendor" ] || [ -L "$unity_root/$vendor" ]; then
    if [ -z "$backup_root" ]; then
      backup_root="$(mktemp -d "$unity_root/.flavor-wiring-backup.XXXXXX")"
    fi
    echo "==> preserving existing $unity_root/$vendor (restored on exit)"
    mv "$unity_root/$vendor" "$backup_root/$vendor"
    restored_vendors+=("$vendor")
  fi
done

create_stub() {
  local vendor="$1" permission="$2" namespace="com.onyxlens.wmr.unitystub.$1"
  local dir="$unity_root/$vendor/unityLibrary"
  created_vendors+=("$vendor")
  mkdir -p "$dir/src/main"
  cat >"$dir/build.gradle" <<EOF
// Throwaway stand-in for a Unity UaaL export, used by tool/test_flavor_wiring.sh.
buildscript {
    repositories {
        google()
        mavenCentral()
    }
    dependencies {
        classpath 'com.android.tools.build:gradle:9.1.0'
    }
}
apply plugin: 'com.android.library'

android {
    namespace = '$namespace'
    compileSdk = 36

    defaultConfig {
        minSdk = 24
    }
}
EOF
  cat >"$dir/src/main/AndroidManifest.xml" <<EOF
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-permission android:name="$permission" />
</manifest>
EOF
}

apk_path() {
  echo "$build_root/app/outputs/flutter-apk/app-$1-debug.apk"
}

has_permission() {
  local apk="$1" permission="$2"
  "$aapt" dump permissions "$apk" | grep -q "$permission"
}

build() {
  local flavor="$1"
  (cd "$app_dir" && tool/build_flavor.sh "$flavor")
}

remove_stub() {
  rm -rf "$unity_root/$1"
}

expect_build_failure() {
  local flavor="$1" expected="$2"
  local output status
  set +e
  output="$(cd "$app_dir" && tool/build_flavor.sh "$flavor" 2>&1)"
  status=$?
  set -e
  if [ "$status" -eq 0 ]; then
    echo "FAIL: $flavor build accepted incompatible Unity exports" >&2
    exit 1
  fi
  if ! grep -q "$expected" <<<"$output"; then
    echo "FAIL: $flavor failure did not name the conflict:" >&2
    echo "$output" >&2
    exit 1
  fi
}

echo "==> base with a VITURE unityLibrary present must not link Unity"
create_stub viture "$viture_permission"
build base
if has_permission "$(apk_path base)" "$viture_permission"; then
  echo "FAIL: base APK linked the VITURE unityLibrary" >&2
  exit 1
fi
echo "PASS: base ignored the VITURE unityLibrary"

echo "==> viture must link the VITURE unityLibrary"
rm -rf "$build_root/app/outputs/flutter-apk/app-viture-debug.apk"
build viture
if ! has_permission "$(apk_path viture)" "$viture_permission"; then
  echo "FAIL: viture APK did not contain the VITURE unityLibrary manifest" >&2
  exit 1
fi
echo "PASS: viture linked the VITURE unityLibrary"

echo "==> xreal + VITURE both present must fail with a clear message"
create_stub xreal "$xreal_permission"
expect_build_failure xreal "Cannot link both Unity libraries"
echo "PASS: both libraries fail the build with a clear message"

echo "==> xreal with no export must still build"
remove_stub xreal
remove_stub viture
build xreal
if has_permission "$(apk_path xreal)" "$viture_permission"; then
  echo "FAIL: xreal APK linked the VITURE unityLibrary" >&2
  exit 1
fi
echo "PASS: xreal built without a Unity export"

echo "==> a unified stub must link only the unified unityLibrary"
create_stub unified "$unified_permission"
rm -rf "$build_root/app/outputs/flutter-apk/app-unified-debug.apk"
build unified
if ! has_permission "$(apk_path unified)" "$unified_permission"; then
  echo "FAIL: unified APK did not contain the unified unityLibrary manifest" >&2
  exit 1
fi
for permission in "$viture_permission" "$xreal_permission"; do
  if has_permission "$(apk_path unified)" "$permission"; then
    echo "FAIL: unified APK linked a per-vendor unityLibrary ($permission)" >&2
    exit 1
  fi
done
echo "PASS: unified linked only the unified unityLibrary"

echo "==> unified + a VITURE export must fail with a clear message"
create_stub viture "$viture_permission"
expect_build_failure unified "cannot be combined with per-vendor Unity exports"
echo "PASS: unified plus a per-vendor export fails the build with a clear message"

echo "==> unified with no export must still build"
remove_stub viture
remove_stub unified
build unified
if has_permission "$(apk_path unified)" "$unified_permission"; then
  echo "FAIL: unified APK without an export linked a Unity stub" >&2
  exit 1
fi
echo "PASS: unified built without a Unity export"

echo "All flavor wiring checks passed."
