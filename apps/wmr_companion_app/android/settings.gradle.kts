pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.1.0" apply false
    // Built-in Kotlin takes its Kotlin compiler from AGP's KGP runtime
    // dependency; this pins that dependency above AGP 9.1.0's bundled
    // 2.2.10, which Flutter 3.47 rejects. KGP is not applied to any module.
    id("org.jetbrains.kotlin.android") version "2.4.0" apply false
}

include(":app")

// Compile-only stubs of the Android XR extension API. The device supplies the
// real classes at run time; the app only needs them on the R8 classpath so the
// androidx.xr callbacks survive shrinking (ONY-758).
include(":xr_extensions_stubs")
project(":xr_extensions_stubs").projectDir = file("xr_extensions_stubs")

// Optional Unity-as-a-Library module (ONY-271, ONY-355). Export `unityLibrary`
// from `packages/wmr_tracking_unity/unity` and copy it to the gitignored
// `android/unity/unified/unityLibrary` path. A missing export is not an error:
// the flavor still builds and the Dart sources report `unavailable`.
//
// The per-vendor exports and flavors are retired (ONY-565); only the unified
// APK ships. A leftover export from the old layout fails configuration so a
// stale checkout cannot silently keep it around.
listOf("viture", "xreal").forEach { vendor ->
    check(!file("unity/$vendor").exists()) {
        "android/unity/$vendor is a retired per-vendor Unity export (ONY-565). " +
            "Remove it; the unified APK links android/unity/unified/unityLibrary."
    }
}

val unifiedUnityLibrary = file("unity/unified/unityLibrary")
if (unifiedUnityLibrary.isDirectory) {
    val module = ":unityLibraryUnified"
    include(module)
    project(module).projectDir = unifiedUnityLibrary
    // Unity's Android export can carry a nested XR manifest library. The export
    // references it as `:unityLibrary:xrmanifest.androidlib`, which
    // tool/install_unity_export.sh remaps to this module. Include it when
    // present so the manifest still merges into the app (ONY-388).
    val xrManifestLibrary = File(unifiedUnityLibrary, "xrmanifest.androidlib")
    if (xrManifestLibrary.isDirectory) {
        include("$module:xrmanifest.androidlib")
        project("$module:xrmanifest.androidlib").projectDir = xrManifestLibrary
    }
}
