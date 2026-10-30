import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing (ONY-492). The project-owned keystore never lives in git:
// key.properties is gitignored and CI can supply the same values through
// WMR_RELEASE_* environment variables. A release build without them fails in
// the task-graph check below; debug builds keep the Android debug key.
val releaseKeystoreProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.isFile) {
        file.inputStream().use { load(it) }
    }
}

fun releaseSigningValue(key: String, env: String): String? =
    releaseKeystoreProperties.getProperty(key) ?: System.getenv(env)

val releaseStoreFile = releaseSigningValue("storeFile", "WMR_RELEASE_STORE_FILE")
val releaseStorePassword =
    releaseSigningValue("storePassword", "WMR_RELEASE_STORE_PASSWORD")
val releaseKeyAlias = releaseSigningValue("keyAlias", "WMR_RELEASE_KEY_ALIAS")
val releaseKeyPassword =
    releaseSigningValue("keyPassword", "WMR_RELEASE_KEY_PASSWORD")
val releaseSigningProperties = listOf(
    "storeFile" to releaseStoreFile,
    "storePassword" to releaseStorePassword,
    "keyAlias" to releaseKeyAlias,
    "keyPassword" to releaseKeyPassword,
)
val missingReleaseSigningProperties =
    releaseSigningProperties.filter { it.second.isNullOrBlank() }.map { it.first }

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

    signingConfigs {
        if (missingReleaseSigningProperties.isEmpty()) {
            create("release") {
                storeFile = file(releaseStoreFile!!)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        debug {
            // Local debug runs and `tool/test_flavor_wiring.sh` keep using the
            // throwaway Android debug key (ONY-492).
            signingConfig = signingConfigs.getByName("debug")
        }
        release {
            // Null when key.properties/env is missing; the task-graph check
            // below refuses to produce an unsigned or debug-signed release.
            signingConfig = signingConfigs.findByName("release")
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    // Only the unified APK ships. `base` remains for emulator and BLE/3DoF
    // development and links no Unity at all; `unified` links the shared
    // unityLibrary exported from packages/wmr_tracking_unity and selects a
    // vendor at runtime. The retired per-vendor flavors are gone (ONY-565).
    flavorDimensions += "vendor"
    productFlavors {
        create("base") {
            dimension = "vendor"
        }
        create("unified") {
            dimension = "vendor"
            // VITURE 0.9.0's VitureUnityXR.aar declares minSdk 33, and the
            // unified export links it alongside XREAL. `base` stays on
            // Flutter's default (ONY-388).
            minSdk = 33
        }
    }

    packaging {
        jniLibs {
            // Flutter's debug engine and the VITURE 0.9.0 AAR both ship this
            // Vulkan validation layer. Keeping either copy is enough; the
            // layer is not loaded unless validation is requested (ONY-388).
            pickFirsts += "**/libVkLayer_khronos_validation.so"
        }
    }
}

// A release build must never silently fall back to the debug key. Debug builds
// keep working without any project keystore (ONY-492).
gradle.taskGraph.whenReady {
    val buildsRelease = allTasks.any { it.name.contains("Release") }
    if (buildsRelease && android.signingConfigs.findByName("release") == null) {
        throw GradleException(
            "Release signing is not configured. Create " +
                "apps/wmr_companion_app/android/key.properties with storeFile, " +
                "storePassword, keyAlias and keyPassword, or set " +
                "WMR_RELEASE_STORE_FILE, WMR_RELEASE_STORE_PASSWORD, " +
                "WMR_RELEASE_KEY_ALIAS and WMR_RELEASE_KEY_PASSWORD. " +
                "Missing: ${missingReleaseSigningProperties.joinToString()}. " +
                "See docs/RELEASE_SIGNING.md."
        )
    }
}

dependencies {
    // Only the unified flavor gets the module, so base can never carry Unity.
    // settings.gradle.kts includes the module only when its export exists.
    findProject(":unityLibraryUnified")?.let {
        "unifiedImplementation"(project(":unityLibraryUnified"))
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
