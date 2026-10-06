-- mod-version:4
-- GitHub: the signed-in user's contributions and streak, fetched through `gh`.
local core = require "core"
local config = require "core.config"
local common = require "core.common"
local command = require "core.command"
local style = require "core.style"
local View = require "core.view"
local git = require "plugins.scm.git"
local views = require "plugins.scm.views"
local data = require "plugins.github.data"

config.plugins.github = common.merge({width = 320}, config.plugins.github)
local options = config.plugins.github
local REFRESH_SECONDS = 600

-- model: what the panel draws (see plugins.github.data). status.state is one of
-- "idle" | "loading" | "ok" | "auth" | "error"; status.at is the last fetch attempt.
local M = {model = nil, status = {state = "idle"}}

local function first_line(text) return (tostring(text):match("[^\r\n]+") or tostring(text)) end
local function needs_login(err)
  local e = tostring(err):lower()
  return e:find("auth", 1, true) or e:find("logged in", 1, true) or e:find("could not start", 1, true) or e:find("no such file", 1, true)
end

local function load()
  local query = data.query(data.windows(os.time()))
  local out, err = git.exec(USERDIR, "gh", {"api", "graphql", "-f", "query=" .. query}, nil, 30)
  if not out then return nil, err end
  local model, parse_err = data.parse(out)
  if not model then return nil, parse_err end
  model.streak = data.streak(model.days, os.date("!%Y-%m-%d"))
  model.fetched_at = os.time()
  return model
end

local function fetch()
  M.status = {state = "loading", at = os.time()}
  core.redraw = true
  local ok, model, err = pcall(load)
  if not ok then model, err = nil, model end
  if model then
    M.model, M.status = model, {state = "ok", at = M.status.at}
  else
    M.status = {state = needs_login(err) and "auth" or "error", error = first_line(err), at = M.status.at}
  end
  core.redraw = true
end

function M.refresh()
  if M.status.state == "loading" then return end
  M.status = {state = "loading", at = os.time()}
  core.add_thread(fetch)
end

local GitHub = View:extend()
local panel
function GitHub:new() GitHub.super.new(self); self.visible = true; self.scrollable = true; self.height = 0 end
function GitHub:get_name() return "GitHub" end
function GitHub:get_size() return self.visible and options.width * SCALE or 0, 0 end
function GitHub:set_target_size(axis, width)
  if axis == "x" then options.width = math.max(200, width / SCALE); core.redraw = true; return true end
end
local function lh() return style.font:get_height() + style.padding.y end
local function header_h() return math.floor(lh() * 1.5) end
function GitHub:get_scrollable_size() return header_h() + self.height + lh() end
function GitHub:on_mouse_wheel(y) self.scroll.to.y = self.scroll.to.y - y * lh() * 3; return true end
function GitHub:update()
  local width = self.visible and options.width * SCALE or 0
  if self.size.x ~= width then self.size.x = width; core.redraw = true end
  GitHub.super.update(self)
end

local number_font, small_font, card_font, label_font, date_font
local function tint(c, a) return {c[1], c[2], c[3], a} end
local BLUE, PURPLE, TEAL, FLAME, BORDER = {91, 155, 245, 255}, {192, 132, 252, 255}, {45, 212, 191, 255}, {251, 146, 60, 255}, {228, 226, 226, 110}
local GREENS = {{14, 68, 41, 255}, {0, 109, 50, 255}, {38, 166, 65, 255}, {57, 211, 83, 255}}

-- Shade thresholds: quartiles of the non-zero days, as on the GitHub profile graph.
local function levels(days)
  local counts = {}
  for _, day in ipairs(days) do if day.count > 0 then counts[#counts + 1] = day.count end end
  table.sort(counts)
  local function q(p) return counts[math.max(1, math.ceil(#counts * p))] or 0 end
  return {q(0.25), q(0.5), q(0.75)}
end

local function weekday(date)
  local y, m, d = date:match("(%d+)-(%d+)-(%d+)")
  return os.date("*t", os.time({year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12})).wday - 1
end

-- ponytail: rounded corners and the ring are rows and dots of draw_rect, the renderer has no paths.
local function rounded(x, y, w, h, r, color)
  for j = 0, r - 1 do
    local dx = math.floor(r - math.sqrt(r * r - (r - j - 0.5) ^ 2) + 0.5)
    renderer.draw_rect(x + dx, y + j, w - dx * 2, 1, color)
    renderer.draw_rect(x + dx, y + h - 1 - j, w - dx * 2, 1, color)
  end
  renderer.draw_rect(x, y + r, w, h - r * 2, color)
end

-- Circle outline with a gap of `gap` radians at the top, where the flame sits.
local function ring(cx, cy, r, t, gap, color)
  local n = math.ceil(math.pi * 4 * r / t)
  for k = 0, n - 1 do
    local a = math.pi * 2 * k / n
    if a > gap / 2 and a < math.pi * 2 - gap / 2 then
      renderer.draw_rect(math.floor(cx + r * math.sin(a) - t / 2), math.floor(cy - r * math.cos(a) - t / 2), t, t, color)
    end
  end
end

local function flame(cx, top, w, h, color)
  for j = 0, h - 1 do
    local fw = math.floor(w * math.sin(math.pi * ((j + 0.5) / h) ^ 1.6) + 0.5)
    if fw > 0 then renderer.draw_rect(math.floor(cx - fw / 2), top + j, fw, 1, color) end
  end
end

local function range(from, to) return from and data.short_date(from) .. " - " .. data.short_date(to) or "No streak" end

function GitHub:draw_card(model, x, y, w)
  card_font = card_font or style.font:copy(24 * SCALE)
  label_font = label_font or style.font:copy(10 * SCALE)
  date_font = date_font or style.font:copy(10 * SCALE)
  local pad, py = style.padding.x, style.padding.y
  local s = model.streak or {current = 0, longest = 0}
  local r, t = math.floor(24 * SCALE), math.max(2, math.floor(2 * SCALE))
  local cx, cw = x + pad, w - pad * 2
  local col = cw / 3
  local ring_y = y + py * 2 + r
  local label_y = ring_y + r + t + py
  local h = label_y + label_font:get_height() + date_font:get_height() + py * 2 - y
  rounded(cx, y, cw, h, math.floor(5 * SCALE), BORDER)
  rounded(cx + 1, y + 1, cw - 2, h - 2, math.floor(5 * SCALE) - 1, {
    math.min(255, style.background2[1] + 10), math.min(255, style.background2[2] + 10), math.min(255, style.background2[3] + 10), 255})
  for i = 1, 2 do renderer.draw_rect(math.floor(cx + col * i), y + py, 1, h - py * 2, BORDER) end
  local columns = {
    {number = model.windows[4] and model.windows[4].contributions or 0, label = "Total Contributions", dates = "Jan 1 - Present", color = BLUE},
    {number = s.current, label = "Current Streak", dates = range(s.current_from, s.current_to), color = PURPLE},
    {number = s.longest, label = "Longest Streak", dates = range(s.longest_from, s.longest_to), color = BLUE},
  }
  for i, c in ipairs(columns) do
    local lx = cx + col * (i - 1)
    if i == 2 then
      local mid = math.floor(lx + col / 2)
      ring(mid, ring_y, r, t, 0.9, PURPLE)
      flame(mid, ring_y - r - math.floor(7 * SCALE), math.floor(9 * SCALE), math.floor(13 * SCALE), FLAME)
    end
    common.draw_text(card_font, c.color, data.thousands(c.number), "center", lx, ring_y - r, col, r * 2)
    common.draw_text(label_font, c.color, views.fit(label_font, c.label, col - 4), "center", lx, label_y, col, label_font:get_height())
    common.draw_text(date_font, TEAL, views.fit(date_font, c.dates, col - 4), "center", lx, label_y + label_font:get_height(), col, date_font:get_height())
  end
  return y + h + pad
end

function GitHub:draw_tiles(model, x, y, w)
  number_font = number_font or style.font:copy(28 * SCALE)
  small_font = small_font or style.font:copy(12 * SCALE)
  local pad = style.padding.x
  local tw = (w - pad * 3) / 2
  local th = number_font:get_height() + style.font:get_height() * 2 + style.padding.y * 2
  for i, win in ipairs(model.windows) do
    local tx, ty = x + pad + ((i - 1) % 2) * (tw + pad), y + ((i - 1) // 2) * (th + pad)
    renderer.draw_rect(tx, ty, tw, th, style.background)
    local cy = ty + style.padding.y
    common.draw_text(number_font, style.text, data.thousands(win.contributions), nil, tx + pad, cy, 0, number_font:get_height())
    cy = cy + number_font:get_height()
    common.draw_text(style.font, style.accent, win.label, nil, tx + pad, cy, 0, style.font:get_height())
    common.draw_text(small_font, style.dim, views.fit(small_font, data.thousands(win.commits) .. " commits", tw - pad * 2), nil, tx + pad, cy + style.font:get_height(), 0, style.font:get_height())
  end
  return y + (th + pad) * 2
end

function GitHub:draw_heatmap(model, x, y, w)
  local days = model.days
  if #days == 0 then return y end
  if self.levels_for ~= model then self.levels, self.levels_for = levels(days), model end
  local step = math.max(2, math.floor((w - style.padding.x * 2) / 53))
  local size = math.max(1, step - math.max(1, math.floor(SCALE)))
  local offset = weekday(days[1].date)
  for i, day in ipairs(days) do
    local slot = i - 1 + offset
    local level = 0
    if day.count > 0 then level = 1; for _, t in ipairs(self.levels) do if day.count > t then level = level + 1 end end end
    local color = level == 0 and tint(style.dim, 48) or GREENS[level]
    renderer.draw_rect(x + style.padding.x + (slot // 7) * step, y + (slot % 7) * step, size, size, color)
  end
  return y + step * 7 + style.padding.y
end

function GitHub:draw()
  if not self.visible then return end
  self:draw_background(style.background2)
  local x, w, top = self.position.x, self.size.x, self.position.y + header_h()
  local model, status = M.model, M.status
  common.draw_text(style.font, style.text, "GITHUB" .. (model and " · " .. model.login or ""), nil, x + style.padding.x, self.position.y, 0, header_h())
  local label = "Refresh"
  local bw = style.font:get_width(label) + style.padding.x
  local bx = x + w - style.padding.x - bw
  self.refresh_button = {x = bx, y = self.position.y, w = bw, h = header_h()}
  local hovered = self.hover_x and self.hover_x >= bx and self.hover_y and self.hover_y < top
  common.draw_text(style.font, (hovered or status.state == "loading") and style.accent or style.dim, label, "center", bx, self.position.y, bw, header_h())

  core.push_clip_rect(x, top, w, self.size.y - header_h())
  local y = top - self.scroll.y
  local note
  if status.state == "auth" then note = "Run gh auth login in a terminal, then refresh."
  elseif status.state == "loading" then note = model and "Refreshing…" or "Loading…"
  elseif status.state == "error" then note = "Couldn't refresh: " .. status.error
  elseif model then note = "Updated " .. views.relative(os.date("!%Y-%m-%dT%H:%M:%SZ", model.fetched_at)) end
  if note then
    common.draw_text(style.font, status.state == "error" and style.error or style.dim, views.fit(style.font, note, w - style.padding.x * 2), nil, x + style.padding.x, y, 0, lh())
    y = y + lh()
  end
  if model and status.state ~= "auth" then
    y = self:draw_card(model, x, y, w)
    y = self:draw_tiles(model, x, y, w)
    y = self:draw_heatmap(model, x, y, w)
  end
  self.height = y + self.scroll.y - top
  core.pop_clip_rect(); self:draw_scrollbar()
end

function GitHub:on_mouse_moved(x, y, ...)
  GitHub.super.on_mouse_moved(self, x, y, ...)
  if x ~= self.hover_x or y ~= self.hover_y then self.hover_x, self.hover_y = x, y; core.redraw = true end
end
function GitHub:on_mouse_left() GitHub.super.on_mouse_left(self); self.hover_x, self.hover_y = nil, nil; core.redraw = true end
function GitHub:on_mouse_pressed(button, x, y, clicks)
  if GitHub.super.on_mouse_pressed(self, button, x, y, clicks) then return true end
  local b = self.refresh_button
  if b and x >= b.x and x < b.x + b.w and y >= b.y and y < b.y + b.h then M.refresh(); return true end
  return true
end

core.add_thread(function()
  while true do
    if panel and panel.visible and M.status.state ~= "loading" and os.time() - (M.status.at or 0) >= REFRESH_SECONDS then fetch() end
    coroutine.yield(1)
  end
end)

command.add(nil, {
  ["github:toggle"] = function()
    if not panel then
      panel = GitHub(); panel.size.x = options.width * SCALE
      core.root_view:get_primary_node():split("right", panel, {x = true}, true)
    else
      panel.visible = not panel.visible
      if not panel.visible and core.active_view == panel then core.set_active_view(core.root_view:get_primary_node().active_view) end
    end
    core.redraw = true
  end,
  ["github:refresh"] = M.refresh,
})

function M.panel() return panel end
return M
