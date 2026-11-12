import java.io.File
import org.gradle.testkit.runner.BuildResult
import org.gradle.testkit.runner.GradleRunner
import org.junit.jupiter.api.io.TempDir

/** Base of the tests that run the init script on a copy of a fixture build. */
abstract class FixtureBuildTest {

    @TempDir
    lateinit var tempDir: File

    private val initScript = File(System.getProperty("initScript"))
    private val fixtures = File(System.getProperty("fixtures"))
    protected val testKitDir = File(System.getProperty("testKitDir"))
    /** The version of the wrapper, which TestKit runs. It is a `-bin` distribution with no sources. */
    protected val gradleVersion = "9.7.0"
    protected val androidHome = requireNotNull(System.getenv("ANDROID_HOME")) {
        "Set ANDROID_HOME to the Android SDK folder"
    }

    protected fun copyFixture(name: String, target: File = File(tempDir, name)): File {
        File(fixtures, name).copyRecursively(target)
        return target
    }

    protected fun runInitScript(
        projectDir: File,
        outputDir: File,
        arguments: List<String> = emptyList(),
        environment: Map<String, String> = emptyMap(),
    ): BuildResult {
        // AGP fails when ANDROID_SDK_ROOT and ANDROID_HOME name different SDKs.
        val baseEnvironment = System.getenv() - setOf("LSP_ANDROID_VARIANT", "KOTLIN_LSP_GRADLE_SOURCES", "ANDROID_SDK_ROOT")
        return GradleRunner.create()
            .withProjectDir(projectDir)
            .withTestKitDir(testKitDir)
            .withEnvironment(
                baseEnvironment + mapOf(
                    "ANDROID_HOME" to androidHome,
                    "KOTLIN_LSP_ANDROID_OUTPUT" to outputDir.absolutePath,
                ) + environment
            )
            .withArguments(listOf("-I", initScript.absolutePath, "lspLibrarySources") + arguments)
            .build()
    }
}
