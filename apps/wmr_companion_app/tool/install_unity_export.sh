#!/usr/bin/env bash
# Install a Unity UaaL export for one Android flavor as a buildable Gradle
# subproject of this app (ONY-388).
#
# Unity writes `unityLibrary/build.gradle` for a root project named
# `unityLibrary`. This app includes the same directory as
# `:unityLibrary<Vendor>` (settings.gradle.kts), so three things in Unity's
# generated file do not hold outside the exporting machine:
#
#   - `apply from: '../shared/keepUnitySymbols.gradle'`; the UaaL zip has no
#     sibling `shared/` directory.
#   - `project(':unityLibrary')` / `project(':unityLibrary:xrmanifest.androidlib')`;
#     the module is included under another name.
#   - `ndkPath "/home/<owner>/Unity/..."` plus the exporting machine's
#     `ndkVersion`.
#
# It also adapts the export to AGP 9 / Gradle 9 and this app's minSdk; see the
# numbered comments in the body. The input zip/directory is treated as
# immutable: it is copied and only the copy is normalised. Installation
# replaces any previous export for the flavor.
#
#   tool/install_unity_export.sh unified path/to/unityLibrary.zip
#   tool/install_unity_export.sh viture path/to/unityLibrary
#
# Options (after the two positional arguments):
#   --ndk-version <version>  NDK to record in unityLibrary/build.gradle.
#                            Default: ANDROID_NDK_HOME, else the newest NDK
#                            under ANDROID_HOME/ndk, else Flutter 3.47's
#                            28.2.13676358.
#   --target-root <dir>      Parent of the flavor directories. Default:
#                            android/unity. Used by the tests.
set -euo pipefail

app_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
android_dir="$app_dir/android"

usage() {
  echo "usage: $0 {viture|xreal|unified} <unityLibrary.zip|unityLibrary dir> [--ndk-version <v>] [--target-root <dir>]" >&2
  exit 64
}

[ "$#" -ge 2 ] || usage
flavor="$1"
source_path="$2"
shift 2

ndk_version=""
target_root="$android_dir/unity"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --ndk-version)
      [ "$#" -ge 2 ] || usage
      ndk_version="$2"
      shift 2
      ;;
    --target-root)
      [ "$#" -ge 2 ] || usage
      target_root="$2"
      shift 2
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage
      ;;
  esac
done

case "$flavor" in
  viture | xreal | unified) ;;
  *) usage ;;
esac
case "$flavor" in
  viture) module="unityLibraryViture" ;;
  xreal) module="unityLibraryXreal" ;;
  unified) module="unityLibraryUnified" ;;
esac

if [ -z "$ndk_version" ]; then
  if [ -n "${ANDROID_NDK_HOME:-}" ]; then
    ndk_version="$(basename "$ANDROID_NDK_HOME")"
  elif [ -d "${ANDROID_HOME:-}/ndk" ]; then
    ndk_version="$(
      find "$ANDROID_HOME/ndk" -mindepth 1 -maxdepth 1 -type d |
        sed "s#.*/##" | sort -V | tail -n 1
    )"
  fi
fi
ndk_version="${ndk_version:-28.2.13676358}"

if [ ! -e "$source_path" ]; then
  echo "FAIL: export not found: $source_path" >&2
  exit 1
fi

mkdir -p "$target_root"
target_root="$(cd "$target_root" && pwd)"
work_dir="$(mktemp -d "$target_root/.install-${flavor}.XXXXXX")"
cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT

# Materialise the export into $work_dir/unityLibrary without touching the input.
if [ -d "$source_path" ]; then
  if [ -f "$source_path/build.gradle" ]; then
    source_library="$source_path"
  elif [ -f "$source_path/unityLibrary/build.gradle" ]; then
    source_library="$source_path/unityLibrary"
  else
    echo "FAIL: $source_path is neither a unityLibrary nor a directory containing one" >&2
    exit 1
  fi
  cp -a "$source_library" "$work_dir/unityLibrary"
elif [ -f "$source_path" ]; then
  unzip -q "$source_path" -d "$work_dir"
  if [ ! -f "$work_dir/unityLibrary/build.gradle" ]; then
    if [ "$(find "$work_dir" -name unityLibrary -type d | wc -l)" -eq 1 ]; then
      found="$(find "$work_dir" -name unityLibrary -type d)"
      mv "$found" "$work_dir/unityLibrary"
    else
      echo "FAIL: $source_path does not contain exactly one unityLibrary" >&2
      exit 1
    fi
  fi
else
  echo "FAIL: unsupported export path: $source_path" >&2
  exit 1
fi

src="$work_dir/unityLibrary"
build_gradle="$src/build.gradle"
[ -f "$build_gradle" ] || {
  echo "FAIL: $source_path has no unityLibrary/build.gradle" >&2
  exit 1
}

libunity_count="$(find "$src" -type f -name libunity.so | wc -l)"
if [ "$libunity_count" -ne 1 ]; then
  echo "FAIL: export must contain exactly one libunity.so, found $libunity_count" >&2
  exit 1
fi

# 1. Drop the sibling shared/ script Unity references but does not export.
perl -0pi -e \
  "s{^[ \t]*apply[ \t]+from:[ \t]*['\"](?:\.\./)?shared/keepUnitySymbols\.gradle['\"][ \t]*(?:\r?\n|\z)}{}mg" \
  "$build_gradle"

# 2. Point Unity's own project references at the module settings.gradle.kts
#    includes. The lookahead keeps already-renamed modules unchanged.
perl -0pi -e \
  "s{project\([ \t]*(['\"]):unityLibrary(?=[:'\")])}{project(\$1:$module}g" \
  "$build_gradle"

# 3. Remove the exporting machine's absolute NDK and pin the installed one.
perl -0pi -e \
  's{^[ \t]*ndkPath[ \t]+["\x27][^"\x27]*["\x27][ \t]*(?:\r?\n|\z)}{}mg' \
  "$build_gradle"
if grep -Eq '^[ \t]*ndkVersion[ \t]' "$build_gradle"; then
  perl -0pi -e \
    "s{^([ \t]*ndkVersion[ \t]+)[\"'][^\"']*[\"']}{\${1}\"$ndk_version\"}mg" \
    "$build_gradle"
else
  perl -0pi -e \
    "s{(android[ \t]*\{)}{$1\n    ndkVersion \"$ndk_version\"}" \
    "$build_gradle"
fi

# 4. AGP 9 dropped the `implementation(name: 'x', ext: 'aar')` local-AAR
#    notation; point the same files at libs/ explicitly.
perl -0pi -e \
  "s{^([ \t]*implementation)[ \t]*\([ \t]*name:[ \t]*['\"]([^'\"]+)['\"][ \t]*,[ \t]*ext:[ \t]*['\"]aar['\"][ \t]*\)}{\$1 files('libs/\$2.aar')}mg" \
  "$build_gradle"

# 5. AGP 9 rejects two AARs whose manifests declare the same package. The
#    owner export's nr_loader/nr_common are native-only carriers (empty
#    classes.jar and R.txt), so give the later duplicate a unique package.
#    Refuse to rewrite an AAR that actually contains code or resources.
aar_packages="$work_dir/aar-packages.txt"
: >"$aar_packages"
for aar in "$src"/libs/*.aar; do
  [ -e "$aar" ] || continue
  package="$(unzip -p "$aar" AndroidManifest.xml 2>/dev/null |
    sed -n 's/.*package="\([^"]*\)".*/\1/p')"
  [ -n "$package" ] || continue
  if ! grep -qxF -- "$package" "$aar_packages"; then
    printf '%s\n' "$package" >>"$aar_packages"
    continue
  fi
  r_txt_bytes="$(unzip -p "$aar" R.txt 2>/dev/null | wc -c || true)"
  classes_jar="$work_dir/classes.jar"
  unzip -p "$aar" classes.jar >"$classes_jar" 2>/dev/null || true
  classes_entries="$(unzip -Z1 "$classes_jar" 2>/dev/null |
    grep -cv '^Empty zipfile\.$' || true)"
  if [ "$r_txt_bytes" -ne 0 ] || [ "$classes_entries" -ne 0 ]; then
    echo "FAIL: $(basename "$aar") reuses package '$package' and is not native-only;" >&2
    echo "      refusing to rename a namespace that may own classes or resources." >&2
    exit 1
  fi
  command -v jar >/dev/null 2>&1 || {
    echo "FAIL: jar is needed to repackage $(basename "$aar") with a unique namespace" >&2
    exit 1
  }
  suffix="$(basename "$aar" .aar | sed 's/[^A-Za-z0-9_]/_/g')"
  unique_package="$package.$suffix"
  aar_work="$work_dir/aar"
  mkdir -p "$aar_work"
  unzip -p "$aar" AndroidManifest.xml >"$aar_work/AndroidManifest.xml"
  perl -pi -e "s/package=\"\Q$package\E\"/package=\"$unique_package\"/" \
    "$aar_work/AndroidManifest.xml"
  (cd "$aar_work" && jar uf "$aar" AndroidManifest.xml)
  echo "  namespace:  $(basename "$aar") $package -> $unique_package"
done

# 6. Unity's export targets Gradle 8. Gradle 9 (Flutter 3.47) cannot resolve
#    script methods from a task action anymore and removed Project.exec; use
#    the provider API and explicit script/project receivers.
perl -0pi -e \
  's{^([ \t]*)exec \{\n(.*?)^\1\}\n}{${1}providers.exec {\n${2}${1}}.result.get()\n}ms' \
  "$build_gradle"
perl -0pi -e \
  's{^([ \t]*)BuildIl2CppImpl\(}{$1this.BuildIl2CppImpl(}m' \
  "$build_gradle"
perl -0pi -e \
  's{(environment "ANDROID_SDK_ROOT", )getSdkDir\(\)}{${1}this.getSdkDir()}' \
  "$build_gradle"
perl -0pi -e \
  's{\bandroid\.ndkDirectory}{project.android.ndkDirectory}g' \
  "$build_gradle"

# 7. Unity reads `unityStreamingAssets` from unityLibrary/gradle.properties,
#    which this export omits. The normal value is empty: only Unity's built-in
#    extensions stay uncompressed.
if grep -q 'unityStreamingAssets' "$build_gradle" &&
  ! grep -qs '^[[:blank:]]*unityStreamingAssets' "$src/gradle.properties" 2>/dev/null; then
  perl -0pi -e \
    's{^(?=[ \t]*android[ \t]*\{)}{// Added by tool/install_unity_export.sh: the export omits gradle.properties.\ndef unityStreamingAssets = ""\n}m' \
    "$build_gradle"
fi

if grep -Eq "implementation[[:blank:]]*\([[:blank:]]*name:" "$build_gradle"; then
  echo "FAIL: local-AAR module notation survived normalisation" >&2
  exit 1
fi
if grep -Eq '^[[:blank:]]*exec[[:blank:]]*\{' "$build_gradle"; then
  echo "FAIL: Gradle-8 Project.exec block survived normalisation" >&2
  exit 1
fi
if grep -Eq '(^|[^.])android\.ndkDirectory' "$build_gradle"; then
  echo "FAIL: unqualified android.ndkDirectory survived normalisation" >&2
  exit 1
fi
if grep -q 'keepUnitySymbols.gradle' "$build_gradle"; then
  echo "FAIL: keepUnitySymbols.gradle reference survived normalisation" >&2
  exit 1
fi
if grep -Eq "project\([[:blank:]]*['\"]:unityLibrary([:'\")])" "$build_gradle"; then
  echo "FAIL: unrenamed :unityLibrary project reference survived" >&2
  exit 1
fi
if grep -Eq '^[[:blank:]]*ndkPath[[:blank:]]' "$build_gradle"; then
  echo "FAIL: absolute ndkPath survived normalisation" >&2
  exit 1
fi
if ! grep -q "\"$ndk_version\"" "$build_gradle"; then
  echo "FAIL: ndkVersion $ndk_version was not written" >&2
  exit 1
fi

dest="$target_root/$flavor/unityLibrary"
rm -rf "$target_root/$flavor/unityLibrary"
mkdir -p "$target_root/$flavor"
mv "$src" "$dest"

echo "Installed $flavor Unity export"
echo "  source:     $source_path"
echo "  target:     $dest"
echo "  module:     :$module"
echo "  ndkVersion: $ndk_version"
echo "  libunity.so: $(find "$dest" -type f -name libunity.so | wc -l)"
echo "Normalised: dropped shared/keepUnitySymbols.gradle apply, remapped"
echo ":unityLibrary project paths to :$module, removed absolute ndkPath."
if [ "$target_root" = "$android_dir/unity" ]; then
  echo "Next: tool/build_flavor.sh $flavor --debug"
fi
