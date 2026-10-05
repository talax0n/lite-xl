local core = require "core"
local style = require "core.style"
local View = require "core.view"
local common = require "core.common"
local parse = require "plugins.scm.parse"
local M = {}
local function line_height() return style.code_font:get_height() + style.padding.y end
-- Diff / commit viewer: parses git output into rows (commit card, file headers,
-- hunk bands, numbered and tinted lines) instead of printing it raw.
local Text = View:extend()
Text.context = "session"
local MONTHS = {Jan = 1, Feb = 2, Mar = 3, Apr = 4, May = 5, Jun = 6, Jul = 7, Aug = 8, Sep = 9, Oct = 10, Nov = 11, Dec = 12}
local function relative(date)
  local mon, d, H, M, S, y, sign, oh, om = (date or ""):match("%a+ (%a+) (%d+) (%d+):(%d+):(%d+) (%d+) ([%+%-])(%d%d)(%d%d)")
  if not mon or not MONTHS[mon] then return date or "" end
  local t = os.time({year = tonumber(y), month = MONTHS[mon], day = tonumber(d), hour = tonumber(H), min = tonumber(M), sec = tonumber(S)})
  t = t + (os.time() - os.time(os.date("!*t"))) - (tonumber(oh) * 3600 + tonumber(om) * 60) * (sign == "-" and -1 or 1)
  local s = os.time() - t
  if s < 60 then return "just now" end
  if s < 3600 then return (s // 60) .. " min ago" end
  if s < 86400 then return (s // 3600) .. (s < 7200 and " hour ago" or " hours ago") end
  if s < 86400 * 14 then return (s // 86400) .. (s < 172800 and " day ago" or " days ago") end
  return os.date("%b %d, %Y", t)
end
local function tint(c, a) return {c[1], c[2], c[3], a} end
local function split_path(path) local dir, name = path:match("^(.*)/([^/]+)$"); return name or path, dir or "" end
local avatar_colors = {{235, 188, 186}, {196, 167, 231}, {156, 207, 216}, {246, 193, 119}, {62, 143, 176}, {234, 154, 151}}

function Text:new(name, text, actions)
  Text.super.new(self); self.name, self.actions = name, actions or {}; self.scrollable = true
  self:set_text(text)
end
-- Parses git output into rows; also reloads a view in place.
function Text:set_text(text)
  self.rows, self.width, self.hunk, self.files = {}, 0, 0, {}
  self.meta, self.summary, self.current_hunk = nil, nil, nil
  self.hunks = parse.hunks(text)
  local lines = {}
  for raw_line in (text .. "\n"):gmatch("([^\n]*)\n") do
    if #lines >= 20000 then lines[#lines + 1] = "Display limited to 20,000 lines. Use the terminal for the complete output."; break end
    lines[#lines + 1] = #raw_line > 4096 and raw_line:sub(1, 4096) .. " [line clipped]" or raw_line
  end
  while lines[#lines] == "" do table.remove(lines) end
  local rows, i = self.rows, 1
  local function add(row) rows[#rows + 1] = row; return row end
  if lines[1] and lines[1]:match("^commit %x+") then
    local meta = {hash = lines[1]:match("^commit (%x+)"), refs = lines[1]:match("%((.*)%)"), body = {}}
    i = 2
    while lines[i] and lines[i] ~= "" do
      local key, value = lines[i]:match("^(%a+):%s*(.*)$")
      if key == "Author" then meta.author = value:match("^(.-)%s*<") or value
      elseif key == "AuthorDate" or key == "Date" then meta.date = value end
      i = i + 1
    end
    while lines[i] and (lines[i] == "" or lines[i]:sub(1, 4) == "    ") do meta.body[#meta.body + 1] = lines[i]:sub(5); i = i + 1 end
    while meta.body[1] == "" do table.remove(meta.body, 1) end
    while meta.body[#meta.body] == "" do table.remove(meta.body) end
    -- The --stat block is recomputed from the diff below.
    while lines[i] and not lines[i]:match("^diff ") do i = i + 1 end
    self.meta = meta
    add({kind = "gap"})
    add({kind = "subject", text = table.remove(meta.body, 1) or ""})
    add({kind = "author", meta = meta})
    if #meta.body > 0 then add({kind = "gap"}) end
    for _, line in ipairs(meta.body) do add({kind = "body", text = line}) end
    add({kind = "gap"})
    self.summary = add({kind = "summary"})
  end
  local file, header, old, new, diff = nil, false, 0, 0, false
  for j = i, #lines do
    local l = lines[j]
    if l:match("^diff %-%-git ") or l:match("^diff %-%-cc ") then
      file = {path = l:match(" b/(.+)$") or l:match("^diff %-%-cc (.+)$") or l, adds = 0, dels = 0}
      self.files[#self.files + 1] = file; diff, header = true, true
      file.row = add({kind = "file", file = file})
    elseif header and not l:match("^@@") then
      if l:match("^new file") then file.badge = "new"
      elseif l:match("^deleted file") then file.badge = "deleted"
      elseif l:match("^rename from ") then file.badge = "renamed"; file.from = l:sub(13)
      elseif l:match("^Binary files") then add({kind = "note", text = "Binary file not shown"}) end
    elseif l:match("^@@") then
      header, diff = false, true
      old, new = tonumber(l:match("%-(%d+)")) or 0, tonumber(l:match("%+(%d+)")) or 0
      add({kind = "hunk", text = l, hunk = l:match("^@@ ") and self:count_hunks() or nil})
    elseif diff and file then
      local c = l:sub(1, 1)
      local row = {text = l:sub(2), hunk = self.current_hunk, file = file}
      if c == "+" then row.kind, row.new = "add", new; new = new + 1; file.adds = file.adds + 1
      elseif c == "-" then row.kind, row.old = "del", old; old = old + 1; file.dels = file.dels + 1
      elseif c == "\\" then row.kind, row.text = "note", l
      else row.kind, row.old, row.new = "ctx", old, new; old, new = old + 1, new + 1 end
      add(row); self.width = math.max(self.width, #row.text)
    else
      add({kind = "plain", text = l}); self.width = math.max(self.width, #l)
    end
  end
  if self.summary then
    for _, f in ipairs(self.files) do add({kind = "filelist", file = f}) end
    -- move the file list right after the summary
    local list = {}
    for k = #rows, 1, -1 do if rows[k].kind == "filelist" then table.insert(list, 1, table.remove(rows, k)) end end
    local at; for k, row in ipairs(rows) do if row == self.summary then at = k end end
    for k, row in ipairs(list) do table.insert(rows, at + k, row) end
    table.insert(rows, at + #list + 1, {kind = "gap"})
  end
  self:layout()
end
function Text:count_hunks() self.current_hunk = (self.current_hunk or 0) + 1; return self.current_hunk end
function Text:get_name() return self.name end
local function code_h() return style.code_font:get_height() + math.floor(5 * SCALE) end
function Text:layout()
  local y, fh = 0, style.font:get_height()
  local heights = {
    gap = style.padding.y, subject = math.floor(fh * 1.3) + style.padding.y, author = fh + style.padding.y * 2,
    body = fh + math.floor(4 * SCALE), summary = fh + style.padding.y, filelist = fh + math.floor(8 * SCALE),
    file = fh + style.padding.y * 2,
  }
  for _, row in ipairs(self.rows) do
    if row.kind == "file" and y > 0 then y = y + style.padding.y end
    row.y = y; row.h = heights[row.kind] or code_h(); y = y + row.h
  end
  self.total, self.layout_scale = y, SCALE
end
function Text:toolbar_height() return style.font:get_height() + style.padding.y * 2 end
function Text:gutter() return #self.files > 0 and style.code_font:get_width("00000") * 2 + style.code_font:get_width("+ ") + style.padding.x or style.padding.x end
function Text:get_scrollable_size() return self.total + self:toolbar_height() + style.padding.y * 4 end
function Text:get_h_scrollable_size() return self.width * style.code_font:get_width("M") + self:gutter() + style.padding.x * 2 end
function Text:on_mouse_wheel(y, x) self.scroll.to.y = self.scroll.to.y - y * code_h() * 3; self.scroll.to.x = self.scroll.to.x + (x or 0) * 30; return true end
function Text:row_at(py)
  local lo, hi = 1, #self.rows
  while lo < hi do
    local mid = (lo + hi + 1) // 2
    if self.rows[mid].y <= py then lo = mid else hi = mid - 1 end
  end
  return lo
end
function Text:on_mouse_moved(x, y, ...)
  Text.super.on_mouse_moved(self, x, y, ...)
  self.mouse_x, self.mouse_y = x, y
end
function Text:on_mouse_left() Text.super.on_mouse_left(self); self.mouse_x = nil end
function Text:hovered(x, y, w, h)
  local mx, my = self.mouse_x, self.mouse_y
  return mx and mx >= x and mx < x + w and my >= y and my < y + h
end
local function pill(font, text, x, y, h, bg, fg)
  local w = font:get_width(text) + math.floor(10 * SCALE)
  local ph = font:get_height() + math.floor(4 * SCALE)
  renderer.draw_rect(x, y + (h - ph) / 2, w, ph, bg)
  common.draw_text(font, fg, text, "center", x, y, w, h)
  return x + w + math.floor(6 * SCALE)
end
local function stats(x, y, h, adds, dels, align_right)
  local plus, minus = "+" .. adds, "−" .. dels
  local w = style.font:get_width(plus) + style.font:get_width(minus) + math.floor(8 * SCALE)
  if align_right then x = x - w end
  x = common.draw_text(style.font, style.good, plus, nil, x, y, 0, h) + math.floor(8 * SCALE)
  common.draw_text(style.font, style.error, minus, nil, x, y, 0, h)
  return w
end
function Text:draw_row(row, x, y, w)
  local px, h = style.padding.x, row.h
  local kind = row.kind
  if kind == "subject" then
    self.subject_font = self.subject_font or style.font:copy(style.font:get_size() * 1.3)
    common.draw_text(self.subject_font, style.syntax.normal, row.text, nil, x + px, y, 0, h)
  elseif kind == "author" then
    local m, s = row.meta, math.floor(style.font:get_height() * 1.3)
    local name = m.author or "?"
    local seed = 0; for c in name:gmatch(".") do seed = seed + c:byte() end
    renderer.draw_rect(x + px, y + (h - s) / 2, s, s, avatar_colors[seed % #avatar_colors + 1])
    common.draw_text(style.font, style.background, name:sub(1, 1):upper(), "center", x + px, y, s, h)
    local tx = common.draw_text(style.font, style.syntax.normal, name, nil, x + px + s + math.floor(10 * SCALE), y, 0, h)
    tx = common.draw_text(style.font, style.dim, "  committed " .. relative(m.date) .. "  ", nil, tx, y, 0, h)
    tx = pill(style.code_font, m.hash:sub(1, 8), tx, y, h, style.background3, style.text)
    for ref in (m.refs or ""):gmatch("[^,]+") do
      ref = ref:gsub("^%s+", ""):gsub("^HEAD %-> ", "")
      tx = pill(style.font, ref, tx, y, h, tint(style.caret, 50), style.caret)
    end
  elseif kind == "body" then
    common.draw_text(style.font, style.text, row.text, nil, x + px, y, 0, h)
  elseif kind == "summary" then
    local adds, dels = 0, 0; for _, f in ipairs(self.files) do adds, dels = adds + f.adds, dels + f.dels end
    renderer.draw_rect(x + px, y, w - px * 2, math.max(1, SCALE), style.divider)
    local label = #self.files .. (#self.files == 1 and " file changed  " or " files changed  ")
    local tx = common.draw_text(style.font, style.dim, label, nil, x + px, y, 0, h)
    stats(tx, y, h, adds, dels)
  elseif kind == "filelist" then
    local f = row.file
    if self:hovered(x, y, w, h) then renderer.draw_rect(x + px / 2, y, w - px, h, style.line_highlight) end
    local name, dir = split_path(f.path)
    local tx = common.draw_text(style.font, style.syntax.normal, name, nil, x + px, y, 0, h)
    common.draw_text(style.font, style.dim, "  " .. dir, nil, tx, y, 0, h)
    -- 5-block bar like `git --stat`
    local bw, gap = math.floor(7 * SCALE), math.floor(2 * SCALE)
    local bx = x + w - px - 5 * (bw + gap)
    local total = f.adds + f.dels
    local green = total > 0 and math.floor(5 * f.adds / total + 0.5) or 0
    for b = 1, 5 do
      local c = total == 0 and style.divider or b <= green and style.good or style.error
      renderer.draw_rect(bx + (b - 1) * (bw + gap), y + (h - bw) / 2, bw, bw, c)
    end
    stats(bx - math.floor(10 * SCALE), y, h, f.adds, f.dels, true)
  elseif kind == "file" then
    local f = row.file
    renderer.draw_rect(x, y, w, h, style.background2)
    renderer.draw_rect(x, y, w, math.max(1, SCALE), style.divider)
    renderer.draw_rect(x, y + h - math.max(1, SCALE), w, math.max(1, SCALE), style.divider)
    local name, dir = split_path(f.path)
    local tx = common.draw_text(style.font, style.syntax.normal, name, nil, x + px, y, 0, h)
    tx = common.draw_text(style.font, style.dim, "  " .. (f.from and (f.from .. " → ") or "") .. dir .. "  ", nil, tx, y, 0, h)
    if f.badge then
      local c = f.badge == "new" and style.good or f.badge == "deleted" and style.error or style.modified
      pill(style.font, f.badge, tx, y, h, tint(c, 45), c)
    end
    stats(x + w - px, y, h, f.adds, f.dels, true)
  elseif kind == "hunk" then
    renderer.draw_rect(x, y, w, h, tint(style.modified, 22))
    common.draw_text(style.code_font, style.dim, row.text, nil, x + self:gutter() - self.scroll.x, y, 0, h)
  elseif kind == "add" or kind == "del" or kind == "ctx" then
    local g, cw = self:gutter(), style.code_font:get_width("00000")
    local c = kind == "add" and style.good or kind == "del" and style.error
    if c then renderer.draw_rect(x, y, w, h, tint(c, 28)); renderer.draw_rect(x, y, g - px / 2, h, tint(c, 30)) end
    core.push_clip_rect(x + g - px / 2, y, w - g + px / 2, h)
    common.draw_text(style.code_font, style.syntax.normal, row.text, nil, x + g - self.scroll.x, y, 0, h)
    core.pop_clip_rect()
    if row.old then common.draw_text(style.code_font, style.dim, tostring(row.old), "right", x, y, cw, h) end
    if row.new then common.draw_text(style.code_font, style.dim, tostring(row.new), "right", x + cw, y, cw, h) end
    if c then common.draw_text(style.code_font, c, kind == "add" and "+" or "−", nil, x + cw * 2 + style.code_font:get_width(" "), y, 0, h) end
  elseif kind == "note" then
    common.draw_text(style.code_font, style.dim, row.text, nil, x + self:gutter(), y, 0, h)
  elseif kind == "plain" then
    common.draw_text(style.code_font, style.syntax.normal, row.text, nil, x + px - self.scroll.x, y, 0, h)
  end
  if row.hunk and row.hunk == self.hunk then renderer.draw_rect(x, y, math.floor(3 * SCALE), h, style.accent) end
end
function Text:draw()
  if self.layout_scale ~= SCALE then self:layout() end
  self:draw_background(style.background)
  local tb = self:toolbar_height()
  local x, top = self.position.x, self.position.y + tb
  core.push_clip_rect(x, top, self.size.x, self.size.y - tb)
  for i = self:row_at(self.scroll.y), #self.rows do
    local row = self.rows[i]
    local y = top + row.y - self.scroll.y
    if y > self.position.y + self.size.y then break end
    self:draw_row(row, x, y, self.size.x)
  end
  core.pop_clip_rect()
  -- Toolbar: action pills, hunk hint on the right.
  renderer.draw_rect(x, self.position.y, self.size.x, tb, style.background)
  renderer.draw_rect(x, self.position.y + tb - math.max(1, SCALE), self.size.x, math.max(1, SCALE), style.divider)
  self.buttons = {}
  local bx, by, bh = x + style.padding.x, self.position.y, tb
  for _, action in ipairs(self.actions) do
    local w = style.font:get_width(action.text) + style.padding.x * 1.5
    local ph = style.font:get_height() + math.floor(8 * SCALE)
    local hovered = self:hovered(bx, by + (bh - ph) / 2, w, ph)
    renderer.draw_rect(bx, by + (bh - ph) / 2, w, ph, action.primary and style.caret or hovered and style.selection or style.background3)
    common.draw_text(style.font, action.primary and style.background or hovered and style.accent or style.text, action.text, "center", bx, by, w, bh)
    self.buttons[#self.buttons + 1] = {x = bx, w = w, fn = action.fn}
    bx = bx + w + math.floor(6 * SCALE)
  end
  if #self.actions == 0 then common.draw_text(style.font, style.dim, self.name, nil, bx, by, 0, bh) end
  local hunk_actions = false; for _, a in ipairs(self.actions) do if a.text:match("hunk") then hunk_actions = true end end
  if hunk_actions and #self.hunks > 0 then
    local hint = self.hunk > 0 and string.format("Hunk %d of %d", self.hunk, #self.hunks) or "Click a hunk to select it"
    common.draw_text(style.font, style.dim, hint, "right", x, by, self.size.x - style.padding.x, bh)
  end
  self:draw_scrollbar()
end
function Text:on_mouse_pressed(button, x, y, clicks)
  if Text.super.on_mouse_pressed(self, button, x, y, clicks) then return true end
  local tb = self:toolbar_height()
  if y < self.position.y + tb then
    for _, b in ipairs(self.buttons or {}) do if x >= b.x and x < b.x + b.w then b.fn(self); return true end end
    return true
  end
  local row = self.rows[self:row_at(y - self.position.y - tb + self.scroll.y)]
  if row and row.kind == "filelist" then self.scroll.to.y = row.file.row.y
  elseif row and row.hunk then self.hunk = row.hunk end
  core.redraw = true; return true
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
function M.prompt(label, submit, text, choices)
  core.command_view:enter(label, {text = text or "", submit = submit,
    suggest = choices and function(input)
      local result = {}; for _, choice in ipairs(choices) do if choice:lower():find(input:lower(), 1, true) then result[#result + 1] = choice end end
      return result
    end or nil})
end
function M.confirm(label, message, fn)
  core.nag_view:show(label, message, {{text = "Cancel"}, {text = "Continue", default_yes = true}}, function(item) if item.text == "Continue" then fn() end end)
end
function M.open(view)
  local node = core.root_view:get_active_node_default()
  for _, old in ipairs(node.views) do
    if view:is(Graph) and old:is(Graph) and old.repo == view.repo then
      node:set_active_view(old); core.redraw = true; return old
    end
  end
  for i = #node.views, 1, -1 do
    local old = node.views[i]
    if view:is(Text) and old:is(Text) and not old.persistent then node:close_view(core.root_view.root_node, old) end
  end
  node:add_view(view)
  core.root_view.root_node:update_layout()
  core.redraw = true
  return view
end
return M
