# Publishing

Status: **phase 8 prepared, nothing published.** Every package still has
`publish_to: none` and the app/example depend on them by path. This page records
the frozen public surface, the checks that guard packaging, and what happens if
the owner approves publishing to pub.dev.

The plan's open decision §13 (publish intent) is **not** settled by preparing
this page. `dart pub publish` must not run, and `publish_to: none` must not be
removed, without an explicit owner approval.

## Frozen surface (0.1.0)

These are the entry points a host may import. Everything under `lib/src/` is
internal. Semver applies from here: before 1.0, a breaking change bumps the
minor version (`0.1.x` → `0.2.0`) and anything else bumps the patch. The app and
example are not published and can change freely.

| Package | Version | Public entry points | Internal deps |
| --- | --- | --- | --- |
| `wmr_fusion` | 0.1.0 | `package:wmr_fusion/wmr_fusion.dart` | — |
| `wmr_core` | 0.1.0 | `package:wmr_core/...` (protocol, domain, services, `ble/ble_transport.dart`); no barrel by design | `wmr_fusion` |
| `wmr_ble` | 0.1.0 | `package:wmr_ble/wmr_ble.dart`, `package:wmr_ble/testing.dart` | `wmr_core` |
| `wmr_companion` | 0.1.0 | `package:wmr_companion/wmr_companion.dart`, `package:wmr_companion/testing.dart` | `wmr_core` |
| `wmr_companion_ui` | 0.1.0 | `package:wmr_companion_ui/wmr_companion_ui.dart` | `wmr_companion` |
| `wmr_companion_hid_android` | 0.1.0 | `package:wmr_companion_hid_android/wmr_companion_hid_android.dart` | `wmr_companion` |

Frozen shapes worth calling out:

- `WmrCompanion` lifecycle and streams, `WmrCompanionConfig`, `Hand`,
  `WmrConnectionState`, `WmrBridgeDevice`, `WmrControllerUpdate`,
  `WmrHandStats`, `WmrLinkSnapshot` and the `WmrException` hierarchy.
- `BleTransport`/`MonotonicClock` in `wmr_core` and the `BleAdapter` seam plus
  `BleAppLifecycle` in `wmr_ble`.
- The optional packages never become required by `wmr_companion`.

The READMEs and CHANGELOGs are part of the surface: the README example is
compiled by `packages/wmr_companion/test/readme_example_test.dart`, and
`example/` is the gallery a new host can copy.

### Deprecation policy

- A public symbol is deprecated with a `@Deprecated` annotation and a
  CHANGELOG entry that names the replacement and the release that removes it.
- A deprecated symbol stays for at least one minor release (for example
  deprecated in `0.2.0`, removed no earlier than `0.3.0`).
- Renames keep a deprecated forwarding alias for that window.
- A removal without a deprecation window is a breaking change and follows the
  same minor-version rule as any other break before 1.0.

## What is checked now

Both scripts are wired into CI (`publish-check` job) and can be run locally:

```sh
./tool/publish_dry_run.sh   # staged `dart pub publish --dry-run` for every package
./tool/fresh_app_check.sh   # a brand-new Flutter app consumes and reads gamepad state
```

`publish_dry_run.sh` refuses to run if any package lost its `publish_to: none`
gate. It copies each package to a temporary directory, drops `publish_to: none`
there only, rewrites internal `path:` dependencies to `^0.1.0` and adds
`pubspec_overrides.yaml` for local resolution. All six packages currently show
**0 warnings**; the only hints are the expected override notices.

`fresh_app_check.sh` runs `flutter create`, adds the four host-facing packages
by path, reads a gamepad frame through `FakeTransport` and checks that the
optional BLE, UI and HID entry points import. It is the "a fresh app can add the
package and read gamepad state" acceptance without publishing anything.

Not covered by either script: a real pub.dev upload, a hosted-version install
(impossible before publishing), Android/iOS device runs, and the pub.dev
scorecard (it also needs the published package).

## If the owner approves publishing

1. Record the approval on ONY-41 and decide the open §13 items (names and
   publishing intent). The names below are prepared, not approved.
2. Remove `publish_to: none` from the packages in dependency order and replace
   internal `path:` dependencies with hosted constraints:
   `wmr_fusion` → `wmr_core` → `wmr_companion` → `wmr_ble` (needs `wmr_core`),
   `wmr_companion_ui` and `wmr_companion_hid_android` (need `wmr_companion`).
3. Run `dart pub publish --dry-run` per package, then `dart pub publish` in the
   same order.
4. Switch the app and `example/` to hosted constraints in a follow-up PR and
   rerun the fresh-app check against pub.dev.
5. Update this page and `docs/LIBRARY.md` §9 with the published versions.

Publishing is irreversible in practice: a version can be retracted but not
deleted, so the dry-run and the fresh-app check are gates, not ceremony.

## Licensing and non-negotiables

- Every package is MIT and ships its own `LICENSE` file.
- The Monado XOR key table is never committed or published. The host supplies
  the key bytes and carries the BSL-1.0 notice.
- The bridge firmware is a separate BTstack-derived project with its own
  non-commercial terms. No package redistributes firmware; the READMEs say so.
- `publish_to: none` stays until the owner approves publishing.
