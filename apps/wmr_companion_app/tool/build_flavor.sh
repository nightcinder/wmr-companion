#!/usr/bin/env bash
# Build one WMR Companion Android flavor with the vendor flags it needs
# (ONY-271, ONY-355). Only the unified APK ships (ONY-565); `base` is the
# emulator/BLE fallback with no Unity runtime.
#
#   tool/build_flavor.sh base
#   tool/build_flavor.sh unified
#
# Extra arguments are passed to `flutter build apk`. The default mode is
# `--debug`; pass `--debug`, `--profile` or `--release` to override it.
set -euo pipefail

app_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
flavor="${1:-}"
if [ "$#" -gt 0 ]; then
  shift
fi

case "$flavor" in
  base)
    # CI builds base with every flag on: all Dart adapters exist but, with no
    # Unity runtime linked, VITURE/XREAL start() reports typed `unavailable`.
    defines=(
      --dart-define=WMR_ANDROID_XR_TRACKING=true
      --dart-define=WMR_VITURE_TRACKING=true
      --dart-define=WMR_XREAL_TRACKING=true
    )
    ;;
  unified)
    # One shared unityLibrary, both vendor adapters compiled in. With no export
    # linked, VITURE/XREAL start() reports typed `unavailable`; with the export
    # present, the runtime dispatch picks the vendor.
    defines=(
      --dart-define=WMR_ANDROID_XR_TRACKING=true
      --dart-define=WMR_VITURE_TRACKING=true
      --dart-define=WMR_XREAL_TRACKING=true
      # The guided bench's Carina gate must be reachable on a signed tester
      # build, not only a debug APK (ONY-740). It is still bench-only.
      --dart-define=WMR_VITURE_CARINA_DIAG=true
    )
    ;;
  *)
    echo "usage: $0 {base|unified} [--debug|--profile|--release] [flutter build args...]" >&2
    exit 64
    ;;
esac

# The bundle manifest records the commit the capture came from. A caller-set
# WMR_APP_COMMIT wins over the checkout's HEAD and is defined exactly once.
app_commit="${WMR_APP_COMMIT:-$(git -C "$app_dir" rev-parse --short HEAD 2>/dev/null || echo unknown)}"
defines+=(--dart-define=WMR_APP_COMMIT="$app_commit")

mode=--debug
passthrough=()
for arg in "$@"; do
  case "$arg" in
    --debug | --profile | --release) mode="$arg" ;;
    *) passthrough+=("$arg") ;;
  esac
done

cd "$app_dir"
exec flutter build apk "$mode" --flavor "$flavor" \
  "${defines[@]}" "${passthrough[@]+"${passthrough[@]}"}"
