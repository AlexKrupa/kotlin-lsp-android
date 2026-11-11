local M = {}

local decompiled_by_uri = {}

---@return vim.lsp.Client?
local function find_client(root_dir)
  return vim.iter(vim.lsp.get_clients({ name = 'kotlin_lsp' })):find(function(candidate)
    return candidate.root_dir == root_dir
  end)
end

---@return { code: string, language: string }? stub source of a class file from the server
local function decompile(uri, root_dir)
  if decompiled_by_uri[uri] then
    return decompiled_by_uri[uri]
  end
  local client = find_client(root_dir)
  if not client then
    return nil
  end
  local response = client:request_sync('workspace/executeCommand', { command = 'decompile', arguments = { uri } }, 10000)
  decompiled_by_uri[uri] = response and response.result
  return decompiled_by_uri[uri]
end

-- The server `decompile` command returns no text for a source file.
---@return string text
---@return string? filetype
local function read_jar_entry(uri, root_dir)
  local jar_path, entry_path = uri:match '^jar://(.-)!/(.+)$'
  if entry_path:match '%.kt$' or entry_path:match '%.java$' then
    local result = vim.system({ 'unzip', '-p', jar_path, entry_path }, { text = true }):wait()
    if result.code ~= 0 then
      error(('kotlin_lsp: cannot read %s from %s: %s'):format(entry_path, jar_path, result.stderr))
    end
    return result.stdout, vim.filetype.match({ filename = entry_path })
  end
  local decompiled = decompile(uri, root_dir)
  if not decompiled then
    error(('kotlin_lsp: the server for %s cannot decompile %s'):format(root_dir, uri))
  end
  return decompiled.code, decompiled.language
end

---@param get_last_root fun(): string?
function M.setup(get_last_root)
  -- The buffer keeps an empty `buftype`, because `vim.lsp.enable` attaches only to such buffers.
  -- `BufWriteCmd` stops writes instead.
  local group = vim.api.nvim_create_augroup('kotlin-lsp-jar', { clear = true })
  vim.api.nvim_create_autocmd('BufWriteCmd', {
    pattern = 'jar:///*',
    group = group,
    callback = function(event)
      error(('kotlin_lsp: %s is a library file in a jar, it is read-only'):format(event.match))
    end,
  })
  vim.api.nvim_create_autocmd('BufReadCmd', {
    pattern = 'jar:///*',
    group = group,
    callback = function(event)
      local text, filetype = read_jar_entry(event.match, get_last_root())
      vim.bo[event.buf].swapfile = false
      vim.api.nvim_buf_set_lines(event.buf, 0, -1, false, vim.split((text:gsub('\n$', '')), '\n'))
      vim.bo[event.buf].modified = false
      vim.bo[event.buf].modifiable = false
      vim.bo[event.buf].filetype = filetype or ''
    end,
  })
end

return M
