#!/usr/bin/env bash
# Build one WMR Companion Android flavor with the vendor flags it needs (ONY-271).
#
#   tool/build_flavor.sh base
#   tool/build_flavor.sh viture --release
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
  viture)
    defines=(
      --dart-define=WMR_ANDROID_XR_TRACKING=false
      --dart-define=WMR_VITURE_TRACKING=true
      --dart-define=WMR_XREAL_TRACKING=false
    )
    ;;
  xreal)
    defines=(
      --dart-define=WMR_ANDROID_XR_TRACKING=false
      --dart-define=WMR_VITURE_TRACKING=false
      --dart-define=WMR_XREAL_TRACKING=true
    )
    ;;
  *)
    echo "usage: $0 {base|viture|xreal} [--debug|--profile|--release] [flutter build args...]" >&2
    exit 64
    ;;
esac

mode=--debug
passthrough=()
for arg in "$@"; do
  case "$arg" in
    --debug | --profile | --release) mode="$arg" ;;
    *) passthrough+=("$arg") ;;
  esac
done

cd "$app_dir"
exec flutter build apk "$mode" --flavor "$flavor" "${defines[@]}" "${passthrough[@]+"${passthrough[@]}"}"
