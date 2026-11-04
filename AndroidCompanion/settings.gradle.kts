pluginManagement {
    repositories {
        mavenLocal { content { includeGroup("works.sloop.shipyard.deploy"); includeGroup("works.sloop.shipyard") } }
        google(); mavenCentral(); gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google(); mavenCentral()
        providers.gradleProperty("sloopworksLocalMaven").orNull?.let { localRepo ->
            maven {
                url = uri(localRepo)
                content { includeGroup("works.sloop.swip"); includeGroup("com.sloopworks.debugdrawer") }
            }
        }
        for (repo in if (providers.gradleProperty("sloopworksInternalTools").orNull == "false") emptyList() else listOf("swip", "debugdrawer", "sloopworks-ui")) {
            maven {
                url = uri("https://maven.pkg.github.com/SloopWorks/$repo")
                content {
                    includeGroup(when (repo) {
                        "swip" -> "works.sloop.swip"
                        "debugdrawer" -> "com.sloopworks.debugdrawer"
                        else -> "com.sloopworks.ui"
                    })
                }
                credentials {
                    username = System.getenv("GITHUB_ACTOR") ?: providers.gradleProperty("gpr.user").orNull ?: ""
                    password = System.getenv("SLOOPWORKS_PACKAGES_TOKEN") ?: providers.gradleProperty("gpr.token").orNull ?: ""
                }
            }
        }
    }
}
rootProject.name = "DroidBridgeCompanion"
include(":app", ":attacker")
