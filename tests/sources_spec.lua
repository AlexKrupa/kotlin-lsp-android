-- Run from the repo root: nvim --clean --headless -l tests/sources_spec.lua
local repo_root = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
vim.opt.runtimepath:prepend(repo_root)
package.path = repo_root .. '/lua/?.lua;' .. repo_root .. '/lua/?/init.lua;' .. package.path

local work_dir = vim.fn.tempname()
vim.env.KOTLIN_LSP_CACHE = work_dir .. '/cache'
vim.env.XDG_CACHE_HOME = work_dir .. '/xdg-cache'
local root_dir = work_dir .. '/project'
vim.fn.mkdir(root_dir, 'p')

-- Like the stdlib sources jar, the files are in a top folder that is not part of the package.
local sources_dir = work_dir .. '/sources'
vim.fn.mkdir(sources_dir .. '/commonMain/kotlin/collections', 'p')
vim.fn.writefile({
  'package kotlin.collections',
  '',
  'public fun <T> emptyList(): List<T> = EmptyList',
}, sources_dir .. '/commonMain/kotlin/collections/Collections.kt')
vim.fn.writefile({
  'package kotlin',
  '',
  'public data class Pair<out A, out B>(val first: A, val second: B)',
}, sources_dir .. '/commonMain/kotlin/Tuples.kt')
local sources_jar = work_dir .. '/kotlin-stdlib-sources.jar'
local zip_result = vim.system({ 'zip', '-q', '-r', sources_jar, 'commonMain' }, { cwd = sources_dir, text = true }):wait()
assert(zip_result.code == 0, 'zip failed: ' .. zip_result.stderr)

local classes_jar = work_dir .. '/lib/kotlin-stdlib.jar'
local cache_dir = ('%s/%s'):format(vim.env.KOTLIN_LSP_CACHE, vim.fn.sha256(root_dir):sub(1, 12))
vim.fn.mkdir(cache_dir .. '/library-sources', 'p')
vim.fn.writefile({
  vim.json.encode({
    libraries = {
      { name = 'Sources: org.jetbrains.kotlin:kotlin-stdlib:2.4.0', roots = { { path = classes_jar }, { path = sources_jar, type = 'SOURCES' } } },
    },
  }),
}, cache_dir .. '/library-sources/workspace.json')

vim.fn.writefile({ 'val pair: Pair<Int, Int> = TODO()', 'val list = emptyList<Int>()' }, root_dir .. '/A.kt')
vim.cmd.edit(vim.fn.fnameescape(root_dir .. '/A.kt'))
local document = { uri = vim.uri_from_bufnr(0) }
local sources = require('kotlin_lsp_android.sources')

local function class_location(entry)
  local position = { line = 3, character = 0 }
  return { uri = ('jar://%s!/%s'):format(classes_jar, entry), range = { start = position, ['end'] = position } }
end

local function assert_location(result, want_entry, want_line)
  assert(#result == 1, ('locations = %s, want 1'):format(vim.inspect(result)))
  local want_uri = ('jar://%s!/%s'):format(sources_jar, want_entry)
  assert(result[1].uri == want_uri, ('uri = %q, want %q'):format(result[1].uri, want_uri))
  assert(result[1].range.start.line == want_line, ('line = %d, want %d'):format(result[1].range.start.line, want_line))
end

local facade_result = sources.to_sources(
  { class_location('kotlin/collections/CollectionsKt.class') },
  { textDocument = document, position = { line = 1, character = 12 } },
  root_dir
)
assert_location(facade_result, 'commonMain/kotlin/collections/Collections.kt', 2)

local class_result = sources.to_sources(
  { class_location('kotlin/Pair.class') },
  { textDocument = document, position = { line = 0, character = 11 } },
  root_dir
)
assert_location(class_result, 'commonMain/kotlin/Tuples.kt', 2)

local other_jar = { uri = 'jar:///other.jar!/a/B.class', range = class_location('a/B.class').range }
local other_result = sources.to_sources({ other_jar }, { textDocument = document, position = { line = 0, character = 11 } }, root_dir)
assert(other_result[1].uri == other_jar.uri, ('uri = %q, want the class file'):format(other_result[1].uri))

vim.fn.delete(work_dir, 'rf')
print 'sources_spec: ok'
