plugins {
    kotlin("jvm") version "2.3.0"
}

repositories {
    mavenCentral()
}

dependencies {
    testImplementation(gradleTestKit())
    testImplementation(platform("org.junit:junit-bom:5.13.4"))
    testImplementation("org.junit.jupiter:junit-jupiter")
    testImplementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.8.1")
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
}

val initScript = layout.projectDirectory.file("../gradle/lsp-library-sources.gradle")
val fixtures = layout.projectDirectory.dir("fixtures")

tasks.test {
    useJUnitPlatform()
    inputs.file(initScript).withPathSensitivity(PathSensitivity.RELATIVE)
    inputs.dir(fixtures).withPathSensitivity(PathSensitivity.RELATIVE)
    systemProperty("initScript", initScript.asFile.absolutePath)
    systemProperty("fixtures", fixtures.asFile.absolutePath)
    // Outside of the temp dirs of the tests, so that the downloads of the fixture builds stay
    // between test runs.
    systemProperty("testKitDir", layout.buildDirectory.dir("testkit").get().asFile.absolutePath)
    testLogging {
        events("failed")
        exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
    }
}
