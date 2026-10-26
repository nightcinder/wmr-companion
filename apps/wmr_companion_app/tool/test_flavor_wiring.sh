#!/usr/bin/env bash
# Prove the ONY-271 Unity include path, flavor isolation and the mutual
# exclusion guard. Creates throwaway `unityLibrary` stubs in the gitignored
# locations, builds flavors, then removes them. Needs an Android SDK with aapt;
# no Unity or vendor SDK is required.
#
#   tool/test_flavor_wiring.sh
set -euo pipefail

app_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
unity_root="$app_dir/android/unity"
build_root="$app_dir/build"

viture_permission="com.onyxlens.wmr.UNITY_STUB_VITURE"
xreal_permission="com.onyxlens.wmr.UNITY_STUB_XREAL"

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

cleanup() {
  rm -rf "$unity_root/viture" "$unity_root/xreal"
}
trap cleanup EXIT
cleanup

create_stub() {
  local vendor="$1" permission="$2" namespace="com.onyxlens.wmr.unitystub.$1"
  local dir="$unity_root/$vendor/unityLibrary"
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
set +e
output="$(cd "$app_dir" && tool/build_flavor.sh xreal 2>&1)"
status=$?
set -e
if [ "$status" -eq 0 ]; then
  echo "FAIL: build accepted both Unity libraries" >&2
  exit 1
fi
if ! grep -q "Cannot link both Unity libraries" <<<"$output"; then
  echo "FAIL: mutual-exclusion failure did not name the conflict:" >&2
  echo "$output" >&2
  exit 1
fi
echo "PASS: both libraries fail the build with a clear message"

echo "All flavor wiring checks passed."
