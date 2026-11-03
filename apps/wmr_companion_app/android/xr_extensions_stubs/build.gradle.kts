// Compile-only stubs for the Android XR extension API that the device provides
// from its shared library. The app never packages these classes: see
// app/build.gradle.kts. They exist so R8 can resolve the SAM interfaces at
// build time.
plugins {
    id("java-library")
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}
