// Public release builds must not resolve the internal development distributor.
// Existing debug/development workflows retain the plugin unless explicitly disabled.
buildscript {
    if (providers.gradleProperty("sloopworksInternalTools").orNull != "false") {
        repositories { mavenLocal() }
        dependencies { classpath("works.sloop.shipyard.deploy:works.sloop.shipyard.deploy.gradle.plugin:0.1.0") }
    }
}

plugins {
    id("com.android.application") version "8.13.2" apply false
    id("org.jetbrains.kotlin.android") version "2.3.21" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.3.21" apply false
}
