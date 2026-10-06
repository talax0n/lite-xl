-- Language server for tests: fixed answers to the requests TreX sends and
-- one diagnostic per opened or changed document. Run with ide-test-runner.
package.path = (os.getenv('TREX_DATA') or './data') .. '/?.lua;' .. package.path
local json = require 'plugins.lsp.json'
local function send(msg)
  local body = json.encode(msg)
  io.write('Content-Length: ' .. #body .. '\r\n\r\n' .. body); io.flush()
end
local function range(l1, c1, l2, c2) return {start = {line = l1, character = c1}, ['end'] = {line = l2, character = c2}} end
local handlers = {
  initialize = function() return {capabilities = {textDocumentSync = 1, hoverProvider = true, definitionProvider = true,
    referencesProvider = true, documentSymbolProvider = true, workspaceSymbolProvider = true}} end,
  ['textDocument/hover'] = function() return {contents = {kind = 'markdown', value = '```ts\nconst answer: number\n```'}} end,
  ['textDocument/definition'] = function(p) return {uri = p.textDocument.uri, range = range(2, 6, 2, 13)} end,
  ['textDocument/references'] = function(p)
    return {{uri = p.textDocument.uri, range = range(0, 6, 0, 12)}, {uri = p.textDocument.uri, range = range(2, 16, 2, 22)}}
  end,
  ['textDocument/documentSymbol'] = function()
    return {{name = 'answer', kind = 13, range = range(0, 0, 0, 17), selectionRange = range(0, 6, 0, 12)}}
  end,
  ['workspace/symbol'] = function() return {{name = 'answer', kind = 13, location = {uri = 'file:///nowhere.ts', range = range(0, 6, 0, 12)}}} end,
  shutdown = function() return json.null end,
}
while true do
  local len
  repeat
    local line = io.read('l')
    if not line then os.exit(0) end
    len = tonumber(line:match('Content%-Length: (%d+)')) or len
  until line:gsub('\r$', '') == ''
  local msg = json.decode(io.read(len))
  if msg.method == 'exit' then os.exit(0) end
  if msg.method == 'initialized' then
    send({jsonrpc = '2.0', id = 'cfg', method = 'workspace/configuration', params = {items = {{section = 'fake'}}}})
  elseif msg.id == 'cfg' and msg.method == nil then
    send({jsonrpc = '2.0', method = 'window/logMessage', params = {type = 3, message = 'configured ' .. #msg.result}})
  elseif msg.method == 'textDocument/didOpen' or msg.method == 'textDocument/didChange' then
    send({jsonrpc = '2.0', method = 'textDocument/publishDiagnostics', params = {uri = msg.params.textDocument.uri,
      diagnostics = {{range = range(0, 6, 0, 12), severity = 1, source = 'fake', code = 7, message = 'answer is not a question'}}}})
  end
  if msg.id ~= nil and msg.method and handlers[msg.method] then
    send({jsonrpc = '2.0', id = msg.id, result = handlers[msg.method](msg.params)})
  end
end
