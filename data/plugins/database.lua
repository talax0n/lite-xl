-- mod-version:4
-- Database: browse Postgres and SQLite connections, preview tables and run SQL through psql / sqlite3.
local core = require "core"
local config = require "core.config"
local common = require "core.common"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local View = require "core.view"
local DocView = require "core.docview"
local git = require "plugins.scm.git"
local views = require "plugins.scm.views"
local data = require "plugins.database.data"

config.plugins.database = common.merge({width = 320, results_height = 360}, config.plugins.database)
local options = config.plugins.database
local CONF = USERDIR .. PATHSEP .. "databases.conf"

-- Tree nodes: {kind = "conn"|"schema"|"table"|"column", conn, label, detail, schema, table, expanded,
-- state = "idle"|"loading"|"ok"|"error", error, children}.
local M = {nodes = {}, saved = {}}

local function root() local p = core.root_project(); return p and p.path end
local function read(path)
  local fp = io.open(path, "rb"); if not fp then return end
  local text = fp:read("*a"); fp:close(); return text
end
local function first_line(text) return (tostring(text):match("[^\r\n]+") or tostring(text)) end

local function query(conn, sql, readonly)
  local exe, args, env, input = data.DRIVERS[conn.kind].argv(conn, sql, readonly)
  local out, err = git.exec(root() or USERDIR, exe, args, input, 35, env)
  if not out then return nil, (tostring(err):gsub("%s+$", "")) end
  return data.parse_csv(out)
end

local function env_conn()
  local dir = root()
  local url = dir and data.read_env_url(read(dir .. PATHSEP .. ".env") or "")
  if not url then return end
  local conn = data.parse_url(common.basename(dir) .. " (.env)", url, dir)
  conn.source = "env"
  return conn
end

-- Keeps the loaded tree of connections whose URL did not change.
local function reload()
  local old, nodes = {}, {}
  for _, node in ipairs(M.nodes) do old[node.conn.name] = node end
  local conns = {env_conn()}
  for _, entry in ipairs(M.saved) do conns[#conns + 1] = data.parse_url(entry.name, entry.url, root()) end
  for _, conn in ipairs(conns) do
    local prev = old[conn.name]
    nodes[#nodes + 1] = prev and prev.conn.url == conn.url and prev.conn.path == conn.path and prev
      or {kind = "conn", conn = conn, label = conn.name, state = conn.error and "error" or "idle", error = conn.error}
  end
  M.nodes = nodes; core.redraw = true
end

local function save()
  local tmp = CONF .. ".tmp"
  local fp, err = io.open(tmp, "wb")
  if not fp then return nil, err end
  -- Holds plaintext passwords: owner-only before any content is written.
  if PLATFORM ~= "Windows" then os.execute("chmod 600 '" .. tmp:gsub("'", "'\\''") .. "'") end
  fp:write(data.serialize_conf(M.saved)); fp:close()
  local ok, rename_err = os.rename(tmp, CONF)
  if not ok then return nil, rename_err end
  reload()
  return true
end

local function entry_named(name) for i, entry in ipairs(M.saved) do if entry.name == name then return entry, i end end end

-- The "+" and Edit flows end here. `old` is the saved entry being edited.
function M.save_connection(name, url, old)
  name, url = name:match("^%s*(.-)%s*$"), url:match("^%s*(.-)%s*$")
  if name == "" or url == "" then return nil, "Name and URL are required" end
  if name:find("[=\r\n]") or name:sub(1, 1) == "#" then return nil, "Name cannot contain = or start with #" end
  local same = entry_named(name)
  local env = env_conn()
  if (same and same ~= old) or (env and env.name == name) then return nil, "A connection named " .. name .. " exists" end
  if old then old.name, old.url = name, url else M.saved[#M.saved + 1] = {name = name, url = url} end
  return save()
end

local function edit_flow(old)
  views.prompt(old and "Connection name" or "New connection name", function(name)
    views.prompt("Connection URL (postgres://user:pass@host:port/db or sqlite:path.db)", function(url)
      local ok, err = M.save_connection(name, url, old)
      if not ok then core.error("Database: %s", err) end
    end, old and old.url)
  end, old and old.name)
end

local LEVELS = {
  conn = {child = "schema", sql = function(d) return d.schemas_sql end},
  schema = {child = "table", sql = function(d, n) return d.tables_sql(n.schema) end},
  table = {child = "column", sql = function(d, n) return d.columns_sql(n.schema, n.table) end},
}

local function load(node)
  local level = LEVELS[node.kind]
  node.state = "loading"; core.redraw = true
  core.add_thread(function()
    local result, err = query(node.conn, level.sql(data.DRIVERS[node.conn.kind], node), true)
    if result then
      local children = {}
      for _, row in ipairs(result.rows) do
        local child = {kind = level.child, conn = node.conn, schema = node.schema, table = node.table, label = row[1], detail = row[2], state = "idle"}
        child[level.child] = row[1]
        children[#children + 1] = child
      end
      node.children, node.state, node.error = children, "ok", nil
    else
      node.state, node.error = "error", err
    end
    core.redraw = true
  end)
end

function M.toggle(node)
  if not LEVELS[node.kind] then return end
  node.expanded = not node.expanded
  if node.expanded and (node.state == "idle" or (node.state == "error" and not node.conn.error)) then load(node) end
end

function M.refresh(node)
  node.children, node.state, node.error = nil, node.conn.error and "error" or "idle", node.conn.error
  reload()
  for _, n in ipairs(M.nodes) do if n.conn.name == node.conn.name and n.expanded and n.state ~= "loading" then n.expanded = false; M.toggle(n) end end
end

-- Results pane, docked under the tree; hidden until something is shown.
local Results = View:extend()
M.Results = Results
local panel, results
local function lh() return style.code_font:get_height() + style.padding.y end
function Results:new() Results.super.new(self); self.scrollable = true; self.run = 0 end
function Results:get_name() return self.title or "Results" end
function Results:get_size() return 0, self.size.y end
function Results:set_target_size(axis, height)
  if axis == "y" then options.results_height = math.max(120, height / SCALE); core.redraw = true; return true end
end
function Results:update()
  local height = panel and panel.visible and self.key and options.results_height * SCALE or 0
  if self.size.y ~= height then self.size.y = height; core.redraw = true end
  Results.super.update(self)
end
local function close_x(self) return self.position.x + self.size.x - style.padding.x - style.font:get_width("×") end
function Results:on_mouse_pressed(button, x, y, clicks)
  if y < self.position.y + lh() and x >= close_x(self) - style.padding.x then self.key, self.title = nil, nil; core.redraw = true; return true end
  return Results.super.on_mouse_pressed(self, button, x, y, clicks)
end
function Results:get_scrollable_size() return lh() * (4 + #(self.rows or {})) end
function Results:get_h_scrollable_size() return (self.total_w or 0) + style.padding.x * 2 end
function Results:on_mouse_wheel(y, x)
  if keymap.modkeys["shift"] then x, y = y, 0 end
  self.scroll.to.y = self.scroll.to.y - y * lh() * 3
  self.scroll.to.x = self.scroll.to.x - (x or 0) * lh() * 3
  return true
end

local MAX_W = 300
local function clean(text) return (text:sub(1, 200):gsub("[\r\n\t]", " ")) end
function Results:set(result, err, limited)
  self.loading, self.error = false, err
  self.columns, self.rows, self.total_w = result and result.columns, result and result.rows, 0
  if not result then core.redraw = true; return end
  self.widths, self.cells = {}, {}
  for i, name in ipairs(self.columns) do self.widths[i] = style.code_font:get_width(clean(name)) end
  for r, row in ipairs(self.rows) do
    self.cells[r] = {}
    for i, value in ipairs(row) do
      self.cells[r][i] = clean(value)
      self.widths[i] = math.max(self.widths[i] or 0, style.code_font:get_width(self.cells[r][i]))
    end
  end
  for i, w in ipairs(self.widths) do self.widths[i] = math.min(w, MAX_W * SCALE) + style.padding.x * 2; self.total_w = self.total_w + self.widths[i] end
  local n = #self.rows
  self.note = #self.columns == 0 and "Statement executed" or (n .. (n == 1 and " row" or " rows") .. (limited and " · first 100 rows" or ""))
  self.scroll.to.x, self.scroll.to.y = 0, 0
  core.redraw = true
end

function Results:draw_cells(cells, y, color)
  local x, h = self.position.x + style.padding.x - self.scroll.x, lh()
  for i, w in ipairs(self.widths) do
    if x + w > self.position.x and x < self.position.x + self.size.x then
      common.draw_text(style.code_font, color, views.fit(style.code_font, cells[i] or "", w - style.padding.x * 2), nil, x + style.padding.x, y, 0, h)
      renderer.draw_rect(x + w - 1, y, 1, h, style.divider)
    end
    x = x + w
  end
end

function Results:draw()
  if not self.key then return end
  self:draw_background(style.background)
  local x, y, h, pad = self.position.x, self.position.y, lh(), style.padding.x
  renderer.draw_rect(x, y, self.size.x, h, style.background2)
  common.draw_text(style.font, style.text, views.fit(style.font, self.title or "", close_x(self) - x - pad * 2), nil, x + pad, y, 0, h)
  common.draw_text(style.font, style.dim, "×", nil, close_x(self), y, 0, h)
  y = y + h
  if self.loading or self.error then
    local lines = self.loading and {"Running…"} or {}
    for line in tostring(self.error or ""):gmatch("[^\r\n]+") do lines[#lines + 1] = line end
    for i, line in ipairs(lines) do common.draw_text(style.code_font, self.error and style.error or style.dim, line, nil, x + pad, y + (i - 1) * h, 0, h) end
    return
  end
  common.draw_text(style.font, style.dim, self.note or "", nil, x + pad, y, 0, h)
  if #self.columns == 0 then return end
  local top = y + h
  core.push_clip_rect(x, top, self.size.x, self.size.y - h * 2)
  local first = math.max(1, math.floor(self.scroll.y / h) + 1)
  for r = first, math.min(#self.cells, first + math.ceil(self.size.y / h)) do
    local ry = top + h * r - self.scroll.y
    if r % 2 == 0 then renderer.draw_rect(x, ry, self.size.x, h, style.line_highlight) end
    self:draw_cells(self.cells[r], ry, style.text)
  end
  renderer.draw_rect(x, top, self.size.x, h, style.background2)
  self:draw_cells(self.columns, top, style.accent)
  core.pop_clip_rect()
  self:draw_scrollbar()
end

local function open_results(key, title)
  if not panel then command.perform("database:toggle") end
  if not panel.visible then command.perform("database:toggle") end
  results.key, results.title = key, title
  return results
end

function M.show(conn, sql, key, title, readonly, limited)
  local view = open_results(key, title)
  view.loading, view.error, view.run = true, nil, view.run + 1
  local run = view.run
  core.add_thread(function()
    local result, err = query(conn, sql, readonly)
    if view.run == run then view:set(result, err, limited) end
  end)
  return view
end

function M.preview(node)
  local d = data.DRIVERS[node.conn.kind]
  return M.show(node.conn, d.preview_sql(node.schema, node.table), "preview\0" .. node.conn.name .. "\0" .. node.schema .. "\0" .. node.table,
    node.table .. " · " .. node.conn.name, true, true)
end

-- Panel
local Database = View:extend()
function Database:new() Database.super.new(self); self.visible = true; self.scrollable = true; self.rows = {} end
function Database:get_name() return "Database" end
function Database:get_size() return self.visible and options.width * SCALE or 0, 0 end
function Database:set_target_size(axis, width)
  if axis == "x" then options.width = math.max(200, width / SCALE); core.redraw = true; return true end
end
local function row_h() return style.font:get_height() + style.padding.y end
local function header_h() return math.floor(row_h() * 1.5) end
function Database:get_scrollable_size() return header_h() + (#self.rows + 1) * row_h() end
function Database:on_mouse_wheel(y) self.scroll.to.y = self.scroll.to.y - y * row_h() * 3; return true end
function Database:update()
  local width = self.visible and options.width * SCALE or 0
  if self.size.x ~= width then self.size.x = width; core.redraw = true end
  Database.super.update(self)
end

-- Flattened visible tree; status rows ("Loading…", errors, "Empty") hang under their node.
function Database:flatten()
  local rows = {}
  local function walk(nodes, depth)
    for _, node in ipairs(nodes) do
      rows[#rows + 1] = {node = node, depth = depth}
      if node.state == "error" and (node.expanded or node.kind == "conn") then rows[#rows + 1] = {depth = depth + 1, text = first_line(node.error), color = style.error, node = node}
      elseif node.expanded and node.state == "loading" then rows[#rows + 1] = {depth = depth + 1, text = "Loading…", color = style.dim}
      elseif node.expanded and node.state == "ok" then
        if #node.children == 0 then rows[#rows + 1] = {depth = depth + 1, text = "Empty", color = style.dim} end
        walk(node.children, depth + 1)
      end
    end
  end
  walk(M.nodes, 0)
  self.rows = rows
end

function Database:draw()
  if not self.visible then return end
  self:draw_background(style.background2)
  self:flatten()
  local x, w, top, pad, h = self.position.x, self.size.x, self.position.y + header_h(), style.padding.x, row_h()
  common.draw_text(style.font, style.text, "DATABASE", nil, x + pad, self.position.y, 0, header_h())
  local bw = style.font:get_width("+") + pad
  self.add_button = {x = x + w - pad - bw, w = bw}
  local hovered = self.hover_y and self.hover_y < top and self.hover_x >= self.add_button.x
  common.draw_text(style.font, hovered and style.accent or style.text, "+", "center", self.add_button.x, self.position.y, bw, header_h())
  core.push_clip_rect(x, top, w, self.size.y - header_h())
  for i, row in ipairs(self.rows) do
    local ry, rx = top + (i - 1) * h - self.scroll.y, x + pad * 0.5 + row.depth * pad
    local node = row.text == nil and row.node
    if self.hover_row == row then renderer.draw_rect(x, ry, w, h, style.line_highlight) end
    if node and node == M.selected_node then renderer.draw_rect(x, ry, math.max(1, math.floor(2 * SCALE)), h, style.accent) end
    if node then
      if LEVELS[node.kind] then common.draw_text(style.icon_font, style.dim, node.expanded and "-" or "+", nil, rx, ry, 0, h) end
      local tx = common.draw_text(style.font, node.kind == "column" and style.text or style.accent, node.label, nil, rx + 18 * SCALE, ry, 0, h)
      local right = x + w - pad
      if node.kind == "conn" and self.hover_row == row then
        right = right - style.font:get_width("…") - pad
        common.draw_text(style.font, self.hover_x >= right and style.accent or style.text, "…", "center", right, ry, x + w - pad - right, h)
        row.actions = right
      end
      if node.detail and node.detail ~= "" then
        common.draw_text(style.font, style.dim, views.fit(style.font, node.detail, math.max(0, right - tx - pad)), nil, tx + pad * 0.6, ry, 0, h)
      end
    else
      common.draw_text(style.font, row.color, views.fit(style.font, row.text, x + w - pad - rx), nil, rx + 18 * SCALE, ry, 0, h)
    end
  end
  if #M.nodes == 0 then common.draw_text(style.font, style.dim, "Click + to add a connection", nil, x + pad, top, 0, h) end
  core.pop_clip_rect(); self:draw_scrollbar()
end

local function actions(node)
  local conn = node.conn
  views.prompt(conn.name, function(action)
    if action == "Refresh" then M.refresh(node)
    elseif action == "Edit" then edit_flow(entry_named(conn.name))
    elseif action == "Delete" then
      views.confirm("Delete connection", "Remove " .. conn.name .. " from databases.conf?", function()
        local _, i = entry_named(conn.name)
        if i then table.remove(M.saved, i); local ok, err = save(); if not ok then core.error("Database: %s", err) end end
      end)
    end
  end, "", conn.source == "env" and {"Refresh"} or {"Refresh", "Edit", "Delete"})
end

function Database:row_at(y)
  local i = math.floor((y - self.position.y - header_h() + self.scroll.y) / row_h()) + 1
  return y >= self.position.y + header_h() and self.rows[i] or nil
end
function Database:on_mouse_moved(x, y, ...)
  Database.super.on_mouse_moved(self, x, y, ...)
  self.hover_x, self.hover_y, self.hover_row = x, y, self:row_at(y); core.redraw = true
end
function Database:on_mouse_left() Database.super.on_mouse_left(self); self.hover_x, self.hover_y, self.hover_row = nil, nil, nil; core.redraw = true end
function Database:on_mouse_pressed(button, x, y, clicks)
  if Database.super.on_mouse_pressed(self, button, x, y, clicks) then return true end
  if y < self.position.y + header_h() then
    if x >= self.add_button.x then edit_flow() end
    return true
  end
  local row = self:row_at(y)
  local node = row and row.node
  if not node then return true end
  M.selected_node = node
  if node.kind == "conn" and (button == "right" or (row.actions and x >= row.actions)) then actions(node)
  elseif row.text then if node.kind == "conn" then M.refresh(node) end
  else
    M.toggle(node)
    if node.kind == "table" then M.preview(node) end
  end
  core.redraw = true
  return true
end

local function selected_conn() return M.selected_node and M.selected_node.conn end
local function sql_view() local v = core.active_view; return v and v:is(DocView) and v end

function M.run_query()
  local doc = sql_view().doc
  local sql = doc:has_selection() and doc:get_text(doc:get_selection()) or doc:get_text(1, 1, math.huge, math.huge)
  if not sql:match("%S") then return end
  local function run(conn)
    if conn.error then core.error("Database: %s: %s", conn.name, conn.error); return end
    local go = function() M.show(conn, sql, "query\0" .. conn.name, "Query · " .. conn.name, false) end
    if data.is_read_only(sql) then go() else views.confirm("Run statement", "This statement can modify " .. conn.name .. ". Run it?", go) end
  end
  if selected_conn() then return run(selected_conn()) end
  reload()
  local names, by_name = {}, {}
  for _, node in ipairs(M.nodes) do names[#names + 1] = node.conn.name; by_name[node.conn.name] = node end
  if #names == 0 then core.error("Database: add a connection first"); return end
  views.prompt("Run against connection", function(name)
    local node = by_name[name]
    if node then M.selected_node = node; run(node.conn) end
  end, "", names)
end

local function load_saved() M.saved = data.load_conf(read(CONF) or ""); reload() end
load_saved()

command.add(nil, {
  ["database:toggle"] = function()
    if not panel then
      panel = Database(); panel.size.x = options.width * SCALE
      local node = core.root_view:get_primary_node():split("right", panel, {x = true}, true)
      results = Results(); node:split("down", results, {y = true}, true)
    else
      panel.visible = not panel.visible
      if not panel.visible and core.active_view == panel then core.set_active_view(core.root_view:get_primary_node().active_view) end
    end
    if panel.visible then load_saved() end
    core.redraw = true
  end,
  ["database:add-connection"] = function() edit_flow() end,
  ["database:open-config"] = function() core.root_view:open_doc(core.open_doc(CONF)) end,
})
command.add(sql_view, {["database:run-query"] = M.run_query})
keymap.add({[PLATFORM == "Mac OS X" and "cmd+return" or "ctrl+return"] = function()
  local v = sql_view()
  if not (v and (v.doc.filename or ""):lower():match("%.sql$")) then return false end
  M.run_query()
end})

function M.panel() return panel end
function M.results() return results end
return M
