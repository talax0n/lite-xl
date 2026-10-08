-- mod-version:4
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local style = require "core.style"
local keymap = require "core.keymap"
local View = require "core.view"

-- Vertical activity bar docked at the far left of the window.
local ToolbarView = View:extend()

function ToolbarView:__tostring() return "ToolbarView" end

local function scm() return package.loaded["plugins.scm"] end
local function scm_visible() local s = scm(); local p = s and s.panel(); return p and p.visible end
local function tree() return package.loaded["plugins.treeview"] end
local function backlog() return package.loaded["plugins.backlog"] end
local function backlog_visible() local b = backlog(); local p = b and b.panel(); return p and p.visible end
local function github_visible() local g = package.loaded["plugins.github"]; local p = g and g.panel(); return p and p.visible end

function ToolbarView:new()
  ToolbarView.super.new(self)
  self.visible = true
  self.tooltip = false
  self.toolbar_font = style.icon_big_font
  self.toolbar_commands = {
    {symbol = "f", command = "treeview:toggle", name = "Explorer",
      active = function() local t = tree(); return t and t.visible and not scm_visible() end,
      perform = function() if scm_visible() then command.perform("scm:toggle") else command.perform("treeview:toggle") end end},
    {symbol = "L", command = "project-search:find", name = "Search"},
    {command = "scm:toggle", name = "Source Control", git = true, active = scm_visible,
      badge = function() local s = scm(); return s and s.change_count() or 0 end},
    {symbol = "B", command = "backlog:toggle", name = "Backlog", active = backlog_visible,
      badge = function() local b = backlog(); return b and b.open_count() or 0 end},
    {symbol = "g", command = "github:toggle", name = "GitHub", active = github_visible},
    {command = "terminal:toggle", name = "Terminal", text = ">_",
      active = function() local t = package.loaded["plugins.terminal"]; local p = t and t.panel and t.panel(); return p and p.visible end},
    {symbol = "P", command = "core:open-user-module", name = "Settings", bottom = true},
  }
end

function ToolbarView:get_width() return math.floor(48 * SCALE) end

function ToolbarView:update()
  self.size.x = self.visible and self:get_width() or 0
  ToolbarView.super.update(self)
end

function ToolbarView:toggle_visible()
  self.visible = not self.visible
  if self.tooltip then
    core.status_view:remove_tooltip()
    self.tooltip = false
  end
  self.hovered_item = nil
end

function ToolbarView:get_min_width() return self:get_width() end
-- Fixed width; claiming the resize lets the divider drag pass the rest to the treeview.
function ToolbarView:set_target_size(axis) return axis == "x" end

function ToolbarView:each_item()
  local w = self.size.x
  local h = math.floor(44 * SCALE)
  local top, bottom = self.position.y + style.padding.y, self.position.y + self.size.y - style.padding.y
  local index = 0
  return function()
    index = index + 1
    local item = self.toolbar_commands[index]
    if not item then return end
    local y
    if item.bottom then bottom = bottom - h; y = bottom else y = top; top = top + h end
    return item, self.position.x, y, w, h
  end
end

local function draw_git(x, y, w, h, color)
  local t = math.max(1, math.floor(2 * SCALE))
  local left, right, top, bottom = x + w * 0.25, x + w * 0.75, y + h * 0.2, y + h * 0.8
  local middle = y + h * 0.55
  renderer.draw_rect(left, top, t, bottom - top, color)
  renderer.draw_rect(right, top, t, middle - top, color)
  renderer.draw_rect(left, middle, right - left + t, t, color)
  for _, point in ipairs({{left, top}, {right, top}, {left, bottom}}) do
    renderer.draw_rect(point[1] - t, point[2] - t, t * 3, t * 3, color)
  end
end

function ToolbarView:draw()
  if not self.visible then return end
  self:draw_background(style.background2)
  local icon = math.floor(24 * SCALE)
  for item, x, y, w, h in self:each_item() do
    local active = item.active and item.active()
    local color = (active or item == self.hovered_item) and style.accent or style.dim
    if active then renderer.draw_rect(x, y, math.max(1, math.floor(2 * SCALE)), h, style.accent) end
    local ix, iy = x + (w - icon) / 2, y + (h - icon) / 2
    if item.git then draw_git(ix, iy, icon, icon, color)
    elseif item.text then common.draw_text(style.code_font, color, item.text, "center", x, y, w, h)
    else common.draw_text(self.toolbar_font, color, item.symbol, "center", x, y, w, h) end
    local count = item.badge and item.badge() or 0
    if count > 0 then
      local label = count > 99 and "99+" or tostring(count)
      local bh = math.floor(16 * SCALE)
      local bw = math.max(bh, style.font:get_width(label) + 8 * SCALE)
      local bx, by = ix + icon - bw / 2, iy + icon - bh / 2
      renderer.draw_rect(bx, by, bw, bh, style.caret)
      common.draw_text(style.font, style.background2, label, "center", bx, by, bw, bh)
    end
  end
end

function ToolbarView:on_mouse_pressed(button, x, y, clicks)
  if not self.visible then return end
  local caught = ToolbarView.super.on_mouse_pressed(self, button, x, y, clicks)
  if caught then return caught end
  core.set_active_view(core.last_active_view)
  local item = self.hovered_item
  if item and item.perform then item.perform()
  elseif item and command.is_valid(item.command) then command.perform(item.command) end
  return true
end

function ToolbarView:on_mouse_left()
  ToolbarView.super.on_mouse_left(self)
  if self.tooltip then
    core.status_view:remove_tooltip()
    self.tooltip = false
  end
  self.hovered_item = nil
end

function ToolbarView:on_mouse_moved(px, py, ...)
  if not self.visible then return end
  ToolbarView.super.on_mouse_moved(self, px, py, ...)
  self.hovered_item = nil
  for item, x, y, w, h in self:each_item() do
    if px >= x and py >= y and px < x + w and py < y + h then
      self.hovered_item = item
      local binding = keymap.get_binding(item.command)
      core.status_view:show_tooltip(binding and { item.name, style.dim, "  ", binding } or { item.name })
      self.tooltip = true
      return
    end
  end
  if self.tooltip then
    core.status_view:remove_tooltip()
    self.tooltip = false
  end
end

-- The activity bar is plugged in by the treeview plugin.

return ToolbarView
