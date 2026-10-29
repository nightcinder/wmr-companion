# Toolchain

## Built-in Kotlin (ONY-521)

The five Android plugins — `wmr_companion_hid_android`,
`wmr_tracking_android_xr`, `wmr_tracking_dispatch`, `wmr_tracking_viture` and
`wmr_tracking_xreal` — no longer apply the Kotlin Gradle Plugin (KGP). Their
Gradle modules compile Kotlin through AGP 9's built-in Kotlin, and their
`pubspec.yaml` files require Flutter 3.44 or later.

`apps/wmr_companion_app/android/gradle.properties` and
`example/android/gradle.properties` set `android.builtInKotlin=true`. Both
settings files still declare `org.jetbrains.kotlin.android` version 2.4.0 with
`apply false`. That declaration only selects the KGP runtime that AGP's
built-in Kotlin uses: AGP 9.1.0 bundles Kotlin 2.2.10, below Flutter 3.47's
2.2.20 minimum, and AGP documents a higher KGP classpath version as the way to
upgrade that compiler. The plugin is not applied, so it is not a KGP migration
regression. Remove the pin once the pinned AGP bundles a new-enough Kotlin.

This is why `android.newDsl` stays `false`: the new AGP DSL is a separate
migration, and the build has not adopted it.

## Dependency review (ONY-521)

Reviewed `flutter pub outdated` on 2026-10-29. Eleven packages are behind.
None of them is needed by the built-in Kotlin migration, so this task upgrades
none of them; every entry below is deliberately left alone.

| Package | Current | Latest | Why left alone |
| --- | --- | --- | --- |
| `analyzer` | 13.3.0 | 14.7.0 | Pinned transitively by the Flutter/Dart SDK toolchain; not resolvable inside the current constraints. |
| `_fe_analyzer_shared` | 103.0.0 | 111.0.0 | Pinned by `analyzer`; moves only with the SDK. |
| `test` | 1.31.1 | 1.33.0 | Dev dependency held by the current Dart/Flutter SDK; not resolvable. |
| `test_api` | 0.7.12 | 0.7.15 | Pinned by `test`/the SDK; not resolvable. |
| `test_core` | 0.6.18 | 0.6.21 | Pinned by `test`; not resolvable. |
| `package_config` | 2.2.0 | 3.0.0 | Pinned by the test toolchain; a major bump is out of scope. |
| `vector_math` | 2.4.3 | 2.4.4 | Direct dependency; the patch is resolvable but unrelated to this migration. |
| `crypto` | 3.0.7 | 3.0.8 | Transitive patch; resolvable but unrelated. |
| `jni` | 1.1.0 | 1.1.1 | Transitive patch; resolvable but unrelated. |
| `cross_file` | 0.3.5+5 | 0.4.0 | Held by current constraints; a major bump is out of scope. |
| `material_color_utilities` | 0.13.0 | 0.13.1 | Held by current constraints; cosmetic only. |

`pubspec.lock` changes only in its Flutter minimum (`>=3.38.4` to `>=3.44.0`)
because the five plugins now declare Flutter 3.44.

## GitHub Actions runtime

The workflows use Node 24 action majors: `actions/checkout@v7`,
`actions/setup-java@v6`, `actions/upload-artifact@v7`, `actions/cache@v6`,
`gradle/actions/setup-gradle@v6`, `dorny/paths-filter@v4`,
`actions/setup-dotnet@v6` and `subosito/flutter-action@v2` (composite,
current major). Only action versions changed; no workflow inputs, jobs or
steps were altered.
