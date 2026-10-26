plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.onyxlens.wmr_companion"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.onyxlens.wmr_companion"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    // One APK can carry the Dart flags for every vendor, but only one Unity
    // runtime. `base` links no Unity at all (Android XR, emulator, BLE/3DoF);
    // `viture` and `xreal` link a locally exported unityLibrary when present.
    flavorDimensions += "vendor"
    productFlavors {
        create("base") {
            dimension = "vendor"
        }
        create("viture") {
            dimension = "vendor"
        }
        create("xreal") {
            dimension = "vendor"
        }
    }
}

dependencies {
    // Only the matching flavor gets the module, so base can never carry Unity
    // and the two runtimes can never be linked together. settings.gradle.kts
    // already fails when both exports exist.
    findProject(":unityLibraryViture")?.let {
        "vitureImplementation"(project(":unityLibraryViture"))
    }
    findProject(":unityLibraryXreal")?.let {
        "xrealImplementation"(project(":unityLibraryXreal"))
    }
    check(findProject(":unityLibraryViture") == null || findProject(":unityLibraryXreal") == null) {
        "Cannot link both unityLibrary modules into one APK."
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
