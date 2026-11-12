-- Run from the repo root: nvim --clean --headless -l tests/start_spec.lua
local repo_root = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
vim.opt.runtimepath:prepend(repo_root)
package.path = repo_root .. '/lua/?.lua;' .. repo_root .. '/lua/?/init.lua;' .. package.path

local work_dir = vim.fn.resolve(vim.fn.tempname())
local project_dir = work_dir .. '/project'
vim.fn.mkdir(project_dir, 'p')

-- The fake server reads these when it starts.
vim.env.FAKE_SOURCE_URI = vim.uri_from_fname(project_dir .. '/Declaration.kt')
vim.env.FAKE_REFERENCE_URI = vim.uri_from_fname(project_dir .. '/Reference.kt')

local messages = {}
vim.notify = function(message)
  table.insert(messages, message)
end

-- The progress of the start, without the indexing progress of the fake server.
local start_kinds = {}
vim.api.nvim_create_autocmd('LspProgress', {
  callback = function(event)
    if event.data.params.token ~= 'indexing' then
      table.insert(start_kinds, event.data.params.value.kind)
    end
  end,
})

---@param lines string[]
local function write_executable(lines)
  local executable = work_dir .. '/kotlin-lsp'
  vim.fn.writefile(lines, executable)
  vim.fn.setfperm(executable, 'rwx------')
  return executable
end

local plugin = require 'kotlin_lsp_android'

local project_file = project_dir .. '/A.kt'
vim.fn.writefile({ 'class A' }, project_file)
vim.cmd.edit(vim.fn.fnameescape(project_file))

-- The start progress ends before `on_init`.
local script_model_calls = work_dir .. '/script-model-calls'
plugin.setup({ executable = write_executable({
  '#!/bin/sh',
  ('[ "$1" = script-model ] && { echo run >> %s; exit 0; }'):format(script_model_calls),
  ('exec nvim --clean --headless -l %s/tests/fake_kotlin_lsp.lua'):format(repo_root),
}) })
local kinds_at_init
local client_id = assert(vim.lsp.start({
  name = 'kotlin_lsp',
  cmd = plugin.cmd,
  root_dir = project_dir,
  on_init = function()
    kinds_at_init = vim.deepcopy(start_kinds)
  end,
}))
assert(vim.wait(5000, function()
  return kinds_at_init ~= nil
end), 'the client did not initialize')
assert(vim.deep_equal(kinds_at_init, { 'begin', 'end' }), ('start progress at on_init = %s, want begin, end'):format(vim.inspect(kinds_at_init)))

-- The end of the indexing progress starts the script model run, and the start progress does not.
assert(vim.fn.filereadable(script_model_calls) == 0, 'script-model ran before the end of the indexing')
assert(vim.lsp.get_client_by_id(client_id)):notify('test/endIndexing')
assert(vim.wait(5000, function()
  return vim.fn.filereadable(script_model_calls) == 1
end), 'script-model did not run at the end of the indexing')

-- The fake server has no hover, so a hover in a Gradle script gets the result of the lookup.
local script_hover = { contents = { kind = 'markdown', value = 'from the lookup' } }
local lookup_params = {}
require('kotlin_lsp_android.script_lookup').hover = function(params)
  table.insert(lookup_params, params)
  return script_hover
end
local function hover_in(path)
  vim.fn.writefile({ 'x' }, path)
  local params = { textDocument = { uri = vim.uri_from_fname(path) }, position = { line = 0, character = 0 } }
  local response = assert(vim.lsp.get_client_by_id(client_id)):request_sync('textDocument/hover', params, 5000)
  return assert(response, 'no hover response').result
end
assert(vim.deep_equal(hover_in(project_dir .. '/build.gradle.kts'), script_hover), 'hover in a Gradle script is not the result of the lookup')
assert(#lookup_params == 1 and lookup_params[1].textDocument.uri:match('build%.gradle%.kts$'), 'the lookup did not get the hover request')
assert(hover_in(project_dir .. '/B.kt') == nil, 'hover in another file is not the result of the server')
assert(#lookup_params == 1, 'the lookup ran for a file that is not a Gradle script')
assert(vim.deep_equal(hover_in(project_dir .. '/error.gradle.kts'), script_hover), 'hover after a server error in a Gradle script is not the result of the lookup')

-- References from a Kotlin buffer: the server result and the uses in Gradle scripts. The script is
-- not in the model, so the lookup asks the server, which finds the declaration of the definition.
local function references_in(path, script_path, script_lines)
  vim.fn.writefile({ 'class ' .. vim.fs.basename(path):gsub('%.kt$', '') }, path)
  vim.fn.writefile(script_lines, script_path)
  vim.cmd.edit(vim.fn.fnameescape(path))
  local params = { textDocument = { uri = vim.uri_from_fname(path) }, position = { line = 0, character = 6 }, context = { includeDeclaration = false } }
  local response = (assert(vim.lsp.get_client_by_id(client_id))):request_sync('textDocument/references', params, 10000)
  return assert(response, 'no references response').result
end
local function location_at(uri, line_index, character)
  local position = { line = line_index, character = character }
  return { uri = uri, range = { start = position, ['end'] = position } }
end
local script_uri = vim.uri_from_fname(project_dir .. '/uses.gradle.kts')
local server_reference = location_at(vim.env.FAKE_REFERENCE_URI, 0, 0)
local references = references_in(project_dir .. '/C.kt', project_dir .. '/uses.gradle.kts', { 'val x = 1', 'C()' })
assert(vim.deep_equal(references, { server_reference, location_at(script_uri, 1, 0) }), ('references = %s, want the server result and the script use'):format(vim.inspect(references)))

messages = {}
local many_uses = vim.tbl_map(function()
  return 'D()'
end, vim.fn.range(201))
references = references_in(project_dir .. '/D.kt', project_dir .. '/uses.gradle.kts', many_uses)
assert(vim.deep_equal(references, { server_reference }), ('references above the limit = %s, want the server result'):format(vim.inspect(references)))
assert(
  vim.deep_equal(messages, { 'kotlin_lsp: more than 200 matches of D in Gradle scripts, they are not in the references' }),
  ('messages = %s, want the message for the limit'):format(vim.inspect(messages))
)
vim.fn.delete(project_dir .. '/uses.gradle.kts')

-- References from a Gradle script: only the uses in Gradle scripts, which go to the targets of the
-- definition lookup.
script_lookup.definition = function()
  return { script_location }
end
local references_script = project_dir .. '/references.gradle.kts'
vim.fn.writefile({ 'android()', 'android()' }, references_script)
vim.cmd.edit(vim.fn.fnameescape(references_script))
local references_response = (assert(vim.lsp.get_client_by_id(client_id))):request_sync(
  'textDocument/references',
  { textDocument = { uri = vim.uri_from_fname(references_script) }, position = { line = 0, character = 0 }, context = { includeDeclaration = false } },
  10000
)
local references_uri = vim.uri_from_fname(references_script)
assert(
  references_response and vim.deep_equal(references_response.result, { location_at(references_uri, 0, 0), location_at(references_uri, 1, 0) }),
  ('references from a Gradle script = %s, want the uses in the script'):format(vim.inspect(references_response))
)
script_lookup.definition = script_definition

-- All declarations with the name, in the order of the server.
local symbol_locations = require('kotlin_lsp_android.sources').find_in_other_libraries(
  { 'Name' },
  { textDocument = { uri = vim.uri_from_fname(project_file) }, position = { line = 0, character = 0 } },
  project_dir,
  { 'Name' }
)
assert(
  vim.deep_equal(symbol_locations, { location_at(vim.env.FAKE_SOURCE_URI, 0, 0), location_at(vim.env.FAKE_REFERENCE_URI, 0, 0) }),
  ('declarations of a name in other libraries = %s, want both declarations of the name'):format(vim.inspect(symbol_locations))
)

assert(vim.lsp.get_client_by_id(client_id)):stop()
assert(vim.wait(5000, function()
  return vim.lsp.get_client_by_id(client_id) == nil
end), 'the client did not stop')

-- If the proxy exits before `initialize`, the progress ends and Neovim shows the error of the proxy.
start_kinds = {}
messages = {}
local body = vim.json.encode({ jsonrpc = '2.0', method = 'window/showMessage', params = { type = 1, message = 'no Gradle root' } })
local message_file = work_dir .. '/message'
local file = assert(io.open(message_file, 'wb'))
file:write(('Content-Length: %d\r\n\r\n%s'):format(#body, body))
file:close()
plugin.setup({ executable = write_executable({ '#!/bin/sh', ('cat %s'):format(message_file), 'exit 1' }) })
client_id = assert(vim.lsp.start({ name = 'kotlin_lsp', cmd = plugin.cmd, root_dir = project_dir }))
assert(vim.wait(5000, function()
  return vim.lsp.get_client_by_id(client_id) == nil
end), 'the client did not exit')
vim.wait(100)
assert(vim.deep_equal(start_kinds, { 'begin', 'end' }), ('start progress = %s, want begin, end'):format(vim.inspect(start_kinds)))
assert(vim.iter(messages):any(function(message)
  return message:find('no Gradle root', 1, true) ~= nil
end), ('messages = %s, want the error of the proxy'):format(vim.inspect(messages)))

vim.fn.delete(work_dir, 'rf')
print 'start_spec: ok'
