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
    // Unify JVM target across Flutter plugin subprojects (which ship their own
    // build.gradle with varying Java/Kotlin targets — e.g. Java 1.8 vs Kotlin
    // 21 — that AGP 8 / Kotlin 2 reject as "Inconsistent JVM Target
    // Compatibility"). Only the Android *library* plugins are touched, so the
    // :app module (com.android.application) keeps its own config from
    // app/build.gradle.kts. We use withId during plugin application rather
    // than afterEvaluate because evaluationDependsOn(":app") above already
    // finalizes some values by the time afterEvaluate would run.
    project.plugins.withId("com.android.library") {
        extensions.getByType<com.android.build.gradle.LibraryExtension>().compileOptions {
            sourceCompatibility = JavaVersion.VERSION_17
            targetCompatibility = JavaVersion.VERSION_17
        }
    }
    project.plugins.withId("org.jetbrains.kotlin.android") {
        tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
            compilerOptions {
                jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
