-- Run from the repo root: nvim --clean --headless -l tests/root_spec.lua
local repo_root = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = repo_root .. '/lua/?.lua;' .. repo_root .. '/lua/?/init.lua;' .. package.path

local plugin = require 'kotlin_lsp_android'
local work_dir = vim.fn.resolve(vim.fn.tempname())

---@param path string
local function touch(path)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  vim.fn.writefile({}, path)
end

---@param path string
---@return string?
local function root_of(path)
  vim.cmd.edit(vim.fn.fnameescape(path))
  local found
  plugin.root_dir(vim.api.nvim_get_current_buf(), function(root_dir)
    found = root_dir
  end)
  return found
end

touch(work_dir .. '/outer/settings.gradle.kts')
vim.fn.mkdir(work_dir .. '/outer/repo/.git', 'p')
touch(work_dir .. '/outer/repo/settings.gradle.kts')
touch(work_dir .. '/outer/repo/build-logic/settings.gradle.kts')
local found = root_of(work_dir .. '/outer/repo/build-logic/convention/src/Plugin.kt')
assert(found == work_dir .. '/outer/repo', ('root in a git repo = %q, want the repo folder'):format(found))

-- A linked worktree has a `.git` file, not a folder.
touch(work_dir .. '/worktree/.git')
touch(work_dir .. '/worktree/settings.gradle')
touch(work_dir .. '/worktree/build-logic/settings.gradle')
found = root_of(work_dir .. '/worktree/build-logic/Plugin.kt')
assert(found == work_dir .. '/worktree', ('root in a worktree = %q, want the worktree folder'):format(found))

touch(work_dir .. '/plain/settings.gradle.kts')
touch(work_dir .. '/plain/module/build.gradle.kts')
found = root_of(work_dir .. '/plain/module/src/A.kt')
assert(found == work_dir .. '/plain', ('root outside git = %q, want the nearest settings folder'):format(found))

touch(work_dir .. '/single/build.gradle')
found = root_of(work_dir .. '/single/src/A.kt')
assert(found == work_dir .. '/single', ('root with no settings = %q, want the build file folder'):format(found))

vim.fn.delete(work_dir, 'rf')
print 'root_spec: ok'
