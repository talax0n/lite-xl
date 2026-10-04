-- mod-version:4
local core = require "core"
local config = require "core.config"
local common = require "core.common"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local View = require "core.view"
local native = require "terminal"

config.plugins.terminal = common.merge({
  height = 280, scrollback = 1000, max_sessions = 8,
  shell = os.getenv(PLATFORM == "Windows" and "COMSPEC" or "SHELL") or (PLATFORM == "Windows" and "cmd.exe" or "/bin/sh"),
  args = PLATFORM == "Windows" and {} or {"-l"},
}, config.plugins.terminal)
local options = config.plugins.terminal
local Panel = View:extend()
local panel
local colors = {}
local font, bold_font, italic_font
local function terminal_fonts()
  if font ~= style.code_font then
    font = style.code_font
    bold_font = font:copy(font:get_size(), {bold = true})
    italic_font = font:copy(font:get_size(), {italic = true})
    colors = {}
  end
  return font:get_width("M"), font:get_height()
end
local function color(value, fallback)
  if value == -1 then return fallback end
  if not colors[value] then
    if next(colors) and (panel.color_count or 0) > 256 then colors = {}; panel.color_count = 0 end
    colors[value] = {(value >> 16) & 255, (value >> 8) & 255, value & 255, 255}
    panel.color_count = (panel.color_count or 0) + 1
  end
  return colors[value]
end
function Panel:new()
  Panel.super.new(self)
  self.sessions, self.selected, self.visible = {}, 1, true
  self.split = false
  self.size.y = options.height * SCALE
end
function Panel:get_name() return "Terminal" end
function Panel:supports_text_input() return self.visible end
function Panel:get_size() return 0, self.visible and options.height or 0 end
function Panel:set_target_size(axis, height)
  if axis == "y" then options.height = math.max(100, height / SCALE); core.redraw = true; return true end
end
function Panel:session() return self.sessions[self.selected] end
function Panel:regions()
  local h = style.font:get_height() + style.padding.y * 2
  local x, y, w = self.position.x + style.padding.x, self.position.y + h, self.size.x - style.padding.x * 2
  local regions = {{session = self:session(), x = x, y = y, w = w, h = self.size.y - h}}
  if self.split and #self.sessions > 1 then
    regions[1].w = w / 2 - style.padding.x
    local other = self.sessions[self.selected % #self.sessions + 1]
    regions[2] = {session = other, x = x + w / 2, y = y, w = w / 2, h = self.size.y - h}
  end
  return regions
end
function Panel:add(cwd, shell, args)
  if #self.sessions >= options.max_sessions then core.error("Terminal session limit reached (%d)", options.max_sessions); return end
  local ok, term = pcall(native.start, {
    shell = shell or options.shell, args = args or options.args,
    cwd = cwd or core.root_project().path, scrollback = options.scrollback,
  })
  if not ok then core.error("%s", term); return end
  local session = {term = term, cwd = cwd or core.root_project().path, offset = 0, screen = term:screen(), changed = true}
  session.background = true
  core.background_tasks = (core.background_tasks or 0) + 1
  self.sessions[#self.sessions + 1] = session; self.selected = #self.sessions
  self.visible = true; core.set_active_view(self); core.redraw = true
end
function Panel:close_session()
  local s = self:session()
  if not s then return end
  if s.background then core.background_tasks = core.background_tasks - 1; s.background = false end
  s.term:close(); table.remove(self.sessions, self.selected)
  self.selected = math.max(1, math.min(self.selected, #self.sessions))
  if #self.sessions == 0 then self.visible = false; core.set_active_view(core.root_view:get_primary_node().active_view) end
  core.redraw = true
end
function Panel:update()
  local height = self.visible and options.height * SCALE or 0
  if self.size.y ~= height then self.size.y = height; core.redraw = true end
  Panel.super.update(self)
  if not self.visible or not system.window_has_focus(core.window) then return end
  local cw, ch = terminal_fonts()
  for _, r in ipairs(self:regions()) do
    local s = r.session
    if s then
      local cols, rows = math.max(1, math.min(500, math.floor(r.w / cw))), math.max(1, math.min(200, math.floor(r.h / ch)))
      if cols ~= s.cols or rows ~= s.rows then
        s.cols, s.rows = cols, rows; s.term:resize(cols, rows); s.changed = true
      end
      if s.changed then s.screen = s.term:screen(s.offset); s.changed = false; core.redraw = true end
    end
  end
end
function Panel:draw()
  if not self.visible then return end
  self:draw_background(style.background)
  local cw, ch = terminal_fonts()
  local x, y = self.position.x + style.padding.x, self.position.y + style.padding.y
  self.buttons = {}
  local function button(text, action, active)
    local width = style.font:get_width(text) + style.padding.x
    renderer.draw_text(style.font, text, x, y, active and style.accent or style.text)
    self.buttons[#self.buttons + 1] = {x = x, w = width, fn = action}
    x = x + width
  end
  for i, s in ipairs(self.sessions) do
    local title = (s.screen.title ~= "" and s.screen.title or common.basename(s.cwd)):sub(1, 24)
    button(i .. ": " .. title .. (s.exit and " [exited]" or ""), function() self.selected = i; s.changed = true end, i == self.selected)
  end
  button("+", function() self:add() end)
  button("Split", function()
    if not self.split and #self.sessions < 2 then self:add(self:session() and self:session().cwd) end
    self.split = not self.split
  end)
  button("Close", function() self:close_session() end)
  button("Hide", function() self.visible = false; core.set_active_view(core.root_view:get_primary_node().active_view) end)
  for _, r in ipairs(self:regions()) do
    local s = r.session
    if s then
      core.push_clip_rect(r.x, r.y, r.w, r.h)
      for row, runs in ipairs(s.screen) do
        for _, run in ipairs(runs) do
          local rx, ry = r.x + run[2] * cw, r.y + (row - 1) * ch
          local fg, bg = color(run[4], style.text), color(run[5], style.background)
          if run[6] & 4 ~= 0 then fg, bg = bg, fg end
          renderer.draw_rect(rx, ry, run[3] * cw, ch, bg)
          renderer.draw_text(run[6] & 1 ~= 0 and bold_font or run[6] & 8 ~= 0 and italic_font or font, run[1], rx, ry, fg)
          if run[6] & 2 ~= 0 then renderer.draw_rect(rx, ry + ch - 2, run[3] * cw, 1, fg) end
          if run[6] & 16 ~= 0 then renderer.draw_rect(rx, ry + ch / 2, run[3] * cw, 1, fg) end
        end
      end
      if s.screen.cursor_visible and not s.exit and core.active_view == self and s == self:session() then
        renderer.draw_rect(r.x + (s.screen.cursor_col - 1) * cw, r.y + (s.screen.cursor_row - 1) * ch, 2 * SCALE, ch, style.caret)
      end
      if s.selection then
        local a, b = s.selection[1], s.selection[2]
        if a.row > b.row or a.row == b.row and a.col > b.col then a, b = b, a end
        for row = a.row, b.row do
          local left, right = row == a.row and a.col or 0, row == b.row and b.col or s.cols
          renderer.draw_rect(r.x + left * cw, r.y + row * ch, (right - left) * cw, ch, {100, 140, 220, 65})
        end
      end
      core.pop_clip_rect()
    end
  end
end
function Panel:on_text_input(text)
  local s = self:session()
  if s and not s.exit then
    s.offset, s.selection = 0, nil
    for _, ch in utf8.codes(text) do s.term:char(ch, 0) end
    s.changed = true
  end
end
function Panel:point(x, y)
  local cw, ch = terminal_fonts()
  for _, r in ipairs(self:regions()) do
    if r.session and x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h then
      return r.session, {row = math.max(0, math.min(r.session.rows - 1, math.floor((y - r.y) / ch))), col = math.max(0, math.min(r.session.cols, math.floor((x - r.x) / cw)))}
    end
  end
end
function Panel:on_mouse_pressed(button, x, y)
  if y < self.position.y + style.font:get_height() + style.padding.y * 2 then
    for _, b in ipairs(self.buttons or {}) do if x >= b.x and x < b.x + b.w then b.fn(); core.redraw = true; return true end end
  end
  local s, p = self:point(x, y)
  if s then
    for i, v in ipairs(self.sessions) do if v == s then self.selected = i end end
    if button == "left" then
      s.selection = {p, p}; self.drag = s
    elseif button == "right" then command.perform("terminal:paste") end
    core.redraw = true
  end
  return true
end
function Panel:on_mouse_moved(x, y)
  if self.drag then local s, p = self:point(x, y); if s == self.drag then s.selection[2] = p; core.redraw = true end end
end
function Panel:on_mouse_released(button)
  self.drag = nil
end
function Panel:on_mouse_wheel(delta)
  local s = self:session()
  if s then s.offset = math.max(0, math.min(s.screen.history, s.offset + math.floor(delta * 3))); s.changed = true end
  return true
end
local function ensure_panel()
  if not panel then
    panel = Panel()
    panel.node = core.root_view:get_primary_node():split("down", panel, {y = true}, true)
    core.add_thread(function()
      while panel do
        local changed = false
        for _, s in ipairs(panel.sessions) do
          local dirty, code, pending = s.term:poll()
          if not pending and s.background then core.background_tasks = core.background_tasks - 1; s.background = false end
          if dirty then s.changed = true; changed = true end
          if code then s.exit = code end
        end
        local focused = system.window_has_focus(core.window)
        if changed and panel.visible and focused then core.redraw = true end
        coroutine.yield(changed and panel.visible and focused and 1 / 30 or panel.visible and focused and 0.1 or 0.25)
      end
    end)
  end
  return panel
end
local M = {}
function M.open(cwd, shell, args) ensure_panel():add(cwd, shell, args) end
command.add(nil, {
  ["terminal:toggle"] = function()
    local p = ensure_panel()
    if #p.sessions == 0 then p:add()
    else p.visible = not p.visible; core.set_active_view(p.visible and p or core.root_view:get_primary_node().active_view) end
    core.redraw = true
  end,
  ["terminal:new"] = function() M.open() end,
  ["terminal:open-here"] = function()
    local path = core.active_view.doc and core.active_view.doc.abs_filename
    M.open(path and common.dirname(path) or core.root_project().path)
  end,
  ["terminal:new-profile"] = function()
    core.command_view:enter("Shell executable", {text = options.shell, submit = function(shell) M.open(nil, shell, {}) end})
  end,
})
command.add(Panel, {
  ["terminal:close"] = function(p) p:close_session() end,
  ["terminal:split"] = function(p) if #p.sessions < 2 then p:add() end; p.split = not p.split; core.redraw = true end,
  ["terminal:next"] = function(p) if #p.sessions > 0 then p.selected = p.selected % #p.sessions + 1; core.redraw = true end end,
  ["terminal:clear"] = function(p) local s = p:session(); if s then s.term:clear(); s.offset = 0; s.changed = true end end,
  ["terminal:paste"] = function(p)
    local s = p:session(); if s and not s.exit then
      local ok, err = pcall(s.term.paste, s.term, system.get_clipboard())
      if not ok then core.error("%s", err) end
      s.offset, s.selection = 0, nil; s.changed = true
    end
  end,
  ["terminal:copy"] = function(p)
    local s = p:session(); if not s then return end
    local selection = s.selection
    local a, b = selection and selection[1] or {row = 0, col = 0}, selection and selection[2] or {row = #s.screen - 1, col = s.cols}
    if a.row > b.row or a.row == b.row and a.col > b.col then a, b = b, a end
    system.set_clipboard(s.term:copy(s.offset, a.row, a.col, b.row, b.col))
  end,
})
keymap.add({["ctrl+`"] = "terminal:toggle", ["ctrl+shift+`"] = "terminal:new", ["ctrl+shift+c"] = "terminal:copy", ["ctrl+shift+v"] = "terminal:paste"})
if PLATFORM == "Mac OS X" then keymap.add({["cmd+c"] = "terminal:copy", ["cmd+v"] = "terminal:paste"}) end
local keys = {return_ = 1, ["return"] = 1, ["keypad enter"] = 1, tab = 2, backspace = 3, escape = 4, up = 5, down = 6, left = 7, right = 8,
  insert = 9, delete = 10, home = 11, ["end"] = 12, pageup = 13, pagedown = 14}
local old_key = keymap.on_key_pressed
function keymap.on_key_pressed(k, ...)
  if panel and panel.visible and core.active_view == panel then
    local s, mods = panel:session(), keymap.modkeys
    if s and not s.exit and not mods.cmd and k ~= "`" and not (mods.ctrl and mods.shift) then
      local bits = (mods.shift and 1 or 0) | ((mods.alt or mods.option) and 2 or 0) | (mods.ctrl and 4 or 0)
      local key = keys[k] or (k:match("^f(%d+)$") and 256 + tonumber(k:sub(2)))
      if key then s.term:key(key, bits); s.offset = 0; s.changed = true; return true end
      if (mods.ctrl or mods.alt or mods.option) and #k == 1 then
        s.term:char(k:byte(), bits); s.offset = 0; s.changed = true; return true
      end
      if mods.ctrl and k == "space" then s.term:char(32, bits); return true end
    end
  end
  return old_key(k, ...)
end
return M
