import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.gradle.testkit.runner.BuildResult
import org.gradle.testkit.runner.GradleRunner
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir

class LibrarySourcesTest {

    @TempDir
    lateinit var tempDir: File

    private val initScript = File(System.getProperty("initScript"))
    private val fixtures = File(System.getProperty("fixtures"))
    private val testKitDir = File(System.getProperty("testKitDir"), "LibrarySourcesTest")
    private val androidHome = requireNotNull(System.getenv("ANDROID_HOME")) {
        "Set ANDROID_HOME to the Android SDK folder"
    }

    private fun copyFixture(name: String, target: File = File(tempDir, name)): File {
        File(fixtures, name).copyRecursively(target)
        return target
    }

    private fun runInitScript(
        projectDir: File,
        outputDir: File,
        arguments: List<String> = emptyList(),
        environment: Map<String, String> = emptyMap(),
    ): BuildResult {
        val baseEnvironment = System.getenv() - "LSP_ANDROID_VARIANT"
        return GradleRunner.create()
            .withProjectDir(projectDir)
            .withTestKitDir(testKitDir)
            .withEnvironment(
                baseEnvironment + environment + mapOf(
                    "ANDROID_HOME" to androidHome,
                    "KOTLIN_LSP_ANDROID_OUTPUT" to outputDir.absolutePath,
                )
            )
            .withArguments(listOf("-I", initScript.absolutePath, "lspLibrarySources") + arguments)
            .build()
    }

    private fun readJson(file: File): JsonObject = Json.parseToJsonElement(file.readText()).jsonObject

    private fun selectedVariants(outputDir: File): Map<String, String> =
        readJson(File(outputDir, "variants.json")).getValue("selected").jsonObject
            .mapValues { it.value.jsonPrimitive.content }

    /** Library name to the paths of its `CLASSES` roots. */
    private fun libraryClasses(workspace: JsonObject): Map<String, Set<String>> =
        workspace.getValue("libraries").jsonArray.associate { library ->
            val roots = library.jsonObject.getValue("roots").jsonArray.map { it.jsonObject }
            library.jsonObject.getValue("name").jsonPrimitive.content to roots
                .filter { "type" !in it }
                .map { it.getValue("path").jsonPrimitive.content }
                .toSet()
        }

    private fun workspace(outputDir: File): JsonObject =
        readJson(File(outputDir, "library-sources/workspace.json"))

    @Test
    fun selectsShortestDebugVariantByDefault() {
        val projectDir = copyFixture("android")
        val outputDir = File(tempDir, "out")

        runInitScript(projectDir, outputDir)

        val selected = selectedVariants(outputDir)
        assertEquals("demoDebug", selected[":app"])
        assertEquals("debug", selected[":lib"])
    }

    @Test
    fun selectsVariantFromEnvironment() {
        val projectDir = copyFixture("android")
        val outputDir = File(tempDir, "out")

        runInitScript(projectDir, outputDir, environment = mapOf("LSP_ANDROID_VARIANT" to "prodRelease"))

        val selected = selectedVariants(outputDir)
        assertEquals("prodRelease", selected[":app"])
        assertEquals("debug", selected[":lib"])
    }

    @Test
    fun selectsVariantFromGradleProperty() {
        val projectDir = copyFixture("android")
        val outputDir = File(tempDir, "out")

        runInitScript(projectDir, outputDir, listOf("-Plsp.android.variant=prodDebug"))

        assertEquals("prodDebug", selectedVariants(outputDir)[":app"])
    }

    @Test
    fun listsAllVariants() {
        val projectDir = copyFixture("android")
        val outputDir = File(tempDir, "out")

        runInitScript(projectDir, outputDir)

        val modules = readJson(File(outputDir, "variants.json")).getValue("modules").jsonObject
        val appVariants = modules.getValue(":app").jsonArray.map { it.jsonPrimitive.content }
        assertEquals(setOf("demoDebug", "demoRelease", "prodDebug", "prodRelease"), appVariants.toSet())
    }

    @Test
    fun librariesUseImportJarPaths() {
        val projectDir = copyFixture("android")
        val outputDir = File(tempDir, "out")

        runInitScript(projectDir, outputDir, listOf(":app:writeImportJars", "-Plsp.android.variant=prodDebug"))

        val importJars = File(projectDir, "app/build/import-jars.txt").readLines()
            .map { it.split("\t") }
            .groupBy({ it[0] }, { it[1] })
            .mapValues { it.value.toSet() }
        val libraries = libraryClasses(workspace(outputDir))
        val coreKtx = libraries.getValue("Sources: androidx.core:core-ktx:1.13.1")
        assertTrue(coreKtx.isNotEmpty())
        coreKtx.forEach { path ->
            assertTrue("/transforms/" in path && path.endsWith("/jars/classes.jar"), path)
            assertTrue(File(path).exists(), path)
        }
        importJars.forEach { (coordinate, files) ->
            assertEquals(files, libraries["Sources: $coordinate"], coordinate)
        }
    }

    @Test
    fun libraryNamesHavePrefix() {
        val projectDir = copyFixture("android")
        val outputDir = File(tempDir, "out")

        runInitScript(projectDir, outputDir)

        val workspace = workspace(outputDir)
        val libraryNames = libraryClasses(workspace).keys
        assertTrue(libraryNames.isNotEmpty())
        libraryNames.forEach { assertTrue(it.startsWith("Sources: "), it) }
        val module = workspace.getValue("modules").jsonArray.single().jsonObject
        assertEquals("lsp-library-sources", module.getValue("name").jsonPrimitive.content)
        val dependencyNames = module.getValue("dependencies").jsonArray
            .map { it.jsonObject }
            .filter { it.getValue("type").jsonPrimitive.content == "library" }
            .map { it.getValue("name").jsonPrimitive.content }
        assertEquals(libraryNames, dependencyNames.toSet())
    }

    @Test
    fun writesValidJsonForJvmOnlyBuild() {
        val projectDir = copyFixture("jvm-only")
        val outputDir = File(tempDir, "out")

        runInitScript(projectDir, outputDir)

        assertEquals(emptyMap<String, Set<String>>(), libraryClasses(workspace(outputDir)))
        assertEquals(emptyMap<String, String>(), selectedVariants(outputDir))
    }

    @Test
    fun keepsOldFileWhenResolutionFails() {
        val projectDir = copyFixture("android")
        File(projectDir, "app/build.gradle.kts")
            .appendText("\ndependencies {\n    implementation(\"com.example:missing:1.0\")\n}\n")
        val outputDir = File(tempDir, "out")

        runInitScript(projectDir, outputDir)

        val libraryNames = libraryClasses(workspace(outputDir)).keys
        assertTrue("Sources: androidx.core:core-ktx:1.13.1" in libraryNames, libraryNames.toString())
        assertTrue(libraryNames.none { "com.example:missing" in it }, libraryNames.toString())
    }

    @Test
    fun writesPathsWithSpaces() {
        val parent = File(tempDir, "with space ą")
        val projectDir = copyFixture("android", File(parent, "project"))
        val outputDir = File(parent, "out")

        runInitScript(projectDir, outputDir)

        val workspace = workspace(outputDir)
        val libraryPaths = libraryClasses(workspace).values.flatten()
        assertTrue(libraryPaths.isNotEmpty())
        val contentRoots = workspace.getValue("modules").jsonArray.single().jsonObject
            .getValue("contentRoots").jsonArray
            .map { it.jsonObject.getValue("path").jsonPrimitive.content }
        assertEquals(listOf(File(outputDir, "library-sources/empty").absolutePath), contentRoots)
        (libraryPaths + contentRoots).forEach { assertTrue(File(it).exists(), it) }
    }
}
