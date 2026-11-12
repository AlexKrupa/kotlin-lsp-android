-- Definition, references, and hover in Gradle Kotlin DSL scripts, which the server does not
-- analyze. The definition searches names in the sources of the script model. The first step with a
-- match gives the result.
local M = {}

local sources = require 'kotlin_lsp_android.sources'
local script_model = require 'kotlin_lsp_android.script_model'

---@alias script_lookup.Match { path: string, line_index: integer, character: integer, uri_for: fun(path: string): string, source_root: string, package_name: string }

---@param matches script_lookup.Match[]
---@return lsp.Location[]? the first matches, up to the limit of the name lookup
local function to_locations(matches)
  if #matches == 0 then
    return nil
  end
  return vim.tbl_map(function(match)
    return sources.to_location(match.uri_for, match)
  end, vim.list_slice(matches, 1, sources.name_lookup_limit))
end

-- The lookup results do not change while the model stays the same. The extracted sources do not
-- change, so the package index stays.
local model_version
---@type table<string, script_lookup.Match|false> declaration of a type by full name and source root
local type_by_root = {}
---@type table<string, script_lookup.Match[]> members by type declaration and name
local members_by_type = {}

local function forget_on_model_change()
  if model_version ~= script_model.version() then
    model_version = script_model.version()
    type_by_root, members_by_type = {}, {}
  end
end

-- A file can be outside the folder of its package, for example `KotlinDependencies.kt` at the root of
-- the Kotlin Gradle plugin sources jar.
---@type table<string, { path: string, directory: string }[]> files of each package in the indexed directories
local files_by_package = {}
---@type table<string, true>
local indexed_directories = {}

-- One `rg` for all new directories. `-m1` stops at the first package line of each file.
---@param directories string[] directories with source files
local function index_packages(directories)
  local new_directories = {}
  for _, directory in ipairs(directories) do
    if not indexed_directories[directory] then
      indexed_directories[directory] = true
      new_directories[directory] = true
    end
  end
  if vim.tbl_isempty(new_directories) then
    return
  end
  local command = { 'rg', '-m1', '-o', '-r', '$1', '--no-heading', '--with-filename', '-g', '*.kt', '-g', '*.java', '-e', '^package\\s+([\\w.]+)' }
  local output = vim.system(vim.list_extend(command, vim.tbl_keys(new_directories)), { text = true }):wait().stdout
  ---@type table<string, string> directory of each folder
  local directory_by_folder = {}
  for line in vim.gsplit(output, '\n', { trimempty = true }) do
    local path, package_name = line:match('^(.*):([%w_.]+)$')
    local folder = vim.fs.dirname(path)
    local directory = directory_by_folder[folder] or folder
    while not new_directories[directory] and vim.fs.dirname(directory) ~= directory do
      directory = vim.fs.dirname(directory)
    end
    directory_by_folder[folder] = directory
    files_by_package[package_name] = files_by_package[package_name] or {}
    table.insert(files_by_package[package_name], { path = path, directory = directory })
  end
end

-- One search over the files of the packages in all source roots, not one for each root: Gradle
-- splits `org.gradle.api` over 76 folders.
---@param package_names string[]
---@return script_lookup.Match[] in the order of the source roots, then by path and position
local function search_packages(source_path, package_names, symbol, types_only)
  ---@type table<string, { index: integer, source_root: string, uri_for: fun(path: string): string }>
  local roots_by_directory = {}
  local directories = {}
  for _, package_name in ipairs(package_names) do
    for _, source_root in ipairs(sources.roots_with_package(source_path, package_name)) do
      -- A sources jar that cannot be extracted has no files.
      local is_open, directory, uri_for = pcall(sources.open_sources, source_root)
      if is_open and not roots_by_directory[directory] then
        table.insert(directories, directory)
        roots_by_directory[directory] = { index = #directories, source_root = source_root, uri_for = uri_for }
      end
    end
  end
  index_packages(directories)
  ---@type table<string, { directory: string, package_name: string }>
  local file_by_path = {}
  local paths = {}
  for _, package_name in ipairs(package_names) do
    for _, file in ipairs(files_by_package[package_name] or {}) do
      if roots_by_directory[file.directory] and not file_by_path[file.path] then
        file_by_path[file.path] = { directory = file.directory, package_name = package_name }
        table.insert(paths, file.path)
      end
    end
  end
  if #paths == 0 then
    return {}
  end
  local found = vim.tbl_map(function(match)
    local file = file_by_path[match.path]
    local root = roots_by_directory[file.directory]
    return vim.tbl_extend('force', match, { uri_for = root.uri_for, source_root = root.source_root, package_name = file.package_name, root_index = root.index })
  end, sources.search_declarations(paths, symbol, types_only))
  table.sort(found, function(first, second)
    if first.root_index ~= second.root_index then
      return first.root_index < second.root_index
    end
    if first.path ~= second.path then
      return first.path < second.path
    end
    if first.line_index ~= second.line_index then
      return first.line_index < second.line_index
    end
    return first.character < second.character
  end)
  return found
end

-- A package name starts with a lowercase letter, and a class name with an uppercase letter.
---@return string?
local function package_of_type(full_name)
  return full_name:match('^(.-)%.%u') or full_name:match('^(.*)%.')
end

-- The first full name with a declaration wins. One search finds all full names that are not known.
---@param full_names string[] names with the same simple name, for example `com.example.Outer.Inner`
---@param source_path string[]
---@return script_lookup.Match? type declaration
local function resolve_type(full_names, source_path)
  local candidates = {}
  local is_known = true
  for _, full_name in ipairs(full_names) do
    local package_name = package_of_type(full_name)
    if package_name then
      local source_roots = sources.roots_with_package(source_path, package_name)
      table.insert(candidates, { full_name = full_name, package_name = package_name, source_roots = source_roots })
      for _, source_root in ipairs(source_roots) do
        is_known = is_known and type_by_root[full_name .. '\n' .. source_root] ~= nil
      end
    end
  end
  if not is_known then
    local package_names = vim.tbl_map(function(candidate)
      return candidate.package_name
    end, candidates)
    local matches = search_packages(source_path, package_names, candidates[1].full_name:match('[%w_]+$'), true)
    for _, candidate in ipairs(candidates) do
      for _, source_root in ipairs(candidate.source_roots) do
        type_by_root[candidate.full_name .. '\n' .. source_root] = vim.iter(matches):find(function(match)
          return match.source_root == source_root and match.package_name == candidate.package_name
        end) or false
      end
    end
  end
  for _, candidate in ipairs(candidates) do
    for _, source_root in ipairs(candidate.source_roots) do
      local found = type_by_root[candidate.full_name .. '\n' .. source_root]
      if found then
        return found
      end
    end
  end
  return nil
end

-- Step 0: the string argument of `id("...")` or `kotlin("...")`.
local plugin_id_prefixes = { id = '', kotlin = 'org.jetbrains.kotlin.' }

---@return lsp.Location[]?
local function find_plugin(lines, line, column, model, params, root_dir)
  for function_name, prefix in pairs(plugin_id_prefixes) do
    for first_column, plugin_id, quote_column in line:gmatch('%f[%w_]' .. function_name .. '%s*%(%s*"()([^"]*)()"') do
      if column >= first_column - 1 and column <= quote_column then
        local class_name = model.plugin_classes[prefix .. plugin_id]
        if not class_name then
          return nil
        end
        local found = resolve_type({ class_name }, model.source_path)
        if found then
          return { sources.to_location(found.uri_for, found) }
        end
        -- The server finds the classes of `build-logic`.
        return sources.find_in_other_libraries({ class_name }, params, root_dir, lines)
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
        or sources.find_in_other_libraries({ full_name }, params, root_dir, lines)
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

---@param close_index integer index of the `close` character
---@param allowed string? pattern of the characters that can be in the pair
---@return integer? index before the `open` character of the pair
local function before_pair(text, close_index, open, close, allowed)
  local index = close_index
  local depth = 0
  repeat
    local char = text:sub(index, index)
    if allowed and not char:match(allowed) then
      return nil
    end
    depth = depth + (char == close and 1 or char == open and -1 or 0)
    index = index - 1
  until depth == 0 or index == 0
  return index
end

---@return string? identifier before the `{` at `brace_index`, also before `(...)` and `<...>`, as in
---`register<Copy>("x") {`
local function block_name(text, brace_index)
  local index = #text:sub(1, brace_index - 1):gsub('%s+$', '')
  if text:sub(index, index) == ')' then
    index = #text:sub(1, before_pair(text, index, '(', ')')):gsub('%s+$', '')
  end
  if text:sub(index, index) == '>' then
    -- The characters of type arguments, so that `x -> {` has no name.
    index = before_pair(text, index, '<', '>', '[%w_.,%s<>?*]')
    if not index then
      return nil
    end
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

---@param full_names string[] names with the same simple name
---@return script_lookup.Type?
local function resolve_named_type(full_names, source_path)
  local found = resolve_type(full_names, source_path)
  return found and vim.tbl_extend('force', found, { name = full_names[1]:match('[%w_]+$') })
end

---@param type_name string simple name, nested name (`Outer.Inner`), or full name
---@param file_lines string[]
---@return script_lookup.Type?
local function resolve_in_file(type_name, file_lines, source_path)
  if type_name:match('^%l[%w_]*%.') then
    return resolve_named_type({ type_name }, source_path)
  end
  local first_name = type_name:match('^[%w_]+')
  local full_names = {}
  for _, line in ipairs(file_lines) do
    local imported = line:match('^import%s+([%w_.]+)%.' .. first_name .. '%s*;?%s*$')
    if imported then
      return resolve_named_type({ imported .. '.' .. type_name }, source_path)
    end
    local package_name = line:match('^package%s+([%w_.]+)') or line:match('^import%s+([%w_.]+)%.%*')
    if package_name then
      table.insert(full_names, package_name .. '.' .. type_name)
    end
  end
  return resolve_named_type(full_names, source_path)
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
---@param type_lines string[] lines of the source file of the type
---@return script_lookup.Match[] declarations of the name in the source file of the type
local function find_members(declared_type, type_lines, name)
  local key = ('%s:%d\n%s'):format(declared_type.path, declared_type.line_index, name)
  if members_by_type[key] then
    return members_by_type[key]
  end
  local matches = sources.search_declarations({ declared_type.path }, name, false)
  if #matches == 0 and vim.endswith(declared_type.path, '.java') then
    -- Kotlin uses a Java getter as a property.
    matches = sources.search_declarations({ declared_type.path }, 'get' .. name:sub(1, 1):upper() .. name:sub(2), false)
  end
  local members = {}
  for _, match in ipairs(matches) do
    local is_type_declaration = match.line_index == declared_type.line_index
    -- Kotlin cannot pass a lambda as a Groovy `Closure`. It calls a Kotlin DSL extension, for example
    -- `Project.dependencies`, which step 3 or step 5 finds.
    local takes_closure = type_lines[match.line_index + 1]:find('%(.*%f[%w_]Closure%f[^%w_]') ~= nil
    if not is_type_declaration and not takes_closure then
      table.insert(members, vim.tbl_extend('force', match, { uri_for = declared_type.uri_for }))
    end
  end
  members_by_type[key] = members
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
    for _, member in ipairs(find_members(declared_type, type_lines, name)) do
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

-- At the top level, Kotlin uses the members of the script template, for example `plugins { }`, before
-- the members of the implicit receiver. `settings.gradle.kts` and `<name>.settings.gradle.kts` are
-- settings scripts. The same applies to init scripts.
local first_receivers_by_suffix = {
  ['settings.gradle.kts'] = { 'org.gradle.kotlin.dsl.KotlinSettingsScriptTemplate', 'org.gradle.api.initialization.Settings' },
  ['init.gradle.kts'] = { 'org.gradle.kotlin.dsl.KotlinGradleScriptTemplate', 'org.gradle.api.invocation.Gradle' },
}
local project_first_receivers = { 'org.gradle.kotlin.dsl.KotlinProjectScriptTemplate', 'org.gradle.api.Project' }

---@return string[] full names of the receivers at the top level of the script, first receiver first
local function first_receivers(script_path)
  local file_name = vim.fs.basename(script_path)
  for suffix, type_names in pairs(first_receivers_by_suffix) do
    if file_name == suffix or vim.endswith(file_name, '.' .. suffix) then
      return type_names
    end
  end
  return project_first_receivers
end

-- Kotlin searches the name in the receiver of the inner block first, then in the receivers of the
-- outer blocks, for example `compileSdk` of `android { }` in `android { defaultConfig { } }`.
---@param position lsp.Position
---@return lsp.Location[]?
local function find_in_receiver(lines, position, symbol, model, script_path)
  local receivers = {}
  for _, full_name in ipairs(first_receivers(script_path)) do
    local receiver = resolve_named_type({ full_name }, model.source_path)
    if receiver then
      table.insert(receivers, receiver)
    end
  end
  local receivers_inner_first = { receivers }
  for _, name in ipairs(M.enclosing_blocks(lines, position)) do
    local block_receiver
    for _, receiver in ipairs(receivers) do
      block_receiver = block_receiver or block_type(receiver, name, model.source_path)
    end
    -- The name can be a member of the unknown receiver, so an outer receiver is only a guess.
    if not block_receiver then
      return nil
    end
    receivers = { block_receiver }
    table.insert(receivers_inner_first, 1, receivers)
  end
  for _, level_receivers in ipairs(receivers_inner_first) do
    for _, receiver in ipairs(level_receivers) do
      local found = find_in_hierarchy(receiver, model.source_path, function(declared_type, type_lines)
        return to_locations(find_members(declared_type, type_lines, symbol))
      end)
      if found then
        return found
      end
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
      local found = resolve_type({ implicit_import }, model.source_path)
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
---@param script_lines string[]? lines of the script, default the lines of its buffer
---@return lsp.Location[]?
function M.definition(params, root_dir, script_lines)
  local symbol = sources.find_symbol(params, script_lines)
  local model = script_model.get(root_dir, vim.uri_to_fname(params.textDocument.uri))
  forget_on_model_change()
  local lines = script_lines or vim.api.nvim_buf_get_lines(vim.uri_to_bufnr(params.textDocument.uri), 0, -1, false)
  if not model then
    -- Step 6 for a script with no entry, for example a new file.
    return symbol and sources.find_in_other_libraries({ symbol }, params, root_dir, lines)
  end
  local line = lines[params.position.line + 1] or ''
  local column = params.position.character + 1
  local found = find_plugin(lines, line, column, model, params, root_dir)
  if found then
    return found
  end
  if not symbol then
    return nil
  end
  return find_in_catalog(line, column, symbol, model, root_dir)
    or find_imported(lines, symbol, model, params, root_dir)
    or find_in_receiver(lines, params.position, symbol, model, vim.uri_to_fname(params.textDocument.uri))
    or find_unpositioned(symbol, model, params, root_dir, lines)
end

M.reference_limit = 200

---@param name string
---@param targets lsp.Location[] declarations of the name
---@return lsp.Location[]? uses of the name in Gradle scripts that go to a target, nil above the limit
function M.references(name, targets, root_dir)
  -- `-o` gives a hit for each use of the name in a line.
  local command = { 'rg', '-w', '-o', '-n', '--column', '--no-heading', '--with-filename', '-g', '*.gradle.kts', '-g', '!**/build/**', '-e', name, root_dir }
  local output = vim.system(command, { text = true }):wait().stdout
  local hits = {}
  for line in vim.gsplit(vim.trim(output), '\n', { trimempty = true }) do
    local path, line_number, column = line:match('^(.-):(%d+):(%d+):')
    table.insert(hits, { path = path, line_index = tonumber(line_number) - 1, character = tonumber(column) - 1 })
  end
  if #hits > M.reference_limit then
    return nil
  end
  table.sort(hits, function(first, second)
    if first.path ~= second.path then
      return first.path < second.path
    end
    if first.line_index ~= second.line_index then
      return first.line_index < second.line_index
    end
    return first.character < second.character
  end)
  ---@type table<string, string[]>
  local lines_by_path = {}
  local locations = {}
  unpositioned_by_source_path = {}
  for _, hit in ipairs(hits) do
    lines_by_path[hit.path] = lines_by_path[hit.path] or vim.fn.readfile(hit.path)
    local position = { line = hit.line_index, character = hit.character }
    local uri = vim.uri_from_fname(hit.path)
    local ok, found = pcall(M.definition, { textDocument = { uri = uri }, position = position }, root_dir, lines_by_path[hit.path])
    if not ok then
      unpositioned_by_source_path = nil
      error(found, 0)
    end
    found = found or {}
    local is_use = vim.iter(found):any(function(location)
      return vim.iter(targets):any(function(target)
        return location.uri == target.uri and location.range.start.line == target.range.start.line
      end)
    end)
    if is_use then
      table.insert(locations, { uri = uri, range = { start = position, ['end'] = position } })
    end
  end
  unpositioned_by_source_path = nil
  return locations
end

---@return integer first_index first line of the annotations above the declaration
---@return string[] doc_lines text of the KDoc or Javadoc comment directly above them
local function find_leading_lines(lines, declaration_index)
  local first_index = declaration_index
  while first_index > 1 and vim.trim(lines[first_index - 1]):match('^@') do
    first_index = first_index - 1
  end
  local doc_end = first_index - 1
  if doc_end < 1 or not vim.trim(lines[doc_end]):match('%*/$') then
    return first_index, {}
  end
  local doc_start = doc_end
  while doc_start > 1 and not vim.trim(lines[doc_start]):match('^/%*') do
    doc_start = doc_start - 1
  end
  if not vim.trim(lines[doc_start]):match('^/%*%*') then
    return first_index, {}
  end
  local doc_lines = {}
  for index = doc_start, doc_end do
    local text = vim.trim(lines[index]):gsub('^/%*%*+%s*', ''):gsub('%s*%*+/$', ''):gsub('^%*%s?', '')
    table.insert(doc_lines, text)
  end
  return first_index, vim.split(vim.trim(table.concat(doc_lines, '\n')), '\n')
end

-- The declaration ends before the first `{` or `=` outside parentheses, or at the first line that
-- ends it, or after the line limit.
---@return string[]
local function find_declaration_lines(lines, first_index)
  local declaration_lines = {}
  local depth = 0
  for index = first_index, math.min(#lines, first_index + sources.declaration_line_count - 1) do
    local line = lines[index]
    for column = 1, #line do
      local char = line:sub(column, column)
      if char == '(' then
        depth = depth + 1
      elseif char == ')' then
        depth = depth - 1
      elseif depth == 0 and (char == '{' or char == '=') then
        local head = line:sub(1, column - 1):gsub('%s+$', '')
        table.insert(declaration_lines, head)
        return declaration_lines
      end
    end
    table.insert(declaration_lines, line)
    if depth == 0 and not line:match('[,:(]%s*$') then
      return declaration_lines
    end
  end
  return declaration_lines
end

---@return string[]? lines
---@return string? filetype
local function read_lines(uri, root_dir)
  if vim.startswith(uri, 'jar://') then
    local text, filetype = require('kotlin_lsp_android.jar').read_jar_entry(uri, root_dir)
    return vim.split(text, '\n'), filetype
  end
  local path = vim.uri_to_fname(uri)
  if vim.fn.filereadable(path) == 0 then
    return nil
  end
  return vim.fn.readfile(path), vim.filetype.match({ filename = path })
end

---@param params lsp.TextDocumentPositionParams for a `.gradle.kts` file
---@return lsp.Hover?
function M.hover(params, root_dir)
  local location = (M.definition(params, root_dir) or {})[1]
  if not location then
    return nil
  end
  local lines, filetype = read_lines(location.uri, root_dir)
  if not lines then
    return nil
  end
  local declaration_index = location.range.start.line + 1
  local first_index, doc_lines = find_leading_lines(lines, declaration_index)
  local code_lines = vim.list_extend(vim.list_slice(lines, first_index, declaration_index - 1), find_declaration_lines(lines, declaration_index))
  local indent = lines[declaration_index]:match('^%s*')
  local code = table.concat(vim.tbl_map(function(line)
    return vim.startswith(line, indent) and line:sub(#indent + 1) or line
  end, code_lines), '\n')
  local parts = #doc_lines > 0 and { table.concat(doc_lines, '\n') } or {}
  table.insert(parts, ('```%s\n%s\n```'):format(filetype or '', code))
  return { contents = { kind = 'markdown', value = table.concat(parts, '\n\n') } }
end

return M
