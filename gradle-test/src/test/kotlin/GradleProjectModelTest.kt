import java.io.File
import org.gradle.tooling.GradleConnector
import org.gradle.tooling.model.GradleProject
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class GradleProjectModelTest : FixtureBuildTest() {

    private val initScript = File(System.getProperty("initScript"))

    @Test
    fun buildsModelWithNoTasksWhenTaskFailsAtCreation() {
        val projectDir = copyFixture("jvm-only")
        File(projectDir, "build.gradle.kts").appendText(
            """
            tasks.register("failsAtCreation") { throw IllegalStateException("created") }
            """.trimIndent()
        )

        val model = GradleConnector.newConnector()
            .useGradleVersion(gradleVersion)
            .useGradleUserHomeDir(testKitDir)
            .forProjectDirectory(projectDir)
            .connect()
            .use { connection ->
                connection.model(GradleProject::class.java)
                    .withArguments("-I", initScript.absolutePath)
                    .get()
            }

        assertTrue(model.tasks.isEmpty(), model.tasks.map { it.name }.toString())
    }
}
