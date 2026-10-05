-- Native Mermaid renderer for the Markdown preview (the renderer has no image
-- support, so diagrams are laid out and drawn with rects + text).
-- Supports flowchart/graph (with subgraphs), stateDiagram(-v2), sequenceDiagram.
-- Everything else returns nil and the preview falls back to a code block.
local style = require "core.style"
local M = {}

local fonts = {}
local function font_at(scale)
  local key = scale .. ":" .. SCALE
  fonts[key] = fonts[key] or style.font:copy(style.font:get_size() * scale * 0.9)
  return fonts[key]
end
local function tint(c, a) return {c[1], c[2], c[3], a} end

---------------------------------------------------------------- primitives
local function seg(x1, y1, x2, y2, t, c, dashed)
  if x1 > x2 then x1, x2 = x2, x1 end
  if y1 > y2 then y1, y2 = y2, y1 end
  local horizontal = y1 == y2
  local len = horizontal and x2 - x1 or y2 - y1
  local dash, gap = dashed and 5 * SCALE or len, dashed and 4 * SCALE or 0
  local p = 0
  while p < len do
    local l = math.min(dash, len - p)
    if horizontal then renderer.draw_rect(x1 + p, y1 - t / 2, l, t, c)
    else renderer.draw_rect(x1 - t / 2, y1 + p, t, l, c) end
    p = p + dash + gap
  end
end

local function arrowhead(x, y, dir, s, c)
  for i = 0, s do
    local half = i * 0.55
    if dir == "down" then renderer.draw_rect(x - half, y - i, half * 2 + 1, 1, c)
    elseif dir == "up" then renderer.draw_rect(x - half, y + i, half * 2 + 1, 1, c)
    elseif dir == "right" then renderer.draw_rect(x - i, y - half, 1, half * 2 + 1, c)
    else renderer.draw_rect(x + i, y - half, 1, half * 2 + 1, c) end
  end
end

-- Scanline fill; `inset(dy, h)` returns the horizontal inset for row dy.
local function fill(shape, x, y, w, h, c)
  if shape == "rect" or w <= 0 or h <= 0 then renderer.draw_rect(x, y, w, h, c); return end
  local r = shape == "round" and math.min(h / 2, 7 * SCALE) or h / 2
  for row = 0, h - 1, 1 do
    local d = math.min(row + 0.5, h - row - 0.5)
    local inset
    if shape == "diamond" then inset = w / 2 * (1 - d / (h / 2))
    elseif shape == "hex" then inset = h / 4 * (1 - d / (h / 2))
    elseif shape == "circle" then
      local dy = 1 - d / (h / 2); inset = w / 2 * (1 - math.sqrt(math.max(0, 1 - dy * dy)))
    else -- round / stadium / cyl
      inset = d < r and r - math.sqrt(math.max(0, r * r - (r - d) ^ 2)) or 0
    end
    if w - inset * 2 > 0 then renderer.draw_rect(x + inset, y + row, w - inset * 2, 1, c) end
  end
end

local function shape_box(shape, x, y, w, h, border, bg)
  local b = math.max(1, math.floor(1.5 * SCALE))
  fill(shape, x, y, w, h, border)
  local k = shape == "diamond" and 2.2 or 1
  fill(shape, x + b * k, y + b, w - b * k * 2, h - b * 2, bg)
end

---------------------------------------------------------------- labels
local function clean(text)
  text = (text or ""):gsub('^%s*"(.*)"%s*$', "%1"):gsub("#quot;", '"'):gsub("&quot;", '"'):gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">")
  text = text:gsub("<br%s*/?>", "\n"):gsub("<[^>]+>", ""):gsub("%*%*", ""):gsub("\\n", "\n")
  -- Bundled fonts have no emoji: drop 4-byte sequences and variation selectors.
  text = text:gsub("[\240-\244][\128-\191][\128-\191][\128-\191]", ""):gsub("\239\184\143", ""):gsub("\n%s+", "\n"):gsub("^%s+", "")
  return text
end

local function wrap(text, f, maxw)
  local out = {}
  for para in (clean(text) .. "\n"):gmatch("([^\n]*)\n") do
    local line = ""
    for word in para:gmatch("%S+") do
      local try = line == "" and word or line .. " " .. word
      if line ~= "" and f:get_width(try) > maxw then out[#out + 1] = line; line = word else line = try end
    end
    out[#out + 1] = line
  end
  while #out > 1 and out[#out] == "" do table.remove(out) end
  local w = 0; for _, l in ipairs(out) do w = math.max(w, f:get_width(l)) end
  return out, w
end

local function draw_lines(lines, f, cx, y, color)
  local lh = f:get_height()
  for i, l in ipairs(lines) do renderer.draw_text(f, l, cx - f:get_width(l) / 2, y + (i - 1) * lh, color) end
end

---------------------------------------------------------------- flowchart parsing
local SHAPES = {
  {"(((", ")))", "circle"}, {"((", "))", "circle"}, {"([", "])", "stadium"}, {"[[", "]]", "rect"},
  {"[(", ")]", "cyl"}, {"{{", "}}", "hex"}, {"[/", "/]", "rect"}, {"[\\", "\\]", "rect"}, {"[/", "\\]", "rect"},
  {"[\\", "/]", "rect"}, {"(", ")", "round"}, {"[", "]", "rect"}, {"{", "}", "diamond"}, {">", "]", "rect"},
}

local function parse_node(s, i)
  local id, j = s:match("^([%w_]+)()", i)
  if not id then return end
  while s:sub(j, j) == "-" and s:sub(j + 1, j + 1):match("[%w_]") do
    local more; more, j = s:match("^%-([%w_]+)()", j); id = id .. "-" .. more
  end
  local node = {id = id}
  for _, sh in ipairs(SHAPES) do
    if s:sub(j, j + #sh[1] - 1) == sh[1] then
      local start = j + #sh[1]
      local stop
      local q = s:match('^%s*"()', start)
      if q then
        local endq = s:find('"', q, true)
        stop = endq and s:find(sh[2], endq + 1, true)
      else stop = s:find(sh[2], start, true) end
      if stop then
        node.label, node.shape, j = s:sub(start, stop - 1), sh[3], stop + #sh[2]
        break
      end
    end
  end
  j = s:match("^:::[%w_%-]+()", j) or j
  return node, j
end

local function parse_edge(s, i)
  i = s:match("^%s*()", i)
  local label, op, j
  for _, p in ipairs({"^%-%-%s+(.-)%s+(%-%-+[>ox]?)()", "^==%s+(.-)%s+(==+[>ox]?)()", "^%-%.%s+(.-)%s+(%.%-+[>ox]?)()"}) do
    label, op, j = s:match(p, i)
    if label then break end
  end
  if not op then
    op, j = s:match("^(<?[%-=%.][%-=%.]+[>ox]?)()", i)
    if not op then return end
    -- `o`/`x` only count as arrowheads when not the start of a node id
    if op:match("[ox]$") and s:sub(j, j):match("[%w_]") then op = op:sub(1, -2); j = j - 1 end
    if #op:gsub("[<>ox]", "") < 2 then return end
  end
  local pipe, k = s:match("^%s*|([^|]*)|()", j)
  if pipe then label, j = pipe, k end
  return {label = label and clean(label) ~= "" and label or nil, dotted = op:find(".", 1, true) ~= nil, thick = op:find("=", 1, true) ~= nil,
    head = op:match("[>ox]$") ~= nil, tail = op:sub(1, 1) == "<"}, j
end

local function flow_parse(lines)
  local g = {nodes = {}, by_id = {}, edges = {}, clusters = {}, dir = "TB"}
  local stack = {}
  local function node(n)
    local v = g.by_id[n.id]
    if not v then
      v = {id = n.id, label = n.id, shape = "rect", index = #g.nodes + 1}
      g.by_id[n.id] = v; g.nodes[#g.nodes + 1] = v
    end
    if n.label then v.label, v.shape = n.label, n.shape end
    if n.shape and n.shape ~= "rect" then v.shape = n.shape end
    local cluster = stack[#stack]
    if cluster and (not v.cluster or n.label) then v.cluster = cluster end
    return v
  end
  g.node = node
  for _, raw in ipairs(lines) do
    for line in (raw .. ";"):gmatch("([^;]*);") do
      line = line:gsub("%%%%.*$", ""):match("^%s*(.-)%s*$")
      local head, dir = line:match("^(%a+)%s*(%u*)")
      if line == "" or line:match("^classDef%s") or line:match("^class%s") or line:match("^style%s") or line:match("^linkStyle%s") or line:match("^click%s") then
      elseif (head == "flowchart" or head == "graph") then g.dir = dir ~= "" and dir or "TB"
      elseif line:match("^direction%s") then
        if #stack == 0 then g.dir = line:match("^direction%s+(%u+)") or g.dir end
      elseif line:match("^subgraph") then
        local rest = line:match("^subgraph%s*(.*)$")
        local id, label = rest:match("^([%w_%-]+)%s*%[(.*)%]$")
        if not id then id = rest:match('^"(.*)"$') or rest; label = id end
        local c = {id = id, label = clean(label), parent = stack[#stack], index = #g.clusters + 1}
        g.clusters[#g.clusters + 1] = c; stack[#stack + 1] = c
      elseif line == "end" then stack[#stack] = nil
      else
        local function group(pos)
          local list = {}
          while true do
            local n, j = parse_node(line, line:match("^%s*()", pos))
            if not n then break end
            list[#list + 1] = n; pos = j
            local amp = line:match("^%s*&%s*()", pos)
            if not amp then break end
            pos = amp
          end
          return list, pos
        end
        local prev, pos = group(1)
        for _, n in ipairs(prev) do node(n) end
        while #prev > 0 do
          local e, j = parse_edge(line, pos)
          if not e then break end
          local nxt; nxt, pos = group(j)
          if #nxt == 0 then break end
          for _, a in ipairs(prev) do for _, b in ipairs(nxt) do
            local edge = {label = e.label, dotted = e.dotted, thick = e.thick, head = e.head, tail = e.tail}
            edge.from, edge.to = node(a), node(b)
            g.edges[#g.edges + 1] = edge
          end end
          prev = nxt
        end
      end
    end
  end
  -- Edges pointing at a subgraph id attach to its first member.
  local first_member = {}
  for _, v in ipairs(g.nodes) do
    local c = v.cluster
    while c do first_member[c.id] = first_member[c.id] or v; c = c.parent end
  end
  local remove = {}
  for i, v in ipairs(g.nodes) do if first_member[v.id] and not v.cluster and v.label == v.id then remove[v] = first_member[v.id] end end
  if next(remove) then
    for _, e in ipairs(g.edges) do e.from, e.to = remove[e.from] or e.from, remove[e.to] or e.to end
    local kept = {}; for _, v in ipairs(g.nodes) do if not remove[v] then kept[#kept + 1] = v end end
    g.nodes = kept
  end
  return g
end

local function state_parse(lines)
  local g = {nodes = {}, by_id = {}, edges = {}, clusters = {}, dir = "TB"}
  local stack, starts = {}, 0
  local function node(id, label, shape)
    local v = g.by_id[id]
    if not v then
      v = {id = id, label = label or id, shape = shape or "round", index = #g.nodes + 1, cluster = stack[#stack]}
      g.by_id[id] = v; g.nodes[#g.nodes + 1] = v
    end
    return v
  end
  local function ref(id, as_target)
    if id == "[*]" then
      local scope = stack[#stack] and stack[#stack].id or ""
      local key = (as_target and "__end_" or "__start_") .. scope
      return node(key, "", as_target and "end" or "start")
    end
    return node(id)
  end
  local in_note = false
  for _, raw in ipairs(lines) do
    local line = raw:gsub("%%%%.*$", ""):match("^%s*(.-)%s*$")
    if in_note then in_note = not line:match("^end note")
    elseif line == "" or line:match("^stateDiagram") or line:match("^classDef") or line:match("^class ") or line == "--" then
    elseif line:match("^direction%s") then g.dir = line:match("^direction%s+(%u+)")
    elseif line:match("^note ") then in_note = not line:find(":", 1, true)
    elseif line:match("^state ") then
      local desc, id = line:match('^state%s+"(.-)"%s+as%s+([%w_]+)')
      if desc then node(id).label = desc
      else
        local cid = line:match("^state%s+([%w_]+)%s*{")
        if cid then
          local c = {id = cid, label = cid, parent = stack[#stack], index = #g.clusters + 1}
          g.clusters[#g.clusters + 1] = c; stack[#stack + 1] = c
        else
          local sid, kind = line:match("^state%s+([%w_]+)%s+<<(%a+)>>")
          if sid then node(sid, "", (kind == "fork" or kind == "join") and "bar" or "diamond") end
        end
      end
    elseif line == "}" then stack[#stack] = nil
    else
      local a, b, label = line:match("^(%S+)%s*%-%->%s*([^:]-)%s*:%s*(.*)$")
      if not a then a, b = line:match("^(%S+)%s*%-%->%s*(%S+)$") end
      if a then
        g.edges[#g.edges + 1] = {from = ref(a), to = ref(b, true), label = label ~= "" and label or nil, head = true}
      else
        local id, text = line:match("^([%w_]+)%s*:%s*(.*)$")
        if id then local v = node(id); v.label = v.label == id and id .. "\n" .. text or v.label .. "\n" .. text
        elseif line:match("^[%w_]+$") then node(line) end
      end
    end
  end
  return g
end

---------------------------------------------------------------- layered layout
local function top_cluster(c) while c and c.parent do c = c.parent end; return c end

local function flow_layout(g, fs, maxw)
  local f = font_at(fs)
  local pad, lh = math.floor(10 * SCALE * fs), f:get_height()
  local horizontal = g.dir == "LR" or g.dir == "RL"
  for _, v in ipairs(g.nodes) do
    if v.shape == "start" or v.shape == "end" then v.lines, v.w, v.h = {}, 14 * SCALE, 14 * SCALE
    elseif v.shape == "bar" then v.lines, v.w, v.h = {}, horizontal and 6 * SCALE or 60 * SCALE, horizontal and 60 * SCALE or 6 * SCALE
    else
      local lines, tw = wrap(v.label, f, math.floor((horizontal and 200 or 220) * SCALE))
      v.lines = lines
      v.w = tw + pad * 2.4; v.h = #lines * lh + pad * 1.6
      if v.shape == "diamond" then v.w, v.h = v.w * 1.5, v.h * 1.5 end
      if v.shape == "hex" then v.w = v.w + v.h / 2 end
      if v.shape == "circle" then v.w = math.max(v.w, v.h); v.h = v.w end
    end
  end
  -- Ranks: drop back edges (DFS), then longest path.
  local out = {}
  for _, v in ipairs(g.nodes) do out[v] = {} end
  for _, e in ipairs(g.edges) do if out[e.from] and out[e.to] then table.insert(out[e.from], e) end end
  local state, dag = {}, {}
  local function dfs(v)
    state[v] = 1
    for _, e in ipairs(out[v]) do
      if state[e.to] == 1 then e.back = true
      else dag[#dag + 1] = e; if not state[e.to] then dfs(e.to) end end
    end
    state[v] = 2
  end
  for _, v in ipairs(g.nodes) do if not state[v] then dfs(v) end end
  local rank = {}
  for _, v in ipairs(g.nodes) do rank[v] = 0 end
  for _ = 1, #g.nodes do
    local changed = false
    for _, e in ipairs(dag) do
      if e.from ~= e.to and rank[e.to] < rank[e.from] + 1 then rank[e.to] = rank[e.from] + 1; changed = true end
    end
    if not changed then break end
  end
  -- Units: each top-level subgraph is one block; loose nodes are their own.
  local units, unit_of = {}, {}
  for _, v in ipairs(g.nodes) do
    local top = top_cluster(v.cluster)
    local u = top and unit_of[top]
    if not u then
      u = {cluster = top, nodes = {}}; units[#units + 1] = u
      if top then unit_of[top] = u end
    end
    table.insert(u.nodes, v); v.unit = u
    v.band = top and #units or 0
  end
  local ranks, max_rank = {}, 0
  for _, v in ipairs(g.nodes) do
    v.rank = rank[v]; max_rank = math.max(max_rank, v.rank)
    ranks[v.rank] = ranks[v.rank] or {}; table.insert(ranks[v.rank], v)
  end
  for r = 0, max_rank do ranks[r] = ranks[r] or {} end
  -- Order within rank: band, then barycenter of neighbours (a few sweeps).
  local pos = {}
  for r = 0, max_rank do for i, v in ipairs(ranks[r]) do pos[v] = i end end
  local nbrs = {}
  for _, v in ipairs(g.nodes) do nbrs[v] = {} end
  for _, e in ipairs(g.edges) do
    if nbrs[e.from] and nbrs[e.to] then table.insert(nbrs[e.from], e.to); table.insert(nbrs[e.to], e.from) end
  end
  for sweep = 1, 6 do
    for r = 0, max_rank do
      local row = ranks[r]
      for _, v in ipairs(row) do
        local sum, n = 0, 0
        for _, u in ipairs(nbrs[v]) do
          if (sweep % 2 == 1 and u.rank < r) or (sweep % 2 == 0 and u.rank > r) then sum, n = sum + pos[u], n + 1 end
        end
        v.bary = n > 0 and sum / n or pos[v]
      end
      table.sort(row, function(a, b)
        if a.band ~= b.band then return a.band < b.band end
        if a.bary ~= b.bary then return a.bary < b.bary end
        return a.index < b.index
      end)
      for i, v in ipairs(row) do pos[v] = i end
    end
  end
  -- Sizes along the main axis (rank direction) and cross axis.
  local function main(v) return horizontal and v.w or v.h end
  local function cross(v) return horizontal and v.h or v.w end
  -- Rank gap fits the biggest edge label.
  local label_main = 0
  for _, e in ipairs(g.edges) do
    if e.label then
      e.lines, e.lw = wrap(e.label, f, 140 * SCALE)
      label_main = math.max(label_main, horizontal and e.lw or #e.lines * lh)
    end
  end
  local nodesep = math.floor(28 * SCALE * fs)
  local ranksep = math.max(math.floor(44 * SCALE * fs), label_main + pad * 3)
  local depth_pad = #g.clusters > 0 and lh + pad * 2 or 0
  local main_at, cursor = {}, depth_pad
  for r = 0, max_rank do
    local size = 0; for _, v in ipairs(ranks[r]) do size = math.max(size, main(v)) end
    main_at[r] = cursor + size / 2; cursor = cursor + size + ranksep
  end
  local main_total = cursor - ranksep + depth_pad
  local cluster_pad = pad * 1.6
  for _, u in ipairs(units) do
    u.r1, u.r2, u.rows, u.width = math.huge, -math.huge, {}, 0
    for _, v in ipairs(u.nodes) do
      u.r1, u.r2 = math.min(u.r1, v.rank), math.max(u.r2, v.rank)
      u.rows[v.rank] = u.rows[v.rank] or {}; table.insert(u.rows[v.rank], v)
    end
    for _, row in pairs(u.rows) do
      table.sort(row, function(a, b) return pos[a] < pos[b] end)
      local w = 0; for _, v in ipairs(row) do w = w + cross(v) end
      u.width = math.max(u.width, w + (#row - 1) * nodesep)
    end
    u.margin = u.cluster and cluster_pad * 2 or 0
    if u.cluster then u.width = math.max(u.width, f:get_width(u.cluster.label or "") + pad * 2 - u.margin) end
    u.full = u.width + u.margin
  end
  -- Pack units along the cross axis; units only collide when their rank ranges overlap.
  local order = {}
  for _, u in ipairs(units) do order[#order + 1] = u end
  table.sort(order, function(a, b)
    if (a.cluster ~= nil) ~= (b.cluster ~= nil) then return a.cluster ~= nil end
    local pa, pb = pos[a.nodes[1]], pos[b.nodes[1]]
    if pa ~= pb then return pa < pb end
    return a.nodes[1].index < b.nodes[1].index
  end)
  local placed, bandsep, cross_total = {}, nodesep * 1.5, 0
  for _, u in ipairs(order) do
    local candidates = {0}
    for _, q in ipairs(placed) do if q.r1 <= u.r2 and u.r1 <= q.r2 then candidates[#candidates + 1] = q.off + q.full + bandsep end end
    table.sort(candidates)
    for _, c in ipairs(candidates) do
      local free = true
      for _, q in ipairs(placed) do
        if q.r1 <= u.r2 and u.r1 <= q.r2 and c < q.off + q.full + bandsep and q.off < c + u.full + bandsep then free = false; break end
      end
      if free then u.off = c; break end
    end
    placed[#placed + 1] = u
    cross_total = math.max(cross_total, u.off + u.full)
    for _, row in pairs(u.rows) do
      local w = 0; for _, v in ipairs(row) do w = w + cross(v) end
      local c = u.off + u.margin / 2 + (u.width - (w + (#row - 1) * nodesep)) / 2
      for _, v in ipairs(row) do v.cross = c + cross(v) / 2; c = c + cross(v) + nodesep end
    end
  end
  local flip = g.dir == "BT" or g.dir == "RL"
  for _, v in ipairs(g.nodes) do
    local m = main_at[v.rank]; if flip then m = main_total - m end
    local cx, cy = horizontal and m or v.cross, horizontal and v.cross or m
    v.x, v.y = cx - v.w / 2, cy - v.h / 2
  end
  local W, H = horizontal and main_total or cross_total, horizontal and cross_total or main_total
  -- Cluster boxes: bounds of descendant nodes.
  for _, c in ipairs(g.clusters) do
    local x1, y1, x2, y2 = math.huge, math.huge, -math.huge, -math.huge
    for _, v in ipairs(g.nodes) do
      local p = v.cluster
      while p and p ~= c do p = p.parent end
      if p then x1, y1, x2, y2 = math.min(x1, v.x), math.min(y1, v.y), math.max(x2, v.x + v.w), math.max(y2, v.y + v.h) end
    end
    local depth = 0; local p = c.parent; while p do depth = depth + 1; p = p.parent end
    local inset = cluster_pad - depth * pad * 0.5
    if x1 < math.huge then
      c.x, c.y, c.w, c.h = x1 - inset, y1 - inset - lh, x2 - x1 + inset * 2, y2 - y1 + inset * 2 + lh
      c.x = math.max(0, c.x); c.y = math.max(0, c.y)
      c.w = math.max(c.w, f:get_width(c.label or "") + pad * 2)
      W, H = math.max(W, c.x + c.w), math.max(H, c.y + c.h)
    end
  end
  -- Edge routes: orthogonal elbows between rank gaps; endpoints spread per side.
  local slots = {}
  local function slot(v, side, e) slots[v] = slots[v] or {}; slots[v][side] = slots[v][side] or {}; table.insert(slots[v][side], e) end
  for _, e in ipairs(g.edges) do
    if e.from.x and e.to.x then
      local forward = e.to.rank > e.from.rank
      if e.to.rank == e.from.rank then e.kind = "same" else e.kind = forward and "fwd" or "back" end
      if e.kind ~= "same" then slot(e.from, forward and "out" or "in", e); slot(e.to, forward and "in" or "out", e) end
    end
  end
  for v, sides in pairs(slots) do
    for side, list in pairs(sides) do
      table.sort(list, function(a, b)
        local oa, ob = a.from == v and a.to or a.from, b.from == v and b.to or b.from
        return (oa.cross or 0) < (ob.cross or 0)
      end)
      local spread = math.min(14 * SCALE, cross(v) / (#list + 1))
      for i, e in ipairs(list) do e[(e.from == v and "a" or "b") .. "off"] = (i - (#list + 1) / 2) * spread end
    end
  end
  for _, e in ipairs(g.edges) do
    if e.kind then
      local a, b = e.from, e.to
      local function point(v, cross_off, main_side) -- main_side: -1 start of node, +1 end
        local cx, cy = v.x + v.w / 2, v.y + v.h / 2
        if horizontal then return cx + main_side * v.w / 2, cy + cross_off end
        return cx + cross_off, cy + main_side * v.h / 2
      end
      local dir = flip and -1 or 1
      local pts
      if e.kind == "same" then
        local side = (b.cross > a.cross) and 1 or -1
        if horizontal then pts = {{a.x + a.w / 2, side > 0 and a.y + a.h or a.y}, {b.x + b.w / 2, side > 0 and b.y or b.y + b.h}}
        else pts = {{side > 0 and a.x + a.w or a.x, a.y + a.h / 2}, {side > 0 and b.x or b.x + b.w, b.y + b.h / 2}} end
        if horizontal then pts = {pts[1], {pts[1][1], (pts[1][2] + pts[2][2]) / 2}, {pts[2][1], (pts[1][2] + pts[2][2]) / 2}, pts[2]}
        else pts = {pts[1], {(pts[1][1] + pts[2][1]) / 2, pts[1][2]}, {(pts[1][1] + pts[2][1]) / 2, pts[2][2]}, pts[2]} end
      else
        local s = e.kind == "fwd" and dir or -dir
        local x1, y1 = point(a, e.aoff or 0, s)
        local x2, y2 = point(b, e.boff or 0, -s)
        -- ponytail: long edges bend in the gap before the target and may cross
        -- nodes in between; add dummy nodes per rank if that gets noisy.
        if horizontal then
          local mx = x2 - s * ranksep / 2
          pts = {{x1, y1}, {mx, y1}, {mx, y2}, {x2, y2}}
        else
          local my = y2 - s * ranksep / 2
          pts = {{x1, y1}, {x1, my}, {x2, my}, {x2, y2}}
        end
      end
      e.pts = pts
      if e.label then
        local p, q = pts[2], pts[3]
        e.lx, e.ly = (p[1] + q[1]) / 2, (p[2] + q[2]) / 2
      end
    end
  end
  -- ponytail: greedy nudge so labels don't sit on nodes or each other.
  local boxes = {}
  for _, v in ipairs(g.nodes) do boxes[#boxes + 1] = {v.x, v.y, v.w, v.h} end
  local function hits(x, y, w, h)
    for _, b in ipairs(boxes) do
      if x < b[1] + b[3] and b[1] < x + w and y < b[2] + b[4] and b[2] < y + h then return true end
    end
  end
  for _, e in ipairs(g.edges) do
    if e.lx then
      local h = #e.lines * lh + 4 * SCALE
      for _ = 1, 12 do
        if not hits(e.lx - e.lw / 2 - 4 * SCALE, e.ly - h / 2, e.lw + 8 * SCALE, h) then break end
        e.ly = e.ly + h * 0.6
      end
      boxes[#boxes + 1] = {e.lx - e.lw / 2 - 4 * SCALE, e.ly - h / 2, e.lw + 8 * SCALE, h}
      H = math.max(H, e.ly + h / 2)
    end
  end
  return {w = W + 2, h = H + 2, draw = function(ox, oy)
    local edge_color, t = style.text, math.max(1, math.floor(1.5 * SCALE))
    for _, c in ipairs(g.clusters) do
      if c.x then
        renderer.draw_rect(ox + c.x, oy + c.y, c.w, c.h, style.divider)
        renderer.draw_rect(ox + c.x + 1, oy + c.y + 1, c.w - 2, c.h - 2, tint(style.background2, 255))
        renderer.draw_rect(ox + c.x + 1, oy + c.y + 1, c.w - 2, c.h - 2, tint(style.modified, 10))
        renderer.draw_text(f, c.label or "", ox + c.x + pad, oy + c.y + pad * 0.4, style.dim)
      end
    end
    for _, e in ipairs(g.edges) do
      if e.pts then
        local c = e.thick and style.syntax.normal or edge_color
        local w = e.thick and t * 2 or t
        for k = 1, #e.pts - 1 do
          local p, q = e.pts[k], e.pts[k + 1]
          seg(ox + p[1], oy + p[2], ox + q[1], oy + q[2], w, c, e.dotted)
        end
        local function head(p, q)
          local dir = q[1] > p[1] and "right" or q[1] < p[1] and "left" or q[2] > p[2] and "down" or "up"
          arrowhead(ox + q[1], oy + q[2], dir, math.floor(7 * SCALE), c)
        end
        if e.head then head(e.pts[#e.pts - 1], e.pts[#e.pts]) end
        if e.tail then head(e.pts[2], e.pts[1]) end
      end
    end
    for _, v in ipairs(g.nodes) do
      local x, y = ox + v.x, oy + v.y
      if v.shape == "start" then fill("circle", x, y, v.w, v.h, style.syntax.normal)
      elseif v.shape == "end" then fill("circle", x, y, v.w, v.h, style.syntax.normal); fill("circle", x + 3 * SCALE, y + 3 * SCALE, v.w - 6 * SCALE, v.h - 6 * SCALE, style.background); fill("circle", x + 5 * SCALE, y + 5 * SCALE, v.w - 10 * SCALE, v.h - 10 * SCALE, style.syntax.normal)
      elseif v.shape == "bar" then renderer.draw_rect(x, y, v.w, v.h, style.syntax.normal)
      else
        shape_box(v.shape, x, y, v.w, v.h, tint(style.modified, 200), style.background3)
        if v.shape == "cyl" then renderer.draw_rect(x + 4 * SCALE, y + 6 * SCALE, v.w - 8 * SCALE, math.max(1, SCALE), tint(style.modified, 120)) end
        draw_lines(v.lines, f, x + v.w / 2, y + (v.h - #v.lines * lh) / 2, style.syntax.normal)
      end
    end
    for _, e in ipairs(g.edges) do
      if e.lines then
        local h = #e.lines * lh
        renderer.draw_rect(ox + e.lx - e.lw / 2 - 4 * SCALE, oy + e.ly - h / 2 - 2 * SCALE, e.lw + 8 * SCALE, h + 4 * SCALE, style.background)
        draw_lines(e.lines, f, ox + e.lx, oy + e.ly - h / 2, style.text)
      end
    end
  end}
end

---------------------------------------------------------------- sequence
local function sequence(lines, fs, maxw)
  local f = font_at(fs)
  local lh, pad = f:get_height(), math.floor(10 * SCALE * fs)
  local parts, by_id, events, autonumber = {}, {}, {}, false
  local function part(id, label)
    if not by_id[id] then
      by_id[id] = {id = id, label = id, index = #parts + 1}; parts[#parts + 1] = by_id[id]
    end
    if label then by_id[id].label = label end
    return by_id[id]
  end
  for _, raw in ipairs(lines) do
    local line = raw:gsub("%%%%.*$", ""):match("^%s*(.-)%s*$")
    local kw = line:match("^(%a+)")
    if line == "" or line:match("^sequenceDiagram") or kw == "activate" or kw == "deactivate" or kw == "title" then
    elseif kw == "autonumber" then autonumber = true
    elseif kw == "participant" or kw == "actor" then
      local id, label = line:match("^%a+%s+(.-)%s+as%s+(.+)$")
      if id then part(id, label) else part(line:match("^%a+%s+(.+)$")) end
    elseif kw == "Note" or kw == "note" then
      local where, who, text = line:match("^%a+%s+(%a+%s*%a*)%s+([^:]+):%s*(.*)$")
      if where then
        local list = {}
        for id in who:gmatch("[^,]+") do list[#list + 1] = part(id:match("^%s*(.-)%s*$")) end
        events[#events + 1] = {kind = "note", where = where:lower(), parts = list, text = text}
      end
    elseif kw == "loop" or kw == "alt" or kw == "opt" or kw == "par" or kw == "critical" or kw == "break" or kw == "rect" or kw == "box" then
      events[#events + 1] = {kind = "open", label = kw, text = line:match("^%a+%s*(.*)$")}
    elseif kw == "else" or kw == "and" or kw == "option" then
      events[#events + 1] = {kind = "divider", text = line:match("^%a+%s*(.*)$")}
    elseif line == "end" then events[#events + 1] = {kind = "close"}
    else
      local a, arrow, b, text = line:match("^(.-)%s*(<?<?%-%-?>?>?[x%)]?)%s*[%+%-]?%s*([^:]-)%s*:%s*(.*)$")
      if not a or a == "" or b == "" or not arrow:match("%-") then a, arrow, b = line:match("^(.-)%s*(<?<?%-%-?>?>?[x%)]?)%s*[%+%-]?%s*(.-)$"); text = "" end
      if a and a ~= "" and b and b ~= "" and arrow:match("%-") then
        events[#events + 1] = {kind = "msg", from = part(a), to = part(b), text = text, dashed = arrow:match("^<?<?%-%-") ~= nil,
          head = arrow:match(">>") or arrow:match("%)$"), cross = arrow:match("x$")}
      end
    end
  end
  if #parts == 0 then return end
  local n = 0
  for _, p in ipairs(parts) do
    p.lines, p.tw = wrap(p.label, f, 180 * SCALE)
    p.w, p.h = p.tw + pad * 2.4, #p.lines * lh + pad * 1.4
  end
  local header = 0; for _, p in ipairs(parts) do header = math.max(header, p.h) end
  -- Column spacing: boxes, then message/note text constraints.
  local x = {}
  x[1] = parts[1].w / 2 + pad
  for i = 2, #parts do x[i] = x[i - 1] + parts[i - 1].w / 2 + parts[i].w / 2 + pad * 3 end
  local constraints = {}
  for _, e in ipairs(events) do
    if e.kind == "msg" then
      n = n + 1
      e.lines, e.tw = wrap((autonumber and n .. ". " or "") .. e.text, f, 260 * SCALE)
      local i, j = math.min(e.from.index, e.to.index), math.max(e.from.index, e.to.index)
      if i == j then
        if j < #parts then constraints[#constraints + 1] = {i, j + 1, e.tw + pad * 5} end
      else constraints[#constraints + 1] = {i, j, e.tw + pad * 3} end
    elseif e.kind == "note" then
      e.lines, e.tw = wrap(e.text, f, 240 * SCALE)
      local i = e.parts[1].index
      if e.where:match("right") and i < #parts then constraints[#constraints + 1] = {i, i + 1, e.tw + pad * 4}
      elseif e.where:match("left") and i > 1 then constraints[#constraints + 1] = {i - 1, i, e.tw + pad * 4} end
    elseif e.kind == "open" or e.kind == "divider" then
      e.lines = wrap(e.text or "", f, 400 * SCALE)
    end
  end
  table.sort(constraints, function(a, b) return a[2] < b[2] end)
  for _, c in ipairs(constraints) do
    local deficit = c[3] - (x[c[2]] - x[c[1]])
    if deficit > 0 then for k = c[2], #parts do x[k] = x[k] + deficit end end
  end
  local W = x[#parts] + parts[#parts].w / 2 + pad
  for _, e in ipairs(events) do
    if e.kind == "note" then
      local i = e.parts[1].index
      if e.where:match("right") then W = math.max(W, x[i] + e.tw + pad * 4)
      elseif e.where:match("left") then e.shift = math.max(0, e.tw + pad * 4 - x[i]) end
    end
  end
  local shift = 0; for _, e in ipairs(events) do shift = math.max(shift, e.shift or 0) end
  for _, e in ipairs(events) do -- notes spanning "over" participants
    if e.kind == "note" and not e.where:match("right") and not e.where:match("left") then
      local a, b = x[e.parts[1].index], x[e.parts[#e.parts].index]
      local w = math.max(e.tw + pad * 2, math.abs(b - a) + pad * 3)
      local mid = (a + b) / 2
      shift = math.max(shift, w / 2 - mid + 2)
      W = math.max(W, mid + w / 2 + 2)
    end
  end
  for i = 1, #parts do x[i] = x[i] + shift end
  W = W + shift
  -- Rows.
  local y, frames, open = header + pad * 1.5, {}, {}
  for _, e in ipairs(events) do
    if e.kind == "msg" then
      e.y = y + #e.lines * lh + 4 * SCALE
      y = e.y + (e.from == e.to and 22 * SCALE or 0) + pad * 1.4
    elseif e.kind == "note" then
      e.y, e.h = y, #e.lines * lh + pad
      y = y + e.h + pad
    elseif e.kind == "open" then
      local fr = {label = e.label, lines = e.lines, y = y, depth = #open, dividers = {}}
      frames[#frames + 1] = fr; open[#open + 1] = fr
      y = y + lh * math.max(1, #e.lines) + pad
    elseif e.kind == "divider" and #open > 0 then
      table.insert(open[#open].dividers, {y = y, lines = e.lines}); y = y + lh + pad
    elseif e.kind == "close" and #open > 0 then
      open[#open].bottom = y; open[#open] = nil; y = y + pad * 0.6
    end
  end
  for _, fr in ipairs(open) do fr.bottom = y end
  local H = y + pad
  return {w = W, h = H, draw = function(ox, oy)
    local t = math.max(1, math.floor(1.5 * SCALE))
    for _, fr in ipairs(frames) do
      local inset = fr.depth * 6 * SCALE
      local fx, fy, fw, fh = ox + inset + 2, oy + fr.y, W - inset * 2 - 4, fr.bottom - fr.y
      if fr.label == "rect" or fr.label == "box" then renderer.draw_rect(fx, fy, fw, fh, tint(style.modified, 14))
      else
        seg(fx, fy, fx + fw, fy, t, style.divider); seg(fx, fy + fh, fx + fw, fy + fh, t, style.divider)
        seg(fx, fy, fx, fy + fh, t, style.divider); seg(fx + fw, fy, fx + fw, fy + fh, t, style.divider)
        local tw = f:get_width(fr.label) + pad * 1.4
        renderer.draw_rect(fx, fy, tw, lh + pad * 0.4, style.divider)
        renderer.draw_text(f, fr.label, fx + pad * 0.7, fy + pad * 0.2, style.syntax.normal)
        if fr.lines[1] and fr.lines[1] ~= "" then renderer.draw_text(f, "[" .. table.concat(fr.lines, " ") .. "]", fx + tw + pad * 0.6, fy + pad * 0.2, style.dim) end
        for _, d in ipairs(fr.dividers) do
          seg(fx, oy + d.y, fx + fw, oy + d.y, t, style.divider, true)
          if d.lines[1] and d.lines[1] ~= "" then renderer.draw_text(f, "[" .. table.concat(d.lines, " ") .. "]", fx + pad * 0.7, oy + d.y + pad * 0.3, style.dim) end
        end
      end
    end
    for i, p in ipairs(parts) do
      seg(ox + x[i], oy + p.h, ox + x[i], oy + H, t, style.divider, true)
      shape_box("round", ox + x[i] - p.w / 2, oy + (header - p.h), p.w, p.h, tint(style.modified, 200), style.background3)
      draw_lines(p.lines, f, ox + x[i], oy + header - p.h + (p.h - #p.lines * lh) / 2, style.syntax.normal)
    end
    for _, e in ipairs(events) do
      if e.kind == "msg" then
        local x1, x2, ly = ox + x[e.from.index], ox + x[e.to.index], oy + e.y
        local c = style.text
        if e.from == e.to then
          local lx = x1 + 30 * SCALE
          seg(x1, ly, lx, ly, t, c, e.dashed); seg(lx, ly, lx, ly + 22 * SCALE, t, c, e.dashed); seg(x1, ly + 22 * SCALE, lx, ly + 22 * SCALE, t, c, e.dashed)
          if e.head then arrowhead(x1, ly + 22 * SCALE, "left", math.floor(7 * SCALE), c) end
          for k, l in ipairs(e.lines) do renderer.draw_text(f, l, x1 + 4 * SCALE, ly - (#e.lines - k + 1) * lh - 2 * SCALE, style.syntax.normal) end
        else
          seg(x1, ly, x2, ly, t, c, e.dashed)
          if e.head then arrowhead(x2, ly, x2 > x1 and "right" or "left", math.floor(7 * SCALE), c) end
          if e.cross then local s = 4 * SCALE; renderer.draw_text(f, "x", x2 - f:get_width("x") / 2 - (x2 > x1 and s or -s), ly - lh / 2, c) end
          draw_lines(e.lines, f, (x1 + x2) / 2, ly - #e.lines * lh - 2 * SCALE, style.syntax.normal)
        end
      elseif e.kind == "note" then
        local i = e.parts[1].index
        local j = e.parts[#e.parts].index
        local w = e.tw + pad * 2
        local nx
        if e.where:match("right") then nx = x[i] + pad
        elseif e.where:match("left") then nx = x[i] - pad - w
        else
          local span = math.abs(x[j] - x[i])
          w = math.max(w, span + pad * 3); nx = math.min(x[i], x[j]) + span / 2 - w / 2
        end
        renderer.draw_rect(ox + nx, oy + e.y, w, e.h, tint(style.warn, 90))
        renderer.draw_rect(ox + nx + 1, oy + e.y + 1, w - 2, e.h - 2, tint(style.background3, 255))
        renderer.draw_rect(ox + nx + 1, oy + e.y + 1, w - 2, e.h - 2, tint(style.warn, 28))
        draw_lines(e.lines, f, ox + nx + w / 2, oy + e.y + pad / 2, style.syntax.normal)
      end
    end
  end}
end

---------------------------------------------------------------- entry
-- Returns {w, h, draw(x, y)} or nil when the diagram type is unsupported.
function M.render(lines, maxw)
  local kind
  for _, l in ipairs(lines) do
    local word = l:match("^%s*(%S+)")
    if word and not word:match("^%%%%") and word ~= "---" then kind = word; break end
  end
  local build
  if kind == "flowchart" or kind == "graph" then
    local g = flow_parse(lines)
    if #g.nodes == 0 then return end
    build = function(fs) return flow_layout(g, fs, maxw) end
  elseif kind == "stateDiagram" or kind == "stateDiagram-v2" then
    local g = state_parse(lines)
    if #g.nodes == 0 then return end
    build = function(fs) return flow_layout(g, fs, maxw) end
  elseif kind == "sequenceDiagram" then
    build = function(fs) return sequence(lines, fs, maxw) end
  else return end
  local result
  for _, fs in ipairs({1, 0.88, 0.76, 0.66}) do
    result = build(fs)
    if not result or result.w <= maxw then break end
  end
  return result
end

M.flow_parse, M.state_parse = flow_parse, state_parse
return M
