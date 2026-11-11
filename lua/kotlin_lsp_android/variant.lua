-- `:AndroidVariant`: lists and sets the build variant with the `kotlin-lsp variant` commands.
local M = {}

-- The same executable as the `cmd` of the client.
local executable = 'kotlin-lsp'

---@param args string[]
---@return vim.SystemObj
local function run(args, root, on_exit)
  return vim.system(vim.list_extend({ executable, 'variant' }, args), { cwd = root, text = true }, on_exit)
end

local function notify_error(result)
  vim.notify(vim.trim(result.stderr), vim.log.levels.ERROR)
end

---@param root string
---@param on_names fun(names: string[])
local function list(root, on_names)
  run({ 'list' }, root, vim.schedule_wrap(function(result)
    if result.code ~= 0 then
      return notify_error(result)
    end
    on_names(vim.split(result.stdout, '\n', { trimempty = true }))
  end))
end

---@param root string
---@param name string
local function set(root, name)
  vim.notify(('All Neovim instances of %s reconnect to a new server.'):format(root))
  run({ 'set', name }, root, vim.schedule_wrap(function(result)
    if result.code ~= 0 then
      return notify_error(result)
    end
    vim.cmd.LspRestart 'kotlin_lsp'
  end))
end

---@param get_last_root fun(): string?
function M.setup(get_last_root)
  local function find_root()
    local client = vim.lsp.get_clients({ name = 'kotlin_lsp', bufnr = 0 })[1]
    local root = client and client.root_dir or get_last_root()
    if not root then
      vim.notify('AndroidVariant: no kotlin_lsp client for this buffer, and no earlier Kotlin buffer', vim.log.levels.ERROR)
    end
    return root
  end

  vim.api.nvim_create_user_command('AndroidVariant', function(command)
    local root = find_root()
    if not root then
      return
    end
    if command.args ~= '' then
      return set(root, command.args)
    end
    list(root, function(names)
      vim.ui.select(names, { prompt = 'Android variant' }, function(choice)
        if choice then
          set(root, choice)
        end
      end)
    end)
  end, {
    nargs = '?',
    desc = 'List or set the Android build variant of the kotlin-lsp server',
    complete = function(prefix)
      local root = find_root()
      if not root then
        return {}
      end
      local result = run({ 'list' }, root):wait()
      if result.code ~= 0 then
        return {}
      end
      return vim.tbl_filter(function(name)
        return vim.startswith(name, prefix)
      end, vim.split(result.stdout, '\n', { trimempty = true }))
    end,
  })
end

return M
