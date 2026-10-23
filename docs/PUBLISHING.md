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

## 4. Pre-Publication Status & Path Dependency Retention

### Why Path Dependencies Are Retained Now

In accordance with scope item 6 of ONY-59:
> *"Convert the inter-package path: deps to hosted constraints only if your chosen mechanism in (5) keeps flutter pub get, flutter analyze and flutter test green for the repo, the packages and example/ with nothing published yet. If it cannot, leave the path deps in place, say so explicitly in docs/PUBLISHING.md, and list it as the one remaining step before the first publish. Do not break the build to look finished."*

Because **none of the packages are published to pub.dev yet**:
1. If `wmr_core` declared `wmr_fusion: ^0.1.0` (hosted) without workspace configuration, `dart pub get` would fail with a 404 error (`could not find package wmr_fusion at https://pub.dev`).
2. Even with `dependency_overrides` in `wmr_core`, `wmr_companion`'s `pub get` fails because `dependency_overrides` are non-transitive; `wmr_companion` would require an override for `wmr_fusion` as well.
3. Downstream packages such as `packages/wmr_companion_ui`, `packages/wmr_companion_hid_android`, and `example/` would immediately break without extensive, coordinated modifications across all subdirectories.
4. Converting to a pub workspace requires modifying all member pubspecs (including `packages/wmr_companion_ui`, `packages/wmr_companion_hid_android`, and the root app) to add `resolution: workspace`, which violates the boundary constraints of ONY-59.

**Status:** The inter-package `path:` dependencies (`path: ../wmr_fusion`, `path: ../wmr_core`, `path: ../wmr_companion`) are **intentionally left in place** in `wmr_core`, `wmr_companion`, `wmr_ble`, `wmr_companion_ui`, and `wmr_companion_hid_android`.

All six packages have been fully prepared for publication:
- `publish_to: none` has been removed from all six packages.
- Each package contains its own `LICENSE` file matching the root MIT license.
- Each package contains a `CHANGELOG.md` with an honest `0.1.0` entry.
- Each package specifies `repository:` and `issue_tracker:` pointing to the GitHub repository.

---

## 5. The One Remaining Step Before First Publish

When the owner authorizes publication (after the API freeze):

1. **Publish `wmr_fusion`:**
   ```sh
   cd packages/wmr_fusion
   dart pub publish
   ```
2. **Update and publish `wmr_core`:**
   - In `packages/wmr_core/pubspec.yaml`, replace:
     ```yaml
     wmr_fusion:
       path: ../wmr_fusion
     ```
     with:
     ```yaml
     wmr_fusion: ^0.1.0
     ```
   - Publish:
     ```sh
     cd packages/wmr_core
     dart pub publish
     ```
3. **Update and publish `wmr_companion`:**
   - In `packages/wmr_companion/pubspec.yaml`, replace `path: ../wmr_core` with `wmr_core: ^0.1.0`.
   - Publish:
     ```sh
     cd packages/wmr_companion
     dart pub publish
     ```
4. **Update and publish `wmr_ble`, `wmr_companion_ui`, and `wmr_companion_hid_android`:**
   - In `packages/wmr_ble/pubspec.yaml`, replace `path: ../wmr_core` with `wmr_core: ^0.1.0`.
   - In `packages/wmr_companion_ui/pubspec.yaml`, replace `path: ../wmr_companion` with `wmr_companion: ^0.1.0`.
   - In `packages/wmr_companion_hid_android/pubspec.yaml`, replace `path: ../wmr_companion` with `wmr_companion: ^0.1.0`.
   - Publish all three:
     ```sh
     cd packages/wmr_ble && flutter pub publish
     cd packages/wmr_companion_ui && flutter pub publish
     cd packages/wmr_companion_hid_android && flutter pub publish
     ```
5. **Configure workspace:**
   - Convert the repository to a root `workspace:` configuration so local development seamlessly resolves inter-package dependencies without path dependencies.

---

## 6. CI Dry-Run Verification

The CI workflow (`.github/workflows/ci.yml`) runs `dart pub publish --dry-run` across all six packages:
- `packages/wmr_fusion` has no inter-package path dependencies and passes dry-run validation strictly with zero errors and zero warnings.
- `packages/wmr_core`, `packages/wmr_companion`, `packages/wmr_ble`, `packages/wmr_companion_ui`, and `packages/wmr_companion_hid_android` report path dependency errors during `--dry-run` because their sister packages are not yet published. The CI step allows them to fail soft with a reference to this document, ensuring that any other packaging issues (missing license, invalid metadata, syntax errors) are surfaced without breaking CI before the first publish.
