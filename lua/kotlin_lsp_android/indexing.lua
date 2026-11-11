-- During the import and the indexing, kotlin-lsp can locate a library symbol in a class file,
-- although the library has sources. This module sends the request again when the indexing ends.
local M = {}

---@param location lsp.Location|lsp.LocationLink
---@return string
local function uri_of(location)
  return location.uri or location.targetUri
end

---@param locations lsp.Location[]|lsp.LocationLink[]
local function is_class_file(locations)
  local first = locations[1]
  return first ~= nil and uri_of(first):match '^jar:.*%.class$' ~= nil
end

-- kotlin-lsp reports the import and the indexing as work done progress.
---@return { observe: fun(notification: function): function, is_active: fun(): boolean, retry: function }
function M.new()
  local active_tokens = {}
  local on_end = {}
  local tracker = {}

  ---@param notification fun(method: string, params: table) notification dispatcher of the client
  function tracker.observe(notification)
    return function(method, params)
      notification(method, params)
      if method ~= '$/progress' or type(params.value) ~= 'table' then
        return
      end
      if params.value.kind == 'begin' then
        active_tokens[params.token] = true
      elseif params.value.kind == 'end' then
        active_tokens[params.token] = nil
        if next(active_tokens) == nil then
          local callbacks = on_end
          on_end = {}
          for _, callback in ipairs(callbacks) do
            callback()
          end
        end
      end
    end
  end

  function tracker.is_active()
    return next(active_tokens) ~= nil
  end

  -- Many libraries have no sources, so the caller retries only a result from the indexing.
  ---@param locations lsp.Location[]|lsp.LocationLink[] result that the user got
  ---@param resend fun(on_locations: fun(locations: lsp.Location[]|lsp.LocationLink[]))
  ---@param offset_encoding string
  function tracker.retry(locations, resend, offset_encoding)
    if not is_class_file(locations) then
      return
    end
    vim.notify('kotlin_lsp: sources are still indexing. The jump moves to the source when the indexing ends.', vim.log.levels.INFO)
    local class_uri = uri_of(locations[1])
    local function send_again()
      resend(function(new_locations)
        -- The user can leave the class file during the indexing.
        if #new_locations == 0 or is_class_file(new_locations) or vim.api.nvim_buf_get_name(0) ~= class_uri then
          return
        end
        -- `vim.lsp.util.show_document` adds the class file to the jumplist and the tagstack. Without
        -- them, one step back goes to the start of the first jump.
        local location = new_locations[1]
        local buffer = vim.uri_to_bufnr(uri_of(location))
        vim.fn.bufload(buffer)
        vim.bo[buffer].buflisted = true
        vim.cmd.buffer({ buffer, mods = { keepjumps = true } })
        local position = (location.range or location.targetSelectionRange).start
        local line = vim.api.nvim_buf_get_lines(buffer, position.line, position.line + 1, false)[1] or ''
        vim.api.nvim_win_set_cursor(0, { position.line + 1, vim.str_byteindex(line, offset_encoding, position.character, false) })
        vim.cmd 'normal! zv'
      end)
    end
    if tracker.is_active() then
      table.insert(on_end, send_again)
    else
      send_again()
    end
  end

  return tracker
end

return M
