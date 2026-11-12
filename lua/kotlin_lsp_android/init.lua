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
  require('kotlin_lsp_android.script_model').setup(executable)
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

---@param located lsp.Location|lsp.Location[]|lsp.LocationLink[]|nil
---@return lsp.Location[]
local function to_locations(located)
  return vim.tbl_map(function(item)
    return item.uri and item or { uri = item.targetUri, range = item.targetSelectionRange }
  end, located == nil and {} or vim.islist(located) and located or { located })
end

-- An error in a lookup, for example for a jar that cannot be read, must not leave a request with no
-- reply. The reply is then the server result.
---@return boolean ok
---@return any result of the lookup, or the error
local function try_lookup(lookup, ...)
  local ok, result = pcall(lookup, ...)
  if not ok then
    vim.notify_once(tostring(result), vim.log.levels.WARN)
  end
  return ok, result
end

---@param hover lsp.Hover?
---@return boolean
local function has_contents(hover)
  local contents = hover and hover.contents
  if type(contents) == 'string' then
    return contents ~= ''
  end
  if type(contents) ~= 'table' then
    return false
  end
  if contents.value ~= nil then
    return contents.value ~= ''
  end
  return #contents > 0
end

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
  local observe_indexing = indexing.observe(dispatchers.notification)
  -- The import writes the Gradle home that the script model needs. The model changes with it.
  ---@param method string
  ---@param params table
  local function notification(method, params)
    observe_indexing(method, params)
    if method == '$/progress' and type(params.value) == 'table' and params.value.kind == 'end' and not indexing.is_active() then
      vim.schedule(function()
        require('kotlin_lsp_android.script_model').refresh(config.root_dir)
      end)
    end
  end
  rpc = vim.lsp.rpc.start(
    { executable, '--stdio' },
    vim.tbl_extend('force', dispatchers, { on_exit = on_exit_after_start, notification = notification }),
    { cwd = config.root_dir }
  )
  -- The change is in the RPC client, not in a handler, so that each consumer of locations, for
  -- example Telescope, gets the sources.
  local request = rpc.request
  ---@param on_located fun(err: lsp.ResponseError?, located: lsp.Location[]|lsp.LocationLink[]|nil, was_indexing: boolean)
  local function request_located(method, params, on_located, notify_reply_callback)
    return request(method, params, function(err, result)
      -- The server does not analyze Gradle scripts. Its error is the same as an empty result.
      if err ~= nil and params.textDocument.uri:match('%.gradle%.kts$') then
        err, result = nil, nil
      end
      -- The `$/progress` end can come directly after the result, before the scheduled callback.
      local was_indexing = indexing.is_active()
      -- The search waits for `rg` and `unzip`, which a fast event cannot do.
      vim.schedule(function()
        local located = result
        if err == nil then
          local ok, mapped = try_lookup(require('kotlin_lsp_android.sources').to_sources, result, params, config.root_dir)
          located = ok and mapped or result
        end
        on_located(err, located, was_indexing)
      end)
    end, notify_reply_callback)
  end
  -- The server does not find the uses of a name in Gradle scripts. The server result stays.
  ---@param params lsp.ReferenceParams
  local function add_script_references(params, err, result, callback)
    local sources = require('kotlin_lsp_android.sources')
    local script_lookup = require('kotlin_lsp_android.script_lookup')
    local name = sources.find_symbol(params)
    local is_script = params.textDocument.uri:match('%.gradle%.kts$') ~= nil
    ---@param targets lsp.Location[]?
    local function reply(targets)
      if not (name and targets and #targets > 0) then
        return callback(err, result)
      end
      local ok, hits = try_lookup(script_lookup.references, name, targets, config.root_dir)
      if not ok then
        return callback(err, result)
      end
      if not hits then
        vim.notify(
          ('kotlin_lsp: more than %d matches of %s in Gradle scripts, they are not in the references'):format(script_lookup.reference_limit, name),
          vim.log.levels.WARN
        )
        return callback(err, result)
      end
      if is_script then
        return callback(nil, hits)
      end
      if err ~= nil then
        return callback(err, result)
      end
      callback(nil, vim.list_extend(to_locations(result), hits))
    end
    if is_script then
      local ok, targets = try_lookup(script_lookup.definition, params, config.root_dir)
      return reply(ok and targets or nil)
    end
    request_located('textDocument/definition', { textDocument = params.textDocument, position = params.position }, function(_, located)
      reply(to_locations(located))
    end)
  end

  rpc.request = function(method, params, callback, notify_reply_callback)
    if method == 'initialize' then
      return request(method, params, function(err, result)
        end_start()
        callback(err, result)
      end, notify_reply_callback)
    end
    -- The server does not analyze Gradle scripts.
    if method == 'textDocument/hover' and params.textDocument.uri:match('%.gradle%.kts$') then
      return request(method, params, function(err, result)
        if err == nil and has_contents(result) then
          return callback(err, result)
        end
        -- The lookup waits for `rg` and `unzip`, which a fast event cannot do.
        vim.schedule(function()
          local ok, hover = try_lookup(require('kotlin_lsp_android.script_lookup').hover, params, config.root_dir)
          if ok and hover then
            return callback(nil, hover)
          end
          callback(err, result)
        end)
      end, notify_reply_callback)
    end
    if method == 'textDocument/references' then
      return request(method, params, function(err, result)
        -- The lookup waits for `rg` and `unzip`, which a fast event cannot do.
        vim.schedule(function()
          add_script_references(params, err, result, callback)
        end)
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
