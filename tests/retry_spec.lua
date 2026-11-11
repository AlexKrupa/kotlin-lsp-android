-- Run from the repo root: nvim --clean --headless -l tests/retry_spec.lua
local repo_root = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
vim.opt.runtimepath:prepend(repo_root)
package.path = repo_root .. '/lua/?.lua;' .. repo_root .. '/lua/?/init.lua;' .. package.path

local work_dir = vim.fn.resolve(vim.fn.tempname())
vim.env.KOTLIN_LSP_CACHE = work_dir .. '/cache'
vim.env.XDG_CACHE_HOME = work_dir .. '/xdg-cache'
local project_dir = work_dir .. '/project'
vim.fn.mkdir(project_dir, 'p')

local source_path = work_dir .. '/B.kt'
vim.fn.writefile({ 'class B' }, source_path)
local class_uri = ('jar://%s/library.jar!/b/B.class'):format(work_dir)
vim.env.FAKE_CLASS_URI = class_uri
vim.env.FAKE_SOURCE_URI = vim.uri_from_fname(source_path)

local executable = work_dir .. '/kotlin-lsp'
vim.fn.writefile({
  '#!/bin/sh',
  ('exec nvim --clean --headless -l %s/tests/fake_kotlin_lsp.lua'):format(repo_root),
}, executable)
vim.fn.setfperm(executable, 'rwx------')

local messages = {}
vim.notify = function(message)
  table.insert(messages, message)
end

local plugin = require 'kotlin_lsp_android'
plugin.setup({ executable = executable })

local project_file = project_dir .. '/A.kt'
vim.fn.writefile({ 'val b = B()' }, project_file)
vim.cmd.edit(vim.fn.fnameescape(project_file))
local project_buffer = vim.api.nvim_get_current_buf()
local client_id = assert(vim.lsp.start({ name = 'kotlin_lsp', cmd = plugin.cmd, root_dir = project_dir }))
local client = assert(vim.lsp.get_client_by_id(client_id))
assert(vim.wait(5000, function()
  return client.initialized
end), 'the fake kotlin_lsp client did not initialize')

local function wait_for_buffer(name)
  assert(vim.wait(5000, function()
    return vim.api.nvim_buf_get_name(0) == name
  end), ('buffer = %q, want %q'):format(vim.api.nvim_buf_get_name(0), name))
end

local function definition_count()
  return assert(client:request_sync('test/definitionCount', {}, 5000)).result
end

local function jump()
  vim.api.nvim_set_current_buf(project_buffer)
  vim.api.nvim_win_set_cursor(0, { 1, 8 })
  vim.lsp.buf.definition()
end

-- A jump during the indexing opens the class file, and moves to the source when the indexing ends.
jump()
wait_for_buffer(class_uri)
assert(#messages == 1 and messages[1]:find('indexing', 1, true), ('messages = %s, want one about the indexing'):format(vim.inspect(messages)))
client:notify('test/endIndexing')
wait_for_buffer(source_path)

-- The source replaces the class file, so that one step back goes to the start of the jump.
vim.api.nvim_feedkeys(vim.keycode '<C-o>', 'nx', false)
wait_for_buffer(project_file)
vim.api.nvim_feedkeys(vim.keycode '<C-i>', 'nx', false)
wait_for_buffer(source_path)
vim.cmd.pop()
wait_for_buffer(project_file)

-- After the user leaves the class file, the result of the retry does not move the cursor.
client:notify('test/beginIndexing')
jump()
wait_for_buffer(class_uri)
local count_before_end = definition_count()
vim.api.nvim_set_current_buf(project_buffer)
client:notify('test/endIndexing')
assert(vim.wait(5000, function()
  return definition_count() == count_before_end + 1
end), 'the plugin did not send the request again')
vim.wait(200)
assert(vim.api.nvim_buf_get_name(0) == project_file, ('buffer = %q, want the project file'):format(vim.api.nvim_buf_get_name(0)))

-- A class file location without the indexing is final, for example a library without sources.
client:notify('test/classOnly')
local count_before_jump = definition_count()
jump()
wait_for_buffer(class_uri)
vim.wait(200)
assert(definition_count() == count_before_jump + 1, 'the plugin sent the request again without the indexing')

client:stop(true)
vim.fn.delete(work_dir, 'rf')
print 'retry_spec: ok'
