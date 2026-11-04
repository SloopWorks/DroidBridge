import java.util.Properties
import java.io.File

plugins { id("com.android.application"); id("org.jetbrains.kotlin.android"); id("org.jetbrains.kotlin.plugin.compose") }
if (providers.gradleProperty("sloopworksInternalTools").orNull != "false") {
    apply(plugin = "works.sloop.shipyard.deploy")
} else if (gradle.startParameter.taskNames.any { it.contains("development", ignoreCase = true) }) {
    throw GradleException("Development distribution requires sloopworksInternalTools=true")
}
android {
    namespace = "dev.droidbridge.companion"
    compileSdk = 37
    testBuildType = System.getenv("DROIDBRIDGE_TEST_BUILD_TYPE") ?: "debug"
    defaultConfig {
        applicationId = "dev.droidbridge.companion"
        minSdk = 33
        targetSdk = 35
        versionCode = 13
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
    buildTypes.create("development") {
        initWith(buildTypes.getByName("debug"))
        applicationIdSuffix = ".dev"
        matchingFallbacks += "debug"
    }
    sourceSets.getByName("development") {
        java.srcDir("src/debug/java")
        manifest.srcFile("src/debug/AndroidManifest.xml")
    }
    sourceSets.maybeCreate("androidTestDevelopment").java.srcDir("src/androidTestDebug/java")
    buildFeatures { compose = true; buildConfig = true }
    compileOptions { isCoreLibraryDesugaringEnabled = true; sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    testOptions { unitTests.isReturnDefaultValues = true }
}
dependencies { implementation("com.google.zxing:core:3.5.3"); testImplementation("junit:junit:4.13.2"); androidTestImplementation("androidx.test:runner:1.7.0"); androidTestImplementation("androidx.test.ext:junit:1.3.0") }

kotlin { compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) } }

dependencies { coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5") }

// Local diagnostics are intentionally absent from every release runtime graph.
dependencies {
    implementation("com.google.android.material:material:1.13.0")
    implementation("androidx.activity:activity:1.11.0")
    releaseCompileOnly("org.jetbrains.compose.runtime:runtime:1.11.1")
    androidTestCompileOnly("org.jetbrains.compose.runtime:runtime:1.11.1")
    testCompileOnly("org.jetbrains.compose.runtime:runtime:1.11.1")
    debugImplementation("androidx.activity:activity-compose:1.11.0")
    debugImplementation("com.sloopworks.debugdrawer:debugdrawer:0.1.1")
    debugImplementation("com.sloopworks.debugdrawer:debugdrawer-swip:0.1.1")
    debugImplementation("works.sloop.swip:swip-core:0.1.12")
    debugImplementation("works.sloop.swip:swip-debug:0.1.1")
    debugImplementation("org.jetbrains.compose.material3:material3:1.9.0")
    add("developmentImplementation", "androidx.activity:activity-compose:1.11.0")
    add("developmentImplementation", "com.sloopworks.debugdrawer:debugdrawer:0.1.1")
    add("developmentImplementation", "com.sloopworks.debugdrawer:debugdrawer-swip:0.1.1")
    add("developmentImplementation", "works.sloop.swip:swip-core:0.1.12")
    add("developmentImplementation", "works.sloop.swip:swip-debug:0.1.1")
    add("developmentImplementation", "org.jetbrains.compose.material3:material3:1.9.0")
}
