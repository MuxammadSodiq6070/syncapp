allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

subprojects {
    val p = this
    val configureSdk = {
        val androidExt = p.extensions.findByName("android")
        if (androidExt is com.android.build.gradle.BaseExtension) {
            val ver = androidExt.compileSdkVersion?.replace("android-", "")?.toIntOrNull() ?: 0
            if (ver < 34) {
                androidExt.compileSdkVersion(35)
            }
        }
    }
    if (p.state.executed) {
        configureSdk()
    } else {
        p.afterEvaluate { configureSdk() }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
