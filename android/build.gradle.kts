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

// mediapipe_face_mesh 默认要求 NDK 26.3，统一指向本机已有的 28.2
subprojects {
    afterEvaluate {
        extensions.findByName("android")?.let { androidExt ->
            val setNdk = androidExt.javaClass.methods.find {
                it.name == "setNdkVersion" && it.parameterCount == 1
            }
            setNdk?.invoke(androidExt, "28.2.13676358")
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
