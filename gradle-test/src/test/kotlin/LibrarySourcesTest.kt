import java.io.File
import java.nio.file.Files
import java.util.jar.JarEntry
import java.util.jar.JarFile
import java.util.jar.JarOutputStream
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
    /** The version of the wrapper, which TestKit runs. It is a `-bin` distribution with no sources. */
    private val gradleVersion = "9.7.0"
    /** The Kotlin version in the `lib` folder of that Gradle distribution. */
    private val gradleKotlinVersion = "2.4.0"
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

    private fun readJson(file: File): JsonObject = Json.parseToJsonElement(file.readText()).jsonObject

    private fun selectedVariants(outputDir: File): Map<String, String> =
        readJson(File(outputDir, "variants.json")).getValue("selected").jsonObject
            .mapValues { it.value.jsonPrimitive.content }

    /** Library name to the paths of its roots of [type]. `CLASSES` roots have no `type` field. */
    private fun libraryRoots(workspace: JsonObject, type: String): Map<String, Set<String>> =
        workspace.getValue("libraries").jsonArray.associate { library ->
            val roots = library.jsonObject.getValue("roots").jsonArray.map { it.jsonObject }
            library.jsonObject.getValue("name").jsonPrimitive.content to roots
                .filter { (it["type"]?.jsonPrimitive?.content ?: "CLASSES") == type }
                .map { it.getValue("path").jsonPrimitive.content }
                .toSet()
        }

    private fun libraryClasses(workspace: JsonObject): Map<String, Set<String>> = libraryRoots(workspace, "CLASSES")

    private fun librarySources(workspace: JsonObject): Map<String, Set<String>> = libraryRoots(workspace, "SOURCES")

    private fun missingSources(outputDir: File, kind: String): List<String> =
        readJson(File(outputDir, "missing-sources.json")).getValue(kind).jsonArray.map { it.jsonPrimitive.content }

    /** A copy of the SDK of [androidHome] with symbolic links, so that a test can add or remove sources. */
    private fun fakeAndroidHome(withSources: Boolean): File {
        val home = File(tempDir, "android-sdk")
        home.mkdirs()
        File(androidHome).listFiles()!!.filter { it.name != "sources" }.forEach {
            Files.createSymbolicLink(File(home, it.name).toPath(), it.toPath())
        }
        if (withSources) {
            File(home, "sources/android-36").mkdirs()
        }
        return home
    }

    /** [entries] maps entry names to their text. */
    private fun writeJar(file: File, entries: Map<String, String> = emptyMap()) {
        file.parentFile.mkdirs()
        JarOutputStream(file.outputStream()).use { jar ->
            entries.forEach { (name, text) ->
                jar.putNextEntry(JarEntry(name))
                jar.write(text.toByteArray())
                jar.closeEntry()
            }
        }
    }

    private fun jarEntryNames(path: String): List<String> = JarFile(path).use { jar -> jar.entries().toList().map { it.name } }

    /** `com.example:<module>:1.0` with Gradle metadata that has only a class jar variant. */
    private fun writeLibraryWithNoSourcesVariant(repo: File, module: String) {
        val libraryDir = File(repo, "com/example/$module/1.0")
        writeJar(File(libraryDir, "$module-1.0.jar"))
        File(libraryDir, "$module-1.0.module").writeText(
            """
            {
              "formatVersion": "1.1",
              "component": {"group": "com.example", "module": "$module", "version": "1.0"},
              "variants": [{
                "name": "apiElements",
                "attributes": {
                  "org.gradle.category": "library",
                  "org.gradle.dependency.bundling": "external",
                  "org.gradle.libraryelements": "jar",
                  "org.gradle.usage": "java-api"
                },
                "files": [{"name": "$module-1.0.jar", "url": "$module-1.0.jar"}]
              }]
            }
            """.trimIndent()
        )
    }

    private fun addMavenRepository(projectDir: File, repo: File) {
        File(projectDir, "settings.gradle.kts").appendText(
            """

            dependencyResolutionManagement {
                repositories {
                    maven {
                        url = uri("${repo.toURI()}")
                        metadataSources { gradleMetadata() }
                    }
                }
            }
            """.trimIndent()
        )
    }

    private fun addLibDependency(projectDir: File, notation: String) {
        File(projectDir, "lib/build.gradle.kts").appendText("\ndependencies {\n    implementation(\"$notation\")\n}\n")
    }

    private fun addGradleApi(projectDir: File) {
        File(projectDir, "build.gradle.kts").appendText("\ndependencies {\n    implementation(gradleApi())\n}\n")
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
    fun selectsVariantFromSystemProperty() {
        val projectDir = copyFixture("android")
        val outputDir = File(tempDir, "out")

        runInitScript(projectDir, outputDir, listOf("-Dlsp.android.variant=prodDebug"))

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
        assertEquals(emptyList<String>(), missingSources(outputDir, "androidPlatforms"))
        assertEquals(emptyList<String>(), missingSources(outputDir, "gradleVersions"))
    }

    @Test
    fun includesResolvedLibrariesWhenOneDependencyIsMissing() {
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
    fun keepsOldFileWhenTaskFails() {
        val projectDir = copyFixture("jvm-only")
        val outputDir = File(tempDir, "out")
        runInitScript(projectDir, outputDir)
        val workspaceFile = File(outputDir, "library-sources/workspace.json")
        val oldContent = workspaceFile.readText()
        val oldModified = workspaceFile.lastModified()
        // A folder with content in place of the fragment file makes the rename of the task fail.
        val fragment = File(outputDir, "library-sources/fragments/_.json")
        fragment.delete()
        File(fragment, "blocker").apply { parentFile.mkdirs() }.writeText("")

        val result = runInitScript(projectDir, outputDir)

        assertTrue("cannot write the library sources" in result.output, result.output)
        assertEquals(oldContent, workspaceFile.readText())
        assertEquals(oldModified, workspaceFile.lastModified())
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

    @Test
    fun attachesSourcesJarOfLibrary() {
        val projectDir = copyFixture("android")
        val outputDir = File(tempDir, "out")

        runInitScript(projectDir, outputDir)

        val sources = librarySources(workspace(outputDir)).getValue("Sources: androidx.core:core-ktx:1.13.1")
        assertTrue(sources.any { it.endsWith("/core-ktx-1.13.1-sources.jar") && File(it).exists() }, sources.toString())
    }

    @Test
    fun findsSourcesInGradleCacheWhenMetadataHasNone() {
        val projectDir = copyFixture("android")
        // The repository has no sources jar, so that only the Gradle cache has sources.
        val repo = File(tempDir, "repo")
        writeLibraryWithNoSourcesVariant(repo, "nosources")
        addMavenRepository(projectDir, repo)
        addLibDependency(projectDir, "com.example:nosources:1.0")
        val cachedSources = File(testKitDir, "caches/modules-2/files-2.1/com.example/nosources/1.0/0123abcd/nosources-1.0-sources.jar")
        writeJar(cachedSources)
        val outputDir = File(tempDir, "out")

        runInitScript(projectDir, outputDir)

        val sources = librarySources(workspace(outputDir))["Sources: com.example:nosources:1.0"]
        assertEquals(setOf(cachedSources.absolutePath), sources)
    }

    @Test
    fun findsClassifierSourcesJarInRepositoryWhenMetadataHasNone() {
        val projectDir = copyFixture("android")
        // A file repository, so that the Gradle cache has no copy of the sources jar.
        val repo = File(tempDir, "repo")
        writeLibraryWithNoSourcesVariant(repo, "classifiedsources")
        val repositorySources = File(repo, "com/example/classifiedsources/1.0/classifiedsources-1.0-sources.jar")
        writeJar(repositorySources)
        addMavenRepository(projectDir, repo)
        addLibDependency(projectDir, "com.example:classifiedsources:1.0")
        val outputDir = File(tempDir, "out")

        runInitScript(projectDir, outputDir)

        val sources = librarySources(workspace(outputDir))["Sources: com.example:classifiedsources:1.0"]
        assertEquals(setOf(repositorySources.absolutePath), sources)
    }

    @Test
    fun copiesJavaFilesOfSourcesJarWithTopFolder() {
        val projectDir = copyFixture("android")
        val repo = File(tempDir, "repo")
        writeLibraryWithNoSourcesVariant(repo, "prefixed")
        val prefixedSources = File(repo, "com/example/prefixed/1.0/prefixed-1.0-sources.jar")
        writeJar(
            prefixedSources,
            mapOf(
                "main/com/example/Prefixed.java" to "// License\npackage com.example;\n\npublic class Prefixed {}\n",
                "main/com/example/Helper.kt" to "package com.example\n",
                "commonMain/com/example/Common.kt" to "package com.example\n",
            ),
        )
        writeLibraryWithNoSourcesVariant(repo, "plain")
        val plainSources = File(repo, "com/example/plain/1.0/plain-1.0-sources.jar")
        writeJar(plainSources, mapOf("com/example/Plain.java" to "package com.example;\n\npublic class Plain {}\n"))
        addMavenRepository(projectDir, repo)
        addLibDependency(projectDir, "com.example:prefixed:1.0")
        addLibDependency(projectDir, "com.example:plain:1.0")
        val outputDir = File(tempDir, "out")

        runInitScript(projectDir, outputDir)

        val sources = librarySources(workspace(outputDir))
        val javaSources = File(outputDir, "library-sources/java-sources/com.example/prefixed-1.0-sources.jar")
        assertEquals(setOf(prefixedSources.absolutePath, javaSources.absolutePath), sources["Sources: com.example:prefixed:1.0"])
        assertEquals(listOf("com/example/Prefixed.java"), jarEntryNames(javaSources.absolutePath))
        assertEquals(setOf(plainSources.absolutePath), sources["Sources: com.example:plain:1.0"])
    }

    @Test
    fun keepsSourcesJarThatIsNotZipFile() {
        val projectDir = copyFixture("android")
        val repo = File(tempDir, "repo")
        writeLibraryWithNoSourcesVariant(repo, "broken")
        val brokenSources = File(repo, "com/example/broken/1.0/broken-1.0-sources.jar")
        brokenSources.writeText("not a zip file")
        addMavenRepository(projectDir, repo)
        addLibDependency(projectDir, "com.example:broken:1.0")
        val outputDir = File(tempDir, "out")

        runInitScript(projectDir, outputDir)

        val sources = librarySources(workspace(outputDir))
        assertEquals(setOf(brokenSources.absolutePath), sources["Sources: com.example:broken:1.0"])
        assertTrue("Sources: androidx.core:core-ktx:1.13.1" in sources, sources.keys.toString())
    }

    @Test
    fun addsSdkWithSourcesWhenInstalled() {
        val projectDir = copyFixture("android")
        val sdk = fakeAndroidHome(withSources = true)
        val outputDir = File(tempDir, "out")

        runInitScript(projectDir, outputDir, environment = mapOf("ANDROID_HOME" to sdk.absolutePath))

        val workspace = workspace(outputDir)
        val classes = libraryClasses(workspace).getValue("Sources: android-36")
        assertTrue(classes.any { it.endsWith("/platforms/android-36/android.jar") }, classes.toString())
        val sources = librarySources(workspace).getValue("Sources: android-36")
        assertEquals(setOf(File(sdk, "sources/android-36").absolutePath), sources)
        assertEquals(emptyList<String>(), missingSources(outputDir, "androidPlatforms"))
    }

    @Test
    fun reportsMissingSdkSources() {
        val projectDir = copyFixture("android")
        val sdk = fakeAndroidHome(withSources = false)
        val outputDir = File(tempDir, "out")

        runInitScript(projectDir, outputDir, environment = mapOf("ANDROID_HOME" to sdk.absolutePath))

        val workspace = workspace(outputDir)
        assertTrue("Sources: android-36" in libraryClasses(workspace))
        assertEquals(emptySet<String>(), librarySources(workspace).getValue("Sources: android-36"))
        assertEquals(listOf("android-36"), missingSources(outputDir, "androidPlatforms"))
    }

    @Test
    fun addsGradleApiWithSources() {
        val projectDir = copyFixture("jvm-only")
        addGradleApi(projectDir)
        val gradleSources = File(tempDir, "gradle-sources")
        val extracted = File(gradleSources, "gradle-$gradleVersion")
        val sourceRoots = listOf(
            "platforms/core-configuration/kotlin-dsl/src/main/kotlin",
            "subprojects/core-api/src/main/java",
            "subprojects/core/src/main/java",
            "subprojects/core/src/main/kotlin",
        ).map { File(extracted, it) }
        sourceRoots.forEach { it.mkdirs() }
        File(extracted, "subprojects/core/src/main/resources").mkdirs()
        val outputDir = File(tempDir, "out")

        runInitScript(projectDir, outputDir, environment = mapOf("KOTLIN_LSP_GRADLE_SOURCES" to gradleSources.absolutePath))

        val workspace = workspace(outputDir)
        val classes = libraryClasses(workspace).getValue("Sources: gradle-api-$gradleVersion")
        assertEquals(setOf("gradle-api-$gradleVersion.jar"), classes.map { File(it).name }.toSet())
        classes.forEach { assertTrue(File(it).exists(), it) }
        val sources = librarySources(workspace).getValue("Sources: gradle-api-$gradleVersion")
        assertEquals(sourceRoots.map { it.absolutePath }.toSet(), sources)
        assertEquals(emptyList<String>(), missingSources(outputDir, "gradleVersions"))
    }

    @Test
    fun addsKotlinDslJarsToGradleApi() {
        val projectDir = copyFixture("jvm-only")
        File(projectDir, "build.gradle.kts").appendText("\ndependencies {\n    implementation(gradleKotlinDsl())\n}\n")
        val gradleSources = File(tempDir, "gradle-sources")
        val sourceRoot = File(gradleSources, "gradle-$gradleVersion/platforms/core-configuration/kotlin-dsl/src/main/kotlin")
        sourceRoot.mkdirs()
        val outputDir = File(tempDir, "out")

        runInitScript(projectDir, outputDir, environment = mapOf("KOTLIN_LSP_GRADLE_SOURCES" to gradleSources.absolutePath))

        val workspace = workspace(outputDir)
        val classes = libraryClasses(workspace).getValue("Sources: gradle-api-$gradleVersion")
        assertEquals(
            setOf(
                "gradle-api-$gradleVersion.jar",
                "gradle-kotlin-dsl-$gradleVersion.jar",
                "gradle-kotlin-dsl-shared-runtime-$gradleVersion.jar",
                "gradle-kotlin-dsl-tooling-models-$gradleVersion.jar",
            ),
            classes.map { File(it).name }.toSet(),
        )
        assertEquals(setOf(sourceRoot.absolutePath), librarySources(workspace).getValue("Sources: gradle-api-$gradleVersion"))
    }

    @Test
    fun attachesCachedSourcesToLibraryJarsOfGradleDistribution() {
        val projectDir = copyFixture("jvm-only")
        File(projectDir, "build.gradle.kts").appendText("\ndependencies {\n    implementation(gradleKotlinDsl())\n}\n")
        val cachedSources = File(
            testKitDir,
            "caches/modules-2/files-2.1/org.jetbrains.kotlin/kotlin-stdlib/$gradleKotlinVersion/0123abcd/kotlin-stdlib-$gradleKotlinVersion-sources.jar",
        )
        writeJar(cachedSources)
        val outputDir = File(tempDir, "out")

        runInitScript(projectDir, outputDir)

        val name = "Sources: org.jetbrains.kotlin:kotlin-stdlib:$gradleKotlinVersion"
        val workspace = workspace(outputDir)
        val classes = libraryClasses(workspace).getValue(name)
        assertEquals(listOf("kotlin-stdlib-$gradleKotlinVersion.jar"), classes.map { File(it).name })
        assertTrue(File(classes.single()).parentFile.name == "lib", classes.toString())
        assertTrue(cachedSources.absolutePath in librarySources(workspace).getValue(name), librarySources(workspace).toString())
    }

    @Test
    fun reportsMissingGradleSources() {
        val projectDir = copyFixture("jvm-only")
        addGradleApi(projectDir)
        val gradleSources = File(tempDir, "gradle-sources")
        gradleSources.mkdirs()
        val outputDir = File(tempDir, "out")

        runInitScript(projectDir, outputDir, environment = mapOf("KOTLIN_LSP_GRADLE_SOURCES" to gradleSources.absolutePath))

        assertEquals(emptySet<String>(), librarySources(workspace(outputDir)).getValue("Sources: gradle-api-$gradleVersion"))
        assertEquals(listOf(gradleVersion), missingSources(outputDir, "gradleVersions"))
    }

    @Test
    fun writesGradleHomeOfBuild() {
        val projectDir = copyFixture("jvm-only")
        val outputDir = File(tempDir, "out")

        runInitScript(projectDir, outputDir)

        val gradleHome = File(outputDir, "library-sources/gradle-home.txt").readText()
        assertTrue(File(gradleHome, "lib/gradle-tooling-api-$gradleVersion.jar").isFile, gradleHome)
    }

    @Test
    fun coversPluginBuildsOfRootBuild() {
        val projectDir = copyFixture("included")
        val outputDir = File(tempDir, "out")

        runInitScript(projectDir, outputDir)

        assertTrue("Sources: gradle-api-$gradleVersion" in libraryClasses(workspace(outputDir)))
    }
}
