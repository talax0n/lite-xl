-- mod-version:4
-- Projects column: sibling project folders, their uncommitted change counts, click to switch.
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local style = require "core.style"
local View = require "core.view"
local git = require "plugins.scm.git"
local data = require "plugins.projects.data"

-- root: parent folder to list; nil means the parent of the current project.
config.plugins.projects = common.merge({width = 180}, config.plugins.projects)
local options = config.plugins.projects
if config.plugins.treeview == false then return end
local tree = require "plugins.treeview"
local REFOCUS_SECONDS = 30

-- core:restart empties core.projects in core.exit and still draws a frame before reloading.
local function current() local project = core.root_project(); return project and project.path end

local Projects = View:extend()
function Projects:__tostring() return "ProjectsView" end
function Projects:new() Projects.super.new(self); self.scrollable = true; self.shown = true; self.rows = {} end
local function lh() return style.font:get_height() + style.padding.y end
local function header_h() return math.floor(lh() * 1.5) end
function Projects:get_scrollable_size() return header_h() + #self.rows * lh() end
function Projects:set_target_size(axis, value)
  if axis == "x" then options.width = math.max(80, value / SCALE); return true end
end

function Projects:refresh()
  self.loaded = system.get_time()
  local old = {}
  for _, row in ipairs(self.rows) do old[row.path] = row.count end
  self.rows = data.list(options.root or common.dirname(core.root_project().path) or PATHSEP)
  for _, row in ipairs(self.rows) do
    row.count = old[row.path]
    if row.git then
      core.add_thread(function()
        local out = git.exec(row.path, "git", {"status", "--porcelain"}, nil, 15)
        row.count = out and data.count(out) or nil
        core.redraw = true
      end)
    end
  end
end

function Projects:update()
  local visible = self.shown and tree.visible
  self:move_towards(self.size, "x", visible and options.width * SCALE or 0, nil, "treeview")
  if visible and current() then
    local focus = system.window_has_focus(core.window)
    if not self.loaded or (focus and not self.focused and system.get_time() - self.loaded > REFOCUS_SECONDS) then self:refresh() end
    self.focused = focus
  end
  Projects.super.update(self)
end

local function refresh_rect(self)
  local w = style.font:get_width("Refresh") + style.padding.x
  return self.position.x + self.size.x - style.padding.x - w, self.position.y, w, header_h()
end

function Projects:draw()
  if self.size.x < 1 or not current() then return end
  self:draw_background(style.background2)
  local x, y, w, h, px = self.position.x, self.position.y, self.size.x, lh(), style.padding.x
  core.push_clip_rect(x, y, w, self.size.y)
  common.draw_text(style.font, style.dim, "PROJECTS", nil, x + px, y, 0, header_h())
  local bx, by, bw, bh = refresh_rect(self)
  local hot = self.hover_x and self.hover_x >= bx and self.hover_y < by + bh
  common.draw_text(style.font, hot and style.accent or style.dim, "Refresh", "center", bx, by, bw, bh)
  local top = y + header_h()
  core.push_clip_rect(x, top, w, self.size.y - header_h())
  local current = current()
  for i, row in ipairs(self.rows) do
    local ry = top + (i - 1) * h - self.scroll.y
    if row.path == current then
      renderer.draw_rect(x, ry, w, h, style.line_highlight)
      renderer.draw_rect(x, ry, math.max(1, math.floor(2 * SCALE)), h, style.caret)
    end
    local right = x + w - px
    if row.count and row.count > 0 then
      local label = tostring(row.count)
      local ch = style.font:get_height()
      local cw = math.max(ch, style.font:get_width(label) + math.floor(10 * SCALE))
      local cx, cy, r = right - cw, ry + math.floor((h - ch) / 2), math.floor(3 * SCALE)
      local tint = {style.modified[1], style.modified[2], style.modified[3], 50}
      -- ponytail: corners are a 3-rect chamfer, the renderer has no rounded rects.
      renderer.draw_rect(cx + r, cy, cw - r * 2, ch, tint)
      renderer.draw_rect(cx, cy + r, r, ch - r * 2, tint)
      renderer.draw_rect(cx + cw - r, cy + r, r, ch - r * 2, tint)
      common.draw_text(style.font, style.modified, label, "center", cx, cy, cw, ch)
      right = cx - px / 2
    end
    core.push_clip_rect(x, ry, right - x, h)
    common.draw_text(style.font, row == self.hovered and style.accent or style.text, row.name, nil, x + px, ry, 0, h)
    core.pop_clip_rect()
  end
  core.pop_clip_rect()
  core.pop_clip_rect()
  self:draw_scrollbar()
end

function Projects:row_at(px, py)
  local top = self.position.y + header_h()
  if px < self.position.x or px >= self.position.x + self.size.x or py < top then return end
  return self.rows[math.floor((py - top + self.scroll.y) / lh()) + 1]
end

local function set_hover(self, x, y)
  self.hover_x, self.hover_y, self.hovered = x, y, x and self:row_at(x, y)
  if self.hovered then core.status_view:show_tooltip({self.hovered.path}); self.tooltip = true
  elseif self.tooltip then core.status_view:remove_tooltip(); self.tooltip = false end
  core.redraw = true
end
function Projects:on_mouse_moved(x, y, ...) Projects.super.on_mouse_moved(self, x, y, ...); set_hover(self, x, y) end
function Projects:on_mouse_left() Projects.super.on_mouse_left(self); set_hover(self) end

function Projects:on_mouse_pressed(button, x, y, clicks)
  if Projects.super.on_mouse_pressed(self, button, x, y, clicks) then return true end
  local bx, by, bw, bh = refresh_rect(self)
  if x >= bx and x < bx + bw and y >= by and y < by + bh then self:refresh(); return true end
  local row = self:row_at(x, y)
  if row and current() and row.path ~= current() then
    core.confirm_close_docs(core.docs, function(dir) core.open_project(dir) end, row.path)
  end
  return true
end

local view = Projects()
-- Left of the tree, inside its locked pane; Node:resize lets the dividers reach both.
core.root_view.root_node:get_node_for_view(tree):split("left", view, {x = true}, true)

command.add(nil, {
  ["projects:toggle"] = function() view.shown = not view.shown end,
  ["projects:refresh"] = function() view:refresh() end,
})

return view
