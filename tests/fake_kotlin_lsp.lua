-- A kotlin-lsp stand-in on stdio for specs. `FAKE_CLASS_URI` and `FAKE_SOURCE_URI` are the
-- definition results during and after the indexing. The indexing starts at `initialized` and at
-- `test/beginIndexing`, and ends at `test/endIndexing`. After `test/classOnly`, each result is the
-- class file.
local indexing = false
local class_only = false
local definition_count = 0

local function send(message)
  message.jsonrpc = '2.0'
  local body = vim.json.encode(message)
  io.stdout:write(('Content-Length: %d\r\n\r\n%s'):format(#body, body))
  io.stdout:flush()
end

local function progress(kind)
  send({ method = '$/progress', params = { token = 'indexing', value = { kind = kind, title = 'Indexing' } } })
end

local function location(uri)
  local position = { line = 0, character = 0 }
  return { uri = uri, range = { start = position, ['end'] = position } }
end

local handlers = {
  initialize = function()
    return { capabilities = { definitionProvider = true } }
  end,
  initialized = function()
    indexing = true
    progress 'begin'
  end,
  ['test/beginIndexing'] = function()
    indexing = true
    progress 'begin'
  end,
  ['test/classOnly'] = function()
    class_only = true
  end,
  ['test/endIndexing'] = function()
    indexing = false
    progress 'end'
  end,
  ['test/definitionCount'] = function()
    return definition_count
  end,
  ['textDocument/definition'] = function()
    definition_count = definition_count + 1
    return { location((indexing or class_only) and vim.env.FAKE_CLASS_URI or vim.env.FAKE_SOURCE_URI) }
  end,
  ['workspace/executeCommand'] = function()
    return { code = 'class C', language = 'kotlin' }
  end,
  exit = function()
    os.exit(0)
  end,
}

while true do
  local length
  for line in io.stdin:lines() do
    if line == '\r' or line == '' then
      break
    end
    length = tonumber(line:match '^Content%-Length: (%d+)') or length
  end
  if not length then
    os.exit(0)
  end
  local message = vim.json.decode(io.stdin:read(length))
  local handler = handlers[message.method]
  local result = handler and handler(message.params)
  if message.id then
    send({ id = message.id, result = result == nil and vim.NIL or result })
  end
end
