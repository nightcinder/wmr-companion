# Publishing `wmr-companion` Packages to pub.dev

This document defines the publication process for the `wmr-companion` multi-package repository, the dependency constraints and publication order, the local-development mechanism, and the exact steps required for the initial `0.1.0` release.

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

---

## 2. Dependency Graph & Publication Order

pub.dev strictly forbids packages from having `path:` dependencies upon publication. Every inter-package dependency is therefore a hosted version constraint (e.g. `wmr_core: ^0.1.0`); the root pub workspace resolves those constraints to the local source while developing (see §3).

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
     - Already declares `wmr_fusion: ^0.1.0`.
     - Publish once `wmr_fusion 0.1.0` is published and indexed on pub.dev.

2. **Wave 2: Public Facade**
   - **Step 2: `packages/wmr_companion`**
     - Already declares `wmr_core: ^0.1.0`.
     - Publish once `wmr_core 0.1.0` is published and indexed on pub.dev.

3. **Wave 3: Platform Transports & Optional Add-ons**
   - **Step 3a: `packages/wmr_ble`**
     - Already declares `wmr_core: ^0.1.0` and depends on the Flutter SDK.
     - Publish once `wmr_core 0.1.0` is indexed.
   - **Step 3b: `packages/wmr_companion_ui`**
     - Already declares `wmr_companion: ^0.1.0` and depends on the Flutter SDK.
     - Publish once `wmr_companion 0.1.0` is indexed.
   - **Step 3c: `packages/wmr_companion_hid_android`**
     - Already declares `wmr_companion: ^0.1.0` and is an Android Flutter plugin.
     - Publish once `wmr_companion 0.1.0` is indexed.

*(Note: Steps 3a, 3b, and 3c are mutually independent and can be published in parallel once Wave 1 and Wave 2 are indexed on pub.dev.)*

---

## 3. Local Development Mechanism: Pub Workspace

When inter-package dependencies became hosted constraints (`^0.1.0`), repository development still had to link to local source code rather than download released artifacts from pub.dev. Two mechanisms exist in the Dart ecosystem: `dependency_overrides` and `pub workspace`.

### Evaluation: `dependency_overrides`

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

### Implemented: Dart `pub workspace`

Introduced in Dart 3.5, pub workspaces provide first-class monorepo support. The repository root defines the workspace member directories, and each member opts in with `resolution: workspace`. This is the mechanism the repository now uses.

The repository root declares the workspace, because it is the common ancestor of
both the packages and the app (app directory moves and `working-directory`
changes do not affect member discovery):

```yaml
# pubspec.yaml (wmr_companion_workspace, publish_to: none)
workspace:
  - apps/wmr_companion_app
  - packages/wmr_fusion
  - packages/wmr_core
  - packages/wmr_companion
  - packages/wmr_ble
  - packages/wmr_companion_ui
  - packages/wmr_companion_hid_android
  - example
```

Each member opts in and declares only hosted constraints:

```yaml
# packages/wmr_core/pubspec.yaml
name: wmr_core
resolution: workspace

dependencies:
  wmr_fusion: ^0.1.0
```

**Benefits, as realised here:**
1. **Workspace-native resolution:** A hosted constraint such as `wmr_fusion: ^0.1.0` resolves to the local workspace member directory. No `dependency_overrides` or path juggling is needed.
2. **Seamless transitive resolution:** Every package, both app hosts and all six packages resolve the whole internal graph locally.
3. **Single source of truth:** One lockfile at the repository root (`pubspec.lock`) replaces the per-package and example locks.
4. **Publish-ready:** `dart pub publish` understands workspaces and the published archive keeps the hosted constraint, not the local path. `resolution: workspace` is workspace metadata and does not make the package depend on the repository layout.

`resolution: workspace` requires language version 3.5 or newer. `wmr_fusion`'s SDK floor was therefore raised from `^3.0.0` to `^3.13.5`, matching the rest of the repository. This is not a behavioural change; the package had no dependency that needed the older floor, and the other five packages already required `^3.13.5`.

---

## 4. Publish-Readiness Status

**Status: landed.** No published package declares a `path:` dependency. The internal dependencies are hosted constraints and the root workspace resolves them locally:

| Package | Internal dependencies |
| --- | --- |
| `wmr_fusion` | none |
| `wmr_core` | `wmr_fusion: ^0.1.0` |
| `wmr_companion` | `wmr_core: ^0.1.0` |
| `wmr_ble` | `wmr_core: ^0.1.0` |
| `wmr_companion_ui` | `wmr_companion: ^0.1.0` |
| `wmr_companion_hid_android` | `wmr_companion: ^0.1.0` |

All six packages are fully prepared for publication:
- `publish_to: none` has been removed from all six packages.
- Each package contains its own `LICENSE` file matching the root MIT license.
- Each package contains a `CHANGELOG.md` with an honest `0.1.0` entry.
- Each package specifies `repository:` and `issue_tracker:` pointing to the GitHub repository.
- Each package has an `export_boundary_test.dart` under `test/` that fails if its `lib/` imports Riverpod, a file plugin, `dart:ui`, or a package above it in the graph. This replaced the hand-written `grep` steps that used to live only in CI.

The two application hosts (`wmr_companion_app` and `example/`) are workspace members with `publish_to: none`; they are not part of the publish set.

---

## 5. First Publication

Publishing is a separate, owner-authorised step. Nothing in the repository publishes automatically, and `dart pub publish --dry-run` uploads nothing.

When the owner authorises publication after the API freeze, publish in the wave order from §2 — **no pubspec edits are required**:

1. **Wave 1:**
   ```sh
   cd packages/wmr_fusion && dart pub publish
   # wait for wmr_fusion 0.1.0 to be indexed on pub.dev
   cd packages/wmr_core && dart pub publish
   ```
2. **Wave 2:**
   ```sh
   cd packages/wmr_companion && dart pub publish
   ```
3. **Wave 3** (order within the wave does not matter):
   ```sh
   cd packages/wmr_ble && flutter pub publish
   cd packages/wmr_companion_ui && flutter pub publish
   cd packages/wmr_companion_hid_android && flutter pub publish
   ```

After the first release, `flutter pub get` in the app and `example/` still resolves the local workspace members, so local development keeps using the working tree. A consumer outside the repository gets the published versions through the same `^0.1.0` constraints.

---

## 6. CI Verification

The CI workflow (`.github/workflows/ci.yml`) is the gate for this document:

- **Strict dry-run for every package in the publish set.** The `pub.dev publish dry-run (every package in the publish set)` step runs `dart pub publish --dry-run` for `wmr_fusion`, `wmr_core`, and `wmr_companion`, and `flutter pub publish --dry-run` for `wmr_ble`, `wmr_companion_ui`, and `wmr_companion_hid_android`. It has no `|| true`: any dry-run error (or warning, which pub reports with a non-zero exit) fails the job. The workspace resolution is what lets the five dependent packages pass before anything is on pub.dev.
- **Export-boundary tests per package.** Each package's test suite includes `test/export_boundary_test.dart`, run by the existing per-package `dart test` / `flutter test` steps. It reads every file under the package's own `lib/` and fails on a forbidden import, so the boundary is checked where the package is developed rather than by a CI-only shell grep.
- **Package tests and analysis.** Each package still runs its own `analyze` and test suite; the app and `example/` run theirs.
- **A fresh app consumes the packages.** `tool/fresh_app_check.sh` creates a throwaway Flutter app, depends on the four host-facing packages by path, connects a `WmrCompanion` to `FakeTransport`, reads a gamepad frame and imports the BLE/UI/HID entry points. It proves the host-facing surface still works for a consumer that is not part of the workspace.

What CI does **not** prove: that the packages upload successfully, that a fresh external app can resolve them from pub.dev (impossible before the first release), the pub score, or anything on hardware. Those are checked after an authorised release, not by a dry-run.
