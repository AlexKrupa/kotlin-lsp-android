-- The Gradle Kotlin DSL script model, which `kotlin-lsp script-model` writes to the cache of a root.
local M = {}

-- The same executable as the `cmd` of the client.
local executable

---@type table<string, boolean> roots with a run in progress
local running_roots = {}
-- A run that started before the last import can miss its changes.
---@type table<string, boolean> roots with a refresh during the run
local pending_roots = {}
---@type table<string, boolean> roots that already got a warning
local warned_roots = {}
---@type table<string, { mtime: { sec: integer, nsec: integer }, model: table }>
local model_by_path = {}
-- It changes when a model file is read again, for example after an import.
local version = 0

---@param executable_path string
function M.setup(executable_path)
  executable = executable_path
end

---@param root_dir string
---@param message string
local function warn(root_dir, message)
  if warned_roots[root_dir] then
    return
  end
  warned_roots[root_dir] = true
  vim.notify(('kotlin_lsp: no Gradle script model for %s: %s'):format(root_dir, message), vim.log.levels.WARN)
end

-- Runs in the background. A run that fails shows one warning for each root.
---@param root_dir string
function M.refresh(root_dir)
  if running_roots[root_dir] then
    pending_roots[root_dir] = true
    return
  end
  running_roots[root_dir] = true
  local started, err = pcall(vim.system, { executable, 'script-model' }, { cwd = root_dir, text = true }, vim.schedule_wrap(function(result)
    running_roots[root_dir] = nil
    if result.code ~= 0 then
      warn(root_dir, vim.trim(result.stderr))
    end
    if pending_roots[root_dir] then
      pending_roots[root_dir] = nil
      M.refresh(root_dir)
    end
  end))
  if not started then
    running_roots[root_dir] = nil
    warn(root_dir, tostring(err))
  end
end

---@return table? model decoded file, nil if the file is missing or invalid
local function read_model(root_dir)
  local path = require('kotlin_lsp_android.sources').cache_dir(root_dir) .. '/library-sources/gradle-scripts.json'
  local stat = vim.uv.fs_stat(path)
  if not stat then
    return nil
  end
  local cached = model_by_path[path]
  if cached and vim.deep_equal(cached.mtime, stat.mtime) then
    return cached.model
  end
  local decoded, model = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), '\n'))
  if not decoded or type(model) ~= 'table' or type(model.lists) ~= 'table' or type(model.scripts) ~= 'table' then
    return nil
  end
  model_by_path[path] = { mtime = stat.mtime, model = model }
  version = version + 1
  return model
end

---@return integer version of the models, so that a cache of lookups in the model can be cleared
function M.version()
  return version
end

---@param root_dir string
---@param script_path string
---@return { source_path: string[], implicit_imports: string[], plugin_classes: table<string, string> }?
function M.get(root_dir, script_path)
  local model = read_model(root_dir)
  if not model then
    M.refresh(root_dir)
    return nil
  end
  -- The model has real paths.
  local entry = model.scripts[vim.uv.fs_realpath(script_path) or script_path]
  if not entry then
    return nil
  end
  return {
    source_path = model.lists[entry.sourcePath + 1],
    implicit_imports = model.lists[entry.implicitImports + 1],
    plugin_classes = entry.pluginClasses,
  }
end

return M
