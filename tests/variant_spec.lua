-- Run from the repo root: nvim --clean --headless -l tests/variant_spec.lua
local repo_root = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
vim.opt.runtimepath:prepend(repo_root)
package.path = repo_root .. '/lua/?.lua;' .. repo_root .. '/lua/?/init.lua;' .. package.path

local work_dir = vim.fn.tempname()
local bin_dir = work_dir .. '/bin'
local project_dir = work_dir .. '/project'
vim.fn.mkdir(bin_dir, 'p')
vim.fn.mkdir(project_dir, 'p')

-- A fake proxy and server: it answers `initialize` and `shutdown`, and ignores all other messages.
-- It reads with the event loop, so that SIGTERM ends it with exit code 3, like the proxy after the
-- server stops.
vim.fn.writefile(vim.split([[
local function send(id, result)
  local body = vim.json.encode({ jsonrpc = '2.0', id = id, result = result })
  io.write(('Content-Length: %d\r\n\r\n%s'):format(#body, body))
  io.flush()
end

local function handle(message)
  if message.method == 'initialize' then
    send(message.id, { capabilities = vim.empty_dict() })
  elseif message.method == 'shutdown' then
    send(message.id, vim.NIL)
  elseif message.method == 'exit' then
    os.exit(0)
  end
end

local received = ''
local stdin = assert(vim.uv.new_pipe())
stdin:open(0)
stdin:read_start(function(_, chunk)
  if not chunk then
    os.exit(0)
  end
  received = received .. chunk
  while true do
    local header_end = received:find('\r\n\r\n', 1, true)
    if not header_end then
      return
    end
    local body_start = header_end + 4
    local body_end = body_start + tonumber(received:match('Content%-Length: (%d+)')) - 1
    if #received < body_end then
      return
    end
    handle(vim.json.decode(received:sub(body_start, body_end)))
    received = received:sub(body_end + 1)
  end
end)
assert(vim.uv.new_signal()):start('sigterm', function()
  os.exit(3)
end)
while true do
  vim.wait(60000, function()
    return false
  end)
end
]], '\n'), bin_dir .. '/server.lua')

-- A fake `kotlin-lsp`. Like the real binary, `variant set` stops the server, so that each client
-- process ends before `variant set` ends.
vim.fn.writefile(vim.split(([[
#!/bin/sh
dir='%s'
case "$1" in
--stdio)
  echo $$ >> "$dir/servers"
  exec nvim --clean -l "$dir/server.lua"
  ;;
variant)
  echo "$3" > "$dir/variant"
  kill $(cat "$dir/servers")
  : > "$dir/servers"
  ;;
esac
]]):format(bin_dir), '\n'), bin_dir .. '/kotlin-lsp')
vim.fn.setfperm(bin_dir .. '/kotlin-lsp', 'rwxr-xr-x')

vim.fn.writefile({}, project_dir .. '/settings.gradle.kts')
vim.fn.writefile({ 'class A' }, project_dir .. '/A.kt')

local plugin = require('kotlin_lsp_android')
-- The fake is not on PATH, so the test fails if `cmd` or `:AndroidVariant` ignores the option.
plugin.setup({ executable = bin_dir .. '/kotlin-lsp' })
vim.lsp.config('kotlin_lsp', { cmd = plugin.cmd, root_dir = plugin.root_dir, filetypes = { 'kotlin' } })
vim.lsp.enable('kotlin_lsp')

---@return vim.lsp.Client?
local function client_of_buffer()
  return vim.lsp.get_clients({ name = 'kotlin_lsp', bufnr = 0 })[1]
end

vim.cmd.edit(vim.fn.fnameescape(project_dir .. '/A.kt'))
assert(vim.wait(10000, function()
  local client = client_of_buffer()
  return client ~= nil and client.initialized
end), 'no kotlin_lsp client attached to A.kt')
local old_client = assert(client_of_buffer())

vim.cmd.AndroidVariant 'prodDebug'

local started = vim.wait(10000, function()
  local client = client_of_buffer()
  return client ~= nil and client.id ~= old_client.id and client.initialized
end)
assert(started, ('no new kotlin_lsp client attached to A.kt, v:errmsg = %q'):format(vim.v.errmsg))
assert(old_client:is_stopped(), 'the old client runs')
assert(#vim.lsp.get_clients({ name = 'kotlin_lsp' }) == 1, 'more than one kotlin_lsp client')
local variant = vim.fn.readfile(bin_dir .. '/variant')[1]
assert(variant == 'prodDebug', ('variant = %q, want "prodDebug"'):format(variant))

for _, client in ipairs(vim.lsp.get_clients()) do
  client:stop(true)
end
assert(vim.wait(5000, function()
  return #vim.lsp.get_clients() == 0
end), 'a client started again after a stop with exit code 0')
vim.fn.delete(work_dir, 'rf')
print 'variant_spec: ok'
