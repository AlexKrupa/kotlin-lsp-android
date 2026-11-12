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

-- Step 3: the receiver of the blocks around the cursor, for example `ApplicationDefaultConfig` in
-- `android { defaultConfig { } }`.

---@alias script_lookup.Type { path: string, line_index: integer, character: integer, uri_for: fun(path: string): string, name: string }

local max_supertype_depth = 5

-- The declaration of a type ends at `{`. A type with no body has no `{`.
local max_declaration_line_count = 20

-- A brace after one of these words does not change the receiver.
local control_flow_keywords = { ['if'] = true, ['else'] = true, ['when'] = true, ['for'] = true, ['while'] = true, ['do'] = true, ['try'] = true, ['catch'] = true, ['finally'] = true }

---@return string? identifier before the `{` at `brace_index`, also before `(...)`
local function block_name(text, brace_index)
  local index = #text:sub(1, brace_index - 1):gsub('%s+$', '')
  if text:sub(index, index) == ')' then
    local depth = 0
    repeat
      local char = text:sub(index, index)
      depth = depth + (char == ')' and 1 or char == '(' and -1 or 0)
      index = index - 1
    until depth == 0 or index == 0
  end
  local name = text:sub(1, index):match('([%w_]+)%s*$')
  if name and not control_flow_keywords[name] then
    return name
  end
  return nil
end

---@param lines string[]
---@param position lsp.Position
---@return string[] names of the blocks around the position, outside block first
function M.enclosing_blocks(lines, position)
  local lines_before = vim.list_slice(lines, 1, position.line)
  table.insert(lines_before, (lines[position.line + 1] or ''):sub(1, position.character))
  local text = table.concat(lines_before, '\n')
  -- A `}` closes a block or a `${` template.
  ---@type { kind: 'block'|'template'|'string'|'raw_string', name: string? }[]
  local frames = {}
  local index = 1
  while true do
    local frame = frames[#frames]
    local in_string = frame ~= nil and (frame.kind == 'string' or frame.kind == 'raw_string')
    index = text:find(in_string and '[\\"$]' or '[/"\'{}]', index)
    if not index then
      break
    end
    local char = text:sub(index, index)
    local next_index = index + 1
    if in_string then
      if char == '\\' and frame.kind == 'string' then
        next_index = index + 2
      elseif text:sub(index, index + 1) == '${' then
        table.insert(frames, { kind = 'template' })
        next_index = index + 2
      elseif char == '"' and frame.kind == 'string' then
        table.remove(frames)
      elseif text:sub(index, index + 2) == '"""' then
        table.remove(frames)
        next_index = index + 3
      end
    elseif text:sub(index, index + 1) == '//' then
      next_index = (text:find('\n', index, true) or #text) + 1
    elseif text:sub(index, index + 1) == '/*' then
      next_index = (select(2, text:find('*/', index + 2, true)) or #text) + 1
    elseif text:sub(index, index + 2) == '"""' then
      table.insert(frames, { kind = 'raw_string' })
      next_index = index + 3
    elseif char == '"' then
      table.insert(frames, { kind = 'string' })
    elseif char == "'" then
      next_index = (select(2, text:find("^'\\.[^']*'", index)) or select(2, text:find("^'.'", index)) or index) + 1
    elseif char == '{' then
      table.insert(frames, { kind = 'block', name = block_name(text, index) })
    elseif char == '}' then
      table.remove(frames)
    end
    index = next_index
  end
  local names = {}
  for _, frame in ipairs(frames) do
    if frame.name then
      table.insert(names, frame.name)
    end
  end
  return names
end

---@return script_lookup.Type?
local function resolve_named_type(full_name, source_path)
  local found = M.resolve_type(full_name, source_path)
  return found and vim.tbl_extend('force', found, { name = full_name:match('[%w_]+$') })
end

---@param type_name string simple name, nested name (`Outer.Inner`), or full name
---@param file_lines string[]
---@return script_lookup.Type?
local function resolve_in_file(type_name, file_lines, source_path)
  if type_name:match('^%l[%w_]*%.') then
    return resolve_named_type(type_name, source_path)
  end
  local first_name = type_name:match('^[%w_]+')
  local full_names = {}
  for _, line in ipairs(file_lines) do
    local imported = line:match('^import%s+([%w_.]+)%.' .. first_name .. '%s*;?%s*$')
    if imported then
      return resolve_named_type(imported .. '.' .. type_name, source_path)
    end
    local package_name = line:match('^package%s+([%w_.]+)') or line:match('^import%s+([%w_.]+)%.%*')
    if package_name then
      table.insert(full_names, package_name .. '.' .. type_name)
    end
  end
  for _, full_name in ipairs(full_names) do
    local found = resolve_named_type(full_name, source_path)
    if found then
      return found
    end
  end
  return nil
end

-- Kotlin `: A, B<...>`, or Java `extends A implements B<...>`.
---@param declared_type script_lookup.Type
---@param type_lines string[] lines of the source file of the type
---@return string[] names of the supertypes in the declaration of the type
local function supertype_names(declared_type, type_lines)
  local declaration_lines = {}
  for line_index = declared_type.line_index, math.min(#type_lines, declared_type.line_index + max_declaration_line_count) - 1 do
    local line = type_lines[line_index + 1]
    if line_index > declared_type.line_index and vim.trim(line) == '' then
      break
    end
    table.insert(declaration_lines, line)
    if line:find('{', 1, true) then
      break
    end
  end
  local declaration = table.concat(declaration_lines, ' ')
  local after_name = declaration:match('%f[%w_]' .. declared_type.name .. '%f[^%w_](.*)', declared_type.character + 1) or ''
  local list = after_name:match('^[^{]*'):gsub('%b<>', ''):gsub('%b()', '')
  list = list:match(':(.*)') or list:gsub('%f[%w_]extends%f[^%w_]', ','):gsub('%f[%w_]implements%f[^%w_]', ',')
  local names = {}
  for part in vim.gsplit(list, ',', { plain = true }) do
    local name = part:match('^%s*([%w_.]+)')
    if name then
      table.insert(names, name)
    end
  end
  return names
end

---@param declared_type script_lookup.Type
---@param find fun(declared_type: script_lookup.Type, type_lines: string[]): any
local function find_in_hierarchy(declared_type, source_path, find)
  local level_types = { declared_type }
  local seen = { [declared_type.path .. ':' .. declared_type.line_index] = true }
  for depth = 0, max_supertype_depth do
    local next_level_types = {}
    for _, level_type in ipairs(level_types) do
      local type_lines = vim.fn.readfile(level_type.path)
      local found = find(level_type, type_lines)
      if found then
        return found
      end
      if depth < max_supertype_depth then
        for _, name in ipairs(supertype_names(level_type, type_lines)) do
          local supertype = resolve_in_file(name, type_lines, source_path)
          if supertype and not seen[supertype.path .. ':' .. supertype.line_index] then
            seen[supertype.path .. ':' .. supertype.line_index] = true
            table.insert(next_level_types, supertype)
          end
        end
      end
    end
    level_types = next_level_types
  end
  return nil
end

---@param declared_type script_lookup.Type
---@return script_lookup.Match[] declarations of the name in the source file of the type
local function find_members(declared_type, name)
  local matches = sources.search_declarations({ declared_type.path }, name, false)
  if #matches == 0 and vim.endswith(declared_type.path, '.java') then
    -- Kotlin uses a Java getter as a property.
    matches = sources.search_declarations({ declared_type.path }, 'get' .. name:sub(1, 1):upper() .. name:sub(2), false)
  end
  local members = {}
  for _, match in ipairs(matches) do
    -- The type declaration has the name of the type.
    if match.line_index ~= declared_type.line_index then
      table.insert(members, vim.tbl_extend('force', match, { uri_for = declared_type.uri_for }))
    end
  end
  return members
end

-- The receiver of a block is `T` in `Action<T>` or `T.() -> Unit`, or the type `: T` of a property or
-- function.
---@return string? type name in the declaration
local function block_type_name(declaration, name)
  local action_type = declaration:match('Action%s*<%s*([^>]+)')
  if action_type then
    return action_type:gsub('^%?%s+super%s+', ''):match('^[%w_.]+')
  end
  return declaration:match('([%w_.]+)%s*%b<>%s*%.%s*%(%)%s*%->')
    or declaration:match('([%w_.]+)%s*%.%s*%(%)%s*%->')
    or declaration:match('`?' .. name .. '`?%s*%b()%s*:%s*([%w_.]+)')
    or declaration:match('`?' .. name .. '`?%s*:%s*([%w_.]+)')
end

-- The Kotlin DSL and the accessors declare extensions, for example
-- `fun Project.android(configure: Action<ApplicationExtension>)`.
---@param receiver_names table<string, true> simple names of the receiver type and its supertypes
---@return script_lookup.Type?
local function find_extension_block_type(receiver_names, name, source_path)
  for _, match in ipairs(search_packages(source_path, { 'org.gradle.kotlin.dsl' }, name, false)) do
    local file_lines = vim.fn.readfile(match.path)
    local declaration = file_lines[match.line_index + 1]
    local receiver = declaration:match('([%w_.]+)%b<>%.`?' .. name .. '`?%f[^%w_`]') or declaration:match('([%w_.]+)%.`?' .. name .. '`?%f[^%w_`]')
    local type_name = receiver and receiver_names[receiver:match('[%w_]+$')] and block_type_name(declaration, name)
    local found = type_name and resolve_in_file(type_name, file_lines, source_path)
    if found then
      return found
    end
  end
  return nil
end

-- Members of the receiver and its supertypes come before extensions.
---@param receiver script_lookup.Type
---@return script_lookup.Type? receiver in the block
local function block_type(receiver, name, source_path)
  local receiver_names = {}
  local found = find_in_hierarchy(receiver, source_path, function(declared_type, type_lines)
    receiver_names[declared_type.name] = true
    for _, member in ipairs(find_members(declared_type, name)) do
      local type_name = block_type_name(type_lines[member.line_index + 1], name)
      local member_type = type_name and resolve_in_file(type_name, type_lines, source_path)
      if member_type then
        return member_type
      end
    end
    return nil
  end)
  return found or find_extension_block_type(receiver_names, name, source_path)
end

-- `settings.gradle.kts` and `<name>.settings.gradle.kts` are settings scripts. The same applies to
-- init scripts.
local first_receivers = { ['settings.gradle.kts'] = 'org.gradle.api.initialization.Settings', ['init.gradle.kts'] = 'org.gradle.api.invocation.Gradle' }

---@return string full name of the receiver at the top level of the script
local function first_receiver(script_path)
  local file_name = vim.fs.basename(script_path)
  for suffix, type_name in pairs(first_receivers) do
    if file_name == suffix or vim.endswith(file_name, '.' .. suffix) then
      return type_name
    end
  end
  return 'org.gradle.api.Project'
end

---@param position lsp.Position
---@return lsp.Location[]?
local function find_in_receiver(lines, position, symbol, model, script_path)
  local receiver = resolve_named_type(first_receiver(script_path), model.source_path)
  for _, name in ipairs(M.enclosing_blocks(lines, position)) do
    receiver = receiver and block_type(receiver, name, model.source_path)
  end
  return receiver
    and find_in_hierarchy(receiver, model.source_path, function(declared_type)
      return to_locations(find_members(declared_type, symbol))
    end)
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
    or find_in_receiver(lines, params.position, symbol, model, vim.uri_to_fname(params.textDocument.uri))
    or find_implicitly_imported(symbol, model)
    or find_accessor(symbol, model)
    or sources.find_in_other_libraries({ symbol }, params, root_dir)
end

return M
