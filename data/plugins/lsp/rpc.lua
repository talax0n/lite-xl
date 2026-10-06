-- JSON-RPC over a language server's stdio. `parser` and `frame` are pure;
-- `start` runs the process in a thread so the UI never blocks.
local json = require "plugins.lsp.json"
local core = require "core"
local process = require "core.process"
local M = {timeout = 10}

-- Feeds raw stdout chunks; returns the message bodies completed so far.
function M.parser()
  local buf = ""
  return function(chunk)
    buf = buf .. chunk
    local bodies = {}
    while true do
      local hs, he = buf:find("\r\n\r\n", 1, true)
      if not hs then break end
      local len = tonumber(buf:sub(1, hs - 1):match("[Cc]ontent%-[Ll]ength:%s*(%d+)"))
      if not len then buf = buf:sub(he + 1) -- junk header: drop it, resync on the next one
      elseif #buf - he < len then break
      else bodies[#bodies + 1] = buf:sub(he + 1, he + len); buf = buf:sub(he + len + 1) end
    end
    return bodies
  end
end

function M.frame(msg)
  local body = json.encode(msg)
  return "Content-Length: " .. #body .. "\r\n\r\n" .. body
end

local RPC = {}
RPC.__index = RPC

local function call(fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok then core.error("LSP: %s", tostring(err)) end
end

function RPC:send(msg) self.out[#self.out + 1] = M.frame(msg) end
function RPC:notify(method, params) self:send({jsonrpc = "2.0", method = method, params = params}) end
function RPC:request(method, params, cb)
  if not self.alive then return cb(nil, "server not running") end
  self.next_id = self.next_id + 1
  self.pending[self.next_id] = {cb = cb, method = method, deadline = system.get_time() + M.timeout}
  self:send({jsonrpc = "2.0", id = self.next_id, method = method, params = params})
end
function RPC:kill() if self.alive then self.proc:kill() end end

function RPC:dispatch(body)
  local msg = json.decode(body)
  if type(msg) ~= "table" then return call(self.on.stderr, "unreadable message: " .. body:sub(1, 200) .. "\n") end
  if msg.method and msg.id ~= nil then
    local ok, result = pcall(self.on.request, msg.method, msg.params)
    self:send({jsonrpc = "2.0", id = msg.id, result = ok and result ~= nil and result or json.null})
  elseif msg.method then
    call(self.on.notify, msg.method, msg.params)
  else
    local p = self.pending[msg.id]
    if p then self.pending[msg.id] = nil; call(p.cb, msg.result, msg.error and msg.error.message) end
  end
end

-- Writes queued frames as far as the pipe accepts them.
function RPC:flush()
  while #self.out > 0 do
    local data = self.out[1]
    local n = self.proc:write(data)
    if not n or n == 0 then return end
    if n < #data then self.out[1] = data:sub(n + 1); return end
    table.remove(self.out, 1)
  end
end

function RPC:expire(now)
  local late = {}
  for id, p in pairs(self.pending) do if now > p.deadline then late[#late + 1] = id end end
  for _, id in ipairs(late) do
    local p = self.pending[id]; self.pending[id] = nil
    call(p.cb, nil, p.method .. " timed out")
  end
end

function M.start(argv, on)
  local ok, proc = pcall(process.start, argv, {cwd = on.cwd, env = on.env})
  if not ok or not proc or not proc.process then return nil, not ok and tostring(proc) or "cannot start " .. argv[1] end
  local self = setmetatable({proc = proc, on = on, out = {}, pending = {}, next_id = 0, alive = true}, RPC)
  local feed = M.parser()
  core.add_thread(function()
    while true do
      self:flush()
      local busy = false
      local out = proc:read(process.STREAM_STDOUT, 65536)
      if out and #out > 0 then busy = true; for _, body in ipairs(feed(out)) do self:dispatch(body) end end
      local err = proc:read(process.STREAM_STDERR, 65536)
      if err and #err > 0 then busy = true; call(self.on.stderr, err) end
      self:expire(system.get_time())
      if not busy and not proc:running() then break end
      coroutine.yield(busy and 0 or 0.02)
    end
    self.alive = false
    self:expire(math.huge)
    call(self.on.exit, proc:returncode())
  end)
  return self
end

return M
