-- Run from the repo root: nvim --clean --headless -l tests/jar_spec.lua
local repo_root = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
vim.opt.runtimepath:prepend(repo_root)
package.path = repo_root .. '/lua/?.lua;' .. repo_root .. '/lua/?/init.lua;' .. package.path

local work_dir = vim.fn.tempname()
vim.fn.mkdir(work_dir .. '/a', 'p')
vim.fn.writefile({ 'class B' }, work_dir .. '/a/B.kt')
local jar_path = work_dir .. '/library-sources.jar'
local zip_result = vim.system({ 'zip', '-q', jar_path, 'a/B.kt' }, { cwd = work_dir, text = true }):wait()
assert(zip_result.code == 0, 'zip failed: ' .. zip_result.stderr)

require('kotlin_lsp_android').setup()

vim.cmd.edit(vim.fn.fnameescape(('jar://%s!/a/B.kt'):format(jar_path)))

local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
assert(text == 'class B', ('buffer text = %q, want "class B"'):format(text))
assert(vim.bo.filetype == 'kotlin', ('filetype = %q, want "kotlin"'):format(vim.bo.filetype))
assert(vim.bo.modifiable == false, 'buffer is modifiable')

local written, message = pcall(vim.cmd.write)
assert(not written, ':write succeeded')
assert(tostring(message):find('read-only', 1, true), (':write error = %q, want it to contain "read-only"'):format(message))

vim.fn.delete(work_dir, 'rf')
print 'jar_spec: ok'
