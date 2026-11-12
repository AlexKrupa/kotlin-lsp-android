local M = {}

-- A library file has no project root. It uses the server of the last Kotlin buffer, which is the
-- buffer that the jump came from, so that a next jump inside the library also works. `#` cannot
-- show that buffer, because the new buffer loads in a temporary window.
local last_root

---@return string? root_dir of the last buffer with a `kotlin_lsp` client
local function get_last_root()
  return last_root
end

-- An LSP client can have a PATH without the folder of the proxy, so `setup` can give a full path.
local executable = 'kotlin-lsp'

---@param opts? { executable?: string } `executable`: the `kotlin-lsp` proxy, default from PATH
function M.setup(opts)
  executable = opts and opts.executable or executable
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
  require('kotlin_lsp_android.variant').setup(get_last_root, executable)
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

-- A server that crashes at each start would get a new Gradle import at each restart. Over the
-- limit, Neovim shows its warning for the exit code.
local restart_limit = 3
local restart_window_ms = 10 * 60 * 1000
---@type table<string, integer[]> restart times of each root, in milliseconds
local restart_times_by_root = {}

-- On the first start of a root, the proxy runs Gradle before the server answers `initialize`.
local start_progress_token = 'kotlin_lsp_android/start'

---@param dispatchers vim.lsp.rpc.Dispatchers
---@param config vim.lsp.ClientConfig
function M.cmd(dispatchers, config)
  local rpc
  ---@return vim.lsp.Client?
  local function find_client()
    return vim.iter(vim.lsp.get_clients({ name = 'kotlin_lsp' })):find(function(candidate)
      return candidate.rpc == rpc
    end)
  end
  local on_exit = dispatchers.on_exit
  local function start_again(code, signal)
    if code ~= server_closed_exit_code then
      return on_exit(code, signal)
    end
    local now_ms = vim.uv.now()
    local restart_times = vim.tbl_filter(function(time_ms)
      return now_ms - time_ms < restart_window_ms
    end, restart_times_by_root[config.root_dir] or {})
    if #restart_times >= restart_limit then
      return on_exit(code, signal)
    end
    table.insert(restart_times, now_ms)
    restart_times_by_root[config.root_dir] = restart_times
    -- The buffers must be read now: the exit detaches them.
    local client = find_client()
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
  local is_starting = true
  ---@param value lsp.WorkDoneProgressBegin|lsp.WorkDoneProgressEnd
  local function report_start(value)
    dispatchers.notification('$/progress', { token = start_progress_token, value = value })
  end
  local function end_start()
    if is_starting then
      is_starting = false
      report_start({ kind = 'end' })
    end
  end
  -- The `$/progress` handler needs the client, which Neovim registers after `cmd` returns.
  vim.schedule(function()
    if is_starting then
      report_start({ kind = 'begin', title = 'Starting kotlin-lsp' })
    end
  end)
  local function on_exit_after_start(code, signal)
    -- Neovim removes the client two event loop cycles after the exit.
    vim.schedule(end_start)
    start_again(code, signal)
  end
  local indexing = require('kotlin_lsp_android.indexing').new()
  rpc = vim.lsp.rpc.start(
    { executable, '--stdio' },
    vim.tbl_extend('force', dispatchers, { on_exit = on_exit_after_start, notification = indexing.observe(dispatchers.notification) }),
    { cwd = config.root_dir }
  )
  -- The change is in the RPC client, not in a handler, so that each consumer of locations, for
  -- example Telescope, gets the sources.
  local request = rpc.request
  ---@param on_located fun(err: lsp.ResponseError?, located: lsp.Location[]|lsp.LocationLink[]|nil, was_indexing: boolean)
  local function request_located(method, params, on_located, notify_reply_callback)
    return request(method, params, function(err, result)
      -- The `$/progress` end can come directly after the result, before the scheduled callback.
      local was_indexing = indexing.is_active()
      -- The search waits for `rg` and `unzip`, which a fast event cannot do.
      vim.schedule(function()
        on_located(err, err == nil and require('kotlin_lsp_android.sources').to_sources(result, params, config.root_dir) or result, was_indexing)
      end)
    end, notify_reply_callback)
  end
  rpc.request = function(method, params, callback, notify_reply_callback)
    if method == 'initialize' then
      return request(method, params, function(err, result)
        end_start()
        callback(err, result)
      end, notify_reply_callback)
    end
    if not location_methods[method] then
      return request(method, params, callback, notify_reply_callback)
    end
    return request_located(method, params, function(err, located, was_indexing)
      callback(err, located)
      if err ~= nil or located == nil or not was_indexing then
        return
      end
      local client = assert(find_client(), 'kotlin_lsp: no client for the RPC client of a location request')
      indexing.retry(located, function(on_locations)
        request_located(method, params, function(_, new_located)
          on_locations(new_located or {})
        end)
      end, client.offset_encoding)
    end, notify_reply_callback)
  end
  return rpc
end

return M
