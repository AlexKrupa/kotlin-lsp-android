import java.io.File
import java.util.concurrent.TimeUnit
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class ScriptModelTest : FixtureBuildTest() {

    private class Script(
        val sourcePath: List<String>,
        val implicitImports: List<String>,
        val pluginClasses: Map<String, String>,
    )

    private class ClientResult(val exitCode: Int, val output: String, val modelFile: File)

    private val scriptModel = File(System.getProperty("scriptModel"))

    /** Gradle reports real paths, and the temp folder is a symbolic link on macOS. */
    private fun copyFixtureWithRealPath(name: String): File = copyFixture(name).canonicalFile

    private fun startClient(root: File, gradleHome: String): ClientResult {
        val modelFile = File(tempDir, "out/library-sources/gradle-scripts.json")
        val process = ProcessBuilder(
            "java", "-cp", "$gradleHome/lib/*", scriptModel.absolutePath,
            root.absolutePath, gradleHome, modelFile.absolutePath,
        )
            .redirectErrorStream(true)
            .apply { environment()["GRADLE_USER_HOME"] = testKitDir.absolutePath }
            .start()
        val output = process.inputStream.bufferedReader().readText()
        assertTrue(process.waitFor(5, TimeUnit.MINUTES), "The client did not end")
        return ClientResult(process.exitValue(), output, modelFile)
    }

    /** Runs the init script, which downloads the plugins and writes the Gradle home. */
    private fun gradleHomeOf(projectDir: File): String {
        val outputDir = File(tempDir, "out")
        runInitScript(projectDir, outputDir)
        return File(outputDir, "library-sources/gradle-home.txt").readText()
    }

    private fun runClient(projectDir: File): JsonObject {
        val result = startClient(projectDir, gradleHomeOf(projectDir))

        assertEquals(0, result.exitCode, result.output)
        return Json.parseToJsonElement(result.modelFile.readText()).jsonObject
    }

    private fun JsonObject.rawScript(file: File): JsonObject =
        getValue("scripts").jsonObject.getValue(file.absolutePath).jsonObject

    private fun JsonObject.list(index: Int): List<String> =
        getValue("lists").jsonArray[index].jsonArray.map { it.jsonPrimitive.content }

    private fun JsonObject.script(file: File): Script {
        val raw = rawScript(file)
        return Script(
            sourcePath = list(raw.getValue("sourcePath").jsonPrimitive.content.toInt()),
            implicitImports = list(raw.getValue("implicitImports").jsonPrimitive.content.toInt()),
            pluginClasses = raw.getValue("pluginClasses").jsonObject
                .mapValues { it.value.jsonPrimitive.content },
        )
    }

    @Test
    fun writesSourcePathImportsAndPluginClassesOfEachScript() {
        val projectDir = copyFixtureWithRealPath("jvm-only")
        val model = runClient(projectDir)

        val script = model.script(File(projectDir, "build.gradle.kts"))

        assertTrue(script.implicitImports.contains("org.gradle.kotlin.dsl.*"))
        assertTrue(script.sourcePath.any { it.endsWith("-sources.jar") || "accessors" in it }, script.sourcePath.toString())
        assertEquals(
            "org.jetbrains.kotlin.gradle.plugin.KotlinPluginWrapper",
            script.pluginClasses["org.jetbrains.kotlin.jvm"],
        )
        assertTrue(model.script(File(projectDir, "settings.gradle.kts")).implicitImports.isNotEmpty())
    }

    @Test
    fun writesSameListOnceForScriptsThatShareIt() {
        val projectDir = copyFixtureWithRealPath("android")
        val model = runClient(projectDir)

        val indexes = listOf("app", "lib").map {
            model.rawScript(File(projectDir, "$it/build.gradle.kts")).getValue("implicitImports")
        }

        assertEquals(indexes[0], indexes[1])
        val lists = model.getValue("lists").jsonArray
        assertEquals(lists.size, lists.toSet().size)
    }

    @Test
    fun writesPluginClassOfIncludedBuild() {
        val projectDir = copyFixtureWithRealPath("included")
        val model = runClient(projectDir)

        val script = model.script(File(projectDir, "build.gradle.kts"))

        assertEquals("ConventionPlugin", script.pluginClasses["fixture.convention"])
    }

    @Test
    fun writesModelWhenScriptHasCompileError() {
        val projectDir = copyFixtureWithRealPath("jvm-only")
        val gradleHome = gradleHomeOf(projectDir)
        val buildFile = File(projectDir, "build.gradle.kts")
        buildFile.appendText("\nnotDeclared(\n")

        val result = startClient(projectDir, gradleHome)

        assertEquals(0, result.exitCode, result.output)
        val model = Json.parseToJsonElement(result.modelFile.readText()).jsonObject
        assertTrue(model.script(buildFile).implicitImports.isNotEmpty())
    }

    @Test
    fun exitsWithOneAndWritesCauseWhenModelFails() {
        val gradleHome = gradleHomeOf(copyFixture("jvm-only"))
        val missingRoot = File(tempDir, "missing")

        val result = startClient(missingRoot, gradleHome)

        assertEquals(1, result.exitCode, result.output)
        assertTrue("missing" in result.output, result.output)
        assertTrue(!result.modelFile.exists())
    }
}
