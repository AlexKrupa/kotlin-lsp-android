local M = {}

-- A library file has no project root. It uses the server of the last Kotlin buffer, which is the
-- buffer that the jump came from, so that a next jump inside the library also works. `#` cannot
-- show that buffer, because the new buffer loads in a temporary window.
local last_root

---@return string? root_dir of the last buffer with a `kotlin_lsp` client
local function get_last_root()
  return last_root
end

function M.setup()
  vim.api.nvim_create_autocmd({ 'BufEnter', 'LspAttach' }, {
    group = vim.api.nvim_create_augroup('kotlin-lsp-last-root', { clear = true }),
    callback = function(event)
      local client = vim.lsp.get_clients({ name = 'kotlin_lsp', bufnr = event.buf })[1]
      if client then
        last_root = client.root_dir
      end
    end,
  })
  require('kotlin_lsp_android.jar').setup(get_last_root)
  require('kotlin_lsp_android.variant').setup(get_last_root)
end

---@param bufnr integer
---@param on_dir fun(root_dir: string)
function M.root_dir(bufnr, on_dir)
  local name = vim.api.nvim_buf_get_name(bufnr)
  local is_library_file = vim.startswith(name, 'jar:')
    or name:match '/sources/android%-[^/]+/' ~= nil
    or name:match '/gradle%-sources/gradle%-[^/]+/' ~= nil
    or name:match '/wrapper/dists/.-/src/' ~= nil
  if is_library_file then
    if last_root then
      on_dir(last_root)
    end
    return
  end
  -- `jdtls` owns the Java files of a project. `java` is in `filetypes` for Java library files.
  if vim.bo[bufnr].filetype == 'java' then
    return
  end
  -- Each marker searches all parents before the next, so a module `build.gradle.kts` does not win
  -- over the repo `settings.gradle.kts`. The `kotlin-lsp` binary uses the same order.
  local root_dir = vim.fs.root(bufnr, { 'settings.gradle.kts', 'settings.gradle', 'build.gradle.kts', 'build.gradle' })
  if root_dir then
    on_dir(root_dir)
  end
end

local location_methods = {
  ['textDocument/declaration'] = true,
  ['textDocument/definition'] = true,
  ['textDocument/implementation'] = true,
  ['textDocument/typeDefinition'] = true,
}

-- The proxy exits with this code when the server closes the connection, for example after
-- `variant set` in any Neovim instance.
local server_closed_exit_code = 3

---@param dispatchers vim.lsp.rpc.Dispatchers
---@param config vim.lsp.ClientConfig
function M.cmd(dispatchers, config)
  local rpc
  local on_exit = dispatchers.on_exit
  local function start_again(code, signal)
    if code ~= server_closed_exit_code then
      return on_exit(code, signal)
    end
    -- The buffers must be read now: the exit detaches them.
    local client = vim.iter(vim.lsp.get_clients({ name = 'kotlin_lsp' })):find(function(candidate)
      return candidate.rpc == rpc
    end)
    local buffers = client and vim.tbl_keys(client.attached_buffers) or {}
    -- Code 0, because Neovim shows a warning for any other code.
    on_exit(0, signal)
    vim.schedule(function()
      for _, buffer in ipairs(buffers) do
        if vim.api.nvim_buf_is_loaded(buffer) then
          vim.lsp.start(config, { bufnr = buffer })
        end
      end
    end)
  end
  rpc = vim.lsp.rpc.start(
    { 'kotlin-lsp', '--stdio' },
    vim.tbl_extend('force', dispatchers, { on_exit = start_again }),
    { cwd = config.root_dir }
  )
  -- The change is in the RPC client, not in a handler, so that each consumer of locations, for
  -- example Telescope, gets the sources.
  local request = rpc.request
  rpc.request = function(method, params, callback, notify_reply_callback)
    if not location_methods[method] then
      return request(method, params, callback, notify_reply_callback)
    end
    return request(method, params, function(err, result)
      -- The search waits for `rg` and `unzip`, which a fast event cannot do.
      vim.schedule(function()
        callback(err, err == nil and require('kotlin_lsp_android.sources').to_sources(result, params, config.root_dir) or result)
      end)
    end, notify_reply_callback)
  end
  return rpc
end

return M
