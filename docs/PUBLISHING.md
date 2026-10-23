# Publishing `wmr-companion` Packages to pub.dev

This document defines the publication process for the `wmr-companion` multi-package repository, the dependency constraints and publication order, the evaluation of local development workflows after publication, and the exact steps required for the initial 0.1.0 release.

---

## 1. Background & Target

As decided by the project owner (2026-10-23, ONY-50), **pub.dev is the release target after the API freeze**.

The repository contains modular Dart and Flutter packages that are intended to be independently published to [pub.dev](https://pub.dev):
- `wmr_fusion` (pure-Dart 6-axis Madgwick and Mahony orientation filters)
- `wmr_core` (pure-Dart protocol, controller pipelines, and BLE seam)
- `wmr_companion` (public framework-agnostic facade)
- `wmr_ble` (Flutter `universal_ble` transport)
- `wmr_companion_ui` (optional Flutter UI widgets, landed in PR #45)
- `wmr_companion_hid_android` (optional Android BLE HID output plugin, landed in PR #48)

All six package names have been verified as available and unclaimed on pub.dev (each returns 404 from `https://pub.dev/api/packages/<name>`). No renaming is required.

The root application (`wmr_companion_app`) and `example/` (`wmr_companion_example`) remain application hosts and retain `publish_to: none`.

### Decision on v1 Publication Set for `wmr_companion_ui` and `wmr_companion_hid_android`

Both `wmr_companion_ui` and `wmr_companion_hid_android` are explicitly included in the **v1 publish set**.
- `wmr_companion_ui` provides reusable widgets (`OrientationView`, `LinkStatusView`, `HandStatsView`, `GamepadStateView`) for hosts that use `wmr_companion`. It has no third-party plugin dependencies beyond Flutter and `vector_math`.
- `wmr_companion_hid_android` provides Android Bluetooth HID gamepad output (`BluetoothHidDevice`), enabling devices running Flutter hosts to act as standard Bluetooth gamepads. It is self-contained as an Android Flutter plugin and introduces no unstable dependencies.

Holding either package back is unnecessary; publishing all six packages under version `0.1.0` delivers the complete modular architecture envisioned in ONY-41 / ONY-50.

---

## 2. Dependency Graph & Publication Order

pub.dev strictly forbids packages from having `path:` dependencies upon publication. Any inter-package dependency must be a hosted version constraint (e.g. `wmr_core: ^0.1.0`).

Because a published package cannot depend on a package version that does not yet exist on pub.dev, the dependency DAG dictates a strict sequential publication order across three distinct waves:

```text
[wmr_fusion] (pure Dart, zero dependencies)
     ▲
     │
[wmr_core] (pure Dart, depends on wmr_fusion)
     ▲
     ├──────────────────────────┐
     │                          │
[wmr_companion] (facade)    [wmr_ble] (Flutter BLE transport)
     ▲
     ├──────────────────────────┐
     │                          │
[wmr_companion_ui]          [wmr_companion_hid_android]
(Flutter UI widgets)        (Android BLE HID output plugin)
```

### Publication Waves

1. **Wave 1: Foundation (Zero Dependencies & Protocol Core)**
   - **Step 1a: `packages/wmr_fusion`**
     - Has no internal dependencies.
     - Must be published first to pub.dev.
   - **Step 1b: `packages/wmr_core`**
     - Depends on `wmr_fusion`.
     - Once `wmr_fusion 0.1.0` is published and indexed on pub.dev, `wmr_core` can switch its dependency from `path: ../wmr_fusion` to `wmr_fusion: ^0.1.0` and be published.

2. **Wave 2: Public Facade**
   - **Step 2: `packages/wmr_companion`**
     - Depends on `wmr_core`.
     - Once `wmr_core 0.1.0` is published on pub.dev, `wmr_companion` switches `path: ../wmr_core` to `wmr_core: ^0.1.0` and is published.

3. **Wave 3: Platform Transports & Optional Add-ons**
   - **Step 3a: `packages/wmr_ble`**
     - Depends on `wmr_core` and Flutter SDK.
     - Switches `path: ../wmr_core` to `wmr_core: ^0.1.0` and is published.
   - **Step 3b: `packages/wmr_companion_ui`**
     - Depends on `wmr_companion` and Flutter SDK.
     - Switches `path: ../wmr_companion` to `wmr_companion: ^0.1.0` and is published.
   - **Step 3c: `packages/wmr_companion_hid_android`**
     - Depends on `wmr_companion` and Android Flutter SDK.
     - Switches `path: ../wmr_companion` to `wmr_companion: ^0.1.0` and is published.

*(Note: Steps 3a, 3b, and 3c are mutually independent and can be published in parallel once Wave 1 and Wave 2 are indexed on pub.dev.)*

---

## 3. Local Development Mechanism: Evaluation & Recommendation

When inter-package dependencies transition from relative `path:` entries to hosted version constraints (`^0.1.0`), repository development must continue to link to local source code rather than downloading released artifacts from pub.dev. Two mechanisms exist in the Dart ecosystem to accomplish this: `dependency_overrides` and `pub workspace`.

### Evaluation: `dependency_overrides`

In this model, packages declare hosted dependencies (e.g. `wmr_core: ^0.1.0`) under `dependencies:`, and add local paths under `dependency_overrides:`:

```yaml
dependencies:
  wmr_core: ^0.1.0

dependency_overrides:
  wmr_core:
    path: ../wmr_core
```

**Drawbacks:**
1. **Non-transitive overrides:** Pub ignores `dependency_overrides` from downstream dependencies. If `wmr_companion` depends on `wmr_core`, and `wmr_core` depends on `wmr_fusion`, overriding `wmr_core` in `wmr_companion` does *not* automatically override `wmr_fusion`. Every consumer (`wmr_companion`, `wmr_ble`, `wmr_companion_ui`, `wmr_companion_hid_android`, `example/`, and `wmr_companion_app`) must manually replicate the entire transitive override closure.
2. **Leaky configuration:** `dependency_overrides` can accidentally be committed into published package archives. While pub.dev ignores overrides when other packages import them, pub issuance flags them with hints or warnings during `dart pub publish --dry-run`.
3. **No coordinated lockfile:** Each package and example maintains its own independent resolution and lockfile, allowing dependency skew across the repository.

### Evaluation: Dart `pub workspace`

Introduced in Dart 3.5, pub workspaces provide first-class monorepo support. The repository root defines the workspace member directories, and each member opts in with `resolution: workspace`:

```yaml
# Root pubspec.yaml
name: wmr_companion_workspace
workspace:
  - packages/wmr_fusion
  - packages/wmr_core
  - packages/wmr_companion
  - packages/wmr_ble
  - packages/wmr_companion_ui
  - packages/wmr_companion_hid_android
  - example
```

```yaml
# Member pubspec.yaml (e.g. packages/wmr_core/pubspec.yaml)
name: wmr_core
resolution: workspace

dependencies:
  wmr_fusion: ^0.1.0
```

**Benefits:**
1. **Workspace-native resolution:** When a workspace member specifies a hosted constraint (`wmr_fusion: ^0.1.0`), pub automatically resolves it to the local workspace member directory. No `dependency_overrides` or path juggling is needed.
2. **Seamless transitive resolution:** Any package or app in the workspace automatically resolves all inter-package dependencies locally without duplicating paths.
3. **Single source of truth:** A single shared lockfile at the workspace root ensures identical dependency resolution across all packages and tools.
4. **Publish-ready:** `dart pub publish` natively understands workspaces and strips `resolution: workspace` when creating publication archives.

### Recommendation: Pub Workspace

**Recommendation: Use Dart `pub workspace` for monorepo development.**

`pub workspace` is the standard, declarative approach designed specifically for multi-package repositories. It eliminates manual, non-transitive `dependency_overrides` boilerplate across packages and prevents transitive resolution failures. Once the repository API freeze is completed and the apps/packages are aligned, the entire repository should be structured as a unified pub workspace.

---

## 4. Dependency shape before publication

The five intra-repo dependencies are **hosted version constraints**
(`wmr_fusion: ^0.1.0`, `wmr_core: ^0.1.0`, `wmr_companion: ^0.1.0`), which is
what pub.dev requires. Nothing is published yet, so local development resolves
them through a committed `pubspec_overrides.yaml` in each package:

```yaml
# packages/wmr_core/pubspec_overrides.yaml
dependency_overrides:
  wmr_fusion:
    path: ../wmr_fusion
```

Overrides are **not transitive**, so each file lists the package's whole
internal closure (for example `wmr_companion_ui` overrides `wmr_companion`,
`wmr_core` and `wmr_fusion`). The root app and `example/` do the same for all
six packages. `pubspec_overrides.yaml` is a development-only file: pub uses it
for resolution and leaves it out of the published archive.

This replaced the temporary `invalid_dependency: ignore` analyzer setting that
the first cut of this PR needed. With hosted constraints and the overrides, the
analyzer's "publishable packages can't have path dependencies" warning cannot
fire, so the five `analysis_options.yaml` files no longer hide it.

*Why not a pub workspace?* A workspace is the long-term simplification (one
lockfile, no override boilerplate) and is still the recommendation in §5. It
touches every member pubspec and the app/example resolution, so it is a
follow-up, not part of this publication prep. The override files give the same
build with fewer moving parts today.

### Preparation status

All six packages are prepared for publication:

- `publish_to: none` removed (they are publishable packages now).
- Hosted constraints for every intra-repo dependency, plus local overrides.
- Per-package `LICENSE` (MIT, matching the repo root) and `CHANGELOG.md`.
- `repository:` and `issue_tracker:` pointing at the GitHub repository.
- `dart analyze`, `flutter analyze`, all tests and the app/example builds stay
  green with nothing published.

---

## 5. Publication order

When the owner authorizes publication, no pubspec edits are needed — only the
publish calls, in dependency order:

1. **`wmr_fusion`** (no internal dependencies)
   ```sh
   cd packages/wmr_fusion && dart pub publish
   ```
2. **`wmr_core`** (`wmr_fusion: ^0.1.0`)
   ```sh
   cd packages/wmr_core && dart pub publish
   ```
3. **`wmr_companion`** (`wmr_core: ^0.1.0`)
   ```sh
   cd packages/wmr_companion && dart pub publish
   ```
4. **`wmr_ble`** (`wmr_core: ^0.1.0`), then **`wmr_companion_ui`** and
   **`wmr_companion_hid_android`** (`wmr_companion: ^0.1.0`)
   ```sh
   cd packages/wmr_ble && flutter pub publish
   cd packages/wmr_companion_ui && flutter pub publish
   cd packages/wmr_companion_hid_android && flutter pub publish
   ```

After each upload, confirm the version is indexed before publishing the next
wave. Optional follow-up: replace the per-package override files with a root
`workspace:` configuration once the published versions make the path overrides
unnecessary.

---

## 6. CI Dry-Run Verification

The CI workflow (`.github/workflows/ci.yml`) runs `dart pub publish --dry-run` across all six packages:
- `packages/wmr_fusion` has no inter-package path dependencies and passes dry-run validation strictly with zero errors and zero warnings.
- `packages/wmr_core`, `packages/wmr_companion`, `packages/wmr_ble`, `packages/wmr_companion_ui`, and `packages/wmr_companion_hid_android` report path dependency errors during `--dry-run` because their sister packages are not yet published. The CI step allows them to fail soft with a reference to this document, ensuring that any other packaging issues (missing license, invalid metadata, syntax errors) are surfaced without breaking CI before the first publish.
