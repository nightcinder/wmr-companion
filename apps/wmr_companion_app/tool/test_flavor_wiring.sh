#!/usr/bin/env bash
# Prove the ONY-355 unified Unity include path: a unified export is linked into
# the unified APK, and a unified build with no export still succeeds without a
# Unity runtime (ONY-520). Creates a throwaway `unityLibrary` stub in the
# gitignored location, builds the flavor, then removes it. Needs an Android SDK
# with aapt; no Unity or vendor SDK is required.
#
#   tool/test_flavor_wiring.sh
set -euo pipefail

app_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
unity_root="$app_dir/android/unity"
build_root="$app_dir/build"

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

# A developer may have a real (proprietary, gitignored) unified export at this
# path. Move it aside before writing the stub and put it back on exit; only
# remove a directory this script created itself.
backup_root=""
created_stub=0

cleanup() {
  if [ "$created_stub" -eq 1 ]; then
    rm -rf "$unity_root/unified"
  fi
  if [ -n "$backup_root" ]; then
    for saved in "$backup_root"/*; do
      if [ -e "$saved" ]; then
        mv "$saved" "$unity_root/"
      fi
    done
    rmdir "$backup_root"
  fi
}
trap cleanup EXIT

if [ -e "$unity_root/unified" ] || [ -L "$unity_root/unified" ]; then
  backup_root="$(mktemp -d "$unity_root/.flavor-wiring-backup.XXXXXX")"
  echo "==> preserving existing $unity_root/unified (restored on exit)"
  mv "$unity_root/unified" "$backup_root/unified"
fi

create_stub() {
  local dir="$unity_root/unified/unityLibrary"
  created_stub=1
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
    namespace = 'com.onyxlens.wmr.unitystub.unified'
    compileSdk = 36

    defaultConfig {
        minSdk = 24
    }
}
EOF
  cat >"$dir/src/main/AndroidManifest.xml" <<EOF
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-permission android:name="$unified_permission" />
</manifest>
EOF
}

apk_path() {
  echo "$build_root/app/outputs/flutter-apk/app-unified-debug.apk"
}

has_permission() {
  local apk="$1" permission="$2"
  "$aapt" dump permissions "$apk" | grep -q "$permission"
}

# settings.gradle.kts probes the export directories at configuration time, which
# the configuration cache cannot track. The project disables the cache, but drop
# any entry anyway so a forced `--configuration-cache` run still re-probes after
# the stub change (ONY-355).
reset_configuration_cache() {
  rm -rf "$app_dir/android/.gradle/configuration-cache"
}

build() {
  reset_configuration_cache
  (cd "$app_dir" && tool/build_flavor.sh unified)
}

echo "==> a unified stub must link the unified unityLibrary"
create_stub
rm -rf "$(apk_path)"
build
if ! has_permission "$(apk_path)" "$unified_permission"; then
  echo "FAIL: unified APK did not contain the unified unityLibrary manifest" >&2
  exit 1
fi
echo "PASS: unified linked the unified unityLibrary"

echo "==> unified with no export must still build"
rm -rf "$unity_root/unified"
created_stub=0
rm -rf "$(apk_path)"
build
if has_permission "$(apk_path)" "$unified_permission"; then
  echo "FAIL: unified APK without an export linked a Unity stub" >&2
  exit 1
fi
echo "PASS: unified built without a Unity export"

echo "All flavor wiring checks passed."
