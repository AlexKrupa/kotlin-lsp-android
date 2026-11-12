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
write_files(dependency_accessors_dir, {
  ['org/gradle/accessors/dm/LibrariesForLibs.java'] = catalog_accessor,
  ['org/gradle/accessors/dm/LibrariesForLibsInPluginsBlock.java'] = catalog_accessor,
})

local plugin_dir = work_dir .. '/plugin/src'
local base_default_config_lines = { 'package com.example.dsl', '', 'interface BaseDefaultConfig {', '    var compileSdk: Int?', '}' }
local application_extension_lines = { 'package com.example', '', 'interface ApplicationExtension :', '    CommonExtension {', '    var namespace: String?', '}' }
local plugin_files = {
  ['com/example/ApplicationExtension.kt'] = application_extension_lines,
  ['com/example/CommonExtension.kt'] = {
    'package com.example',
    '',
    'import com.example.dsl.ApplicationDefaultConfig',
    '',
    'interface CommonExtension {',
    '    fun defaultConfig(action: ApplicationDefaultConfig.() -> Unit)',
    '}',
  },
  ['com/example/dsl/ApplicationDefaultConfig.kt'] = { 'package com.example.dsl', '', 'interface ApplicationDefaultConfig : BaseDefaultConfig' },
  ['com/example/dsl/BaseDefaultConfig.kt'] = base_default_config_lines,
  ['com/example/LibraryExtension.kt'] = { 'package com.example', '', 'interface LibraryExtension {', '    var namespace: String?', '}' },
  ['com/example/AppPlugin.kt'] = { 'package com.example', '', 'class AppPlugin : Plugin<Project> {', '}' },
  ['com/example/ManagedDevice.kt'] = { 'package com.example', '', 'class ManagedDevice' },
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

local gradle_api_jar = work_dir .. '/gradle-api-sources.jar'
write_jar(gradle_api_jar, {
  ['org/gradle/api/Project.java'] = { 'package org.gradle.api;', '', 'public interface Project extends Comparable<Project> {', '    Project getRootProject();', '}' },
  ['org/gradle/api/initialization/Settings.java'] = {
    'package org.gradle.api.initialization;',
    '',
    'public interface Settings {',
    '    ProjectDescriptor getRootProject();',
    '}',
  },
  ['org/gradle/internal/Project.java'] = { 'package org.gradle.internal;', '', 'public class Project {', '}' },
})

local kotlin_plugin_jar = work_dir .. '/kotlin-gradle-plugin-sources.jar'
write_jar(kotlin_plugin_jar, {
  ['org/jetbrains/kotlin/gradle/plugin/KotlinAndroidPluginWrapper.kt'] = {
    'package org.jetbrains.kotlin.gradle.plugin',
    '',
    'open class KotlinAndroidPluginWrapper : AbstractKotlinAndroidPluginWrapper()',
  },
})

local missing_jar = work_dir .. '/missing-sources.jar'
local source_path = { accessors_dir, dependency_accessors_dir, plugin_dir, other_jar, gradle_api_jar, kotlin_plugin_jar, missing_jar }

local script_lines = {
  'import com.example.ManagedDevice',
  '',
  'plugins {',
  '    id("com.example.app")',
  '    kotlin("android")',
  '    alias(libs.plugins.ksp)',
  '    id("com.example.convention")',
  '}',
  '',
  'android {',
  '    val device: ManagedDevice? = null',
  '    namespace = "com.example.app"',
  '    defaultConfig {',
  '        compileSdk = 36',
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
vim.fn.writefile({
  vim.json.encode({
    lists = { source_path, { 'org.gradle.api.*', 'org.gradle.kotlin.dsl.*', 'java.io.File' } },
    scripts = {
      [assert(vim.uv.fs_realpath(settings_path))] = { sourcePath = 0, implicitImports = 1, pluginClasses = {} },
      [assert(vim.uv.fs_realpath(script_path))] = {
        sourcePath = 0,
        implicitImports = 1,
        pluginClasses = {
          ['com.example.app'] = 'com.example.AppPlugin',
          ['com.example.convention'] = 'ConventionPlugin',
          ['org.jetbrains.kotlin.android'] = 'org.jetbrains.kotlin.gradle.plugin.KotlinAndroidPluginWrapper',
        },
      },
    },
  }),
}, model_path)

-- `workspace/symbol` needs a server.
local other_library_location = { uri = 'file:///build-logic/Found.kt', range = { start = { line = 1, character = 0 }, ['end'] = { line = 1, character = 0 } } }
local other_library_names = {}
sources.find_in_other_libraries = function(names)
  table.insert(other_library_names, names)
  return { other_library_location }
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
assert_equal(sources.roots_with_package(source_path, 'org.gradle.kotlin.dsl'), { accessors_dir }, 'roots of org.gradle.kotlin.dsl')

assert_location(lookup.definition(params_at('id("com.example.app")', 'app'), root_dir), folder_uri(plugin_dir, 'com/example/AppPlugin.kt'), 2, 'plugin id')

assert_location(
  lookup.definition(params_at('kotlin("android")', 'android'), root_dir),
  jar_uri(kotlin_plugin_jar, 'org/jetbrains/kotlin/gradle/plugin/KotlinAndroidPluginWrapper.kt'),
  2,
  'Kotlin plugin id'
)

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
assert_location(sources.to_sources({}, params_at('val root: Project', 'Project'), root_dir), jar_uri(gradle_api_jar, 'org/gradle/api/Project.java'), 2, 'implicit import')

assert_location(
  lookup.definition(params_at('implementation(libs.androidx', 'implementation'), root_dir),
  folder_uri(accessors_dir, 'org/gradle/kotlin/dsl/ImplementationConfigurationAccessors.kt'),
  8,
  'accessor'
)

-- Review focus 2: braces in strings and comments.
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

local foo_accessor_uri = folder_uri(accessors_dir, 'org/gradle/kotlin/dsl/Accessors1.kt')
local foo_accessor_line_index = 19
assert_location(lookup.definition(params_at('unknownBlock { foo }', 'foo'), root_dir), foo_accessor_uri, foo_accessor_line_index, 'name in a block with no type')
assert_location(lookup.definition(params_at('deep { foo }', 'foo'), root_dir), foo_accessor_uri, foo_accessor_line_index, 'member after 6 supertype levels')
assert_location(lookup.definition(params_at('deep { bar }', 'bar'), root_dir), folder_uri(plugin_dir, 'com/example/Deep5.kt'), 3, 'member after 5 supertype levels')

assert_equal(other_library_names, {}, 'workspace/symbol queries before the cases that need the server')

-- Review focus 4: a catalog from another file, then no catalog file.
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

-- A script that is not in the model, for example a new file.
other_library_names = {}
vim.cmd.edit(vim.fn.fnameescape(root_dir .. '/other/build.gradle.kts'))
local other_params = { textDocument = { uri = vim.uri_from_bufnr(0) }, position = { line = 0, character = 11 } }
assert_equal(lookup.definition(other_params, root_dir), { other_library_location }, 'name in a script with no entry')
assert_equal(other_library_names, { { 'foo' } }, 'workspace/symbol queries for a script with no entry')
assert_equal(warnings, {}, 'warnings')

vim.fn.delete(work_dir, 'rf')
print 'script_lookup_spec: ok'
