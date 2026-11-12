-- Workarounds for locations of kotlin-lsp in libraries. `workspace.json` gives the sources, and
-- these lookups only use them:
-- - The server can locate a symbol in a class file although `workspace.json` gives sources for its
--   jar, for example the Kotlin stdlib of the Gradle distribution in build logic.
-- - The server finds nothing for a jump from a library source file that it does not know.
local M = {}

local extract_root = vim.fn.stdpath('cache') .. '/kotlin-lsp-android/sources'

-- A declaration can span several lines, for example one parameter on each line.
local declaration_line_count = 40

-- The name lookup lists all members of the same name, up to this count.
local name_lookup_limit = 30

---@return string
local function cache_dir(root_dir)
  local cache_root = vim.env.KOTLIN_LSP_CACHE or vim.fn.expand('~/.cache/kotlin-lsp')
  return ('%s/%s'):format(cache_root, vim.fn.sha256(root_dir):sub(1, 12))
end

local sources_by_jar_cache = {}

---@return table<string, string[]> source roots of each class jar
local function sources_by_jar(root_dir)
  local path = cache_dir(root_dir) .. '/library-sources/workspace.json'
  local stat = vim.uv.fs_stat(path)
  if not stat then
    return {}
  end
  local cached = sources_by_jar_cache[path]
  if cached and cached.mtime == stat.mtime.sec then
    return cached.map
  end
  local map = {}
  for _, library in ipairs(vim.json.decode(table.concat(vim.fn.readfile(path), '\n')).libraries or {}) do
    local classes, sources = {}, {}
    for _, root in ipairs(library.roots) do
      table.insert(root.type == 'SOURCES' and sources or classes, root.path)
    end
    for _, jar in ipairs(classes) do
      map[jar] = vim.list_extend(map[jar] or {}, sources)
    end
  end
  sources_by_jar_cache[path] = { mtime = stat.mtime.sec, map = map }
  return map
end

---@return string directory with the files of the sources jar
local function extract(sources_jar)
  local directory = ('%s/%s'):format(extract_root, vim.fn.sha256(sources_jar):sub(1, 16))
  if vim.uv.fs_stat(directory) then
    return directory
  end
  -- An unzip that stops halfway leaves no directory, so a later call extracts again.
  local partial = directory .. '.partial'
  vim.fn.delete(partial, 'rf')
  vim.fn.mkdir(extract_root, 'p')
  local result = vim.system({ 'unzip', '-q', '-o', sources_jar, '-d', partial }):wait()
  if result.code ~= 0 then
    error(('kotlin_lsp: cannot extract %s: %s'):format(sources_jar, result.stderr))
  end
  assert(vim.uv.fs_rename(partial, directory))
  return directory
end

-- `source_root` is a sources jar or a directory.
---@return string directory with the source files
---@return fun(path: string): string uri of a source file in the directory
local function open_sources(source_root)
  if vim.fn.isdirectory(source_root) == 1 then
    return source_root, vim.uri_from_fname
  end
  local directory = extract(source_root)
  return directory, function(path)
    return ('jar://%s!/%s'):format(source_root, path:sub(#directory + 2))
  end
end

---@type table<string, { mtime: integer, packages: table<string, true> }>
local packages_by_jar_cache = {}

-- The entries of a jar can be in a top folder that is not part of the package, so each folder
-- gives all package names that it can have.
---@return table<string, true> package names
local function jar_packages(jar_path, stat)
  local cached = packages_by_jar_cache[jar_path]
  if cached and cached.mtime == stat.mtime.sec then
    return cached.packages
  end
  local packages = {}
  local output = vim.system({ 'unzip', '-Z1', jar_path }, { text = true }):wait().stdout
  for entry in vim.gsplit(output, '\n', { trimempty = true }) do
    local folder = entry:match('^(.*)/[^/]+$')
    local package_name = folder and folder:gsub('/', '.')
    while package_name and not packages[package_name] do
      packages[package_name] = true
      package_name = package_name:match('^[^.]+%.(.+)$')
    end
  end
  packages_by_jar_cache[jar_path] = { mtime = stat.mtime.sec, packages = packages }
  return packages
end

---@param source_roots string[] sources jars and directories
---@return string[] source roots with a folder for the package
function M.roots_with_package(source_roots, package_name)
  local package_path = package_name:gsub('%.', '/')
  return vim.tbl_filter(function(source_root)
    -- A missing jar or directory has no package.
    local stat = vim.uv.fs_stat(source_root)
    if not stat then
      return false
    end
    if stat.type == 'directory' then
      return vim.uv.fs_stat(source_root .. '/' .. package_path) ~= nil
    end
    return jar_packages(source_root, stat)[package_name] == true
  end, source_roots)
end

---@param lines string[]? lines of the document, default the lines of its buffer
---@return string? identifier at the position of a request
local function find_symbol(params, lines)
  local line
  if lines then
    line = lines[params.position.line + 1] or ''
  else
    local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
    line = vim.api.nvim_buf_get_lines(bufnr, params.position.line, params.position.line + 1, false)[1] or ''
  end
  local column = params.position.character + 1
  for start_column, identifier in line:gmatch('()([%w_]+)') do
    if column >= start_column and column < start_column + #identifier then
      return identifier
    end
  end
  return nil
end

---@param paths string[] files or directories
---@return { path: string, line_index: integer, character: integer }[]
local function search(pattern, paths, globs)
  local command = { 'rg', '-n', '--column', '--no-heading', '--with-filename', '-e', pattern }
  for _, glob in ipairs(globs or { '*.kt', '*.java' }) do
    vim.list_extend(command, { '-g', glob })
  end
  local output = vim.system(vim.list_extend(command, paths), { text = true }):wait().stdout
  local matches = {}
  for line in vim.gsplit(vim.trim(output), '\n', { trimempty = true }) do
    local path, line_number, column = line:match('^(.-):(%d+):(%d+):')
    table.insert(matches, { path = path, line_index = tonumber(line_number) - 1, character = tonumber(column) - 1 })
  end
  return matches
end

---@return string[] paths of the source files of a package
local function find_package_files(directory, package_name)
  local pattern = '^package ' .. package_name:gsub('%.', '\\.') .. ';?\\s*$'
  return vim.tbl_map(function(match)
    return match.path
  end, search(pattern, { directory }))
end

---@param paths string[] files or directories
---@param types_only boolean
local function search_declarations(paths, symbol, types_only)
  local type_declaration = '\\b(class|interface|object|enum|record|typealias)\\s+' .. symbol .. '\\b|@interface\\s+' .. symbol .. '\\b'
  -- The Gradle accessors put each name in backticks. A name before `.` is a part of the receiver, for
  -- example `android` in `val com.android.Foo.bar`.
  local declaration = type_declaration .. '|\\b(fun|val|var)\\s+(<[^>]*>\\s*)?([\\w.<>?, ]+\\.)?`?' .. symbol .. '\\b([^.]|$)'
  local matches = search(types_only and type_declaration or declaration, paths)
  if #matches == 0 and not types_only then
    -- A Java member has a type before its name. A call in a method body can match too, so this
    -- search runs only when no other declaration matches.
    matches = search('^\\s*[\\w@<>\\[\\],.? ]+\\s' .. symbol .. '\\s*[(=;]', paths, { '*.java' })
  end
  return matches
end

---@return lsp.Location
local function to_location(uri_for, match)
  local position = { line = match.line_index, character = match.character }
  return { uri = uri_for(match.path), range = { start = position, ['end'] = position } }
end

-- Overloads

-- Removes annotations, type arguments, package names, and spaces, so that a type in a stub
-- (`kotlin.collections.List<T>`) and in a source file (`List<T>`) give the same text.
local function simple_type(type_text)
  local text = type_text:gsub('@[%w_.]+%b()', ''):gsub('@[%w_.]+', ''):gsub('%b<>', '')
  return (text:gsub('%f[%w_]%l[%w_]*%.', ''):gsub('%s+', ''))
end

local function split_parameters(text)
  local parts = {}
  local depth = 0
  local start = 1
  -- The `>` of a function type arrow is not a closing bracket.
  text = text:gsub('%->', ' returns ')
  for index = 1, #text do
    local char = text:sub(index, index)
    if char:match('[(<%[]') then
      depth = depth + 1
    elseif char:match('[)>%]]') then
      depth = depth - 1
    elseif char == ',' and depth == 0 then
      table.insert(parts, text:sub(start, index - 1))
      start = index + 1
    end
  end
  table.insert(parts, text:sub(start))
  -- A Kotlin trailing comma leaves an empty last part.
  return vim.tbl_filter(function(part)
    return vim.trim(part) ~= ''
  end, parts)
end

local function parameter_type(parameter)
  parameter = parameter:gsub('@[%w_.]+%b()', ''):gsub('@[%w_.]+', ''):gsub('=.*$', '')
  local kotlin_type = parameter:match('^[^:]-:(.*)$')
  if kotlin_type then
    local vararg = parameter:find('%f[%w]vararg%f[%W]') and 'vararg ' or ''
    return vararg .. simple_type(kotlin_type)
  end
  local java_type = vim.trim(parameter):gsub('^final%s+', ''):match('^(.-)%s+[%w_]+$')
  return simple_type(java_type or parameter)
end

---@return string? receiver and parameter types of the first declaration of `symbol` in `text`
local function signature_key(text, symbol)
  local symbol_start, parenthesis = text:match('()%f[%w_]' .. symbol .. '%s*()%(')
  local parameters = symbol_start and text:match('^%b()', parenthesis)
  if not parameters then
    return nil
  end
  local receiver = ''
  local prefix = text:sub(1, symbol_start - 1)
  if prefix:match('%.%s*$') then
    prefix = prefix:gsub('%.%s*$', '')
    local depth = 0
    local index = #prefix
    while index > 0 do
      local char = prefix:sub(index, index)
      if char == '>' then
        depth = depth + 1
      elseif char == '<' then
        depth = depth - 1
      elseif char:match('%s') and depth == 0 then
        break
      end
      index = index - 1
    end
    receiver = simple_type(prefix:sub(index + 1))
  end
  local types = {}
  if vim.trim(parameters:sub(2, -2)) ~= '' then
    for _, parameter in ipairs(split_parameters(parameters:sub(2, -2))) do
      table.insert(types, parameter_type(parameter))
    end
  end
  return receiver .. '(' .. table.concat(types, ',') .. ')'
end

-- The stub of the class file has the signature of the overload that the server located.
---@param declarations { location: lsp.Location, path: string, line_index: integer }[]
local function select_overloads(declarations, class_location, root_dir, symbol)
  local stub = require('kotlin_lsp_android.jar').decompile(class_location.uri or class_location.targetUri, root_dir)
  if not stub then
    return declarations
  end
  local stub_lines = vim.split(stub.code, '\n')
  local stub_line = (class_location.range or class_location.targetSelectionRange).start.line + 1
  local stub_key = signature_key(table.concat(stub_lines, ' ', stub_line, math.min(#stub_lines, stub_line + declaration_line_count)), symbol)
  local matching = vim.tbl_filter(function(declaration)
    local lines = vim.fn.readfile(declaration.path, '', declaration.line_index + declaration_line_count)
    return stub_key ~= nil and signature_key(table.concat(lines, ' ', declaration.line_index + 1), symbol) == stub_key
  end, declarations)
  return #matching > 0 and matching or declarations
end

-- Class file locations

---@return { location: lsp.Location, path: string, line_index: integer }[]
local function find_declarations(source_root, package_name, class_name, symbol)
  local directory, uri_for = open_sources(source_root)
  local files = find_package_files(directory, package_name)
  if #files == 0 then
    return {}
  end
  -- For a symbol with the name of the class file, the server located the class, not a function of
  -- the same name.
  local matches = symbol == class_name and search_declarations(files, symbol, true) or {}
  if #matches == 0 then
    matches = search_declarations(files, symbol, false)
  end
  local preferred, others = {}, {}
  for _, match in ipairs(matches) do
    -- `Foo.java` holds the members of `Foo`, and `Foo.kt` the members of the file facade `FooKt`.
    local file_name = vim.fn.fnamemodify(match.path, ':t:r')
    local declaration = { location = to_location(uri_for, match), path = match.path, line_index = match.line_index }
    table.insert((file_name == class_name or file_name .. 'Kt' == class_name) and preferred or others, declaration)
  end
  return #preferred > 0 and preferred or others
end

---@param location lsp.Location|lsp.LocationLink
---@return lsp.Location[]
local function to_declarations(location, symbol, root_dir)
  local uri = location.uri or location.targetUri
  local jar_path, entry_path = uri:match('^jar://(.-)!/(.+)%.class$')
  if not jar_path then
    return {}
  end
  local package_name = vim.fs.dirname(entry_path):gsub('/', '.')
  local class_name = vim.fs.basename(entry_path):gsub('%$.*', '')
  for _, source_root in ipairs(sources_by_jar(root_dir)[jar_path] or {}) do
    local declarations = find_declarations(source_root, package_name, class_name, symbol)
    if #declarations > 1 then
      declarations = select_overloads(declarations, location, root_dir, symbol)
    end
    if #declarations > 0 then
      return vim.tbl_map(function(declaration)
        return declaration.location
      end, declarations)
    end
  end
  return {}
end

-- Name lookup in library sources

---@return string? sources jar or source directory of a library document
local function find_document_sources(uri)
  local archive = uri:match('^jar://(.-)!/.+%.kt$') or uri:match('^jar://(.-)!/.+%.java$')
  if archive then
    return archive
  end
  local path = vim.uri_to_fname(uri)
  return path:match('^(.*/sources/android%-[^/]+)/') or path:match('^(.*/gradle%-sources/gradle%-[^/]+)/') or path:match('^(.*/wrapper/dists/.-/src)/')
end

-- The server finds the class files of a name, and these class files map to sources like any
-- location from the server. The first name with a result wins.
---@param names string[] full or simple names
---@param lines string[]? lines of the document, default the lines of its buffer
---@return lsp.Location[]?
local function find_in_other_libraries(names, params, root_dir, lines)
  local client = vim.iter(vim.lsp.get_clients({ name = 'kotlin_lsp' })):find(function(candidate)
    return candidate.root_dir == root_dir
  end)
  if not client then
    return nil
  end
  for _, name in ipairs(names) do
    local response = client:request_sync('workspace/symbol', { query = name }, 10000)
    local locations = vim
      .iter(response and response.result or {})
      :filter(function(item)
        return item.name == name
      end)
      :take(name_lookup_limit)
      :map(function(item)
        return item.location
      end)
      :totable()
    if #locations > 0 then
      return M.to_sources(locations, params, root_dir, lines)
    end
  end
  return nil
end

-- A type goes through the imports and the package of the file, any other name through
-- declarations in the file, the package, and then all sources of the library. A name from another
-- library goes to the server by its full name.
---@return lsp.Location[]?
local function find_by_name(params, root_dir)
  local sources = find_document_sources(params.textDocument.uri)
  local symbol = find_symbol(params)
  if not (sources and symbol) then
    return nil
  end
  local directory, uri_for = open_sources(sources)
  local lines = vim.api.nvim_buf_get_lines(vim.uri_to_bufnr(params.textDocument.uri), 0, -1, false)
  -- Each scope is a list of files or directories. The first scope with a declaration wins.
  local scopes = {}
  local full_names = {}
  for _, line in ipairs(lines) do
    local imported = line:match('^import%s+static%s+([%w_.]+)%.' .. symbol .. '%f[^%w_]') or line:match('^import%s+([%w_.]+)%.' .. symbol .. '%f[^%w_]')
    if imported then
      local files = find_package_files(directory, imported)
      if #files == 0 then
        -- The import names a class: a nested class or a static member of `<package>.<class>`.
        local package_name, class_name = imported:match('^(.*)%.([%w_]+)$')
        files = vim.tbl_filter(function(path)
          return vim.fn.fnamemodify(path, ':t:r') == class_name
        end, package_name and find_package_files(directory, package_name) or {})
      end
      -- An import that is not in this library names a declaration in another library.
      if #files == 0 then
        return find_in_other_libraries({ imported .. '.' .. symbol }, params, root_dir) or {}
      end
      table.insert(scopes, files)
    end
  end
  local document_path = params.textDocument.uri:match('^jar://') and directory .. '/' .. params.textDocument.uri:match('!/(.+)$')
    or vim.uri_to_fname(params.textDocument.uri)
  table.insert(scopes, { document_path })
  for _, line in ipairs(lines) do
    local package_name = line:match('^package%s+([%w_.]+)') or line:match('^import%s+([%w_.]+)%.%*')
    if package_name then
      table.insert(scopes, find_package_files(directory, package_name))
      table.insert(full_names, package_name .. '.' .. symbol)
    end
  end
  table.insert(scopes, { directory })
  -- A capitalized name is usually a type, but it can also be a function, for example a composable.
  for _, types_only in ipairs(symbol:match('^%u') and { true, false } or { false }) do
    for _, paths in ipairs(scopes) do
      local matches = #paths > 0 and search_declarations(paths, symbol, types_only) or {}
      if #matches > 0 then
        return vim
          .iter(matches)
          :take(name_lookup_limit)
          :map(function(match)
            return to_location(uri_for, match)
          end)
          :totable()
      end
    end
  end
  return find_in_other_libraries(full_names, params, root_dir) or {}
end

---@param result lsp.Location|lsp.Location[]|lsp.LocationLink[]|nil
---@param lines string[]? lines of the document, default the lines of its buffer
---@return lsp.Location|lsp.Location[]|lsp.LocationLink[]|nil
function M.to_sources(result, params, root_dir, lines)
  if result == nil or (vim.islist(result) and #result == 0) then
    -- The server does not analyze Gradle scripts.
    if params.textDocument.uri:match('%.gradle%.kts$') then
      return require('kotlin_lsp_android.script_lookup').definition(params, root_dir, lines) or result
    end
    return find_by_name(params, root_dir) or result
  end
  local symbol = find_symbol(params, lines)
  if not symbol then
    return result
  end
  local mapped = {}
  for _, location in ipairs(vim.islist(result) and result or { result }) do
    local declarations = to_declarations(location, symbol, root_dir)
    vim.list_extend(mapped, #declarations > 0 and declarations or { location })
  end
  return mapped
end

-- For the lookup in Gradle scripts
M.cache_dir = cache_dir
M.name_lookup_limit = name_lookup_limit
M.declaration_line_count = declaration_line_count
M.open_sources = open_sources
M.find_symbol = find_symbol
M.search_declarations = search_declarations
M.to_location = to_location
M.find_in_other_libraries = find_in_other_libraries

return M
