-- Neovim side of `kotlin-lsp-android`: the client command, the project root, `jar:` buffers, and
-- `:AndroidVariant`.
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
  local is_library_file = vim.startswith(name, 'jar:') or name:match '/sources/android%-[^/]+/' ~= nil
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

---@param dispatchers vim.lsp.rpc.Dispatchers
---@param config vim.lsp.ClientConfig
function M.cmd(dispatchers, config)
  return vim.lsp.rpc.start({ 'kotlin-lsp', '--stdio' }, dispatchers, { cwd = config.root_dir })
end

return M
