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
