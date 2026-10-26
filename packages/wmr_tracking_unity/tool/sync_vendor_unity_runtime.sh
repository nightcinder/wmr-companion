#!/usr/bin/env bash
# Keeps the two vendor Runtime assemblies inside the unified Unity project in
# lockstep with their per-vendor projects.
#
# The unified smoke scene stores the vendor bridges by script GUID, and the
# unified Runtime asmdef references both vendor assembly names. Unity needs the
# scripts, asmdefs and .meta files inside this project (the per-vendor Unity
# projects are not package dependencies).
#
#   packages/wmr_tracking_unity/tool/sync_vendor_unity_runtime.sh
#       Copy the vendor Runtime folders into the unified project.
#
#   packages/wmr_tracking_unity/tool/sync_vendor_unity_runtime.sh --check
#       Fail when a copy is missing, differs or has extra files. CI runs this.
#
# The per-vendor projects stay the source of truth; never edit the copies.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
check_only=false
case "${1:-}" in
  "") ;;
  --check) check_only=true ;;
  *)
    echo "usage: $(basename "$0") [--check]" >&2
    exit 2
    ;;
esac

sources=(
  "$repo_root/packages/wmr_tracking_viture/unity/Assets/WmrTrackingViture/Runtime"
  "$repo_root/packages/wmr_tracking_xreal/unity/Assets/WmrTrackingXreal/Runtime"
)
targets=(
  "$repo_root/packages/wmr_tracking_unity/unity/Assets/WmrTrackingViture/Runtime"
  "$repo_root/packages/wmr_tracking_unity/unity/Assets/WmrTrackingXreal/Runtime"
)

failed=false
for i in "${!sources[@]}"; do
  source="${sources[$i]}"
  target="${targets[$i]}"
  if [[ ! -d "$source" ]]; then
    echo "missing vendor runtime: $source" >&2
    failed=true
    continue
  fi

  if $check_only; then
    if [[ ! -d "$target" ]]; then
      echo "missing unified vendor runtime copy: $target" >&2
      failed=true
      continue
    fi
    if ! diff -ru "$source" "$target"; then
      echo "vendor runtime copy is out of sync: $target" >&2
      echo "run packages/wmr_tracking_unity/tool/sync_vendor_unity_runtime.sh" >&2
      failed=true
    fi
  else
    rm -rf "$target"
    mkdir -p "$target"
    cp -a "$source/." "$target/"
    echo "synced ${target#$repo_root/}"
  fi
done

if $failed; then
  exit 1
fi
if $check_only; then
  echo "PASS: vendor runtime copies are in sync"
fi
