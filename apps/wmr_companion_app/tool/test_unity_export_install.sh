#!/usr/bin/env bash
# Exercise tool/install_unity_export.sh against a fixture that reproduces the
# owner export's Gradle integration defects (ONY-388): a missing
# shared/keepUnitySymbols.gradle, `:unityLibrary` project paths, and an
# absolute ndkPath/old ndkVersion. Runs without Unity, an Android SDK or the
# real proprietary export.
#
#   tool/test_unity_export_install.sh
set -euo pipefail

app_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
installer="$app_dir/tool/install_unity_export.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

make_aar() {
  local path="$1" package="$2" empty="${3:-yes}"
  python3 - "$path" "$package" "$empty" <<'PY'
import io
import sys
import zipfile

path, package, empty = sys.argv[1], sys.argv[2], sys.argv[3] == "yes"
manifest = (
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<manifest xmlns:android="http://schemas.android.com/apk/res/android"\n'
    f'    package="{package}" >\n'
    "</manifest>\n"
)
classes = io.BytesIO()
with zipfile.ZipFile(classes, "w") as jar:
    if not empty:
        jar.writestr("com/example/Marker.class", b"\xca\xfe\xba\xbe")
with zipfile.ZipFile(path, "w") as zf:
    zf.writestr("R.txt", "")
    zf.writestr("AndroidManifest.xml", manifest)
    zf.writestr("classes.jar", classes.getvalue())
    zf.writestr("META-INF/com/android/build/gradle/aar-metadata.properties",
                "aarFormatVersion=1.0\n")
PY
}

make_export() {
  local root="$1"
  local library="$root/unityLibrary"
  mkdir -p "$library/src/main/jniLibs/arm64-v8a" "$library/libs" \
    "$library/xrmanifest.androidlib"
  cat >"$library/build.gradle" <<'EOF'
apply plugin: 'com.android.library'
apply from: '../shared/keepUnitySymbols.gradle'

def BuildIl2CppImpl(String workingDir) {
    def ndk = android.ndkDirectory
    exec {
        executable "${workingDir}/il2cpp"
        environment "ANDROID_SDK_ROOT", getSdkDir()
    }
}

def getSdkDir() {
    return "/sdk"
}

dependencies {
    implementation fileTree(dir: 'libs', include: ['*.jar'])
    implementation(name: 'VitureUnityXR', ext:'aar')
    implementation(name: 'nr_common', ext:'aar')
    implementation project(':unityLibrary:xrmanifest.androidlib')
}

android {
    namespace "com.unity3d.player"
    ndkPath "/home/liesa/Unity/Hub/Editor/6000.0.27f1/Editor/Data/PlaybackEngines/AndroidPlayer/NDK"
    ndkVersion "23.1.7779620"
    compileSdk 35

    androidResources {
        noCompress = ['.unity3d'] + unityStreamingAssets.tokenize(', ')
    }
}

android {
    tasks.register('buildIl2Cpp') {
        doLast {
            BuildIl2CppImpl("unityLibrary")
        }
    }
    afterEvaluate {
        if (project(':unityLibrary').tasks.findByName('mergeDebugJniLibFolders'))
            project(':unityLibrary').mergeDebugJniLibFolders.dependsOn buildIl2Cpp
        if (project(':unityLibrary').tasks.findByName('mergeReleaseJniLibFolders'))
            project(':unityLibrary').mergeReleaseJniLibFolders.dependsOn buildIl2Cpp
    }
}
EOF
  printf 'not really an ELF\n' >"$library/src/main/jniLibs/arm64-v8a/libunity.so"
  cat >"$library/proguard-unity.txt" <<'EOF'
-keep class com.unity3d.player.* { *; }
-ignorewarnings
EOF
  make_aar "$library/libs/VitureUnityXR.aar" com.viture.xr.unity
  make_aar "$library/libs/xr-lib.aar" com.xreal.xr.lib
  make_aar "$library/libs/nr_loader.aar" nrsdk.pack
  make_aar "$library/libs/nr_common.aar" nrsdk.pack
  cat >"$library/xrmanifest.androidlib/build.gradle" <<'EOF'
apply plugin: 'com.android.library'
android {
    namespace "com.UnityTechnologies.XR.Manifest"
}
EOF
  cat >"$library/xrmanifest.androidlib/AndroidManifest.xml" <<'EOF'
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
  <application>
    <meta-data android:name="nreal_sdk" android:value="true" />
  </application>
</manifest>
EOF
}

check_normalised() {
  local target="$1"
  local build_gradle="$target/unityLibrary/build.gradle"
  [ -f "$build_gradle" ] || fail "missing $build_gradle"

  grep -q 'keepUnitySymbols.gradle' "$build_gradle" &&
    fail "keepUnitySymbols.gradle apply survived"
  grep -Eq '^[[:blank:]]*ndkPath[[:blank:]]' "$build_gradle" &&
    fail "absolute ndkPath survived"
  grep -q 'ndkVersion "28.2.13676358"' "$build_gradle" ||
    fail "ndkVersion was not pinned"
  grep -q "ndkVersion \"23.1.7779620\"" "$build_gradle" &&
    fail "exporting machine's ndkVersion survived"
  grep -q 'def unityStreamingAssets = ""' "$build_gradle" ||
    fail "missing unityStreamingAssets default was not restored"
  grep -q "implementation files('libs/VitureUnityXR.aar')" "$build_gradle" ||
    fail "local AAR dependency was not rewritten"
  grep -Eq "implementation[[:blank:]]*\([[:blank:]]*name:" "$build_gradle" &&
    fail "local-AAR module notation survived"
  grep -q 'providers.exec {' "$build_gradle" ||
    fail "Project.exec was not rewritten for Gradle 9"
  grep -q '}.result.get()' "$build_gradle" ||
    fail "rewritten exec block is not executed"
  grep -Eq '^[[:blank:]]*exec[[:blank:]]*\{' "$build_gradle" &&
    fail "Project.exec block survived"
  grep -q 'this.BuildIl2CppImpl(' "$build_gradle" ||
    fail "buildIl2Cpp invocation was not qualified for Gradle 9"
  grep -q 'project.android.ndkDirectory' "$build_gradle" ||
    fail "android.ndkDirectory was not qualified"
  grep -q "project(':unityLibraryUnified')" "$build_gradle" ||
    fail "':unityLibrary' was not remapped"
  grep -q "project(':unityLibraryUnified:xrmanifest.androidlib')" "$build_gradle" ||
    fail "nested xrmanifest project was not remapped"
  grep -Eq "project\([[:blank:]]*['\"]:unityLibrary([:'\")])" "$build_gradle" &&
    fail "an unrenamed :unityLibrary project reference survived"

  [ -f "$target/unityLibrary/src/main/jniLibs/arm64-v8a/libunity.so" ] ||
    fail "libunity.so was not copied"
  [ -d "$target/unityLibrary/xrmanifest.androidlib" ] ||
    fail "nested xrmanifest.androidlib was not copied"
  [ -f "$target/unityLibrary/libs/VitureUnityXR.aar" ] ||
    fail "vendor AAR was not copied"

  local proguard="$target/unityLibrary/proguard-unity.txt"
  [ -f "$proguard" ] || fail "proguard-unity.txt was not copied"
  grep -q '^-ignorewarnings$' "$proguard" &&
    fail "-ignorewarnings survived in the consumer ProGuard file"
  grep -q '^-keep class com.unity3d.player' "$proguard" ||
    fail "Unity keep rules were dropped from proguard-unity.txt"

  local duplicate_package
  duplicate_package="$(unzip -p "$target/unityLibrary/libs/nr_loader.aar" \
    AndroidManifest.xml | sed -n 's/.*package="\([^"]*\)".*/\1/p')"
  [ "$duplicate_package" = "nrsdk.pack.nr_loader" ] ||
    fail "duplicate AAR namespace was not made unique ($duplicate_package)"
  local common_package
  common_package="$(unzip -p "$target/unityLibrary/libs/nr_common.aar" \
    AndroidManifest.xml | sed -n 's/.*package="\([^"]*\)".*/\1/p')"
  [ "$common_package" = "nrsdk.pack" ] ||
    fail "first AAR namespace changed unexpectedly ($common_package)"
}

echo "==> normalise a directory export"
make_export "$tmp/source"
source_before="$(cat "$tmp/source/unityLibrary/build.gradle" \
  "$tmp/source/unityLibrary/proguard-unity.txt" | sha256sum)"
"$installer" unified "$tmp/source" \
  --ndk-version 28.2.13676358 --target-root "$tmp/target-dir" >/dev/null
check_normalised "$tmp/target-dir/unified"
source_after="$(cat "$tmp/source/unityLibrary/build.gradle" \
  "$tmp/source/unityLibrary/proguard-unity.txt" | sha256sum)"
[ "$source_before" = "$source_after" ] ||
  fail "installer modified the source export"
echo "PASS: directory export normalised; source untouched"

echo "==> normalise the same export from a zip"
python3 - "$tmp/source" "$tmp/export.zip" <<'PY'
import os
import sys
import zipfile

root, archive = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(archive, "w") as zf:
    for directory, _, files in os.walk(root):
        for name in files:
            path = os.path.join(directory, name)
            zf.write(path, os.path.relpath(path, root))
PY
zip_before="$(sha256sum "$tmp/export.zip")"
"$installer" unified "$tmp/export.zip" \
  --ndk-version 28.2.13676358 --target-root "$tmp/target-zip" >/dev/null
check_normalised "$tmp/target-zip/unified"
zip_after="$(sha256sum "$tmp/export.zip")"
[ "$zip_before" = "$zip_after" ] || fail "installer modified the source zip"
diff "$tmp/target-dir/unified/unityLibrary/build.gradle" \
  "$tmp/target-zip/unified/unityLibrary/build.gradle" >/dev/null ||
  fail "directory and zip build.gradle differ"
for aar in VitureUnityXR xr-lib nr_loader nr_common; do
  diff <(unzip -p "$tmp/target-dir/unified/unityLibrary/libs/$aar.aar" \
    AndroidManifest.xml) \
    <(unzip -p "$tmp/target-zip/unified/unityLibrary/libs/$aar.aar" \
      AndroidManifest.xml) >/dev/null ||
    fail "directory and zip $aar.aar manifests differ"
done
echo "PASS: zip export normalised identically; zip untouched"

echo "==> reinstalling replaces the previous export"
"$installer" unified "$tmp/export.zip" \
  --ndk-version 28.2.13676358 --target-root "$tmp/target-zip" >/dev/null
check_normalised "$tmp/target-zip/unified"
[ "$(grep -c 'ndkVersion "' "$tmp/target-zip/unified/unityLibrary/build.gradle")" -eq 1 ] ||
  fail "reinstall duplicated ndkVersion"
echo "PASS: reinstall replaces cleanly"

echo "==> unknown flavor is rejected"
if "$installer" base "$tmp/export.zip" --target-root "$tmp/target-bad" >/dev/null 2>&1; then
  fail "base flavor was accepted"
fi
[ ! -e "$tmp/target-bad" ] || fail "rejected install wrote a target"
echo "PASS: unknown flavor rejected"

echo "==> an export without exactly one libunity.so is rejected"
rm "$tmp/source/unityLibrary/src/main/jniLibs/arm64-v8a/libunity.so"
if "$installer" unified "$tmp/source" \
  --ndk-version 28.2.13676358 --target-root "$tmp/target-empty" >/dev/null 2>&1; then
  fail "export without libunity.so was accepted"
fi
echo "PASS: missing libunity.so rejected"

echo "All unityLibrary export installer checks passed."
