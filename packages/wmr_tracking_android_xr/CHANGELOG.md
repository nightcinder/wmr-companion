# Changelog

## Unreleased

- Migrate the Android plugin to AGP 9 built-in Kotlin: drop the Kotlin Gradle Plugin classpath and `org.jetbrains.kotlin.android`, and require Flutter 3.44 or later.

## 0.2.2

- Version aligned with the v0.2.2 release; `wmr_tracking` constraint raised to `^0.2.2`. No breaking public API change.

## 0.2.1

- Version aligned with the v0.2.1 gate and harness release; `wmr_tracking` constraint raised to `^0.2.1`. No breaking public API change.

## 0.2.0

- Version aligned with the v0.2.0 release; no breaking public API change.

## 0.1.0

- Add the default-off Android XR head and 26-joint hand `TrackingSource`.
- Add the Kotlin ARCore for Jetpack XR session, permissions, typed failures and
  OpenXR joint-name mapping.
