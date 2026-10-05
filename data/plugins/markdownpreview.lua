-- mod-version:4
-- Live Markdown preview, opened to the side of the source (like VS Code).
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local View = require "core.view"
local DocView = require "core.docview"
local RootView = require "core.rootview"
local mermaid = require "plugins.markdownpreview.mermaid"

local Preview = View:extend()
Preview.context = "session"
function Preview:__tostring() return "MarkdownPreview" end

local function is_markdown(doc)
  local ext = doc and doc.filename and doc.filename:lower():match("%.(%w+)$")
  return ext == "md" or ext == "markdown"
end

-- Inline: `code`, **bold**, *italic*, ~~strike~~, [link](url), ![image](url), <br>.
local function inline(text)
  local spans, buf, bold, italic, strike = {}, {}, false, false, false
  local function flush()
    if #buf > 0 then spans[#spans + 1] = {text = table.concat(buf), bold = bold, italic = italic, strike = strike}; buf = {} end
  end
  local i = 1
  while i <= #text do
    local two, c = text:sub(i, i + 1), text:sub(i, i)
    local prev, nxt = text:sub(i - 1, i - 1), text:sub(i + 1, i + 1)
    if c == "\\" and nxt:match("%p") then buf[#buf + 1] = nxt; i = i + 2
    elseif c == "`" and text:find("`", i + 1, true) then
      local j = text:find("`", i + 1, true)
      flush(); spans[#spans + 1] = {text = text:sub(i + 1, j - 1), code = true}; i = j + 1
    elseif two == "**" or two == "__" then flush(); bold = not bold; i = i + 2
    elseif two == "~~" then flush(); strike = not strike; i = i + 2
    elseif (c == "*" or c == "_") and (italic or (nxt:match("%S") and not prev:match("%w"))) and (not italic or not nxt:match("%w")) then
      flush(); italic = not italic; i = i + 1
    elseif text:match("^!%[[^%]]*%]%([^)]*%)", i) then
      local alt, len = text:match("^!%[([^%]]*)%]%([^)]*%)()", i)
      flush(); spans[#spans + 1] = {text = "[image: " .. alt .. "]", dim = true}; i = len
    elseif text:match("^%[[^%]]+%]%([^)]*%)", i) then
      local label, url, len = text:match("^%[([^%]]+)%]%(([^)]*)%)()", i)
      flush(); spans[#spans + 1] = {text = label, link = url, bold = bold, italic = italic}; i = len
    elseif text:match("^<br%s*/?>", i) then flush(); spans[#spans + 1] = {br = true}; i = text:match("^<br%s*/?>()", i)
    else buf[#buf + 1] = c; i = i + 1 end
  end
  flush()
  return spans
end

local function parse(lines)
  local blocks, i = {}, 1
  local function add(b) blocks[#blocks + 1] = b; return b end
  if lines[1] == "---" then
    local j = 2
    while lines[j] and lines[j] ~= "---" do j = j + 1 end
    if lines[j] then
      local rows = {}
      for k = 2, j - 1 do
        local key, value = lines[k]:match("^([%w_%-]+):%s*(.*)$")
        if key then rows[#rows + 1] = {inline(key), inline(value)} elseif #rows > 0 then table.insert(rows[#rows][2], {text = " " .. lines[k]:gsub("^%s+", "")}) end
      end
      add({type = "table", rows = rows, front = true}); i = j + 1
    end
  end
  local function starts_block(l)
    return l:match("^%s*$") or l:match("^#+%s") or l:match("^%s*```") or l:match("^%s*~~~") or l:match("^>")
      or l:match("^%s*[%-%*%+]%s") or l:match("^%s*%d+[%.%)]%s") or l:match("^%s*|") or l:match("^%s*[%-%*_][%-%*_%s]*$")
  end
  while i <= #lines do
    local l = lines[i]
    local fence = l:match("^%s*(```+)") or l:match("^%s*(~~~+)")
    if l:match("^%s*$") then i = i + 1
    elseif fence then
      local code = {}; local lang = l:match("^%s*[`~]+%s*(%S*)")
      i = i + 1
      while lines[i] and not lines[i]:match("^%s*" .. fence:sub(1, 1):gsub("%p", "%%%0") .. "+%s*$") do code[#code + 1] = lines[i]; i = i + 1 end
      add({type = "code", lang = lang, lines = code}); i = i + 1
    elseif l:match("^#+%s") then
      local hashes, text = l:match("^(#+)%s+(.-)%s*#*%s*$")
      add({type = "heading", level = math.min(#hashes, 6), spans = inline(text)}); i = i + 1
    elseif l:match("^%s*[%-%*_]%s*[%-%*_]%s*[%-%*_][%-%*_%s]*$") then add({type = "hr"}); i = i + 1
    elseif l:match("^%s*|") and lines[i + 1] and lines[i + 1]:match("^%s*|?%s*:?%-+") then
      local rows = {}
      while lines[i] and lines[i]:match("^%s*|") do
        if not lines[i]:match("^%s*|?[%s:|%-]+$") then
          local cells, row = lines[i]:gsub("^%s*|", ""):gsub("|%s*$", ""), {}
          for cell in (cells .. "|"):gmatch("(.-)|") do row[#row + 1] = inline(cell:match("^%s*(.-)%s*$")) end
          rows[#rows + 1] = row
        end
        i = i + 1
      end
      add({type = "table", rows = rows})
    elseif l:match("^>") then
      local text = {}
      while lines[i] and lines[i]:match("^>") do text[#text + 1] = lines[i]:gsub("^>%s?", ""); i = i + 1 end
      add({type = "quote", spans = inline(table.concat(text, " "))})
    elseif l:match("^%s*[%-%*%+]%s") or l:match("^%s*%d+[%.%)]%s") then
      local indent, marker, text = l:match("^(%s*)([%-%*%+])%s+(.*)$")
      if not indent then indent, marker, text = l:match("^(%s*)(%d+[%.%)])%s+(.*)$") end
      local check = text:match("^%[([ xX])%]%s")
      if check then text = text:sub(5) end
      i = i + 1
      while lines[i] and lines[i]:match("^%s+%S") and not starts_block(lines[i]) do text = text .. " " .. lines[i]:gsub("^%s+", ""); i = i + 1 end
      add({type = "item", depth = #indent:gsub("\t", "  ") // 2, marker = marker:match("%d") and marker or "•", check = check, spans = inline(text)})
    else
      local text = {l}
      i = i + 1
      while lines[i] and not starts_block(lines[i]) do text[#text + 1] = lines[i]; i = i + 1 end
      add({type = "para", spans = inline(table.concat(text, " "))})
    end
  end
  return blocks
end

local fonts = {}
local function font(kind, scale)
  local key = kind .. scale .. SCALE
  if not fonts[key] then
    local base = kind == "code" and style.code_font or style.font
    fonts[key] = base:copy(base:get_size() * scale)
  end
  return fonts[key]
end
local HEADING = {1.9, 1.5, 1.25, 1.1, 1.0, 0.95}

function Preview:new(doc)
  Preview.super.new(self)
  self.doc, self.scrollable, self.ops = doc, true, {}
end
function Preview:get_name() return (self.doc.filename or "untitled"):match("[^/\\]*$") end
function Preview:get_scrollable_size() return (self.height or 0) + style.padding.y * 4 end

-- Lays out spans into wrapped lines, appending draw ops; returns the new y.
function Preview:flow(spans, x0, y, width, base, color)
  local lh = math.floor(base:get_height() * 1.5)
  local code = font("code", base:get_size() / style.code_font:get_size() * 0.9)
  local x, ops = x0, self.ops
  for _, span in ipairs(spans) do
    if span.br then x, y = x0, y + lh
    else
      local f = span.code and code or base
      local c = span.link and style.caret or span.code and style.syntax.string or span.dim and style.dim
        or span.italic and style.syntax.keyword2 or span.bold and style.syntax.normal or color
      for chunk in span.text:gmatch("%s*%S+%s*") do
        local w = f:get_width(chunk)
        if x + f:get_width((chunk:gsub("%s+$", ""))) > x0 + width and x > x0 then
          x, y = x0, y + lh; chunk = chunk:gsub("^%s+", ""); w = f:get_width(chunk)
        end
        ops[#ops + 1] = {text = chunk, x = x, y = y, h = lh, font = f, color = c, bold = span.bold, code = span.code, strike = span.strike, link = span.link}
        x = x + w
      end
    end
  end
  return y + lh
end

-- Unsupported or broken diagrams fall back to a plain code block.
function Preview:diagram(b, maxw)
  local ok, d = pcall(mermaid.render, b.lines, maxw)
  if not ok then core.log_quiet("Mermaid: %s", d) end
  b.diagram = ok and d or nil
  return b.diagram
end

function Preview:layout(width)
  self.ops, self.layout_width, self.layout_scale = {}, width, SCALE
  local ops, px = self.ops, style.padding.x * 2
  local body = style.font
  local maxw = math.min(width - px * 2, math.floor(900 * SCALE))
  local x0 = math.max(px, math.floor((width - maxw) / 2))
  local y, gap = style.padding.y * 2, math.floor(body:get_height() * 0.8)
  for _, b in ipairs(self.blocks) do
    if b.type == "heading" then
      local f = font("ui", HEADING[b.level])
      y = y + (b.level <= 2 and gap or gap / 2)
      local first = #ops + 1
      y = self:flow(b.spans, x0, y, maxw, f, style.syntax.normal)
      for k = first, #ops do ops[k].bold = true end
      if b.level <= 2 then ops[#ops + 1] = {rect = true, x = x0, y = y + 2 * SCALE, w = maxw, h = math.max(1, SCALE), color = style.divider}; y = y + gap / 2 end
      y = y + gap / 2
    elseif b.type == "para" then y = self:flow(b.spans, x0, y, maxw, body, style.text) + gap / 2
    elseif b.type == "quote" then
      local top = y
      y = self:flow(b.spans, x0 + px, y, maxw - px, body, style.dim)
      ops[#ops + 1] = {rect = true, x = x0, y = top, w = math.floor(3 * SCALE), h = y - top, color = style.modified}
      y = y + gap / 2
    elseif b.type == "item" then
      local indent = x0 + b.depth * px + px
      local lh = math.floor(body:get_height() * 1.5)
      if b.check then
        local s = math.floor(body:get_height() * 0.75)
        local bx, by = indent - px + (px - s) / 2, y + (lh - s) / 2
        ops[#ops + 1] = {rect = true, x = bx, y = by, w = s, h = s, color = b.check == " " and style.divider or style.good}
        if b.check == " " then ops[#ops + 1] = {rect = true, x = bx + SCALE, y = by + SCALE, w = s - 2 * SCALE, h = s - 2 * SCALE, color = style.background} end
      else
        ops[#ops + 1] = {text = b.marker, x = indent - body:get_width(b.marker) - math.floor(6 * SCALE), y = y, h = lh, font = body, color = style.caret}
      end
      y = self:flow(b.spans, indent, y, maxw - (indent - x0), body, b.check and b.check ~= " " and style.dim or style.text)
      if b.check and b.check ~= " " then for k = #ops, 1, -1 do if ops[k].y < y - lh then break end; ops[k].strike = ops[k].text and true end end
      y = y + math.floor(2 * SCALE)
    elseif b.type == "code" and b.lang == "mermaid" and self:diagram(b, width - px * 2) then
      local d = b.diagram
      y = y + gap / 2
      ops[#ops + 1] = {custom = d.draw, x = math.max(px, math.floor((width - d.w) / 2)), y = y, h = d.h}
      y = y + d.h + gap
    elseif b.type == "code" then
      local cf = font("code", 0.9)
      local lh = math.floor(cf:get_height() * 1.45)
      local h = #b.lines * lh + style.padding.y * 2
      y = y + gap / 4
      ops[#ops + 1] = {rect = true, x = x0, y = y, w = maxw, h = h, color = style.background3}
      if b.lang ~= "" then ops[#ops + 1] = {text = b.lang, x = x0 + maxw - style.padding.x - style.font:get_width(b.lang), y = y, h = lh + style.padding.y, font = style.font, color = style.dim} end
      for k, line in ipairs(b.lines) do
        ops[#ops + 1] = {text = line, x = x0 + style.padding.x, y = y + style.padding.y + (k - 1) * lh, h = lh, font = cf, color = style.syntax.normal, clip = {x0, maxw}}
      end
      y = y + h + gap
    elseif b.type == "hr" then
      y = y + gap / 2
      ops[#ops + 1] = {rect = true, x = x0, y = y, w = maxw, h = math.max(1, 2 * SCALE), color = style.divider}
      y = y + gap
    elseif b.type == "table" then
      local cols = 0
      for _, row in ipairs(b.rows) do cols = math.max(cols, #row) end
      local widths, total = {}, 0
      for c = 1, cols do
        local w = 0
        for _, row in ipairs(b.rows) do
          local cw = 0; for _, s in ipairs(row[c] or {}) do cw = cw + body:get_width(s.text or "") end
          w = math.max(w, cw)
        end
        widths[c] = w + style.padding.x * 2; total = total + widths[c]
      end
      -- Shrink wide columns proportionally; cells wrap.
      if total > maxw then for c = 1, cols do widths[c] = math.max(math.floor(60 * SCALE), widths[c] * maxw / total) end end
      y = y + gap / 4
      for r, row in ipairs(b.rows) do
        local top, x, bottom = y, x0, y
        local first = #ops + 1
        for c = 1, cols do
          bottom = math.max(bottom, self:flow(row[c] or {}, x + style.padding.x, top + style.padding.y / 2, widths[c] - style.padding.x * 2, body,
            b.front and c == 1 and style.dim or style.text))
          x = x + widths[c]
        end
        bottom = bottom + style.padding.y / 2
        local width_sum = x - x0
        local bg = (r == 1 and not b.front) and style.background3 or nil
        if bg then table.insert(ops, first, {rect = true, x = x0, y = top, w = width_sum, h = bottom - top, color = bg}) end
        if r == 1 and not b.front then for k = first, #ops do if ops[k].text then ops[k].bold, ops[k].color = true, style.syntax.normal end end end
        ops[#ops + 1] = {rect = true, x = x0, y = bottom, w = width_sum, h = math.max(1, SCALE), color = style.divider}
        if r == 1 then ops[#ops + 1] = {rect = true, x = x0, y = top, w = width_sum, h = math.max(1, SCALE), color = style.divider} end
        y = bottom
      end
      y = y + gap
    end
  end
  self.height = y
end

function Preview:update()
  local change = self.doc:get_change_id()
  if change ~= self.change_id then
    self.change_id = change
    local lines = {}
    for k, line in ipairs(self.doc.lines) do lines[k] = line:gsub("\n$", "") end
    self.blocks = parse(lines); self.layout_width = nil
  end
  if self.layout_width ~= self.size.x or self.layout_scale ~= SCALE then self:layout(self.size.x) end
  Preview.super.update(self)
end

function Preview:draw()
  self:draw_background(style.background)
  local ox, oy = self:get_content_offset()
  local top, bottom = self.position.y, self.position.y + self.size.y
  self.hover_link = nil
  for _, op in ipairs(self.ops) do
    local y = oy + op.y
    if y + (op.h or 0) >= top and y <= bottom then
      if op.custom then
        local ok, err = pcall(op.custom, ox + op.x, y)
        if not ok then op.custom = function() end; core.log_quiet("Mermaid draw: %s", err) end
      elseif op.rect then renderer.draw_rect(ox + op.x, y, op.w, op.h, op.color)
      else
        if op.clip then core.push_clip_rect(ox + op.clip[1], y, op.clip[2], op.h) end
        local fh = op.font:get_height()
        local x, ty = ox + op.x, y + math.floor((op.h - fh) / 2)
        local w = op.font:get_width(op.text)
        if op.code then renderer.draw_rect(x - 2 * SCALE, ty, w + 4 * SCALE, fh, style.background3) end
        renderer.draw_text(op.font, op.text, x, ty, op.color)
        if op.bold then renderer.draw_text(op.font, op.text, x + math.max(1, SCALE * 0.6), ty, op.color) end -- faux bold
        if op.strike then renderer.draw_rect(x, ty + fh / 2, w, math.max(1, SCALE), op.color) end
        if op.link then
          renderer.draw_rect(x, ty + fh - SCALE, w, math.max(1, SCALE), op.color)
          local mx, my = self.mouse_x or -1, self.mouse_y or -1
          if mx >= x and mx < x + w and my >= ty and my < ty + fh then self.hover_link = op.link end
        end
        if op.clip then core.pop_clip_rect() end
      end
    end
  end
  self:draw_scrollbar()
end

function Preview:on_mouse_moved(x, y, ...)
  Preview.super.on_mouse_moved(self, x, y, ...)
  self.mouse_x, self.mouse_y = x, y
  self.cursor = self.hover_link and "hand" or "arrow"
end

function Preview:on_mouse_pressed(button, x, y, clicks)
  if Preview.super.on_mouse_pressed(self, button, x, y, clicks) then return true end
  local link = self.hover_link
  if not link then return end
  if link:match("^%a[%w+.-]*:") then system.exec(string.format("open %q", link))
  elseif self.doc.abs_filename then
    local path = common.normalize_path(self.doc.abs_filename:match("^(.*)[/\\]") .. PATHSEP .. link:gsub("#.*$", ""))
    if system.get_file_info(path) then core.root_view:open_doc(core.open_doc(path)) end
  end
  return true
end

local function find_preview(doc)
  for _, view in ipairs(core.root_view.root_node:get_children()) do
    if view:is(Preview) and view.doc == doc then return view end
  end
end

-- Closing the last view of an unsaved doc asks to save, same as the editor.
Preview.try_close = DocView.try_close

-- Replace `old` with `new` in the same tab slot (no close prompt, no new tab).
local function swap(old, new)
  local node = core.root_view.root_node:get_node_for_view(old)
  if not node then return end
  node.views[node:get_view_idx(old)] = new
  if node.active_view == old then node:set_active_view(new) end
  core.root_view.root_node:update_layout()
  return new
end

local function in_active_node(doc, kind)
  for _, view in ipairs(core.root_view:get_active_node_default().views) do
    if view.doc == doc and view:is(kind) then return view end
  end
end

-- Anything that opens a doc for editing (search results, go to line, ...)
-- turns a preview tab back into the editor.
local open_doc = RootView.open_doc
function RootView:open_doc(doc)
  local preview = in_active_node(doc, Preview)
  if preview and not in_active_node(doc, DocView) then return swap(preview, DocView(doc)) end
  return open_doc(self, doc)
end

-- Clicking a Markdown file in the tree opens the preview in a normal tab.
local function open_preview(doc)
  local existing = in_active_node(doc, Preview) or in_active_node(doc, DocView)
  if existing then core.root_view:get_active_node_default():set_active_view(existing); return existing end
  local preview = Preview(doc)
  core.root_view:get_active_node_default():add_view(preview)
  core.root_view.root_node:update_layout()
  return preview
end

core.add_thread(function()
  local tree = package.loaded["plugins.treeview"]
  if type(tree) ~= "table" or not tree.open_doc then return end
  local tree_open = tree.open_doc
  tree.open_doc = function(self, filename)
    local doc = core.open_doc(filename)
    if is_markdown(doc) then return open_preview(doc) end
    return tree_open(self, filename)
  end
end)

command.add(function()
  local view = core.active_view
  return view:is(Preview) or (view:is(DocView) and is_markdown(view.doc)), view
end, {
  -- Swap the current tab between preview and editor.
  ["markdown:toggle-preview"] = function(view)
    if view:is(Preview) then swap(view, DocView(view.doc)) else swap(view, Preview(view.doc)) end
  end,
  ["markdown:open-preview-to-side"] = function(view)
    local existing = find_preview(view.doc)
    if existing then core.root_view.root_node:get_node_for_view(existing):close_view(core.root_view.root_node, existing); return end
    core.root_view:get_active_node():split("right", Preview(view.doc))
    core.set_active_view(view)
  end,
})

keymap.add({[PLATFORM == "Mac OS X" and "cmd+shift+v" or "ctrl+shift+v"] = "markdown:toggle-preview"})

core.status_view:add_item({
  name = "markdown:preview",
  alignment = core.status_view.Item.RIGHT,
  predicate = function() local v = core.active_view; return v and (v:is(Preview) or (v:is(DocView) and is_markdown(v.doc))) end,
  position = -1,
  command = "markdown:toggle-preview",
  tooltip = "Switch between preview and editor",
  get_item = function() return {style.accent, core.active_view:is(Preview) and "Edit" or "Preview"} end,
})

return {Preview = Preview, parse = parse}
