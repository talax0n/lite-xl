local core = require "core"
local style = require "core.style"
local View = require "core.view"
local common = require "core.common"
local parse = require "plugins.scm.parse"
local M = {}
local function line_height() return style.code_font:get_height() + style.padding.y end
local Text = View:extend()
Text.context = "session"
function Text:new(name, text, actions)
  Text.super.new(self); self.name, self.actions = name, actions or {}; self.scrollable = true
  self.lines, self.width, self.hunk = {}, 0, 0
  for raw_line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local line = raw_line
    if #self.lines >= 20000 then self.lines[#self.lines + 1] = "Display limited to 20,000 lines. Use the terminal for the complete output."; break end
    if #line > 4096 then line = line:sub(1, 4096) .. " [line clipped]" end
    self.lines[#self.lines + 1] = line
    self.width = math.max(self.width, #line * style.code_font:get_width("M"))
  end
  self.hunks = parse.hunks(text)
end
function Text:get_name() return self.name end
function Text:get_scrollable_size() return (#self.lines + 3) * line_height() end
function Text:get_h_scrollable_size() return self.width + style.padding.x * 2 end
function Text:on_mouse_wheel(y, x) self.scroll.to.y = self.scroll.to.y - y * line_height() * 3; self.scroll.to.x = self.scroll.to.x + (x or 0) * 30; return true end
function Text:draw()
  self:draw_background(style.background)
  local lh = line_height()
  local x, y = self:get_content_offset(); x = x + style.padding.x; y = y + lh * 2
  core.push_clip_rect(self.position.x, self.position.y + lh * 2, self.size.x, self.size.y - lh * 2)
  local first = math.max(1, math.floor(self.scroll.y / lh) - 1)
  local last = math.min(#self.lines, first + math.ceil(self.size.y / lh) + 1)
  local hunk = 0
  for i = 1, first - 1 do if self.lines[i]:match("^@@ ") then hunk = hunk + 1 end end
  for i = first, last do
    local text, color = self.lines[i], style.text
    if text:match("^@@ ") then hunk = hunk + 1; color = style.accent
    elseif text:sub(1, 1) == "+" then color = {110, 200, 130}
    elseif text:sub(1, 1) == "-" then color = {230, 120, 120} end
    if hunk > 0 and hunk == self.hunk then renderer.draw_rect(self.position.x, y + (i - 1) * lh, self.size.x, lh, style.line_highlight) end
    renderer.draw_text(style.code_font, text, x, y + (i - 1) * lh, color)
  end
  core.pop_clip_rect()
  self.buttons = {}; x, y = self.position.x + style.padding.x, self.position.y + style.padding.y
  for _, action in ipairs(self.actions) do
    local w = style.font:get_width(action.text) + style.padding.x * 2
    renderer.draw_text(style.font, action.text, x, y, style.accent)
    self.buttons[#self.buttons + 1] = {x = x, w = w, fn = action.fn}; x = x + w
  end
  if #self.actions == 0 then renderer.draw_text(style.font, self.name, x, y, style.dim) end
  if #self.hunks > 0 then renderer.draw_text(style.font, "Click a diff hunk to select it", self.position.x + style.padding.x, self.position.y + lh, style.dim) end
  self:draw_scrollbar()
end
function Text:on_mouse_pressed(button, x, y, clicks)
  if Text.super.on_mouse_pressed(self, button, x, y, clicks) then return true end
  if y < self.position.y + line_height() then
    for _, b in ipairs(self.buttons or {}) do if x >= b.x and x < b.x + b.w then b.fn(self); return true end end
  end
  local index = math.floor((y - self.position.y + self.scroll.y) / line_height()) - 1
  local hunk = 0
  for i = 1, math.min(index, #self.lines) do if self.lines[i]:match("^@@ ") then hunk = hunk + 1 end end
  self.hunk = hunk; core.redraw = true; return true
end
M.Text = Text

local List = View:extend()
List.context = "session"
function List:new(name, rows, on_select)
  List.super.new(self); self.name, self.rows, self.on_select = name, rows, on_select; self.scrollable = true; self.selected = 0
end
function List:get_name() return self.name end
function List:get_scrollable_size() return (#self.rows + 2) * line_height() end
function List:get_h_scrollable_size() return 1600 * SCALE end
List.on_mouse_wheel = Text.on_mouse_wheel
function List:draw()
  self:draw_background(style.background)
  local x, y = self:get_content_offset(); x = x + style.padding.x
  local lh = line_height()
  for i = math.max(1, math.floor(self.scroll.y / lh)), math.min(#self.rows, math.ceil((self.scroll.y + self.size.y) / lh) + 1) do
    local row = self.rows[i]
    if i == self.selected then renderer.draw_rect(self.position.x, y + (i - 1) * lh, self.size.x, lh, style.line_highlight) end
    renderer.draw_text(style.code_font, type(row) == "table" and row.text or row, x, y + (i - 1) * lh, style.text)
  end
  self:draw_scrollbar()
end
function List:on_mouse_pressed(button, x, y, clicks)
  if List.super.on_mouse_pressed(self, button, x, y, clicks) then return true end
  local i = math.floor((y - self.position.y + self.scroll.y) / line_height()) + 1
  self.selected = i
  if self.rows[i] and self.on_select then self.on_select(self.rows[i], clicks) end
  core.redraw = true; return true
end
M.List = List
local Graph = List:extend()
local palette = {{115, 175, 245}, {230, 150, 100}, {145, 200, 120}, {190, 135, 220}, {220, 195, 100}, {100, 200, 200}}
local function graph_line(x1, y1, x2, y2, color)
  if x1 == x2 then renderer.draw_rect(x1, math.min(y1, y2), 2 * SCALE, math.abs(y2 - y1) + 2 * SCALE, color); return end
  local steps = math.max(1, math.ceil(math.abs(y2 - y1) / SCALE))
  for i = 0, steps do
    local p = i / steps
    renderer.draw_rect(math.floor(x1 + (x2 - x1) * p), math.floor(y1 + (y2 - y1) * p), 2 * SCALE, 2 * SCALE, color)
  end
end
function Graph:new(repo, git, on_commit)
  Graph.super.new(self, "History: " .. repo.name, {}, on_commit); self.repo, self.git = repo, git
end
function Graph:get_scrollable_size() return (#self.repo.history + 4) * line_height() end
function Graph:draw()
  self:draw_background(style.background)
  local x, y = self:get_content_offset(); x = x + style.padding.x
  local lh, gap = line_height(), 15 * SCALE
  local first, last = math.max(1, math.floor(self.scroll.y / lh)), math.min(#self.repo.history, math.ceil((self.scroll.y + self.size.y) / lh) + 1)
  for i = first, last do
    local c = self.repo.history[i]; local cy = y + (i - 1) * lh + lh / 2
    if i == self.selected then renderer.draw_rect(self.position.x, cy - lh / 2, self.size.x, lh, style.line_highlight) end
    for _, edge in ipairs(c.edges) do
      local color = palette[(edge[1] - 1) % #palette + 1]
      graph_line(x + (edge[1] - 1) * gap, edge[3] and cy or cy - lh / 2, x + (edge[2] - 1) * gap, cy + lh / 2, color)
    end
    local color = palette[(c.lane - 1) % #palette + 1]
    if c.incoming then graph_line(x + (c.lane - 1) * gap, cy - lh / 2, x + (c.lane - 1) * gap, cy, color) end
    renderer.draw_rect(x + (c.lane - 1) * gap - 3 * SCALE, cy - 3 * SCALE, 7 * SCALE, 7 * SCALE, color)
    local text = c.hash:sub(1, 8) .. "  " .. (c.refs ~= "" and "[" .. c.refs .. "]  " or "") .. c.subject .. (c.graph_limited and " [additional graph lanes omitted]" or "") .. "   " .. c.author .. "  " .. c.date:sub(1, 10)
    renderer.draw_text(style.code_font, text, x + math.max(4, c.lanes) * gap, cy - style.code_font:get_height() / 2, style.text)
  end
  local footer = self.repo.history_done and "End of history" or #self.repo.history >= 2000 and "History display limit reached (2,000 commits)" or "Load next 100 commits"
  renderer.draw_text(style.font, footer, x, y + #self.repo.history * lh, style.accent)
  self:draw_scrollbar()
end
function Graph:on_mouse_pressed(button, x, y, clicks)
  if View.on_mouse_pressed(self, button, x, y, clicks) then return true end
  local i = math.floor((y - self.position.y + self.scroll.y) / line_height()) + 1
  if i > #self.repo.history then self.git.history(self.repo)
  else self.selected = i; self.on_select(self.repo.history[i], clicks) end
  core.redraw = true; return true
end
M.Graph = Graph
function M.open(view)
  local node = core.root_view:get_active_node_default()
  for _, old in ipairs(node.views) do
    if view:is(Graph) and old:is(Graph) and old.repo == view.repo then
      node:set_active_view(old); core.redraw = true; return old
    end
  end
  for i = #node.views, 1, -1 do
    local old = node.views[i]
    if view:is(Text) and old:is(Text) then node:close_view(core.root_view.root_node, old) end
  end
  node:add_view(view)
  core.root_view.root_node:update_layout()
  core.redraw = true
  return view
end
return M
