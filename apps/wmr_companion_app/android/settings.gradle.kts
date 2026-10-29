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

// Optional Unity-as-a-Library modules (ONY-271, ONY-355). Export `unityLibrary`
// from `packages/wmr_tracking_<vendor>/unity` (or the shared
// `packages/wmr_tracking_unity/unity`) and copy it to the gitignored
// `android/unity/<flavor>/unityLibrary` path. A missing export is not an error:
// the flavor still builds and the Dart source reports `unavailable` when asked
// to start. Only one Unity runtime can run in a process, so more than one export
// fails the build instead of silently linking one.
val unityLibraries: Map<String, File> =
    mapOf(
        "viture" to file("unity/viture/unityLibrary"),
        "xreal" to file("unity/xreal/unityLibrary"),
        "unified" to file("unity/unified/unityLibrary"),
    )
val presentUnityLibraries = unityLibraries.filterValues { it.isDirectory }

if (presentUnityLibraries.size > 1) {
    if ("unified" in presentUnityLibraries) {
        throw GradleException(
            "The unified unityLibrary cannot be combined with per-vendor Unity exports. Remove " +
                (presentUnityLibraries.keys - "unified")
                    .joinToString(" and ") { "android/unity/$it/unityLibrary" } +
                ", then rebuild the unified flavor.",
        )
    }
    throw GradleException(
        "Cannot link both Unity libraries into one APK. Remove " +
            presentUnityLibraries.keys.joinToString(" and ") { "android/unity/$it/unityLibrary" } +
            ", then rebuild the flavor that needs the remaining one.",
    )
}

presentUnityLibraries.forEach { (vendor, directory) ->
    val module = ":unityLibrary${vendor.replaceFirstChar { it.uppercase() }}"
    include(module)
    project(module).projectDir = directory
    // Unity's Android export can carry a nested XR manifest library. The export
    // references it as `:unityLibrary:xrmanifest.androidlib`, which
    // tool/install_unity_export.sh remaps to this module. Include it when
    // present so the manifest still merges into the app (ONY-388).
    val xrManifestLibrary = File(directory, "xrmanifest.androidlib")
    if (xrManifestLibrary.isDirectory) {
        include("$module:xrmanifest.androidlib")
        project("$module:xrmanifest.androidlib").projectDir = xrManifestLibrary
    }
}
