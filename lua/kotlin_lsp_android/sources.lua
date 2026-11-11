-- kotlin-lsp can locate a symbol in a class file although `workspace.json` gives sources for its
-- jar, for example the Kotlin stdlib of the Gradle distribution in build logic. This module moves
-- such a location to the declaration in those sources.
local M = {}

local extract_root = vim.fn.stdpath('cache') .. '/kotlin-lsp-android/sources'

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

---@return string? identifier at the position of a request
local function find_symbol(params)
  local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
  local line = vim.api.nvim_buf_get_lines(bufnr, params.position.line, params.position.line + 1, false)[1] or ''
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
local function search(pattern, paths)
  local command = { 'rg', '-n', '--column', '--no-heading', '--with-filename', '-g', '*.kt', '-g', '*.java', '-e', pattern }
  local output = vim.system(vim.list_extend(command, paths), { text = true }):wait().stdout
  local matches = {}
  for line in vim.gsplit(vim.trim(output), '\n', { trimempty = true }) do
    local path, line_number, column = line:match('^(.-):(%d+):(%d+):')
    table.insert(matches, { path = path, line_index = tonumber(line_number) - 1, character = tonumber(column) - 1 })
  end
  return matches
end

---@return lsp.Location[]
local function find_declarations(source_root, package_name, class_name, symbol)
  local directory = vim.fn.isdirectory(source_root) == 1 and source_root or extract(source_root)
  local package_pattern = '^package ' .. package_name:gsub('%.', '\\.') .. ';?\\s*$'
  local files = vim.tbl_map(function(match)
    return match.path
  end, search(package_pattern, { directory }))
  if #files == 0 then
    return {}
  end
  local type_declaration = '\\b(class|interface|object|enum|record|typealias)\\s+' .. symbol .. '\\b|@interface\\s+' .. symbol .. '\\b'
  local member_declaration = '\\b(fun|val|var)\\s+(<[^>]*>\\s*)?([\\w.<>?, ]+\\.)?' .. symbol .. '\\b'
  -- For a symbol with the name of the class file, the server located the class, not a function of
  -- the same name.
  local matches = symbol == class_name and search(type_declaration, files) or {}
  if #matches == 0 then
    matches = search(type_declaration .. '|' .. member_declaration, files)
  end
  local preferred, others = {}, {}
  for _, match in ipairs(matches) do
    -- `Foo.kt` holds the members of the file facade `FooKt`.
    local file_name = vim.fn.fnamemodify(match.path, ':t:r')
    local position = { line = match.line_index, character = match.character }
    local uri = directory == source_root and vim.uri_from_fname(match.path)
      or ('jar://%s!/%s'):format(source_root, match.path:sub(#directory + 2))
    local location = { uri = uri, range = { start = position, ['end'] = position } }
    table.insert((file_name == class_name or file_name .. 'Kt' == class_name) and preferred or others, location)
  end
  return #preferred > 0 and preferred or others
end

---@param location lsp.Location|lsp.LocationLink
---@return lsp.Location[]
local function to_declarations(location, symbol, root_dir)
  local uri = location.uri or location.targetUri
  local jar_path, entry_path = uri:match('^jar://(.-)!/(.+)%.class$')
  local source_roots = jar_path and sources_by_jar(root_dir)[jar_path] or {}
  local package_name = jar_path and vim.fs.dirname(entry_path):gsub('/', '.')
  local class_name = jar_path and vim.fs.basename(entry_path):gsub('%$.*', '')
  for _, source_root in ipairs(source_roots) do
    local declarations = find_declarations(source_root, package_name, class_name, symbol)
    if #declarations > 0 then
      return declarations
    end
  end
  return {}
end

---@param result lsp.Location|lsp.Location[]|lsp.LocationLink[]|nil
---@return lsp.Location|lsp.Location[]|lsp.LocationLink[]|nil
function M.to_sources(result, params, root_dir)
  if result == nil or (vim.islist(result) and #result == 0) then
    return result
  end
  local symbol = find_symbol(params)
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

return M
