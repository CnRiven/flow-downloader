plugins { id("com.android.application"); id("org.jetbrains.kotlin.android") }

android {
    namespace = "app.flow.downloader"
    compileSdk = 35
    defaultConfig {
        applicationId = "app.flow.downloader"
        minSdk = 29
        targetSdk = 35
        versionCode = 2
        versionName = "1.0.1"
        testInstrumentationRunner = "app.flow.downloader.FlowInstrumentation"
        ndk { abiFilters += listOf("arm64-v8a", "armeabi-v7a", "x86_64") }
    }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    kotlinOptions { jvmTarget = "17" }
    packaging { jniLibs.useLegacyPackaging = true }
    buildTypes { release { isMinifyEnabled = false } }
}

dependencies {
    implementation("io.github.junkfood02.youtubedl-android:library:0.18.1")
    implementation("io.github.junkfood02.youtubedl-android:ffmpeg:0.18.1")
    testImplementation("junit:junit:4.13.2")
}
