-- mod-version:4
-- GitHub: the signed-in user's contributions, streak, PRs and pushes, fetched through `gh`.
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
function M.open_url(url) system.exec(string.format("open %q", url)) end

local function first_line(text) return (tostring(text):match("[^\r\n]+") or tostring(text)) end
local function needs_login(err)
  local e = tostring(err):lower()
  return e:find("auth", 1, true) or e:find("logged in", 1, true) or e:find("could not start", 1, true) or e:find("no such file", 1, true)
end

local function fetch()
  M.status = {state = "loading", at = os.time()}
  core.redraw = true
  local query = data.query(data.windows(os.time()))
  local out, err = git.exec(USERDIR, "gh", {"api", "graphql", "-f", "query=" .. query}, nil, 30)
  local model
  if out then model, err = data.parse(out) end
  if model then
    local events = git.exec(USERDIR, "gh", {"api", "/users/" .. model.login .. "/events?per_page=50"}, nil, 30)
    model = data.parse(out, events)
    model.streak = data.streak(model.days, os.date("!%Y-%m-%d"))
    model.fetched_at = os.time()
    M.model, M.status = model, {state = "ok", at = M.status.at}
  else
    M.status = {state = needs_login(err) and "auth" or "error", error = first_line(err), at = M.status.at}
  end
  core.redraw = true
end

function M.refresh() if M.status.state ~= "loading" then core.add_thread(fetch) end end

local GitHub = View:extend()
local panel
function GitHub:new() GitHub.super.new(self); self.visible = true; self.scrollable = true; self.height = 0; self.hits = {} end
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

local number_font, small_font
local function tint(c, a) return {c[1], c[2], c[3], a} end

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
    common.draw_text(number_font, style.text, tostring(win.contributions), nil, tx + pad, cy, 0, number_font:get_height())
    cy = cy + number_font:get_height()
    common.draw_text(style.font, style.accent, win.label, nil, tx + pad, cy, 0, style.font:get_height())
    common.draw_text(small_font, style.dim, views.fit(small_font, win.commits .. " commits visible", tw - pad * 2), nil, tx + pad, cy + style.font:get_height(), 0, style.font:get_height())
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
    local color = level == 0 and style.line_highlight or tint(style.accent, 64 * level - 1)
    renderer.draw_rect(x + style.padding.x + (slot // 7) * step, y + (slot % 7) * step, size, size, color)
  end
  y = y + step * 7 + style.padding.y
  local s = model.streak or {current = 0, longest = 0}
  common.draw_text(style.font, style.dim, string.format("Streak %d days · longest %d", s.current, s.longest), nil, x + style.padding.x, y, 0, lh())
  return y + lh()
end

function GitHub:draw_section(title, rows, x, y, w, primary, secondary, time)
  local pad, fh = style.padding.x, style.font:get_height()
  y = y + style.padding.y
  common.draw_text(style.font, style.accent, title, nil, x + pad, y, 0, lh())
  y = y + lh()
  if not rows or #rows == 0 then
    common.draw_text(style.font, style.dim, rows and "None" or "Unavailable", nil, x + pad, y, 0, lh())
    return y + lh()
  end
  for _, row in ipairs(rows) do
    local h = fh * 2 + style.padding.y
    if self.hover_y and self.hover_y >= y and self.hover_y < y + h then renderer.draw_rect(x, y, w, h, style.line_highlight) end
    local when = views.relative(row[time])
    local ww = style.font:get_width(when)
    common.draw_text(style.font, style.dim, when, nil, x + w - pad - ww, y + style.padding.y / 2, 0, fh)
    common.draw_text(style.font, style.text, views.fit(style.font, row[primary], w - pad * 3 - ww), nil, x + pad, y + style.padding.y / 2, 0, fh)
    common.draw_text(style.font, style.dim, views.fit(style.font, row[secondary], w - pad * 2), nil, x + pad, y + style.padding.y / 2 + fh, 0, fh)
    self.hits[#self.hits + 1] = {x = x, y = y, w = w, h = h, url = row.url}
    y = y + h
  end
  return y
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

  self.hits = {}
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
    y = self:draw_tiles(model, x, y, w)
    y = self:draw_heatmap(model, x, y, w)
    y = self:draw_section("MY PULL REQUESTS", model.prs, x, y, w, "title", "repo", "updated")
    y = self:draw_section("REVIEW REQUESTS", model.reviews, x, y, w, "title", "repo", "updated")
    y = self:draw_section("RECENT PUSHES", model.pushes, x, y, w, "repo", "branch", "at")
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
  if y < self.position.y + header_h() then return true end
  for _, hit in ipairs(self.hits) do
    if y >= hit.y and y < hit.y + hit.h then M.open_url(hit.url); return true end
  end
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
