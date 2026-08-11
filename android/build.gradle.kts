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

    // tflite_flutter 0.12.1 的 Java 源码目标是 11；新版 Kotlin 工具链会
    // 默认继承宿主 JDK 21，仅对该子工程对齐，不改动主应用的 Java 17。
    if (project.name == "tflite_flutter") {
        tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
            compilerOptions.jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_11)
        }
    }
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
