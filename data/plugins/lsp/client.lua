-- One language server per (server, project root): starts it, keeps open
-- docs in sync, stores diagnostics and restarts it after a crash. No drawing.
local core = require "core"
local json = require "plugins.lsp.json"
local rpc = require "plugins.lsp.rpc"
local servers = require "plugins.lsp.servers"
local util = require "plugins.lsp.util"
local M = {clients = {}, diagnostics = {}, generation = 0, idle_timeout = 300}

local function changed() M.generation = M.generation + 1; core.redraw = true end

local function log(c, text)
  for line in text:gmatch("[^\r\n]+") do
    c.log[#c.log + 1] = line
    if #c.log > 500 then table.remove(c.log, 1) end
  end
end

local function send_open(c, doc)
  local entry = c.docs[doc]
  c.rpc:notify("textDocument/didOpen", {textDocument = {uri = entry.uri,
    languageId = servers.language_id(c.spec, doc.abs_filename), version = entry.version, text = table.concat(doc.lines)}})
end

local function lines_for(path)
  for _, c in pairs(M.clients) do
    for doc in pairs(c.docs) do if doc.abs_filename == path then return doc.lines end end
  end
end

local function on_notify(c, method, params)
  if method == "textDocument/publishDiagnostics" then
    local path = util.uri_to_path(params.uri)
    M.diagnostics[path] = util.diagnostics(params.diagnostics, lines_for(path))
    changed()
  elseif method == "window/showMessage" or method == "window/logMessage" then
    log(c, params.message or "")
    if method == "window/showMessage" and (params.type or 4) <= 2 then core.log("%s: %s", c.spec.label, params.message) end
  end
end

local function on_request(c, method, params)
  if method == "workspace/configuration" then
    local out = {}
    for i = 1, #(params and params.items or {}) do out[i] = {} end
    return out
  elseif method == "workspace/workspaceFolders" then
    return {{uri = util.path_to_uri(c.root), name = c.root:match("[^/]+$") or c.root}}
  end
end

local start

local function on_exit(c, r, code)
  if c.rpc ~= r then return end
  c.rpc = nil
  if c.stopping then return end
  log(c, "server exited with code " .. tostring(code))
  c.state = "crashed"; changed()
  if util.may_restart(c.crashes, system.get_time()) then
    core.add_thread(function() coroutine.yield(1); if c.state == "crashed" and not c.stopping then start(c) end end)
  end
end

function start(c)
  local exe = servers.resolve(c.spec)
  if not exe then c.state = "missing"; changed(); return end
  local argv = {exe, table.unpack(c.spec.cmd, 2)}
  local env = {PATH = servers.path()}
  for k, v in pairs(c.spec.env or {}) do env[k] = v end
  c.state, c.caps = "starting", nil
  local r
  r = rpc.start(argv, {cwd = c.root, env = env,
    notify = function(m, p) on_notify(c, m, p) end, request = function(m, p) return on_request(c, m, p) end,
    stderr = function(text) log(c, text) end, exit = function(code) on_exit(c, r, code) end})
  if not r then log(c, "cannot start " .. exe); c.state = "crashed"; changed(); return end
  c.rpc = r
  changed()
  local root_uri = util.path_to_uri(c.root)
  r:request("initialize", {processId = json.null, rootUri = root_uri, rootPath = c.root, clientInfo = {name = "TreX"},
    workspaceFolders = {{uri = root_uri, name = c.root:match("[^/]+$") or c.root}},
    capabilities = {
      textDocument = {synchronization = {didSave = true}, publishDiagnostics = {relatedInformation = false},
        hover = {contentFormat = {"markdown", "plaintext"}}, definition = {linkSupport = true},
        references = {dynamicRegistration = false}, documentSymbol = {hierarchicalDocumentSymbolSupport = true}},
      workspace = {workspaceFolders = true, configuration = true, symbol = {dynamicRegistration = false}},
    }}, function(result, err)
      if c.rpc ~= r then return end
      if not result then log(c, "initialize failed: " .. tostring(err)); r:kill(); return end
      c.caps, c.state = result.capabilities or {}, "ready"
      r:notify("initialized", {})
      for doc in pairs(c.docs) do send_open(c, doc) end
      changed()
    end)
end

function M.get(spec, root)
  local key = spec.name .. "\0" .. root
  local c = M.clients[key]
  if not c then
    c = {key = key, spec = spec, root = root, docs = {}, log = {}, crashes = {}, state = "missing"}
    M.clients[key] = c
    start(c)
  end
  return c
end

function M.open(c, doc)
  if c.docs[doc] then return M.change(c, doc) end
  c.docs[doc], c.idle_since = {version = 0, uri = util.path_to_uri(doc.abs_filename)}, nil
  if c.state == "ready" then send_open(c, doc) end
end

function M.change(c, doc)
  local entry = c.docs[doc]
  if not entry then return end
  entry.version = entry.version + 1
  if c.state ~= "ready" then return end
  c.rpc:notify("textDocument/didChange", {textDocument = {uri = entry.uri, version = entry.version},
    contentChanges = {{text = table.concat(doc.lines)}}})
end

function M.save(c, doc)
  if c.state == "ready" and c.docs[doc] then c.rpc:notify("textDocument/didSave", {textDocument = {uri = c.docs[doc].uri}}) end
end

function M.close(c, doc)
  local entry = c.docs[doc]
  if not entry then return end
  if c.state == "ready" then c.rpc:notify("textDocument/didClose", {textDocument = {uri = entry.uri}}) end
  c.docs[doc] = nil
  if next(c.docs) == nil then c.idle_since = system.get_time() end
end

function M.request(c, method, params, cb)
  if c.state ~= "ready" then return cb(nil, c.spec.label .. " language server is not ready") end
  c.rpc:request(method, params, cb)
end

function M.supports(c, capability) return c.state == "ready" and c.caps[capability] ~= nil and c.caps[capability] ~= false end

function M.restart(c)
  local old = c.rpc
  c.rpc, c.crashes, c.stopping = nil, {}, nil
  if old then old:kill() end
  start(c)
end

function M.stop(c)
  c.stopping = true
  M.clients[c.key] = nil
  local r = c.rpc
  if r then
    r:request("shutdown", nil, function()
      r:notify("exit")
      core.add_thread(function() coroutine.yield(2); r:kill() end)
    end)
  end
end

function M.tick(now)
  for _, c in pairs(M.clients) do
    if c.idle_since and now - c.idle_since > M.idle_timeout then M.stop(c) end
  end
end

return M
