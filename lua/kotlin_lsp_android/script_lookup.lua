-- Definition, references, and hover in Gradle Kotlin DSL scripts, which the server does not
-- analyze. The definition searches names in the sources of the script model. The first step with a
-- match gives the result.
local M = {}

local sources = require 'kotlin_lsp_android.sources'
local script_model = require 'kotlin_lsp_android.script_model'

---@alias script_lookup.Match { path: string, line_index: integer, character: integer, uri_for: fun(path: string): string }

---@param matches script_lookup.Match[]
---@return lsp.Location[]?
local function to_locations(matches)
  if #matches == 0 then
    return nil
  end
  return vim.tbl_map(function(match)
    return sources.to_location(match.uri_for, match)
  end, matches)
end

---@return string? package name in the source file
local function package_of(path)
  for _, line in ipairs(vim.fn.readfile(path)) do
    local package_name = line:match('^package%s+([%w_.]+)')
    if package_name then
      return package_name
    end
  end
  return nil
end

-- One search for each source root with one of the packages, not for each package: a script has
-- about 200 implicit imports.
---@param package_names string[]
---@return script_lookup.Match[]
local function search_packages(source_path, package_names, symbol, types_only)
  local wanted_packages = {}
  local source_roots = {}
  for _, package_name in ipairs(package_names) do
    wanted_packages[package_name] = true
    for _, source_root in ipairs(sources.roots_with_package(source_path, package_name)) do
      if not vim.list_contains(source_roots, source_root) then
        table.insert(source_roots, source_root)
      end
    end
  end
  local found = {}
  for _, source_root in ipairs(source_roots) do
    local directory, uri_for = sources.open_sources(source_root)
    for _, match in ipairs(sources.search_declarations({ directory }, symbol, types_only)) do
      if #found < sources.name_lookup_limit and wanted_packages[package_of(match.path)] then
        table.insert(found, vim.tbl_extend('force', match, { uri_for = uri_for }))
      end
    end
  end
  return found
end

-- A package name starts with a lowercase letter, and a class name with an uppercase letter.
---@param full_name string for example `com.example.Outer.Inner`
---@param source_path string[]
---@return script_lookup.Match? type declaration
function M.resolve_type(full_name, source_path)
  local package_name = full_name:match('^(.-)%.%u') or full_name:match('^(.*)%.')
  if not package_name then
    return nil
  end
  return search_packages(source_path, { package_name }, full_name:match('[%w_]+$'), true)[1]
end

-- Step 0: the string argument of `id("...")` or `kotlin("...")`.
local plugin_id_prefixes = { id = '', kotlin = 'org.jetbrains.kotlin.' }

---@return lsp.Location[]?
local function find_plugin(line, column, model, params, root_dir)
  for function_name, prefix in pairs(plugin_id_prefixes) do
    for first_column, plugin_id, quote_column in line:gmatch('%f[%w_]' .. function_name .. '%s*%(%s*"()([^"]*)()"') do
      if column >= first_column - 1 and column <= quote_column then
        local class_name = model.plugin_classes[prefix .. plugin_id]
        if not class_name then
          return nil
        end
        local found = M.resolve_type(class_name, model.source_path)
        if found then
          return { sources.to_location(found.uri_for, found) }
        end
        -- The server finds the classes of `build-logic`.
        return sources.find_in_other_libraries({ class_name }, params, root_dir)
      end
    end
  end
  return nil
end

-- Step 1: `libs.<a>.<b>...`. Only the `libs` catalog has a file at a fixed path.
local catalog_tables = { plugins = 'plugins', versions = 'versions', bundles = 'bundles' }

-- Gradle makes the same accessor for `-`, `_`, and `.` between the parts of a key.
local function normalize_key(key)
  return (key:gsub('[-_.]', '.'))
end

---@param parts string[] accessor parts after `libs`
---@return lsp.Location[]?
local function find_catalog_key(root_dir, parts)
  local catalog_path = root_dir .. '/gradle/libs.versions.toml'
  if vim.fn.filereadable(catalog_path) == 0 then
    return nil
  end
  local table_name = catalog_tables[parts[1]]
  local key_parts = table_name and vim.list_slice(parts, 2) or parts
  local key = normalize_key(table.concat(key_parts, '.'))
  local current_table
  for index, line in ipairs(vim.fn.readfile(catalog_path)) do
    current_table = line:match('^%s*%[([%w_.-]+)%]') or current_table
    local indent, line_key = line:match('^(%s*)"?([%w_.-]+)"?%s*=')
    if current_table == (table_name or 'libraries') and line_key and normalize_key(line_key) == key then
      local position = { line = index - 1, character = #indent }
      return { { uri = vim.uri_from_fname(catalog_path), range = { start = position, ['end'] = position } } }
    end
  end
  return nil
end

-- With no key in `libs.versions.toml`, for example for a catalog from another file, the getter of
-- the generated Java class `LibrariesForLibs` is the declaration.
---@return lsp.Location[]?
local function find_catalog_accessor(source_path, symbol)
  local getter = 'get' .. symbol:sub(1, 1):upper() .. symbol:sub(2)
  local matches = vim.tbl_filter(function(match)
    return vim.fs.basename(match.path) == 'LibrariesForLibs.java'
  end, search_packages(source_path, { 'org.gradle.accessors.dm' }, getter, false))
  return to_locations(matches)
end

---@return lsp.Location[]?
local function find_in_catalog(line, column, symbol, model, root_dir)
  for start_column, path, end_column in line:gmatch('()%f[%w_]libs%.([%w_.]+)()') do
    if column >= start_column and column < end_column then
      local parts = vim.split(path, '.', { plain = true })
      -- A call after the expression, for example `.get()`, is not part of the key.
      if line:sub(end_column, end_column) == '(' then
        table.remove(parts)
      end
      return find_catalog_key(root_dir, parts) or find_catalog_accessor(model.source_path, symbol)
    end
  end
  return nil
end

-- Step 2: an import of the script.
---@return lsp.Location[]?
local function find_imported(lines, symbol, model, params, root_dir)
  for _, line in ipairs(lines) do
    local imported = line:match('^import%s+([%w_.]+)%.' .. symbol .. '%f[^%w_]')
    if imported then
      local full_name = imported .. '.' .. symbol
      -- The import can name a member of a class: the package ends before the class name.
      local package_name = full_name:match('^(.-)%.%u') or imported
      return to_locations(search_packages(model.source_path, { package_name }, symbol, false))
        or sources.find_in_other_libraries({ full_name }, params, root_dir)
    end
  end
  return nil
end

-- Step 4: the implicit imports. Exact names first, then the `.*` packages. Only types: step 5
-- finds the functions and properties of `org.gradle.kotlin.dsl`.
---@return lsp.Location[]?
local function find_implicitly_imported(symbol, model)
  local star_packages = {}
  for _, implicit_import in ipairs(model.implicit_imports) do
    local star_package = implicit_import:match('^(.*)%.%*$')
    if star_package then
      table.insert(star_packages, star_package)
    elseif implicit_import:match('[%w_]+$') == symbol then
      local found = M.resolve_type(implicit_import, model.source_path)
      if found then
        return { sources.to_location(found.uri_for, found) }
      end
    end
  end
  return to_locations(search_packages(model.source_path, star_packages, symbol, true))
end

-- Step 5: the generated accessors and the Kotlin DSL API.
---@return lsp.Location[]?
local function find_accessor(symbol, model)
  return to_locations(search_packages(model.source_path, { 'org.gradle.kotlin.dsl' }, symbol, false))
end

-- Steps 4 to 6 do not use the position. A references call looks up the same name at each hit. It
-- keeps the results of these steps until it ends.
---@type table<string[], table<string, { locations: lsp.Location[]? }>>?
local unpositioned_by_source_path

---@return lsp.Location[]?
local function find_unpositioned(symbol, model, params, root_dir, lines)
  local function find()
    return find_implicitly_imported(symbol, model)
      or find_accessor(symbol, model)
      or sources.find_in_other_libraries({ symbol }, params, root_dir, lines)
  end
  if not unpositioned_by_source_path then
    return find()
  end
  local by_symbol = unpositioned_by_source_path[model.source_path] or {}
  unpositioned_by_source_path[model.source_path] = by_symbol
  by_symbol[symbol] = by_symbol[symbol] or { locations = find() }
  return by_symbol[symbol].locations
end

---@param params lsp.TextDocumentPositionParams for a `.gradle.kts` file
---@param root_dir string
---@return lsp.Location[]?
function M.definition(params, root_dir)
  local symbol = sources.find_symbol(params)
  local model = script_model.get(root_dir, vim.uri_to_fname(params.textDocument.uri))
  if not model then
    -- Step 6 for a script with no entry, for example a new file.
    return symbol and sources.find_in_other_libraries({ symbol }, params, root_dir)
  end
  local lines = vim.api.nvim_buf_get_lines(vim.uri_to_bufnr(params.textDocument.uri), 0, -1, false)
  local line = lines[params.position.line + 1] or ''
  local column = params.position.character + 1
  local found = find_plugin(line, column, model, params, root_dir)
  if found then
    return found
  end
  if not symbol then
    return nil
  end
  return find_in_catalog(line, column, symbol, model, root_dir)
    or find_imported(lines, symbol, model, params, root_dir)
    or find_implicitly_imported(symbol, model)
    or find_accessor(symbol, model)
    or sources.find_in_other_libraries({ symbol }, params, root_dir)
end

return M
