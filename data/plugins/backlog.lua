-- mod-version:4
-- Backlog: a checklist sidebar backed by a plain markdown file.
local core = require "core"
local config = require "core.config"
local common = require "core.common"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local View = require "core.view"

config.plugins.backlog = common.merge({width = 320, path = USERDIR .. PATHSEP .. "backlog.md"}, config.plugins.backlog)
local options = config.plugins.backlog

-- Model: one entry per markdown line, so the file round-trips unchanged.
local lines, generation, mtime = {}, 0, nil
local collapsed = {DONE = true, CONFIG = true}
-- Sections holding env vars / credentials: plain lines, values masked in the UI.
local SECRET_SECTIONS = {CONFIG = true, ENV = true, SECRETS = true}
local function is_secret(heading) return heading and SECRET_SECTIONS[heading.text:upper()] end
local function split_kv(text) return text:match("^%s*([%w_%.%-]+)%s*[=:]%s*(.-)%s*$") end
local revealed = {}

local function parse(text)
  local result = {}
  for raw in (text .. "\n"):gmatch("([^\n]*)\n") do
    local line = raw:gsub("\r$", "")
    local hashes, heading = line:match("^(#+)%s+(.-)%s*$")
    local mark, item = line:match("^%s*[-*]%s+%[([ xX])%]%s?(.*)$")
    if hashes then result[#result + 1] = {kind = "heading", level = #hashes, text = heading}
    elseif mark then result[#result + 1] = {kind = "item", done = mark ~= " ", text = item}
    elseif line:match("^%s*$") then result[#result + 1] = {kind = "blank"}
    else result[#result + 1] = {kind = "text", text = line} end
  end
  while #result > 0 and result[#result].kind == "blank" do result[#result] = nil end
  return result
end

local function serialize()
  local out = {}
  for _, line in ipairs(lines) do
    if line.kind == "heading" then out[#out + 1] = string.rep("#", line.level) .. " " .. line.text
    elseif line.kind == "item" then out[#out + 1] = (line.done and "- [x] " or "- [ ] ") .. line.text
    elseif line.kind == "blank" then out[#out + 1] = ""
    else out[#out + 1] = line.text end
  end
  return table.concat(out, "\n") .. "\n"
end

local function load()
  local info = system.get_file_info(options.path)
  local fp = info and io.open(options.path, "rb")
  local text = fp and fp:read("*a") or "## TODO\n\n## DONE\n"
  if fp then fp:close() end
  lines, mtime = parse(text), info and info.modified
  generation = generation + 1; core.redraw = true
end

local function save()
  -- Write a sibling file first so a failed write never truncates the backlog.
  local tmp = options.path .. ".tmp"
  local fp, err = io.open(tmp, "wb")
  if not fp then core.error("Backlog: %s", err); return end
  fp:write(serialize()); fp:close()
  -- The file can hold credentials: keep it readable by the owner only.
  if PLATFORM ~= "Windows" then os.execute("chmod 600 '" .. tmp:gsub("'", "'\\''") .. "'") end
  local ok, rename_err = os.rename(tmp, options.path)
  if not ok then core.error("Backlog: %s", rename_err); return end
  local info = system.get_file_info(options.path)
  mtime = info and info.modified
  generation = generation + 1; core.redraw = true
end

local function index_of(entry) for i, line in ipairs(lines) do if line == entry then return i end end end
local function section_end(heading)
  -- Insert after the section's last non-blank line.
  local start = heading and index_of(heading) or 0
  local last = start
  for i = start + 1, #lines do
    if lines[i].kind == "heading" then break end
    if lines[i].kind ~= "blank" then last = i end
  end
  return last
end
local function find_heading(name)
  for _, line in ipairs(lines) do if line.kind == "heading" and line.text:upper() == name:upper() then return line end end
end
local function first_heading() for _, line in ipairs(lines) do if line.kind == "heading" then return line end end end

local function prompt(label, text, submit, choices)
  core.command_view:enter(label, {text = text or "", submit = submit,
    suggest = choices and function(input)
      local result = {}
      for _, choice in ipairs(choices) do if choice:lower():find(input:lower(), 1, true) then result[#result + 1] = choice end end
      return result
    end or nil})
end

local function add_item(heading)
  local secret = is_secret(heading)
  prompt(secret and "New entry (KEY=value)" or "New backlog item", "", function(text)
    if not text:match("%S") then return end
    table.insert(lines, section_end(heading) + 1, secret and {kind = "text", text = text} or {kind = "item", done = false, text = text})
    if heading then collapsed[heading.text:upper()] = nil end
    save()
  end)
end

local function archive_done()
  local done_heading = find_heading("DONE")
  if not done_heading then
    lines[#lines + 1] = {kind = "blank"}
    done_heading = {kind = "heading", level = 2, text = "DONE"}
    lines[#lines + 1] = done_heading
  end
  local moved, owner = {}, nil
  local i = 1
  while i <= #lines do
    local line = lines[i]
    if line.kind == "heading" then owner = line end
    if line.kind == "item" and line.done and owner ~= done_heading then table.insert(moved, line); table.remove(lines, i)
    else i = i + 1 end
  end
  local at = section_end(done_heading)
  for n, line in ipairs(moved) do table.insert(lines, at + n, line) end
  save()
  core.log("Archived %d completed item%s", #moved, #moved == 1 and "" or "s")
end

local function item_actions(entry)
  local headings = {}
  for _, line in ipairs(lines) do if line.kind == "heading" then headings[#headings + 1] = line.text end end
  prompt(entry.text, "", function(action)
    local i = index_of(entry)
    if not i then return end
    if action == "Edit" then
      prompt("Edit item", entry.text, function(text) if text:match("%S") then entry.text = text; save() end end)
    elseif action == "Mark done" or action == "Mark open" then entry.done = not entry.done; save()
    elseif action == "Move up" and i > 1 then lines[i], lines[i - 1] = lines[i - 1], lines[i]; save()
    elseif action == "Move down" and i < #lines then lines[i], lines[i + 1] = lines[i + 1], lines[i]; save()
    elseif action == "Move to section" then
      prompt("Move to section", "", function(name)
        local heading = find_heading(name)
        if not heading then core.error("No section named %s", name); return end
        table.remove(lines, index_of(entry))
        table.insert(lines, section_end(heading) + 1, entry); save()
      end, headings)
    elseif action == "Delete" then table.remove(lines, i); save() end
  end, {"Edit", entry.done and "Mark open" or "Mark done", "Move up", "Move down", "Move to section", "Delete"})
end

local function text_actions(entry)
  local key, value = split_kv(entry.text)
  local choices = key and {revealed[entry] and "Hide value" or "Reveal value", "Copy value", "Edit", "Delete"} or {"Edit", "Delete"}
  prompt(key or entry.text, "", function(action)
    if action == "Reveal value" or action == "Hide value" then revealed[entry] = not revealed[entry] or nil; core.redraw = true
    elseif action == "Copy value" then system.set_clipboard(value); core.log("Copied %s", key)
    elseif action == "Edit" then prompt("Edit line", entry.text, function(text) entry.text = text; save() end)
    elseif action == "Delete" then local i = index_of(entry); if i then table.remove(lines, i); save() end end
  end, choices)
end

local function open_count()
  local n = 0
  for _, line in ipairs(lines) do if line.kind == "item" and not line.done then n = n + 1 end end
  return n
end

-- View
local Backlog = View:extend()
local panel
function Backlog:new()
  Backlog.super.new(self); self.visible = true; self.scrollable = true; self.rows = {}; self.height = 0; self.generation = -1
end
function Backlog:get_name() return "Backlog" end
function Backlog:get_size() return self.visible and options.width * SCALE or 0, 0 end
function Backlog:set_target_size(axis, width)
  if axis == "x" then options.width = math.max(200, width / SCALE); core.redraw = true; return true end
end
local function lh() return style.font:get_height() + style.padding.y end
local function header_h() return math.floor(lh() * 1.5) end
local function box() return math.floor(14 * SCALE) end
function Backlog:get_scrollable_size() return header_h() + self.height + lh() * 2 end
function Backlog:on_mouse_wheel(y) self.scroll.to.y = self.scroll.to.y - y * lh() * 3; return true end

local function wrap(text, width)
  local result, current = {}, ""
  for word in text:gmatch("%S+") do
    local candidate = current == "" and word or current .. " " .. word
    if current ~= "" and style.font:get_width(candidate) > width then result[#result + 1] = current; current = word
    else current = candidate end
  end
  result[#result + 1] = current
  return result
end

function Backlog:rebuild()
  local rows, hidden, heading, text_width = {}, false, nil, self.size.x - style.padding.x * 4 - box()
  self.generation, self.width = generation, self.size.x
  for _, line in ipairs(lines) do
    if line.kind == "heading" then
      hidden, heading = collapsed[line.text:upper()], line
      local count = 0
      for i = index_of(line) + 1, #lines do
        if lines[i].kind == "heading" then break end
        if lines[i].kind == "item" and not lines[i].done then count = count + 1 end
      end
      rows[#rows + 1] = {kind = "heading", line = line, count = count, h = math.floor(lh() * 1.2)}
    elseif not hidden then
      if line.kind == "item" then
        local wrapped = wrap(line.text, math.max(50, text_width))
        rows[#rows + 1] = {kind = "item", line = line, wrapped = wrapped, h = #wrapped * style.font:get_height() + style.padding.y}
      elseif line.kind == "blank" then rows[#rows + 1] = {kind = "blank", h = math.floor(lh() * 0.6)}
      else rows[#rows + 1] = {kind = "text", line = line, secret = is_secret(heading), h = lh()} end
    end
  end
  local y = 0
  for _, row in ipairs(rows) do row.y = y; y = y + row.h end
  self.rows, self.height = rows, y
end

function Backlog:update()
  local width = self.visible and options.width * SCALE or 0
  if self.size.x ~= width then self.size.x = width; core.redraw = true end
  Backlog.super.update(self)
  if self.generation ~= generation or self.width ~= self.size.x then self:rebuild() end
end

function Backlog:button(row, font, text, right, y, h, fn)
  local w = font:get_width(text) + style.padding.x
  local x = right - w
  local hovered = self.hover_row == row and self.hover_x and self.hover_x >= x and self.hover_x < right
  if hovered then renderer.draw_rect(x, y + 2 * SCALE, w, h - 4 * SCALE, style.line_highlight) end
  common.draw_text(font, hovered and style.accent or style.text, text, "center", x, y, w, h)
  row.buttons[#row.buttons + 1] = {x1 = x, x2 = right, fn = fn}
  return x
end

function Backlog:draw_row(row, x, y, w)
  local pad, h = style.padding.x, row.h
  local right = x + w - pad
  local hovered = self.hover_row == row
  row.buttons = {}
  if row.kind == "heading" then
    local key = row.line.text:upper()
    common.draw_text(style.icon_font, style.text, collapsed[key] and "+" or "-", nil, x + pad * 0.5, y, 0, h)
    local tx = common.draw_text(style.font, style.accent, row.line.text, nil, x + pad * 0.5 + 18 * SCALE, y, 0, h)
    if row.count > 0 then common.draw_text(style.font, style.dim, tostring(row.count), nil, tx + pad * 0.6, y, 0, h) end
    if hovered then self:button(row, style.font, "+", right, y, h, function() add_item(row.line) end) end
  elseif row.kind == "item" then
    local line = row.line
    if hovered then renderer.draw_rect(x, y, w, h, style.line_highlight) end
    local fh = style.font:get_height()
    local s, t = box(), math.max(1, math.floor(1.5 * SCALE))
    local bx, by = x + pad * 1.5, y + style.padding.y / 2 + (fh - s) / 2
    if line.done then
      renderer.draw_rect(bx, by, s, s, style.text)
      -- check mark from two bars
      for i = 0, math.floor(s * 0.25) do renderer.draw_rect(bx + s * 0.2 + i, by + s * 0.5 + i, t, t, style.background2) end
      for i = 0, math.floor(s * 0.45) do renderer.draw_rect(bx + s * 0.45 + i, by + s * 0.75 - i, t, t, style.background2) end
    else
      local color = self.hover_row == row and self.hover_x and self.hover_x < bx + s + pad / 2 and style.caret or style.text
      renderer.draw_rect(bx, by, s, t, color); renderer.draw_rect(bx, by + s - t, s, t, color)
      renderer.draw_rect(bx, by, t, s, color); renderer.draw_rect(bx + s - t, by, t, s, color)
    end
    row.buttons[1] = {x1 = x, x2 = bx + s + pad / 2, fn = function() line.done = not line.done; save() end}
    local tx = bx + s + pad * 0.75
    for i, text in ipairs(row.wrapped) do
      local ly = y + style.padding.y / 2 + (i - 1) * fh
      local endx = renderer.draw_text(style.font, text, tx, ly, line.done and style.dim or style.accent)
      if line.done then renderer.draw_rect(tx, ly + fh / 2, endx - tx, math.max(1, SCALE), style.dim) end
    end
  elseif row.kind == "text" then
    if hovered then renderer.draw_rect(x, y, w, h, style.line_highlight) end
    local key, value = split_kv(row.line.text)
    core.push_clip_rect(x, y, w - pad, h)
    if row.secret and key then
      local kx = common.draw_text(style.code_font, style.caret, key, nil, x + pad * 1.5, y, 0, h)
      local shown = revealed[row.line] and value or string.rep("•", math.min(12, math.max(6, #value)))
      common.draw_text(style.code_font, revealed[row.line] and style.accent or style.dim, "=" .. shown, nil, kx, y, 0, h)
    else
      common.draw_text(row.secret and style.code_font or style.font, row.secret and style.accent or style.dim, row.line.text, nil, x + pad * 1.5, y, 0, h)
    end
    core.pop_clip_rect()
  end
end

function Backlog:draw()
  if not self.visible then return end
  self:draw_background(style.background2)
  local x, w, top = self.position.x, self.size.x, self.position.y + header_h()
  common.draw_text(style.font, style.text, "BACKLOG", nil, x + style.padding.x, self.position.y, 0, header_h())
  self.header = {buttons = {}}
  local right = self:button(self.header, style.font, "…", x + w - style.padding.x, self.position.y, header_h(), function()
    prompt("Backlog action", "", function(action)
      if action == "Archive completed" then archive_done()
      elseif action == "New section" then
        prompt("Section name", "", function(name)
          if name:match("%S") then lines[#lines + 1] = {kind = "blank"}; lines[#lines + 1] = {kind = "heading", level = 2, text = name}; save() end
        end)
      elseif action == "Open as markdown" then core.root_view:open_doc(core.open_doc(options.path))
      elseif action == "Reload" then load() end
    end, {"Archive completed", "New section", "Open as markdown", "Reload"})
  end)
  self:button(self.header, style.font, "+", right, self.position.y, header_h(), function() add_item(first_heading()) end)
  core.push_clip_rect(x, top, w, self.size.y - header_h())
  local origin = top - self.scroll.y
  for _, row in ipairs(self.rows) do
    local ry = origin + row.y
    if ry > self.position.y + self.size.y then break end
    if ry + row.h >= top then self:draw_row(row, x, ry, w) end
  end
  if #self.rows == 0 then common.draw_text(style.font, style.dim, "Click + to add a backlog item", nil, x + style.padding.x, top, 0, lh()) end
  core.pop_clip_rect(); self:draw_scrollbar()
end

function Backlog:row_at(y)
  if y < self.position.y + header_h() then return self.header end
  local offset = y - self.position.y - header_h() + self.scroll.y
  for _, row in ipairs(self.rows) do if offset >= row.y and offset < row.y + row.h then return row end end
end
function Backlog:on_mouse_moved(x, y, ...)
  Backlog.super.on_mouse_moved(self, x, y, ...)
  local row = self:row_at(y)
  if row ~= self.hover_row or x ~= self.hover_x then self.hover_row, self.hover_x = row, x; core.redraw = true end
end
function Backlog:on_mouse_left()
  Backlog.super.on_mouse_left(self); self.hover_row, self.hover_x = nil, nil; core.redraw = true
end
function Backlog:on_mouse_pressed(button, x, y, clicks)
  if Backlog.super.on_mouse_pressed(self, button, x, y, clicks) then return true end
  local row = self:row_at(y)
  if not row then return true end
  for _, b in ipairs(row.buttons or {}) do if x >= b.x1 and x < b.x2 then b.fn(); return true end end
  if row.kind == "heading" then
    local key = row.line.text:upper(); collapsed[key] = not collapsed[key] or nil; generation = generation + 1
  elseif row.kind == "text" then
    local key, value = split_kv(row.line.text)
    if button == "right" then text_actions(row.line)
    elseif row.secret and key then system.set_clipboard(value); core.log("Copied %s", key)
    elseif clicks > 1 then prompt("Edit line", row.line.text, function(text) row.line.text = text; save() end) end
  elseif row.kind == "item" then
    if button == "right" then item_actions(row.line)
    elseif clicks > 1 then prompt("Edit item", row.line.text, function(text) if text:match("%S") then row.line.text = text; save() end end) end
  end
  core.redraw = true
  return true
end

load()
core.add_thread(function()
  while true do
    local info = system.get_file_info(options.path)
    if info and info.modified ~= mtime then load() end
    coroutine.yield(1)
  end
end)

command.add(nil, {
  ["backlog:toggle"] = function()
    if not panel then
      panel = Backlog(); panel.size.x = options.width * SCALE
      core.root_view:get_primary_node():split("right", panel, {x = true}, true)
    else
      panel.visible = not panel.visible
      if not panel.visible and core.active_view == panel then core.set_active_view(core.root_view:get_primary_node().active_view) end
    end
    core.redraw = true
  end,
  ["backlog:add-item"] = function() add_item(first_heading()) end,
  ["backlog:archive-completed"] = archive_done,
  ["backlog:open-markdown"] = function() core.root_view:open_doc(core.open_doc(options.path)) end,
})
keymap.add({["ctrl+shift+b"] = "backlog:toggle"})

return {panel = function() return panel end, open_count = open_count}
