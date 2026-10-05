-- mod-version:4
-- LLM subscription usage (Claude, ChatGPT/Codex) in the status bar.
-- Like t3code, usage is asked from each vendor CLI so it owns tokens and refresh:
--   Claude: `claude -p --input-format stream-json` + control_request `get_usage`
--   Codex:  `codex app-server` JSON-RPC `account/rateLimits/read`
-- One status item per account: ~/.claude, ~/.claude-<name> (CLAUDE_CONFIG_DIR),
-- ~/.codex, ~/.codex-<name> (CODEX_HOME).
local core = require "core"
local common = require "core.common"
local config = require "core.config"
local command = require "core.command"
local style = require "core.style"
local process = require "core.process"

config.plugins.usage = common.merge({
  refresh_interval = 300, -- seconds, same default as t3code
  timeout = 30,
  -- Override discovery: {{provider = "claude"|"codex", dir = "/path", name = "work"}, ...}
  accounts = nil,
}, config.plugins.usage)

local HOME = os.getenv("HOME") or ""
local PATH = table.concat({HOME .. "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", os.getenv("PATH") or "/usr/bin:/bin"}, ":")

local function exists(path) return system.get_file_info(path) ~= nil end

local function discover()
  if config.plugins.usage.accounts then return config.plugins.usage.accounts end
  local accounts = {}
  for _, entry in ipairs(system.list_dir(HOME) or {}) do
    local provider, suffix = entry:match("^%.(claude)(.*)$")
    if not provider then provider, suffix = entry:match("^%.(codex)(.*)$") end
    local dir = HOME .. "/" .. entry
    if provider and (suffix == "" or suffix:match("^%-.+")) then
      local marker = provider == "claude" and (suffix == "" and dir or dir .. "/.claude.json") or dir .. "/auth.json"
      if exists(marker) then
        accounts[#accounts + 1] = {provider = provider, dir = dir, name = provider .. suffix:gsub("^%-", "/")}
      end
    end
  end
  table.sort(accounts, function(a, b) return a.provider .. a.name < b.provider .. b.name end)
  return accounts
end

local function find(name)
  for dir in PATH:gmatch("[^:]+") do
    if exists(dir .. "/" .. name) then return dir .. "/" .. name end
  end
end

-- Write `input`, read stdout until `done(output)` matches, then kill.
local function ask(argv, env, input, done)
  local ok, proc = pcall(process.start, argv, {env = env, cwd = HOME})
  if not ok or not proc then return nil, "could not start " .. argv[1] end
  proc:write(input)
  local output, started = "", system.get_time()
  while system.get_time() - started < config.plugins.usage.timeout do
    proc:read(process.STREAM_STDERR, 65536) -- drain so a chatty CLI can't block on a full pipe
    local chunk = proc:read(process.STREAM_STDOUT, 65536)
    if chunk and #chunk > 0 then
      output = output .. chunk
      local result = done(output)
      if result then proc:kill(); return result end
    elseif not proc:running() then break end
    coroutine.yield(0.1)
  end
  proc:kill()
  return nil, proc:running() and "timed out" or "no usage data"
end

-- ponytail: field extraction by pattern instead of a JSON decoder; the vendor
-- payloads are flat objects, add a decoder if their shape gets nested.
local function utc_iso(text)
  local y, m, d, H, M, S = (text or ""):match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then return end
  local t = os.time({year = y, month = m, day = d, hour = H, min = M, sec = S})
  return t + (os.time() - os.time(os.date("!*t")))
end

local function window(object, label, percent_key, reset_key)
  if not object then return end
  local used = tonumber(object:match('"' .. percent_key .. '":%s*([%d%.]+)'))
  if not used then return end
  local reset = object:match('"' .. reset_key .. '":%s*"([^"]+)"') or object:match('"' .. reset_key .. '":%s*(%d+)')
  return {label = label, used = used, resets = tonumber(reset) or utc_iso(reset)}
end

local function probe_claude(account)
  local exe = find("claude")
  if not exe then return nil, "claude CLI not found" end
  -- The default ~/.claude must run without CLAUDE_CONFIG_DIR: the keychain entry name depends on it.
  local env = {PATH = PATH, CLAUDE_CONFIG_DIR = account.dir ~= HOME .. "/.claude" and account.dir or nil}
  local request = '{"type":"control_request","request_id":"usage","request":{"subtype":"get_usage","skip_behaviors":true}}\n'
  return ask({exe, "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
      "--setting-sources", "", "--strict-mcp-config", "--no-session-persistence"}, env, request, function(out)
    local line = out:match('[^\n]*"request_id":"usage"[^\n]*\n')
    if not line then return end
    if not line:match('"rate_limits_available":true') then
      return {error = "no usage data, sign in again: CLAUDE_CONFIG_DIR=" .. account.dir .. " claude /login", windows = {}}
    end
    return {
      plan = line:match('"subscription_type":"([^"]+)"'),
      windows = {
        window(line:match('"five_hour":(%b{})'), "5h", "utilization", "resets_at"),
        window(line:match('"seven_day":(%b{})'), "7d", "utilization", "resets_at"),
      },
    }
  end)
end

local function probe_codex(account)
  local exe = find("codex")
  if not exe then return nil, "codex CLI not found" end
  local input = table.concat({
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"TreX","title":"TreX","version":"1"},"capabilities":{"experimentalApi":true}}}',
    '{"jsonrpc":"2.0","method":"initialized"}',
    '{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":null}', ""}, "\n")
  return ask({exe, "app-server"}, {PATH = PATH, CODEX_HOME = account.dir}, input, function(out)
    local line = out:match('[^\n]*"id":2,[^\n]*\n')
    if not line then return end
    if line:match('"error"') then return {error = line:match('"message":"([^"]+)"') or "not signed in", windows = {}} end
    local limits = line:match('"rateLimitsByLimitId":%s*{%s*"codex":(%b{})') or line:match('"rateLimits":(%b{})') or ""
    local function codex_window(key)
      local object = limits:match('"' .. key .. '":(%b{})')
      local w = window(object, nil, "usedPercent", "resetsAt")
      local mins = w and tonumber(object:match('"windowDurationMins":%s*(%d+)'))
      if w then w.label = not mins and (key == "primary" and "5h" or "7d") or mins >= 1440 and (mins // 1440) .. "d" or (mins // 60) .. "h" end
      return w
    end
    return {plan = limits:match('"planType":"([^"]+)"'), windows = {codex_window("primary"), codex_window("secondary")}}
  end)
end

local function until_reset(t)
  local s = t and t - os.time()
  if not s or s <= 0 then return "now" end
  if s >= 86400 then return string.format("%dd %dh", s // 86400, s % 86400 // 3600) end
  return string.format("%dh %02dm", s // 3600, s % 3600 // 60)
end


local accounts = discover()
local M = {accounts = accounts}

function M.refresh()
  for _, account in ipairs(accounts) do
    local result, err = (account.provider == "claude" and probe_claude or probe_codex)(account)
    if result and not result.error then
      account.result, account.error = result, nil
    else
      -- Keep the last good snapshot on failure, like t3code.
      account.error = err or result.error
    end
    -- Signed-out / revoked accounts are hidden until they log in again.
    account.item.visible = not (result and result.error and not account.result)
    account.checked = os.time()
    core.redraw = true
  end
end

local refreshing = false
local function refresh_async()
  if refreshing then return end
  refreshing = true
  core.add_thread(function() M.refresh(); refreshing = false end)
end

local function line(x1, y1, x2, y2, t, c)
  local steps = math.max(1, math.ceil(math.max(math.abs(x2 - x1), math.abs(y2 - y1))))
  for i = 0, steps do
    local p = i / steps
    renderer.draw_rect(x1 + (x2 - x1) * p - t / 2, y1 + (y2 - y1) * p - t / 2, t, t, c)
  end
end

-- ponytail: logos approximated with rect strokes (renderer has no image/SVG support).
local CLAUDE = {217, 119, 87, 255}
local function draw_logo(provider, cx, cy, r)
  local t = math.max(1.5, 1.6 * SCALE)
  if provider == "claude" then -- starburst
    for k = 0, 11 do
      local a = k * math.pi / 6 + 0.2
      local len = (k % 2 == 0) and r or r * 0.75
      line(cx + math.cos(a) * r * 0.2, cy + math.sin(a) * r * 0.2, cx + math.cos(a) * len, cy + math.sin(a) * len, t, CLAUDE)
    end
  else -- OpenAI knot: hexagon with pinwheel strokes
    for k = 0, 5 do
      local a, b = k * math.pi / 3 + math.pi / 6, (k + 1) * math.pi / 3 + math.pi / 6
      line(cx + math.cos(a) * r, cy + math.sin(a) * r, cx + math.cos(b) * r, cy + math.sin(b) * r, t, style.accent)
      line(cx + math.cos(a) * r, cy + math.sin(a) * r, cx + math.cos(b + math.pi / 3) * r * 0.35, cy + math.sin(b + math.pi / 3) * r * 0.35, t, style.accent)
    end
  end
end

local function color(left) return left <= 10 and style.error or left <= 30 and style.warn or style.text end

for _, account in ipairs(accounts) do
  local item = core.status_view:add_item({
    name = "usage:" .. account.provider .. ":" .. account.name,
    alignment = core.status_view.Item.RIGHT,
    position = 1,
    command = "usage:refresh",
    get_item = function() return {} end,
  })
  account.item = item
  item.on_draw = function(x, y, h, hovered, calc_only)
    local r = account.result
    local parts, tip = {}, {account.name .. (r and r.plan and " (" .. r.plan .. ")" or "")}
    for _, w in ipairs(r and r.windows or {}) do
      local left = math.max(0, math.floor(100 - w.used + 0.5))
      parts[#parts + 1] = {style.dim, " " .. w.label .. " "}
      parts[#parts + 1] = {color(left), left .. "%"}
      tip[#tip + 1] = string.format("%s %d%% left, resets in %s", w.label, left, until_reset(w.resets))
    end
    if #parts == 0 then parts[1] = {style.dim, " -"} end
    if account.error then tip[#tip + 1] = account.error end
    item.tooltip = table.concat(tip, " · ")
    local logo = math.floor(h * 0.6)
    local width = logo
    for _, part in ipairs(parts) do width = width + style.font:get_width(part[2]) end
    if calc_only then return width end
    draw_logo(account.provider, x + logo / 2, y + h / 2, logo / 2)
    local tx = x + logo
    for _, part in ipairs(parts) do
      tx = common.draw_text(style.font, part[1], part[2], nil, tx, y, 0, h)
    end
    return width
  end
end

command.add(nil, {["usage:refresh"] = refresh_async})

if #accounts > 0 then
  core.add_thread(function()
    coroutine.yield(2)
    while true do
      refreshing = true; M.refresh(); refreshing = false
      coroutine.yield(config.plugins.usage.refresh_interval)
    end
  end)
end

return M
