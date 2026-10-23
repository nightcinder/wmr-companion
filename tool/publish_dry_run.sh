#!/usr/bin/env bash
# Stage every package as it would be published and run `dart pub publish
# --dry-run` on it, strictly: every package must pass. Nothing is uploaded.
#
# The packages depend on each other by path until their first release. The
# staging copy removes the path dependencies only in a temporary directory:
#   * any `publish_to` gate is dropped in the copy so pub validates the package;
#   * `path:` dependencies become `^<version>` constraints, as they must be on
#     pub.dev;
#   * `pubspec_overrides.yaml` points those constraints back at the staged
#     siblings so resolution works without publishing anything.
#
# The only expected hints are the override notices. Any other warning or error
# is a packaging problem to fix in the real package.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# `dart` is on PATH in CI; a local Flutter checkout can be passed with DART=...
dart_bin="${DART:-dart}"
if ! command -v "$dart_bin" >/dev/null 2>&1; then
  if [ -n "${FLUTTER_ROOT:-}" ] && [ -x "$FLUTTER_ROOT/bin/dart" ]; then
    dart_bin="$FLUTTER_ROOT/bin/dart"
  elif [ -x /tmp/flutter-sdk/flutter/bin/dart ]; then
    dart_bin=/tmp/flutter-sdk/flutter/bin/dart
  fi
fi
packages=(
  wmr_fusion
  wmr_core
  wmr_ble
  wmr_companion
  wmr_companion_ui
  wmr_companion_hid_android
)

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

for package in "${packages[@]}"; do
  mkdir -p "$stage/$package"
  tar -C "$root/packages/$package" \
    --exclude=build \
    --exclude=.dart_tool \
    --exclude=pubspec.lock \
    --exclude='*.iml' \
    -cf - . | tar -C "$stage/$package" -xf -
  # Only the temporary copy drops publish_to; the repository stays
  # publish_to: none until the owner approves publishing.
  sed -i.bak '/^publish_to: none$/d' "$stage/$package/pubspec.yaml"
  rm -f "$stage/$package/pubspec.yaml.bak"
done

python3 - "$stage" <<'PY'
import pathlib
import sys

stage = pathlib.Path(sys.argv[1])
versions = {}
for package in stage.iterdir():
    if not package.is_dir():
        continue
    for line in (package / "pubspec.yaml").read_text().splitlines():
        if line.startswith("version:"):
            versions[package.name] = line.split(":", 1)[1].strip()
            break

for package in stage.iterdir():
    if not package.is_dir():
        continue
    pubspec = package / "pubspec.yaml"
    text = pubspec.read_text()
    for name, version in versions.items():
        path_dep = f"  {name}:\n    path: ../{name}\n"
        if path_dep in text:
            text = text.replace(path_dep, f"  {name}: ^{version}\n")
    pubspec.write_text(text)

# A dependency_override is a property of the package being validated, so each
# root needs overrides for its whole internal closure, not only direct deps.
def internal_deps(name):
    text = (stage / name / "pubspec.yaml").read_text()
    return {
        dep
        for dep in versions
        if dep != name and f"  {dep}: ^{versions[dep]}\n" in text
    }

def closure(name):
    seen = set()
    pending = list(internal_deps(name))
    while pending:
        dep = pending.pop()
        if dep in seen:
            continue
        seen.add(dep)
        pending.extend(internal_deps(dep) - seen)
    return seen

for package in stage.iterdir():
    if not package.is_dir():
        continue
    package_closure = closure(package.name)
    if package_closure:
        overrides = "\n".join(
            f"  {name}:\n    path: ../{name}" for name in sorted(package_closure)
        )
        (package / "pubspec_overrides.yaml").write_text(
            f"dependency_overrides:\n{overrides}\n"
        )
PY

status=0
for package in "${packages[@]}"; do
  echo
  echo "=== $package"
  if ! (cd "$stage/$package" && "$dart_bin" pub publish --dry-run); then
    status=1
  fi
done

if [ "$status" -ne 0 ]; then
  echo
  echo "publish dry-run failed; see the output above." >&2
fi
exit "$status"
