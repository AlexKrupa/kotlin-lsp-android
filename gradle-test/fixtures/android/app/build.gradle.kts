import org.gradle.api.artifacts.component.ModuleComponentIdentifier

plugins {
    id("com.android.application")
}

android {
    namespace = "com.example.app"
    compileSdk = 36
    defaultConfig {
        minSdk = 24
    }
    flavorDimensions += "contentType"
    productFlavors {
        create("demo") {
            dimension = "contentType"
        }
        create("prod") {
            dimension = "contentType"
        }
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    implementation(project(":lib"))
}

// The jar view of the compile classpath, as the import of kotlin-lsp resolves it.
tasks.register("writeImportJars") {
    val artifacts = configurations.getByName("prodDebugCompileClasspath").incoming.artifactView {
        attributes.attribute(Attribute.of("artifactType", String::class.java), "jar")
        componentFilter { it is ModuleComponentIdentifier }
    }.artifacts
    val output = layout.buildDirectory.file("import-jars.txt")
    inputs.files(artifacts.artifactFiles)
    outputs.file(output)
    doLast {
        val lines = artifacts.map { "${it.id.componentIdentifier.displayName}\t${it.file}" }
        output.get().asFile.writeText(lines.joinToString("\n"))
    }
}
