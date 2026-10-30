#!/usr/bin/env bash
# Prove the ONY-355 unified Unity include path: a unified export is linked into
# the unified APK, and a unified build with no export still succeeds without a
# Unity runtime (ONY-520). Creates a throwaway `unityLibrary` stub in the
# gitignored location, builds the flavor, then removes it. Needs an Android SDK
# with aapt; no Unity or vendor SDK is required.
#
# Also proves ONY-561: every Unity flavor keeps exactly one home-screen icon
# when the linked export declares standalone MAIN/LAUNCHER activities.
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

# A developer may have a real (proprietary, gitignored) export at these paths.
# Move it aside before writing a stub and put it back on exit; only remove a
# directory this script created itself.
backup_root=""
created_flavors=()

cleanup() {
  local flavor
  for flavor in "${created_flavors[@]+"${created_flavors[@]}"}"; do
    rm -rf "$unity_root/$flavor"
  done
  if [ -n "$backup_root" ]; then
    for saved in "$backup_root"/*; do
      if [ -e "$saved" ]; then
        mv "$saved" "$unity_root/"
      fi
    done
    rmdir "$backup_root" 2>/dev/null || true
  fi
}
trap cleanup EXIT

drop_created() {
  local keep=() flavor
  for flavor in "${created_flavors[@]+"${created_flavors[@]}"}"; do
    if [ "$flavor" != "$1" ]; then
      keep+=("$flavor")
    fi
  done
  created_flavors=("${keep[@]+"${keep[@]}"}")
}

backup_export() {
  local flavor="$1"
  if [ -e "$unity_root/$flavor" ] || [ -L "$unity_root/$flavor" ]; then
    if [ -z "$backup_root" ]; then
      backup_root="$(mktemp -d "$unity_root/.flavor-wiring-backup.XXXXXX")"
    fi
    echo "==> preserving existing $unity_root/$flavor (restored on exit)"
    mv "$unity_root/$flavor" "$backup_root/$flavor"
  fi
}

for flavor in unified viture xreal; do
  backup_export "$flavor"
done

create_stub() {
  local dir="$unity_root/unified/unityLibrary"
  created_flavors+=(unified)
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
    <!-- Mimic the XREAL/Unity export: both activities carry a standalone
         launcher filter. The app flavor manifest must remove them so the APK
         installs one icon (ONY-561). -->
    <application>
        <activity
            android:name="ai.nreal.activitylife.NRXRActivity"
            android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
                <category android:name="android.intent.category.LEANBACK_LAUNCHER" />
                <category android:name="android.intent.category.DEFAULT" />
            </intent-filter>
        </activity>
        <activity
            android:name="com.unity3d.player.UnityPlayerActivity"
            android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>
    </application>
</manifest>
EOF
}

# A per-vendor stub: the viture flavor links only Unity's player activity, the
# xreal flavor also carries the XREAL SDK's NRXRActivity. Both declare the
# launcher filters each vendor's export ships (ONY-561).
create_vendor_stub() {
  local vendor="$1"
  local dir="$unity_root/$vendor/unityLibrary"
  created_flavors+=("$vendor")
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
    namespace = 'com.onyxlens.wmr.unitystub.$vendor'
    compileSdk = 36

    defaultConfig {
        minSdk = 24
    }
}
EOF
  local permission="com.onyxlens.wmr.UNITY_STUB_$vendor"
  {
    cat <<EOF
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-permission android:name="$permission" />
    <application>
EOF
    cat <<'EOF'

        <activity
            android:name="com.unity3d.player.UnityPlayerActivity"
            android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>
EOF
    if [ "$vendor" = "xreal" ]; then
      cat <<'EOF'
        <activity
            android:name="ai.nreal.activitylife.NRXRActivity"
            android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
                <category android:name="android.intent.category.LEANBACK_LAUNCHER" />
                <category android:name="android.intent.category.DEFAULT" />
            </intent-filter>
        </activity>
EOF
    fi
    cat <<'EOF'
    </application>
</manifest>
EOF
  } >"$dir/src/main/AndroidManifest.xml"
}

apk_path() {
  local flavor="${1:-unified}"
  echo "$build_root/app/outputs/flutter-apk/app-$flavor-debug.apk"
}

has_permission() {
  local apk="$1" permission="$2"
  "$aapt" dump permissions "$apk" | grep -q "$permission"
}

launcher_activities() {
  "$aapt" dump badging "$1" |
    sed -n "s/^launchable-activity: name='\([^']*\)'.*/\1/p"
}

assert_one_launcher() {
  local flavor="$1"
  local apk launchers
  apk="$(apk_path "$flavor")"
  launchers="$(launcher_activities "$apk")"
  if [ "$launchers" != "com.onyxlens.wmr_companion.MainActivity" ]; then
    echo "FAIL: $flavor APK launcher activities: ${launchers:-none}" >&2
    echo "      expected only com.onyxlens.wmr_companion.MainActivity" >&2
    exit 1
  fi
  if "$aapt" dump badging "$apk" | grep -q '^leanback-launchable-activity'; then
    echo "FAIL: $flavor APK still exposes a leanback launcher activity" >&2
    exit 1
  fi
  echo "PASS: $flavor APK has one launcher icon"
}

# settings.gradle.kts probes the export directories at configuration time, which
# the configuration cache cannot track. The project disables the cache, but drop
# any entry anyway so a forced `--configuration-cache` run still re-probes after
# the stub change (ONY-355).
reset_configuration_cache() {
  rm -rf "$app_dir/android/.gradle/configuration-cache"
}

build() {
  local flavor="${1:-unified}"
  reset_configuration_cache
  (cd "$app_dir" && tool/build_flavor.sh "$flavor")
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

assert_one_launcher unified

echo "==> unified plus a per-vendor export must fail at configuration"
# settings.gradle.kts rejects a unified export next to a per-vendor one; an
# empty directory is enough because the guard runs before any module builds.
backup_export viture
created_flavors+=(viture)
mkdir -p "$unity_root/viture/unityLibrary"
if build_output="$(build 2>&1)"; then
  echo "FAIL: unified plus a per-vendor export built instead of failing" >&2
  exit 1
fi
if ! grep -q "cannot be combined with per-vendor" <<<"$build_output"; then
  echo "FAIL: expected the unified/per-vendor guard, got:" >&2
  echo "$build_output" >&2
  exit 1
fi
rm -rf "$unity_root/viture"
drop_created viture
echo "PASS: unified refused a per-vendor export"

echo "==> unified with no export must still build"
rm -rf "$unity_root/unified"
drop_created unified
rm -rf "$(apk_path)"
build
if has_permission "$(apk_path)" "$unified_permission"; then
  echo "FAIL: unified APK without an export linked a Unity stub" >&2
  exit 1
fi
echo "PASS: unified built without a Unity export"

# The xreal and viture flavor manifests are separate from unified's; merge each
# with a launcher-bearing stub so the ONY-561 removal is proven for all three.
for vendor in viture xreal; do
  echo "==> $vendor stub must keep one launcher inside the $vendor APK"
  create_vendor_stub "$vendor"
  rm -rf "$(apk_path "$vendor")"
  build "$vendor"
  if ! has_permission "$(apk_path "$vendor")" "com.onyxlens.wmr.UNITY_STUB_$vendor"; then
    echo "FAIL: $vendor APK did not contain the $vendor unityLibrary manifest" >&2
    exit 1
  fi
  assert_one_launcher "$vendor"
  rm -rf "$unity_root/$vendor"
  drop_created "$vendor"
done

echo "All flavor wiring checks passed."
