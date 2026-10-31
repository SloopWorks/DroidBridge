import java.util.Properties
import java.io.File

plugins { id("com.android.application"); id("org.jetbrains.kotlin.android") }
android {
    namespace = "dev.droidbridge.companion"
    compileSdk = 35
    testBuildType = System.getenv("DROIDBRIDGE_TEST_BUILD_TYPE") ?: "debug"
    defaultConfig {
        applicationId = "dev.droidbridge.companion"
        minSdk = 33
        targetSdk = 35
        versionCode = 12
        versionName = "0.2.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
    val signingPath = System.getenv("DROIDBRIDGE_ANDROID_SIGNING")
    val signingProperties = Properties()
    if (signingPath != null) File(signingPath).inputStream().use { signingProperties.load(it) }
    signingConfigs {
        if (signingPath != null) create("localRelease") {
            storeFile = File(signingProperties.getProperty("store_file"))
            storePassword = signingProperties.getProperty("store_password")
            keyAlias = signingProperties.getProperty("key_alias")
            keyPassword = signingProperties.getProperty("key_password")
        }
    }
    buildTypes { release { isMinifyEnabled = false; if (signingPath != null) signingConfig = signingConfigs.getByName("localRelease") } }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    testOptions { unitTests.isReturnDefaultValues = true }
}
dependencies { implementation("com.google.zxing:core:3.5.3"); testImplementation("junit:junit:4.13.2"); androidTestImplementation("androidx.test:runner:1.7.0"); androidTestImplementation("androidx.test.ext:junit:1.3.0") }

kotlin { compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) } }
