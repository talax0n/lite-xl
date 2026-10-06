-- mod-version:4
-- Language servers: errors and warnings (squiggles, gutter, Problems tab,
-- status bar) and, below, navigation. Servers come from plugins.lsp.servers
-- and start per project root when a matching file opens.
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local Doc = require "core.doc"
local DocView = require "core.docview"
local git = require "plugins.scm.git"
local client = require "plugins.lsp.client"
local servers = require "plugins.lsp.servers"
local util = require "plugins.lsp.util"
local views = require "plugins.lsp.views"

local M = {client = client, servers = servers, views = views}
local pending, offered, installing = {}, {}, {}

function M.project_root(path)
  for _, p in ipairs(core.projects) do
    if common.path_belongs_to(path, p.path) then return p.path end
  end
end

function M.rel(path)
  local root = M.project_root(path)
  return root and path:sub(#root + 2) or common.home_encode(path)
end

function M.install(spec)
  installing[spec.name] = true; core.redraw = true
  core.add_thread(function()
    common.mkdirp(servers.dir)
    local out, err = git.exec(servers.dir, "/usr/bin/env", servers.install_argv(spec), nil, 900)
    installing[spec.name] = nil
    if not out then
      core.error("Installing the %s language server failed: %s", spec.label, (err or "unknown error"):sub(-400))
      return
    end
    core.log("Installed the %s language server", spec.label)
    for _, c in pairs(client.clients) do if c.spec == spec then client.restart(c) end end
  end)
end

local function offer_install(spec)
  if offered[spec.name] or installing[spec.name] or not spec.install then return end
  offered[spec.name] = true
  core.nag_view:show("Language server missing",
    spec.label .. " language server not found. Install it with: " .. servers.install_text(spec)
      .. (spec.install.global and " (a global Homebrew install)" or ""),
    {{text = "Install", default_yes = true}, {text = "Not now", default_no = true}},
    function(item) if item.text == "Install" then M.install(spec) end end)
end

local function attach(doc)
  local path = doc.abs_filename
  local spec = path and servers.find(path)
  if not spec then return end
  local c = client.get(spec, util.find_root(path, spec.roots, M.project_root(path)))
  if doc.lsp and doc.lsp ~= c then client.close(doc.lsp, doc) end
  doc.lsp = c
  client.open(c, doc)
  if c.state == "missing" then offer_install(spec) end
end

function M.flush(doc)
  if pending[doc] and doc.lsp then pending[doc] = nil; client.change(doc.lsp, doc) end
end

local doc_load, doc_save, doc_close, doc_change = Doc.load, Doc.save, Doc.on_close, Doc.on_text_change
function Doc:load(...)
  local result = doc_load(self, ...)
  attach(self)
  return result
end
function Doc:save(...)
  local result = doc_save(self, ...)
  pending[self] = nil
  attach(self) -- save-as can change the server or the root
  if self.lsp then client.save(self.lsp, self) end
  return result
end
function Doc:on_close(...)
  if self.lsp then client.close(self.lsp, self); self.lsp = nil end
  pending[self] = nil
  return doc_close(self, ...)
end
function Doc:on_text_change(...)
  if self.lsp then pending[self] = system.get_time() end
  return doc_change(self, ...)
end

core.add_thread(function()
  while true do
    local now = system.get_time()
    for doc, t in pairs(pending) do if now - t >= 0.3 then M.flush(doc) end end
    client.tick(now)
    coroutine.yield(0.1)
  end
end)

-- Diagnostics of `doc` touching `line`, indexed once per store change.
local index = setmetatable({}, {__mode = "k"})
function M.line_diagnostics(doc, line)
  local cached = index[doc]
  if not cached or cached.gen ~= client.generation or cached.path ~= doc.abs_filename then
    cached = {gen = client.generation, path = doc.abs_filename, lines = {}}
    for _, d in ipairs(doc.abs_filename and client.diagnostics[doc.abs_filename] or {}) do
      for l = d.line1, math.min(d.line2, d.line1 + 200) do
        cached.lines[l] = cached.lines[l] or {}
        table.insert(cached.lines[l], d)
      end
    end
    index[doc] = cached
  end
  return cached.lines[line] or {}
end

local function severity_color(s) return s == 1 and style.error or s == 2 and style.warn or style.dim end

local function squiggle(x1, x2, y, color)
  local s = math.max(1, math.floor(SCALE))
  local i = 0
  for x = x1, x2 - s, 2 * s do
    renderer.draw_rect(x, y + (i % 2) * s, 2 * s, s, color)
    i = i + 1
  end
end

local draw_line_text, draw_line_gutter = DocView.draw_line_text, DocView.draw_line_gutter
function DocView:draw_line_text(line, x, y)
  local lh = draw_line_text(self, line, x, y)
  local text = self.doc.lines[line]
  for _, d in ipairs(M.line_diagnostics(self.doc, line)) do
    local x1 = x + self:get_col_x_offset(line, d.line1 == line and d.col1 or 1)
    local x2 = x + self:get_col_x_offset(line, d.line2 == line and d.col2 or #text)
    squiggle(x1, math.max(x2, x1 + 6 * SCALE), y + lh - 3 * math.max(1, math.floor(SCALE)), severity_color(d.severity))
  end
  return lh
end
function DocView:draw_line_gutter(line, x, y, width)
  local lh = draw_line_gutter(self, line, x, y, width)
  local worst
  for _, d in ipairs(M.line_diagnostics(self.doc, line)) do worst = math.min(worst or 4, d.severity) end
  if worst then
    local s = math.floor(6 * SCALE)
    renderer.draw_rect(x + (style.padding.x - s) / 2, y + (self:get_line_height() - s) / 2, s, s, severity_color(worst))
  end
  return lh
end

-- Hover tooltips: diagnostics under the mouse plus the server's hover text.
local hover = {}
function M.hover_state() return hover end
function M.set_hover(h) hover = h; core.redraw = true end

local function diagnostics_at(doc, line, col)
  local out = {}
  for _, d in ipairs(M.line_diagnostics(doc, line)) do
    if (line > d.line1 or col >= d.col1) and (line < d.line2 or col <= math.max(d.col2, d.col1 + 1)) then
      out[#out + 1] = util.describe(d)
    end
  end
  return out
end

function M.position(doc, line, col)
  return {textDocument = {uri = util.path_to_uri(doc.abs_filename)},
    position = {line = line - 1, character = util.utf16_col(doc.lines[line] or "", col)}}
end

function M.hover(doc, line, col, cb)
  local parts = diagnostics_at(doc, line, col)
  if not (doc.lsp and client.supports(doc.lsp, "hoverProvider")) then return cb(table.concat(parts, "\n")) end
  M.flush(doc)
  client.request(doc.lsp, "textDocument/hover", M.position(doc, line, col), function(result)
    local text = result and util.hover_text(result.contents) or ""
    if text ~= "" then parts[#parts + 1] = text end
    cb(table.concat(parts, "\n\n"))
  end)
end

local function wrap(text, width)
  local out = {}
  for para in (text .. "\n"):gmatch("([^\n]*)\n") do
    while #para > width do
      local cut = para:sub(1, width):match(".*()%s")
      if not cut or cut < width / 3 then cut = width + 1 end
      out[#out + 1] = para:sub(1, cut - 1)
      para = para:sub(cut):gsub("^%s+", "")
    end
    out[#out + 1] = para
  end
  return out
end

function M.draw_tooltip(dv, text, x, y)
  local font, pad = dv:get_font(), style.padding.x / 2
  local lines = wrap(text, 90)
  if #lines > 20 then lines = {table.unpack(lines, 1, 20)}; lines[20] = "..." end
  local lh, w = font:get_height(), 0
  for _, l in ipairs(lines) do w = math.max(w, font:get_width(l)) end
  w = w + pad * 2
  local h = #lines * lh + pad * 2
  x = math.max(dv.position.x, math.min(x, dv.position.x + dv.size.x - w))
  if y + h > dv.position.y + dv.size.y then y = y - h - dv:get_line_height() * 2 end
  renderer.draw_rect(x - 1, y - 1, w + 2, h + 2, style.divider)
  renderer.draw_rect(x, y, w, h, style.background3)
  for i, l in ipairs(lines) do renderer.draw_text(font, l, x + pad, y + pad + (i - 1) * lh, style.text) end
end

local dv_moved, dv_released, dv_update, dv_overlay = DocView.on_mouse_moved, DocView.on_mouse_released, DocView.update, DocView.draw_overlay
function DocView:on_mouse_moved(x, y, ...)
  if hover.view ~= self or hover.x ~= x or hover.y ~= y then
    if hover.text then core.redraw = true end
    hover = {view = self, x = x, y = y, t = system.get_time()}
  end
  return dv_moved(self, x, y, ...)
end
function DocView:on_mouse_released(...)
  if hover.text then hover = {}; core.redraw = true end
  return dv_released(self, ...)
end
function DocView:update(...)
  local h = hover
  if h.view == self and not h.asked and self.doc.lsp and system.get_time() - h.t > 0.5 then
    h.asked = true
    if h.x > self.position.x + self:get_gutter_width() and h.y >= self.position.y and h.y < self.position.y + self.size.y then
      local line, col = self:resolve_screen_position(h.x, h.y)
      local text = self.doc.lines[line] or ""
      if col < #text and (text:sub(col, col):match("%S") or #diagnostics_at(self.doc, line, col) > 0) then
        M.hover(self.doc, line, col, function(t)
          if hover == h and t ~= "" then h.text = t; core.redraw = true end
        end)
      end
    end
  end
  return dv_update(self, ...)
end
function DocView:draw_overlay(...)
  dv_overlay(self, ...)
  if hover.view == self and hover.text then
    M.draw_tooltip(self, hover.text, hover.x, hover.y + self:get_line_height())
  end
end

-- Opens a location; `col` is a byte column, `character` an LSP UTF-16 one.
function M.jump(t)
  local ok, doc = pcall(core.open_doc, t.path)
  if not ok then core.error("Cannot open %s", t.path); return end
  local dv = core.root_view:open_doc(doc)
  local line = common.clamp(t.line, 1, #doc.lines)
  local text = doc.lines[line]
  local c1 = t.col or util.byte_col(text, t.character or 0)
  local c2 = t.end_character and util.byte_col(text, t.end_character) or c1
  doc:set_selection(line, c2, line, c1)
  dv:scroll_to_line(line, true, true)
  return dv
end

local function problem_rows()
  local rows = {}
  for _, group in ipairs(util.problems(client.diagnostics)) do
    rows[#rows + 1] = {{style.accent, M.rel(group.path)}, {style.dim, tostring(#group.items)}}
    for _, d in ipairs(group.items) do
      rows[#rows + 1] = {target = {path = group.path, line = d.line1, col = d.col1}, indent = style.padding.x,
        mark = severity_color(d.severity), {style.dim, d.line1 .. ":" .. d.col1}, {style.text, util.describe(d)}}
    end
  end
  if #rows == 0 then rows[1] = {{style.dim, "No problems"}} end
  return rows
end

function M.problems()
  return views.show(views.List("Problems", problem_rows, function() return client.generation end, M.jump))
end

local function active_doc()
  local v = core.active_view
  return v and v:is(DocView) and v.doc.lsp and v.doc or nil
end

local counts_item = core.status_view:add_item({
  name = "lsp:diagnostics", alignment = core.status_view.Item.LEFT, command = "lsp:problems",
  predicate = function() return active_doc() ~= nil end, get_item = function() return {} end,
})
counts_item.on_draw = function(x, y, h, hovered, calc_only)
  local errors, warnings = 0, 0
  for _, d in ipairs(client.diagnostics[active_doc().abs_filename] or {}) do
    if d.severity == 1 then errors = errors + 1 elseif d.severity == 2 then warnings = warnings + 1 end
  end
  local s, gap = math.floor(8 * SCALE), style.padding.x / 2
  local parts = {{style.error, tostring(errors)}, {style.warn, tostring(warnings)}}
  local width = 0
  for _, p in ipairs(parts) do width = width + s + gap + style.font:get_width(p[2]) + style.padding.x end
  if calc_only then return width end
  for _, p in ipairs(parts) do
    renderer.draw_rect(x, y + (h - s) / 2, s, s, p[1])
    x = common.draw_text(style.font, hovered and style.accent or style.text, p[2], nil, x + s + gap, y, 0, h) + style.padding.x
  end
  return width
end

core.status_view:add_item({
  name = "lsp:server", alignment = core.status_view.Item.RIGHT, command = "lsp:server-action",
  predicate = function() return active_doc() ~= nil end,
  get_item = function()
    local c = active_doc().lsp
    local s = c.spec.short
    if installing[c.spec.name] then return {style.dim, s .. " installing..."} end
    if c.state == "ready" then return {style.text, s} end
    if c.state == "starting" then return {style.dim, s .. "..."} end
    if c.state == "missing" then return {style.dim, s .. " not installed"} end
    return {style.error, s .. " crashed"}
  end,
})

local function show_log(c)
  local doc = core.open_doc()
  doc:insert(1, 1, (#c.log > 0 and table.concat(c.log, "\n") or "(empty)") .. "\n")
  doc:clean()
  core.root_view:open_doc(doc)
end

command.add(nil, {
  ["lsp:problems"] = function() M.problems() end,
})
command.add(function() local d = active_doc(); return d ~= nil, d end, {
  ["lsp:restart"] = function(doc) client.restart(doc.lsp) end,
  ["lsp:show-log"] = function(doc) show_log(doc.lsp) end,
  ["lsp:server-action"] = function(doc)
    local c = doc.lsp
    if c.state == "crashed" then client.restart(c)
    elseif c.state == "missing" then offered[c.spec.name] = nil; offer_install(c.spec)
    else show_log(c) end
  end,
})
keymap.add({[PLATFORM == "Mac OS X" and "cmd+shift+m" or "ctrl+shift+m"] = "lsp:problems"})

return M
