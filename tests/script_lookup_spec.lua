-- Run from the repo root: nvim --clean --headless -l tests/script_lookup_spec.lua
local repo_root = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
vim.opt.runtimepath:prepend(repo_root)
package.path = repo_root .. '/lua/?.lua;' .. repo_root .. '/lua/?/init.lua;' .. package.path

local work_dir = vim.fn.tempname()
vim.env.KOTLIN_LSP_CACHE = work_dir .. '/cache'
vim.env.XDG_CACHE_HOME = work_dir .. '/xdg-cache'
local root_dir = work_dir .. '/project'

local warnings = {}
vim.notify = function(message, level)
  if level == vim.log.levels.WARN then
    table.insert(warnings, message)
  end
end

---@param files table<string, string[]> lines of each file by path in the folder
local function write_files(folder, files)
  for path, lines in pairs(files) do
    vim.fn.mkdir(vim.fs.dirname(folder .. '/' .. path), 'p')
    vim.fn.writefile(lines, folder .. '/' .. path)
  end
end

---@param files table<string, string[]> lines of each jar entry by path
local function write_jar(jar_path, files)
  local staging = vim.fn.tempname()
  write_files(staging, files)
  local zip_result = vim.system({ 'zip', '-q', '-r', jar_path, '.' }, { cwd = staging, text = true }):wait()
  assert(zip_result.code == 0, 'zip failed: ' .. zip_result.stderr)
end

local accessors_dir = work_dir .. '/accessors/sources'
write_files(accessors_dir, {
  ['org/gradle/kotlin/dsl/Accessors1.kt'] = {
    '@file:Suppress("unused")',
    '',
    'package org.gradle.kotlin.dsl',
    '',
    '/**',
    ' * Retrieves the [android][com.example.ApplicationExtension] extension.',
    ' */',
    'val org.gradle.api.Project.`android`: com.example.ApplicationExtension get() =',
    '    (this as org.gradle.api.plugins.ExtensionAware).extensions.getByName("android") as com.example.ApplicationExtension',
    '',
    '/**',
    ' * Configures the [android][com.example.ApplicationExtension] extension.',
    ' */',
    'fun org.gradle.api.Project.`android`(configure: Action<com.example.ApplicationExtension>): Unit =',
    '    (this as org.gradle.api.plugins.ExtensionAware).extensions.configure("android", configure)',
    '',
    'fun org.gradle.api.Project.`deep`(configure: Action<com.example.Deep0>): Unit =',
    '    (this as org.gradle.api.plugins.ExtensionAware).extensions.configure("deep", configure)',
    '',
    'val org.gradle.api.Project.`foo`: Int get() = 0',
  },
  -- The name is a part of the package of the receiver.
  ['org/gradle/kotlin/dsl/Accessors2.kt'] = {
    'package org.gradle.kotlin.dsl',
    '',
    'val com.example.android.ExampleExtension.`ext`: Int get() = 0',
  },
  ['org/gradle/kotlin/dsl/ImplementationConfigurationAccessors.kt'] = {
    'package org.gradle.kotlin.dsl',
    '',
    'import org.gradle.api.artifacts.Dependency',
    'import org.gradle.api.artifacts.dsl.DependencyHandler',
    '',
    '/**',
    " * Adds a dependency to the 'implementation' configuration.",
    ' */',
    'fun DependencyHandler.`implementation`(dependencyNotation: Any): Dependency? =',
    '    add("implementation", dependencyNotation)',
  },
})

-- The version catalog accessors have a copy of each getter for the `plugins` block.
local dependency_accessors_dir = work_dir .. '/dependencies-accessors/sources'
local catalog_accessor = {
  'package org.gradle.accessors.dm;',
  '',
  'public class LibrariesForLibs extends AbstractExternalDependencyFactory {',
  '    public Provider<MinimalExternalModuleDependency> getFoo() {',
  '        return create("foo");',
  '    }',
  '}',
}
-- The accessors of another catalog have more getters of the name than the name lookup lists.
local other_catalog_accessor = { 'package org.gradle.accessors.dm;', '', 'public class LibrariesForAnother extends AbstractExternalDependencyFactory {' }
for index = 1, 30 do
  vim.list_extend(other_catalog_accessor, {
    ('    public static class Accessors%d {'):format(index),
    '        public Provider<MinimalExternalModuleDependency> getFoo() {',
    '            return create("foo");',
    '        }',
    '    }',
  })
end
table.insert(other_catalog_accessor, '}')
write_files(dependency_accessors_dir, {
  ['org/gradle/accessors/dm/LibrariesForAnother.java'] = other_catalog_accessor,
  ['org/gradle/accessors/dm/LibrariesForLibs.java'] = catalog_accessor,
  ['org/gradle/accessors/dm/LibrariesForLibsInPluginsBlock.java'] = catalog_accessor,
})

local plugin_dir = work_dir .. '/plugin/src'
local base_default_config_lines = {
  'package com.example.dsl',
  '',
  'interface BaseDefaultConfig {',
  '    /**',
  '     * The API level to compile against.',
  '     *',
  '     * Set it in each module.',
  '     */',
  '    var compileSdk: Int?',
  '}',
}
-- As in AGP: `release` is a member extension of the container of `buildTypes`.
local application_extension_lines = {
  'package com.example',
  '',
  'interface ApplicationExtension :',
  '    CommonExtension {',
  '    var namespace: String?',
  '',
  '    fun buildTypes(action: Action<in Container<BuildType>>)',
  '',
  '    fun Container<BuildType>.release(action: BuildType.() -> Unit)',
  '}',
}
local container_lines = { 'package com.example', '', 'interface Container<T> {', '    fun findByName(name: String): T?', '}' }
local build_type_lines = { 'package com.example', '', 'interface BuildType {', '    var isMinifyEnabled: Boolean', '}' }
local plugin_files = {
  ['com/example/ApplicationExtension.kt'] = application_extension_lines,
  ['com/example/Container.kt'] = container_lines,
  ['com/example/BuildType.kt'] = build_type_lines,
  ['com/example/CommonExtension.kt'] = {
    'package com.example',
    '',
    'import com.example.dsl.ApplicationDefaultConfig',
    '',
    'interface CommonExtension {',
    '    fun defaultConfig(action: ApplicationDefaultConfig.() -> Unit)',
    '',
    '    var buildToolsVersion: String',
    '}',
  },
  ['com/example/dsl/ApplicationDefaultConfig.kt'] = { 'package com.example.dsl', '', 'interface ApplicationDefaultConfig : BaseDefaultConfig' },
  ['com/example/dsl/BaseDefaultConfig.kt'] = base_default_config_lines,
  ['com/example/LibraryExtension.kt'] = { 'package com.example', '', 'interface LibraryExtension {', '    var namespace: String?', '}' },
  ['com/example/AppPlugin.kt'] = { 'package com.example', '', 'class AppPlugin : Plugin<Project> {', '}' },
  ['java/io/File.java'] = { 'package java.io;', '', 'public class File {', '}' },
  ['com/example/ManagedDevice.kt'] = { 'package com.example', '', 'class ManagedDevice(', '    val name: String', ') {', '}' },
  ['com/example/Wide.kt'] = vim.list_extend({ 'package com.example', '', 'class Wide(' }, vim.tbl_map(function(index)
    return ('    val p%d: Int,'):format(index)
  end, vim.fn.range(50))),
}
-- A supertype chain of 6 levels: `Deep0 : Deep1`, ..., `Deep5 : Deep6`.
for level = 0, 6 do
  local supertype = level < 6 and (' : Deep%d'):format(level + 1) or ''
  local members = { [5] = '    val bar: Int', [6] = '    val foo: Int' }
  plugin_files[('com/example/Deep%d.kt'):format(level)] = { 'package com.example', '', ('interface Deep%d%s {'):format(level, supertype), members[level] or '', '}' }
end
write_files(plugin_dir, plugin_files)

-- Like the stdlib sources jar, the files are in a top folder that is not part of the package.
local other_jar = work_dir .. '/other-sources.jar'
write_jar(other_jar, { ['src/main/kotlin/com/example/Other.kt'] = { 'package com.example', '', 'class Other' } })

-- As in Gradle: the Groovy blocks of `Project` take a `Closure`, and `getPlugins()` is in `PluginAware`.
local project_lines = {
  'package org.gradle.api;',
  '',
  'import groovy.lang.Closure;',
  'import org.gradle.api.plugins.ExtensionAware;',
  'import org.gradle.api.plugins.PluginAware;',
  '',
  '/**',
  ' * Gives access to the build model.',
  ' */',
  'public interface Project extends Comparable<Project>, ExtensionAware, PluginAware {',
  '    Project getRootProject();',
  '',
  '    void dependencies(Closure configureClosure);',
  '}',
}
local gradle_api_jar = work_dir .. '/gradle-api-sources.jar'
write_jar(gradle_api_jar, {
  ['org/gradle/api/Project.java'] = project_lines,
  ['org/gradle/api/plugins/ExtensionAware.java'] = { 'package org.gradle.api.plugins;', '', 'public interface ExtensionAware {', '}' },
  ['org/gradle/api/plugins/PluginAware.java'] = { 'package org.gradle.api.plugins;', '', 'public interface PluginAware {', '    PluginContainer getPlugins();', '}' },
  ['org/gradle/api/initialization/Settings.java'] = {
    'package org.gradle.api.initialization;',
    '',
    'public interface Settings {',
    '    ProjectDescriptor getRootProject();',
    '}',
  },
  ['org/gradle/internal/Project.java'] = { 'package org.gradle.internal;', '', 'public class Project {', '}' },
})

-- The script template and the extensions of the Kotlin DSL, as in Gradle.
local script_template_lines = {
  'package org.gradle.kotlin.dsl',
  '',
  'import org.gradle.api.Project',
  'import org.gradle.kotlin.dsl.support.DefaultKotlinScript',
  '',
  'abstract class KotlinProjectScriptTemplate(',
  '    private val host: KotlinScriptHost<Project>',
  ') : DefaultKotlinScript(defaultKotlinScriptHostForProject(host.target)) {',
  '',
  '    open fun buildscript(block: ScriptHandlerScope.() -> Unit): Unit =',
  '        internalError()',
  '',
  '    fun plugins(@Suppress("unused_parameter") block: PluginDependenciesSpecScope.() -> Unit): Unit =',
  '        invalidPluginsCall()',
  '}',
}
local project_extensions_lines = {
  'package org.gradle.kotlin.dsl',
  '',
  'import org.gradle.api.Project',
  '',
  'fun Project.dependencies(configuration: DependencyHandlerScope.() -> Unit) =',
  '    DependencyHandlerScope.of(dependencies).configuration()',
  '',
  'fun Project.plugins(@Suppress("unused_parameter") block: PluginDependenciesSpec.() -> Unit): Nothing =',
  '    invalidPluginsCall()',
}
local kotlin_dsl_jar = work_dir .. '/gradle-kotlin-dsl-sources.jar'
write_jar(kotlin_dsl_jar, {
  ['org/gradle/kotlin/dsl/KotlinProjectScriptTemplate.kt'] = script_template_lines,
  ['org/gradle/kotlin/dsl/ProjectExtensions.kt'] = project_extensions_lines,
})

-- Like the Kotlin Gradle plugin sources jar, a file can be outside the folder of its package.
local kotlin_plugin_jar = work_dir .. '/kotlin-gradle-plugin-sources.jar'
write_jar(kotlin_plugin_jar, {
  ['org/jetbrains/kotlin/gradle/plugin/KotlinAndroidPluginWrapper.kt'] = {
    'package org.jetbrains.kotlin.gradle.plugin',
    '',
    'open class KotlinAndroidPluginWrapper : AbstractKotlinAndroidPluginWrapper()',
  },
  ['KotlinPluginWrapper.kt'] = { 'package org.jetbrains.kotlin.gradle.plugin', '', 'open class KotlinPluginWrapper : AbstractKotlinPluginWrapper()' },
})

local missing_jar = work_dir .. '/missing-sources.jar'
local source_path = { accessors_dir, dependency_accessors_dir, plugin_dir, other_jar, gradle_api_jar, kotlin_dsl_jar, kotlin_plugin_jar, missing_jar }

local script_lines = {
  'import com.example.ManagedDevice',
  'import com.example.Wide',
  'import com.other.Remote',
  '',
  'plugins {',
  '    id("com.example.app")',
  '    kotlin("android")',
  '    kotlin("jvm")',
  '    alias(libs.plugins.ksp)',
  '    id("com.example.convention")',
  '    id("com.unknown.android")',
  '}',
  '',
  'android {',
  '    val device: ManagedDevice? = null',
  '    namespace = "com.example.app"',
  '    defaultConfig {',
  '        compileSdk = 36',
  '        buildToolsVersion = "36.0.0"',
  '    }',
  '    buildTypes {',
  '        findByName("debug")',
  '        release {',
  '            isMinifyEnabled = true',
  '        }',
  '    }',
  '}',
  '',
  'unknownBlock { foo }',
  'deep { foo }',
  'deep { bar }',
  '',
  'dependencies {',
  '    implementation(libs.androidx.core.ktx)',
  '    implementation(libs.foo)',
  '}',
  '',
  'val root: Project = project',
  'val toolVersion = libs.versions.ksp.get()',
  'val file: File? = null',
  'val remote: Remote? = null',
}
local script_path = root_dir .. '/build.gradle.kts'
local settings_path = root_dir .. '/settings.gradle.kts'
write_files(root_dir, {
  ['build.gradle.kts'] = script_lines,
  ['settings.gradle.kts'] = { 'rootProject.name = "app"' },
  ['other/build.gradle.kts'] = { 'val bar = foo()' },
})

-- Scripts for the references of `compileSdk`. The script in `build/` is in the model, so that a hit in
-- it would only be missing because of the search.
local block_script_lines = { 'android {', '    defaultConfig {', '        compileSdk = 35', '    }', '}' }
local reference_script_paths = { 'references/a.gradle.kts', 'references/b.gradle.kts', 'references/variable.gradle.kts', 'build/generated.gradle.kts' }
write_files(root_dir, {
  [reference_script_paths[1]] = block_script_lines,
  [reference_script_paths[2]] = vim.list_extend({ '// Both scripts configure the SDK.' }, block_script_lines),
  [reference_script_paths[3]] = { 'val compileSdk = 35', 'println(compileSdk)' },
  [reference_script_paths[4]] = block_script_lines,
  -- The hits above the limit and at the limit.
  ['references/limit.gradle.kts'] = vim.tbl_map(function()
    return 'limitName()'
  end, vim.fn.range(200)),
  ['references/over-limit.gradle.kts'] = vim.tbl_map(function()
    return 'overLimitName()'
  end, vim.fn.range(201)),
})

local catalog_lines = {
  '[versions]',
  'ksp = "2.3.0"',
  '',
  '[libraries]',
  'androidx-core-ktx = { group = "androidx.core", name = "core-ktx", version = "1.17.0" }',
  '',
  '[plugins]',
  'ksp = { id = "com.google.devtools.ksp", version.ref = "ksp" }',
}
local catalog_path = root_dir .. '/gradle/libs.versions.toml'
write_files(root_dir, { ['gradle/libs.versions.toml'] = catalog_lines })

local sources = require 'kotlin_lsp_android.sources'
local model_path = sources.cache_dir(root_dir) .. '/library-sources/gradle-scripts.json'
vim.fn.mkdir(vim.fs.dirname(model_path), 'p')
local scripts_in_model = {}
for _, path in ipairs(vim.list_extend(vim.deepcopy(reference_script_paths), { 'references/limit.gradle.kts', 'references/over-limit.gradle.kts' })) do
  scripts_in_model[assert(vim.uv.fs_realpath(root_dir .. '/' .. path))] = { sourcePath = 0, implicitImports = 1, pluginClasses = {} }
end
vim.fn.writefile({
  vim.json.encode({
    lists = { source_path, { 'org.gradle.api.*', 'org.gradle.kotlin.dsl.*', 'java.io.File' } },
    scripts = vim.tbl_extend('error', scripts_in_model, {
      [assert(vim.uv.fs_realpath(settings_path))] = { sourcePath = 0, implicitImports = 1, pluginClasses = {} },
      [assert(vim.uv.fs_realpath(script_path))] = {
        sourcePath = 0,
        implicitImports = 1,
        pluginClasses = {
          ['com.example.app'] = 'com.example.AppPlugin',
          ['com.example.convention'] = 'ConventionPlugin',
          ['org.jetbrains.kotlin.android'] = 'org.jetbrains.kotlin.gradle.plugin.KotlinAndroidPluginWrapper',
          ['org.jetbrains.kotlin.jvm'] = 'org.jetbrains.kotlin.gradle.plugin.KotlinPluginWrapper',
        },
      },
    }),
  }),
}, model_path)

-- `workspace/symbol` needs a server.
local other_library_location = { uri = 'file:///build-logic/Found.kt', range = { start = { line = 1, character = 0 }, ['end'] = { line = 1, character = 0 } } }
local other_library_names = {}
local other_library_result = { other_library_location }
sources.find_in_other_libraries = function(names, params, lookup_root_dir, lines)
  table.insert(other_library_names, names)
  return sources.to_sources(other_library_result, params, lookup_root_dir, lines)
end

local lookup = require 'kotlin_lsp_android.script_lookup'

local function assert_equal(actual, expected, label)
  assert(vim.deep_equal(actual, expected), ('%s = %s, want %s'):format(label, vim.inspect(actual), vim.inspect(expected)))
end

---@return integer index of the first line with the text
local function line_index_of(lines, text)
  for index, line in ipairs(lines) do
    if line:find(text, 1, true) then
      return index - 1
    end
  end
  error(('no line with %q'):format(text))
end

vim.cmd.edit(vim.fn.fnameescape(script_path))
local document = { uri = vim.uri_from_bufnr(0) }

---@return lsp.TextDocumentPositionParams at the first `word` in the first line with `line_text`
local function params_at(line_text, word)
  local line_index = line_index_of(script_lines, line_text)
  local character = script_lines[line_index + 1]:find(word, 1, true) - 1
  return { textDocument = document, position = { line = line_index, character = character } }
end

local function assert_location(result, want_uri, want_line_index, label)
  assert(result and #result == 1, ('%s: locations = %s, want 1'):format(label, vim.inspect(result)))
  assert(result[1].uri == want_uri, ('%s: uri = %q, want %q'):format(label, result[1].uri, want_uri))
  local line_index = result[1].range.start.line
  assert(line_index == want_line_index, ('%s: line = %d, want %d'):format(label, line_index, want_line_index))
end

local function folder_uri(folder, path)
  return vim.uri_from_fname(folder .. '/' .. path)
end

local function jar_uri(jar_path, entry)
  return ('jar://%s!/%s'):format(jar_path, entry)
end

-- The package index: a jar with a top folder, and a missing jar, which is skipped.
assert_equal(sources.roots_with_package(source_path, 'com.example'), { plugin_dir, other_jar }, 'roots of com.example')
assert_equal(sources.roots_with_package(source_path, 'org.gradle.api'), { gradle_api_jar }, 'roots of org.gradle.api')
assert_equal(sources.roots_with_package(source_path, 'org.gradle.kotlin.dsl'), { accessors_dir, kotlin_dsl_jar }, 'roots of org.gradle.kotlin.dsl')

assert_location(lookup.definition(params_at('id("com.example.app")', 'app'), root_dir), folder_uri(plugin_dir, 'com/example/AppPlugin.kt'), 2, 'plugin id')

assert_location(
  lookup.definition(params_at('kotlin("android")', 'android'), root_dir),
  jar_uri(kotlin_plugin_jar, 'org/jetbrains/kotlin/gradle/plugin/KotlinAndroidPluginWrapper.kt'),
  2,
  'Kotlin plugin id'
)
-- The word in the string of an unknown plugin id is not a name of the script.
assert_equal(lookup.definition(params_at('id("com.unknown.android")', 'android'), root_dir), nil, 'unknown plugin id')
assert_location(lookup.definition(params_at('kotlin("jvm")', 'jvm'), root_dir), jar_uri(kotlin_plugin_jar, 'KotlinPluginWrapper.kt'), 2, 'class in a file outside its package folder')

assert_location(
  lookup.definition(params_at('libs.androidx.core.ktx', 'ktx'), root_dir),
  vim.uri_from_fname(catalog_path),
  line_index_of(catalog_lines, 'androidx-core-ktx = '),
  'catalog library'
)

assert_location(
  lookup.definition(params_at('alias(libs.plugins.ksp)', 'ksp'), root_dir),
  vim.uri_from_fname(catalog_path),
  line_index_of(catalog_lines, 'ksp = {'),
  'catalog plugin'
)

-- A call after the expression is not part of the key.
assert_location(
  lookup.definition(params_at('libs.versions.ksp.get()', 'ksp'), root_dir),
  vim.uri_from_fname(catalog_path),
  line_index_of(catalog_lines, 'ksp = "'),
  'catalog version with a call'
)

assert_location(lookup.definition(params_at('ManagedDevice? = null', 'ManagedDevice'), root_dir), folder_uri(plugin_dir, 'com/example/ManagedDevice.kt'), 2, 'explicit import')
assert_location(lookup.definition(params_at('val file: File', 'File'), root_dir), folder_uri(plugin_dir, 'java/io/File.java'), 2, 'implicit import of a class')

-- `to_sources` calls the lookup for an empty server result.
assert_location(
  sources.to_sources({}, params_at('val root: Project', 'Project'), root_dir),
  jar_uri(gradle_api_jar, 'org/gradle/api/Project.java'),
  line_index_of(project_lines, 'public interface Project'),
  'implicit import'
)

assert_location(
  lookup.definition(params_at('implementation(libs.androidx', 'implementation'), root_dir),
  folder_uri(accessors_dir, 'org/gradle/kotlin/dsl/ImplementationConfigurationAccessors.kt'),
  8,
  'accessor'
)

local function hover_value(line_text, word)
  local hover = lookup.hover(params_at(line_text, word), root_dir)
  assert(hover and hover.contents.kind == 'markdown', ('%s: hover = %s, want markdown'):format(word, vim.inspect(hover)))
  return hover.contents.value
end

assert_equal(
  hover_value('compileSdk = 36', 'compileSdk'),
  table.concat({ 'The API level to compile against.', '', 'Set it in each module.', '', '```kotlin', 'var compileSdk: Int?', '```' }, '\n'),
  'hover with KDoc'
)
assert_equal(
  hover_value('ManagedDevice? = null', 'ManagedDevice'),
  table.concat({ '```kotlin', 'class ManagedDevice(', '    val name: String', ')', '```' }, '\n'),
  'hover on a declaration that ends at a brace'
)
assert_equal(
  hover_value('val root: Project', 'Project'),
  table.concat({
    'Gives access to the build model.',
    '',
    '```java',
    'public interface Project extends Comparable<Project>, ExtensionAware, PluginAware',
    '```',
  }, '\n'),
  'hover on a Java declaration with Javadoc'
)
assert_equal(
  hover_value('implementation(libs.androidx', 'implementation'),
  table.concat({
    "Adds a dependency to the 'implementation' configuration.",
    '',
    '```kotlin',
    'fun DependencyHandler.`implementation`(dependencyNotation: Any): Dependency?',
    '```',
  }, '\n'),
  'hover on a declaration that ends at an equals sign'
)
local wide_hover = hover_value('import com.example.Wide', 'Wide')
assert_equal(#vim.split(wide_hover, '\n'), 40 + 2, 'lines of a declaration over the limit, with the fence')

-- Braces in strings and comments do not open or close a block.
local lines = {
  'android {',
  '  // }',
  '  val s = "}${"{"}"',
  '  defaultConfig {',
  '    compileSdk = 36',
}
assert(vim.deep_equal(lookup.enclosing_blocks(lines, { line = 4, character = 6 }), { 'android', 'defaultConfig' }))

assert_equal(
  lookup.enclosing_blocks({ '/* { */ tasks.register("a{") {', "  val c = '{'", '  val r = """}${x}"""', '  if (c) {', '    x', '  }', '  y' }, { line = 6, character = 2 }),
  { 'register' },
  'blocks after a call, a char, a raw string, and an if'
)

assert_equal(
  lookup.enclosing_blocks({ 'android {', '  tasks.withType<Test> {', '  }', '  tasks.register<Copy>("x") {', '    group = "a"' }, { line = 4, character = 4 }),
  { 'android', 'register' },
  'blocks after type arguments'
)

-- At the top level, the members of the script template come before the members of `Project`. A
-- Kotlin lambda is not a Groovy `Closure`.
assert_location(
  lookup.definition(params_at('plugins {', 'plugins'), root_dir),
  jar_uri(kotlin_dsl_jar, 'org/gradle/kotlin/dsl/KotlinProjectScriptTemplate.kt'),
  line_index_of(script_template_lines, 'fun plugins'),
  'plugins at the top level'
)
assert_location(
  lookup.definition(params_at('dependencies {', 'dependencies'), root_dir),
  jar_uri(kotlin_dsl_jar, 'org/gradle/kotlin/dsl/ProjectExtensions.kt'),
  line_index_of(project_extensions_lines, 'fun Project.dependencies'),
  'dependencies at the top level'
)

assert_location(
  lookup.definition(params_at('compileSdk = 36', 'compileSdk'), root_dir),
  folder_uri(plugin_dir, 'com/example/dsl/BaseDefaultConfig.kt'),
  line_index_of(base_default_config_lines, 'compileSdk'),
  'member of a supertype in a block from a member of a supertype'
)

assert_location(
  lookup.definition(params_at('namespace = ', 'namespace'), root_dir),
  folder_uri(plugin_dir, 'com/example/ApplicationExtension.kt'),
  line_index_of(application_extension_lines, 'namespace'),
  'member of the block receiver'
)

local accessor_uri = folder_uri(accessors_dir, 'org/gradle/kotlin/dsl/Accessors1.kt')
local function accessor_at(line_index)
  local position = { line = line_index, character = 0 }
  return { uri = accessor_uri, range = { start = position, ['end'] = position } }
end
assert_equal(lookup.definition(params_at('android {', 'android'), root_dir), { accessor_at(7), accessor_at(13) }, 'accessor with the name in the package of another receiver')

-- Kotlin searches the receiver of the outer block after the receiver of the inner block.
assert_location(
  lookup.definition(params_at('buildToolsVersion = ', 'buildToolsVersion'), root_dir),
  folder_uri(plugin_dir, 'com/example/CommonExtension.kt'),
  7,
  'member of the outer block receiver'
)

assert_location(
  lookup.definition(params_at('findByName("debug")', 'findByName'), root_dir),
  folder_uri(plugin_dir, 'com/example/Container.kt'),
  line_index_of(container_lines, 'findByName'),
  'member of the receiver from Action<in T>'
)
assert_location(
  lookup.definition(params_at('isMinifyEnabled = true', 'isMinifyEnabled'), root_dir),
  folder_uri(plugin_dir, 'com/example/BuildType.kt'),
  line_index_of(build_type_lines, 'isMinifyEnabled'),
  'member in a block from a member extension of the outer receiver'
)

local foo_accessor_line_index = 19
assert_location(lookup.definition(params_at('unknownBlock { foo }', 'foo'), root_dir), accessor_uri, foo_accessor_line_index, 'name in a block with no type')
assert_location(lookup.definition(params_at('deep { foo }', 'foo'), root_dir), accessor_uri, foo_accessor_line_index, 'member after 6 supertype levels')
assert_location(lookup.definition(params_at('deep { bar }', 'bar'), root_dir), folder_uri(plugin_dir, 'com/example/Deep5.kt'), 3, 'member after 5 supertype levels')

assert_equal(other_library_names, {}, 'workspace/symbol queries before the cases that need the server')

-- A catalog from another file, then no catalog file: the getter of the accessor class.
local getter_uri = folder_uri(dependency_accessors_dir, 'org/gradle/accessors/dm/LibrariesForLibs.java')
assert_location(lookup.definition(params_at('libs.foo', 'foo'), root_dir), getter_uri, 3, 'catalog with no key')
vim.fn.delete(catalog_path)
assert_location(lookup.definition(params_at('libs.foo', 'foo'), root_dir), getter_uri, 3, 'no catalog file')

-- A plugin class of `build-logic` is not in the source path.
assert_equal(lookup.definition(params_at('id("com.example.convention")', 'convention'), root_dir), { other_library_location }, 'plugin id in build-logic')
assert_equal(other_library_names, { { 'ConventionPlugin' } }, 'workspace/symbol queries for a plugin in build-logic')

-- An import of a class that is not in the source path.
assert_equal(lookup.definition(params_at('val remote: Remote', 'Remote'), root_dir), { other_library_location }, 'import from another library')
assert_equal(other_library_names, { { 'ConventionPlugin' }, { 'com.other.Remote' } }, 'workspace/symbol queries for an import from another library')

-- The first receiver of a settings script is `Settings`. `Project` has the same getter.
vim.cmd.edit(vim.fn.fnameescape(settings_path))
assert_location(
  lookup.definition({ textDocument = { uri = vim.uri_from_bufnr(0) }, position = { line = 0, character = 0 } }, root_dir),
  jar_uri(gradle_api_jar, 'org/gradle/api/initialization/Settings.java'),
  3,
  'getter of the settings receiver'
)

assert_equal(lookup.hover(params_at('unknownBlock { foo }', 'unknownBlock'), root_dir), nil, 'hover on a location with no readable file')

-- References: the script of the fixture and the two new scripts use `compileSdk` of
-- `BaseDefaultConfig`. The variable `compileSdk` has no block, and the script in `build/` is not
-- searched.
local compile_sdk_target = {
  uri = folder_uri(plugin_dir, 'com/example/dsl/BaseDefaultConfig.kt'),
  range = { start = { line = line_index_of(base_default_config_lines, 'compileSdk'), character = 8 }, ['end'] = { line = 0, character = 0 } },
}
local function use_at(path, line_index, character)
  local position = { line = line_index, character = character }
  return { uri = vim.uri_from_fname(root_dir .. '/' .. path), range = { start = position, ['end'] = position } }
end
assert_equal(lookup.references('compileSdk', { compile_sdk_target }, root_dir), {
  use_at('build.gradle.kts', line_index_of(script_lines, 'compileSdk = 36'), 8),
  use_at('references/a.gradle.kts', 2, 8),
  use_at('references/b.gradle.kts', 3, 8),
}, 'references of a member in a block')
assert_equal(lookup.references('compileSdk', { { uri = 'file:///other/Target.kt', range = compile_sdk_target.range } }, root_dir), {}, 'references of another target')

-- The steps that do not use the position run once for all hits.
other_library_names = {}
write_files(root_dir, { [reference_script_paths[3]] = { 'remoteCall()', 'remoteCall()' } })
assert_equal(lookup.references('remoteCall', { other_library_location }, root_dir), {
  use_at(reference_script_paths[3], 0, 0),
  use_at(reference_script_paths[3], 1, 0),
}, 'references of a name from another library')
assert_equal(other_library_names, { { 'remoteCall' } }, 'workspace/symbol queries for the references of a name from another library')

assert_equal(#assert(lookup.references('limitName', {}, root_dir)), 0, 'references at the limit')
assert_equal(lookup.references('overLimitName', {}, root_dir), nil, 'references above the limit')

-- The server finds a class file of a library for a name in a script that is not in the model and not
-- in a buffer. The class file maps to the same source as the target.
local library_classes_jar = work_dir .. '/lib/example.jar'
vim.fn.writefile({
  vim.json.encode({ libraries = { { name = 'Example', roots = { { path = library_classes_jar }, { path = plugin_dir, type = 'SOURCES' } } } } }),
}, sources.cache_dir(root_dir) .. '/library-sources/workspace.json')
write_files(root_dir, { ['references/library.gradle.kts'] = { 'val device: ManagedDevice? = null' } })
other_library_result = { { uri = ('jar://%s!/com/example/ManagedDevice.class'):format(library_classes_jar), range = compile_sdk_target.range } }
local managed_device_target = { uri = folder_uri(plugin_dir, 'com/example/ManagedDevice.kt'), range = { start = { line = 2, character = 0 }, ['end'] = { line = 2, character = 0 } } }
assert_equal(lookup.references('ManagedDevice', { managed_device_target }, root_dir), {
  use_at('build.gradle.kts', line_index_of(script_lines, 'import com.example.ManagedDevice'), 19),
  use_at('build.gradle.kts', line_index_of(script_lines, 'val device'), 16),
  use_at('references/library.gradle.kts', 0, 12),
}, 'references of a class file in a script with no buffer')
other_library_result = { other_library_location }

-- A script that is not in the model, for example a new file.
other_library_names = {}
vim.cmd.edit(vim.fn.fnameescape(root_dir .. '/other/build.gradle.kts'))
local other_params = { textDocument = { uri = vim.uri_from_bufnr(0) }, position = { line = 0, character = 11 } }
assert_equal(lookup.definition(other_params, root_dir), { other_library_location }, 'name in a script with no entry')
assert_equal(other_library_names, { { 'foo' } }, 'workspace/symbol queries for a script with no entry')
assert_equal(warnings, {}, 'warnings')

vim.fn.delete(work_dir, 'rf')
print 'script_lookup_spec: ok'
