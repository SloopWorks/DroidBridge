plugins { id("com.android.application"); id("org.jetbrains.kotlin.android") }
android {
 namespace = "dev.droidbridge.peerattack"
 compileSdk = 35
 defaultConfig { applicationId = "dev.droidbridge.peerattack"; minSdk = 33; targetSdk = 35; versionCode = 1; versionName = "1" }
 compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
}
kotlin { compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) } }
