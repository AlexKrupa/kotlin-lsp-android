-- Run from the repo root: nvim --clean --headless -l tests/script_model_spec.lua
local repo_root = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
vim.opt.runtimepath:prepend(repo_root)
package.path = repo_root .. '/lua/?.lua;' .. repo_root .. '/lua/?/init.lua;' .. package.path

-- Not resolved on purpose: on macOS, the temporary folder is a symlink (`/var` to `/private/var`).
local work_dir = vim.fn.tempname()
vim.fn.mkdir(work_dir, 'p')
vim.env.KOTLIN_LSP_CACHE = work_dir .. '/cache'

local warnings = {}
vim.notify = function(message, level)
  if level == vim.log.levels.WARN then
    table.insert(warnings, message)
  end
end

local sources = require 'kotlin_lsp_android.sources'
local script_model = require 'kotlin_lsp_android.script_model'

-- A fake `kotlin-lsp`. It counts its calls, and it writes `model.json` as the model of the root in
-- its folder, to the library sources folder that `targets/<root name>` names. A `fail` file in its
-- folder makes it fail.
local executable = work_dir .. '/kotlin-lsp'
vim.fn.writefile({
  '#!/bin/sh',
  ('dir=%q'):format(work_dir),
  '[ "$1" = script-model ] || exit 2',
  'echo run >> "$dir/calls"',
  'if [ -e "$dir/fail" ]; then echo "no gradle-home.txt" >&2; exit 1; fi',
  'out="$(cat "$dir/targets/$(basename "$PWD")")"',
  'mkdir -p "$out"',
  'cp "$dir/model.json" "$out/gradle-scripts.json.tmp"',
  'mv "$out/gradle-scripts.json.tmp" "$out/gradle-scripts.json"',
}, executable)
vim.fn.setfperm(executable, 'rwx------')
script_model.setup(executable)

local function model_path(root_dir)
  return sources.cache_dir(root_dir) .. '/library-sources/gradle-scripts.json'
end

local function new_root(name)
  local root_dir = work_dir .. '/' .. name
  vim.fn.mkdir(root_dir, 'p')
  vim.fn.writefile({}, root_dir .. '/build.gradle.kts')
  vim.fn.mkdir(work_dir .. '/targets', 'p')
  vim.fn.writefile({ vim.fs.dirname(model_path(root_dir)) }, work_dir .. '/targets/' .. name)
  return root_dir
end

local function write_model(root_dir)
  vim.fn.mkdir(vim.fs.dirname(model_path(root_dir)), 'p')
  vim.fn.writefile({ vim.fn.readblob(work_dir .. '/model.json') }, model_path(root_dir))
end

local function call_count()
  return vim.fn.filereadable(work_dir .. '/calls') == 1 and #vim.fn.readfile(work_dir .. '/calls') or 0
end

local function set_model(real_script_path)
  vim.fn.writefile({ vim.json.encode({
    lists = { { '/lib/a-sources.jar', '/lib/src' }, { 'org.gradle.api.*' } },
    scripts = {
      [real_script_path] = {
        sourcePath = 0,
        implicitImports = 1,
        pluginClasses = { ['com.example.app'] = 'com.example.AppPlugin' },
      },
    },
  }) }, work_dir .. '/model.json')
end

local function assert_equal(actual, expected, label)
  assert(vim.deep_equal(actual, expected), ('%s = %s, want %s'):format(label, vim.inspect(actual), vim.inspect(expected)))
end

local expected_entry = {
  source_path = { '/lib/a-sources.jar', '/lib/src' },
  implicit_imports = { 'org.gradle.api.*' },
  plugin_classes = { ['com.example.app'] = 'com.example.AppPlugin' },
}

-- A path with a symlink in it: the model has the real path of the script.
local root_dir = new_root('present')
local script_path = root_dir .. '/build.gradle.kts'
local real_script_path = assert(vim.uv.fs_realpath(script_path))
if vim.uv.os_uname().sysname == 'Darwin' then
  assert(real_script_path ~= script_path, 'the temporary folder has no symlink: ' .. script_path)
end
set_model(real_script_path)
write_model(root_dir)

assert_equal(script_model.get(root_dir, script_path), expected_entry, 'get of a script in the file')
assert_equal(script_model.get(root_dir, real_script_path), expected_entry, 'get with the real path')

-- The file changes: the cache follows the modification time.
local changed = vim.fn.readblob(work_dir .. '/model.json'):gsub('com.example.AppPlugin', 'com.example.Other')
vim.fn.writefile({ changed }, model_path(root_dir))
assert(script_model.get(root_dir, script_path).plugin_classes['com.example.app'] == 'com.example.Other', 'get returns the old file')

-- A script that the file does not list: no entry, and no run.
assert(script_model.get(root_dir, root_dir .. '/other/build.gradle.kts') == nil, 'get of an unknown script is not nil')
vim.wait(300)
assert_equal(call_count(), 0, 'calls after get of an unknown script')

-- No file: nil, one run, then the entry.
local missing_root = new_root('missing')
local missing_script = missing_root .. '/build.gradle.kts'
set_model(assert(vim.uv.fs_realpath(missing_script)))
assert(script_model.get(missing_root, missing_script) == nil, 'get with no file is not nil')
assert(vim.wait(5000, function()
  return script_model.get(missing_root, missing_script) ~= nil
end), 'get returns nil after the run')
assert_equal(script_model.get(missing_root, missing_script), expected_entry, 'get after the run')
assert_equal(call_count(), 1, 'calls after a missing file')

-- Invalid JSON, for example from a crash during an old write: nil, one run, then the entry.
local invalid_root = new_root('invalid')
local invalid_script = invalid_root .. '/build.gradle.kts'
set_model(assert(vim.uv.fs_realpath(invalid_script)))
vim.fn.mkdir(vim.fs.dirname(model_path(invalid_root)), 'p')
vim.fn.writefile({ '{ "lists": [[' }, model_path(invalid_root))
assert(script_model.get(invalid_root, invalid_script) == nil, 'get with invalid JSON is not nil')
assert(vim.wait(5000, function()
  return script_model.get(invalid_root, invalid_script) ~= nil
end), 'get returns nil after the run')
assert_equal(call_count(), 2, 'calls after invalid JSON')

-- Three refresh calls before the end of the first run: one more run after the first run.
local twice_root = new_root('twice')
script_model.refresh(twice_root)
script_model.refresh(twice_root)
script_model.refresh(twice_root)
assert(vim.wait(5000, function()
  return call_count() == 4
end), 'no second run after refresh calls during a run')
vim.wait(300)
assert_equal(call_count(), 4, 'calls after three refresh calls')

-- A failed run shows one warning for the root, also after a second failed run.
vim.fn.writefile({}, work_dir .. '/fail')
local failing_root = new_root('failing')
script_model.refresh(failing_root)
assert(vim.wait(5000, function()
  return #warnings > 0
end), 'no warning after a failed run')
assert_equal(warnings, { ('kotlin_lsp: no Gradle script model for %s: no gradle-home.txt'):format(failing_root) }, 'warnings')
script_model.refresh(failing_root)
assert(vim.wait(5000, function()
  return call_count() == 6
end), 'no second run')
vim.wait(500)
assert_equal(#warnings, 1, 'warning count after a second failed run')

-- Another root gets its own warning.
script_model.refresh(new_root('failing-too'))
assert(vim.wait(5000, function()
  return #warnings == 2
end), 'no warning for the second root')

vim.fn.delete(work_dir, 'rf')
print 'script_model_spec: ok'
