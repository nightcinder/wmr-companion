import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

// Release signing (ONY-961). The probe ships as a release APK beside the
// companion app. A debug key is minted fresh on every CI runner, so a
// debug-signed probe can never replace one built by an earlier run: Android
// rejects it with INSTALL_FAILED_UPDATE_INCOMPATIBLE. Release builds therefore
// use the project-owned keystore, which is never in git. key.properties is
// gitignored; CI supplies the same values through WMR_RELEASE_* variables.
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
val missingReleaseSigningProperties = listOf(
    "storeFile" to releaseStoreFile,
    "storePassword" to releaseStorePassword,
    "keyAlias" to releaseKeyAlias,
    "keyPassword" to releaseKeyPassword,
).filter { it.second.isNullOrBlank() }.map { it.first }

// A published probe must carry a strictly increasing versionCode or Android
// refuses the update even under the same key. The tag job passes a value
// derived from the release version; local builds keep 1.
val probeVersionCode = (project.findProperty("probeVersionCode") as String?)?.toInt() ?: 1
val probeVersionName = (project.findProperty("probeVersionName") as String?) ?: "1.0"

android {
    namespace = "com.onyxlens.wmr.gattprobe"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.onyxlens.wmr.gattprobe"
        minSdk = 26
        targetSdk = 35
        versionCode = probeVersionCode
        versionName = probeVersionName
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
            // CI artifacts and local builds keep the throwaway Android debug
            // key; they are not the sideloadable release asset.
        }
        release {
            isMinifyEnabled = false
            // No signing config when the project key is absent: Gradle then
            // emits an unsigned APK instead of quietly publishing a debug
            // one. The tag job verifies the certificate before it uploads.
            if (missingReleaseSigningProperties.isEmpty()) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    testOptions {
        unitTests.isReturnDefaultValues = true
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.appcompat:appcompat:1.8.0")
    implementation("com.google.android.material:material:1.14.0")
    implementation("androidx.activity:activity-ktx:1.9.3")

    testImplementation("junit:junit:4.13.2")
}
