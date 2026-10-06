-- Problems and References tabs: file header rows and location rows.
local core = require "core"
local common = require "core.common"
local style = require "core.style"
local View = require "core.view"
local M = {}

local List = View:extend()
M.List = List

-- build() -> rows; live() -> a value that changes when rows must be rebuilt.
function List:new(name, build, live, on_pick)
  List.super.new(self)
  self.name, self.build, self.live, self.on_pick, self.scrollable = name, build, live, on_pick, true
  self.gen, self.rows = live and live(), build()
end
function List:get_name() return self.name end

local function lh() return style.font:get_height() + style.padding.y end
function List:get_scrollable_size() return #self.rows * lh() + style.padding.y end

function List:update()
  if self.live and self.live() ~= self.gen then self.gen, self.rows = self.live(), self.build() end
  List.super.update(self)
end

function List:row_at(y)
  local _, oy = self:get_content_offset()
  local i = math.floor((y - oy - style.padding.y / 2) / lh()) + 1
  return self.rows[i] and i
end

function List:draw()
  self:draw_background(style.background)
  local h, mark = lh(), math.floor(8 * SCALE)
  local ox, oy = self:get_content_offset()
  core.push_clip_rect(self.position.x, self.position.y, self.size.x, self.size.y)
  for i = math.max(1, (self:row_at(self.position.y) or 1)), #self.rows do
    local y = oy + style.padding.y / 2 + (i - 1) * h
    if y > self.position.y + self.size.y then break end
    local row, x = self.rows[i], ox + style.padding.x + (self.rows[i].indent or 0)
    if i == self.hovered_row and row.target then renderer.draw_rect(self.position.x, y, self.size.x, h, style.line_highlight) end
    if row.mark then
      renderer.draw_rect(x, y + (h - mark) / 2, mark, mark, row.mark)
      x = x + mark + style.padding.x / 2
    end
    for _, part in ipairs(row) do x = common.draw_text(style.font, part[1], part[2], nil, x, y, 0, h) + style.padding.x / 2 end
  end
  core.pop_clip_rect()
  self:draw_scrollbar()
end

function List:on_mouse_moved(x, y, ...)
  List.super.on_mouse_moved(self, x, y, ...)
  self.hovered_row = self:row_at(y)
end

function List:on_mouse_pressed(button, x, y, clicks)
  if List.super.on_mouse_pressed(self, button, x, y, clicks) then return true end
  local i = self:row_at(y)
  if i and self.rows[i].target then self.on_pick(self.rows[i].target) end
  return true
end

-- One tab per name: an open one takes the new content and is focused.
function M.show(list)
  for _, v in ipairs(core.root_view.root_node:get_children()) do
    if v:is(List) and v.name == list.name then
      v.build, v.live, v.on_pick, v.gen, v.rows = list.build, list.live, list.on_pick, list.gen, list.rows
      core.root_view.root_node:get_node_for_view(v):set_active_view(v)
      return v
    end
  end
  core.root_view:get_active_node_default():add_view(list)
  return list
end

return M
