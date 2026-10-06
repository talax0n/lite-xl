-- mod-version:4
local core = require "core"
local config = require "core.config"
local common = require "core.common"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local View = require "core.view"
local git = require "plugins.scm.git"
local views = require "plugins.scm.views"
local review = require "plugins.scm.review"

config.plugins.scm = common.merge({width = 320, refresh_interval = 5, fetch_interval = 180, discovery_depth = 3, discovery_limit = 100, show_checkpoints = false}, config.plugins.scm)
local options = config.plugins.scm
local panel, selected_repo, selected_file
local explorer_was_visible
local function set_visible(view, visible)
  view.visible = visible
  local explorer = package.loaded["plugins.treeview"]
  if explorer then
    if visible then explorer_was_visible = explorer.visible; explorer.visible = false
    elseif explorer_was_visible then explorer.visible = true; explorer_was_visible = nil end
  end
  if not visible and core.active_view == view then core.set_active_view(core.root_view:get_primary_node().active_view) end
  core.redraw = true
end
local prompt, confirm = views.prompt, views.confirm
local function current()
  if selected_repo then return selected_repo end
  local path = core.active_view.doc and core.active_view.doc.abs_filename
  local best
  for _, repo in ipairs(git.repositories) do
    if path and common.path_belongs_to(path, repo.root) and (not best or #repo.root > #best.root) then best = repo end
  end
  return best or git.repositories[1]
end
local function with_repo(fn)
  local repo = current()
  if repo then fn(repo)
  else core.add_thread(function()
    git.discover()
    local discovered = current()
    if discovered then fn(discovered) else core.error("No Git repository selected. Open a repository folder or use Source Control: Add Repository.") end
  end) end
end
local function operation(repo, label, args, input, done)
  git.enqueue(repo, label, function() return git.git(repo, args, input) end, function(out, err)
    if out then git.refresh(repo); if done then done(out) end end
  end)
end
local function show_output(name, text, actions) return views.open(views.Text(name, text, actions)) end
local function show_git(repo, label, args, input)
  operation(repo, label, args, input, function(out) show_output(label .. ": " .. repo.name, out) end)
end
local function pathargs(entry)
  local args = {entry.path}; if entry.original then args[#args + 1] = entry.original end; return args
end
local function stage(repo, entry)
  local args = {"add", "--"}; for _, path in ipairs(pathargs(entry)) do args[#args + 1] = path end
  operation(repo, "Stage " .. entry.path, args)
end
local function unstage(repo, entry)
  local args = repo.status.head == "(initial)" and {"rm", "--cached", "--"} or {"restore", "--staged", "--"}
  for _, path in ipairs(pathargs(entry)) do args[#args + 1] = path end
  operation(repo, "Unstage " .. entry.path, args)
end
local function discard(repo, entry)
  confirm("Discard changes", "Discard unstaged changes to " .. entry.path .. "? This cannot be undone by Git.", function()
    if entry.untracked then
      git.enqueue(repo, "Discard untracked file", function()
        local path = repo.root .. PATHSEP .. entry.path; local info = system.get_file_info(path)
        if not info or info.type ~= "file" then return nil, "Only individual untracked files can be discarded. Open the folder to review its contents." end
        return os.remove(path)
      end, function(result) if result then git.refresh(repo) end end)
    else operation(repo, "Discard " .. entry.path, {"restore", "--worktree", "--", entry.path}) end
  end)
end
local function diff(repo, entry)
  local args = {"diff", "--no-ext-diff", "--no-textconv", "--unified=3"}
  if entry.staged then args[#args + 1] = "--cached" end
  args[#args + 1] = "--"; args[#args + 1] = entry.path
  git.enqueue(repo, "Review " .. entry.path, function()
    if entry.untracked then
      local fp = io.open(repo.root .. PATHSEP .. entry.path, "rb")
      if not fp then return nil, "Cannot open untracked file. Open its folder to select an individual file." end
      local content = fp:read(1024 * 1024 + 1); fp:close()
      if #content > 1024 * 1024 then return nil, "File exceeds 1 MiB preview limit" end
      if content:find("\0", 1, true) then return "Binary file. Stage it with the file action." end
      -- Shown as an all-added diff so it renders like other changes.
      local lines = {}; for line in content:gmatch("([^\n]*)\n?") do lines[#lines + 1] = "+" .. line end
      if lines[#lines] == "+" then lines[#lines] = nil end
      return "diff --git a/" .. entry.path .. " b/" .. entry.path .. "\nnew file mode 100644\n@@ -0,0 +1," .. #lines .. " @@\n" .. table.concat(lines, "\n")
    end
    return git.git(repo, args)
  end, function(out)
    if not out then return end
    local actions = {
      {text = entry.staged and "Unstage file" or "Stage file", fn = function() if entry.staged then unstage(repo, entry) else stage(repo, entry) end end},
      {text = "Open file", fn = function() core.root_view:open_doc(core.open_doc(repo.root .. PATHSEP .. entry.path)) end},
    }
    if not entry.untracked and not entry.submodule and entry.status ~= "!" then
      actions[#actions + 1] = {text = entry.staged and "Unstage hunk" or "Stage hunk", fn = function(view)
        local hunk = view.hunks[view.hunk]
        if not hunk then core.error("Click a diff hunk first"); return end
        local apply = {"apply", "--cached", "--unidiff-zero", "-"}
        if entry.staged then table.insert(apply, 2, "--reverse") end
        operation(repo, entry.staged and "Unstage hunk" or "Stage hunk", apply, hunk.patch, function() diff(repo, entry) end)
      end}
    end
    if not entry.staged then actions[#actions + 1] = {text = "Discard", fn = function() discard(repo, entry) end} end
    show_output((entry.staged and "Staged: " or "Changes: ") .. entry.path, out ~= "" and out or "No text diff. This may be a binary file or submodule.", actions)
  end)
end
local function commit_actions(repo)
  return function(hash) return {
    {text = "Copy hash", fn = function() system.set_clipboard(hash) end},
    {text = "Compare with HEAD", fn = function() show_git(repo, "Compare commit", {"diff", "--no-ext-diff", "--no-textconv", hash, "HEAD", "--"}) end},
    {text = "Revert", fn = function()
      confirm("Revert commit", "Create a commit reverting " .. hash:sub(1, 8) .. "?", function() operation(repo, "Revert", {"revert", "--no-edit", hash}) end)
    end},
    {text = "Cherry-pick", fn = function() confirm("Cherry-pick", "Apply " .. hash:sub(1, 8) .. " to the current branch?", function() operation(repo, "Cherry-pick", {"cherry-pick", hash}) end) end},
    {text = "GitHub", fn = function() git.enqueue(repo, "Open commit on GitHub", function() return git.exec(repo.root, "gh", {"browse", hash}) end) end},
  } end
end
local function inspect(repo, commit) review.show_commit(repo, commit.hash, commit_actions(repo)) end
local function history(repo)
  git.history(repo, function() views.open(views.Graph(repo, git, function(commit) inspect(repo, commit) end)) end, true)
end
local function change_count(repo) local s = repo.status; return #s.changes + #s.staged + #s.conflicts end
local function stage_all(repo) operation(repo, "Stage all", {"add", "--all", "--", "."}) end
local function unstage_all(repo)
  if repo.status.head == "(initial)" then operation(repo, "Unstage all", {"rm", "--cached", "-r", "--", "."})
  else operation(repo, "Unstage all", {"restore", "--staged", "--", "."}) end
end

local Sidebar = View:extend()
local collapsed = {}
local GRAPH_ROWS = 20
local lane_colors = {{115, 175, 245}, {230, 150, 100}, {145, 200, 120}, {190, 135, 220}, {220, 195, 100}, {100, 200, 200}}
function Sidebar:new()
  Sidebar.super.new(self); self.visible = true; self.scrollable = true; self.rows = {}; self.height = 0; self.generation = -1; self.size.x = options.width * SCALE
end
function Sidebar:get_name() return "Source Control" end
function Sidebar:get_size() return self.visible and options.width * SCALE or 0, 0 end
function Sidebar:set_target_size(axis, width)
  if axis == "x" then options.width = math.max(200, width / SCALE); core.redraw = true; return true end
end
local function lh() return style.font:get_height() + style.padding.y end
local function header_h() return math.floor(lh() * 1.5) end
function Sidebar:get_scrollable_size() return header_h() + self.height + lh() * 2 end
function Sidebar:get_h_scrollable_size() return self.size.x end
function Sidebar:on_mouse_wheel(y) self.scroll.to.y = self.scroll.to.y - y * lh() * 3; return true end
function Sidebar:rebuild()
  local rows, repo = {}, current()
  self.generation, self.repo = git.generation, repo
  local function add(row) row.h = row.h or lh(); rows[#rows + 1] = row end
  add({kind = "section", key = "repos", text = "REPOSITORIES"})
  if not collapsed.repos then
    for _, r in ipairs(git.repositories) do add({kind = "repo", repo = r}) end
    if #git.repositories == 0 then add({kind = "note", text = git.discovering and "Discovering repositories..." or "Use … to add or clone a repository"}) end
  end
  if repo then
    local status = repo.status
    add({kind = "section", key = "changes", text = "CHANGES"})
    if not collapsed.changes then
      add({kind = "message", repo = repo, h = math.floor(lh() * 1.6)})
      add({kind = "commit", repo = repo, h = math.floor(lh() * 1.7)})
      if (status.ahead or 0) > 0 then
        add({kind = "more", repo = repo, action = "scm:review", text = "Review " .. status.ahead .. " unpushed commit" .. (status.ahead == 1 and "" or "s")})
      end
      if status.limited then add({kind = "note", color = style.error, text = "Preview limited to 10,000 files. Use terminal for more."}) end
      if repo.busy then add({kind = "note", text = repo.busy .. "..."}) end
      if repo.error then add({kind = "note", color = style.error, text = repo.error:match("[^\r\n]+") or repo.error}) end
      for _, group in ipairs({{"Merge Changes", status.conflicts}, {"Staged Changes", status.staged, true}, {"Changes", status.changes}}) do
        if #group[2] > 0 then
          local key = repo.root .. ":" .. group[1]
          add({kind = "group", repo = repo, key = key, text = group[1], count = #group[2], staged = group[3]})
          if not collapsed[key] then for _, entry in ipairs(group[2]) do add({kind = "file", repo = repo, entry = entry}) end end
        end
      end
      if change_count(repo) == 0 and not repo.busy then add({kind = "note", text = "No changes"}) end
    end
    add({kind = "section", key = "graph", text = "GRAPH", actions = {
      {"↓", function() operation(repo, "Pull", {"pull", "--ff-only"}) end},
      {"↑", function() operation(repo, "Push", {"push"}) end},
      {"…", function() history(repo) end},
    }})
    if not collapsed.graph then
      if status.head and repo.graph_head ~= status.head and not repo.worker then
        repo.graph_head = status.head; git.history(repo, nil, true)
      end
      for i = 1, math.min(GRAPH_ROWS, #repo.history) do add({kind = "graph", repo = repo, commit = repo.history[i], first = i == 1, last = i == math.min(GRAPH_ROWS, #repo.history)}) end
      if #repo.history > 0 then add({kind = "more", repo = repo, text = "View full graph"}) end
    end
  end
  local y = 0
  for _, row in ipairs(rows) do row.y = y; y = y + row.h end
  self.rows, self.height = rows, y
end
function Sidebar:update()
  local width = self.visible and options.width * SCALE or 0
  if self.size.x ~= width then self.size.x = width; core.redraw = true end
  Sidebar.super.update(self)
  if self.generation ~= git.generation or self.repo ~= current() then self:rebuild() end
end
local function status_color(s)
  if s == "M" or s == "T" then return style.warn end
  if s == "A" or s == "?" then return style.good end
  if s == "D" or s == "!" then return style.error end
  return style.caret
end
local function text_w(font, text) return font:get_width(text) end
-- Draws a clickable glyph right-aligned at `right`; returns its left edge.
function Sidebar:button(row, font, text, right, y, h, fn)
  local w = text_w(font, text) + style.padding.x
  local x = right - w
  local hovered = self.hover_x and self.hover_row == row and self.hover_x >= x and self.hover_x < right
  if hovered then renderer.draw_rect(x, y + 2 * SCALE, w, h - 4 * SCALE, style.line_highlight) end
  common.draw_text(font, hovered and style.accent or style.text, text, "center", x, y, w, h)
  row.buttons[#row.buttons + 1] = {x1 = x, x2 = right, fn = fn}
  return x
end
function Sidebar:draw_row(row, x, y, w)
  local pad, h = style.padding.x, row.h
  local right = x + w - pad
  local hovered = self.hover_row == row
  row.buttons = {}
  if row.kind == "section" then
    common.draw_text(style.icon_font, style.text, collapsed[row.key] and "+" or "-", nil, x + pad * 0.5, y, 0, h)
    common.draw_text(style.font, style.accent, row.text, nil, x + pad * 0.5 + 18 * SCALE, y, 0, h)
    for i = #(row.actions or {}), 1, -1 do right = self:button(row, style.font, row.actions[i][1], right, y, h, row.actions[i][2]) end
  elseif row.kind == "repo" then
    local repo, status = row.repo, row.repo.status
    local selected = repo == self.repo
    if selected then renderer.draw_rect(x, y, w, h, style.selection) elseif hovered then renderer.draw_rect(x, y, w, h, style.line_highlight) end
    right = self:button(row, style.font, "…", right, y, h, function() selected_repo, selected_file = repo, nil; command.perform("scm:actions") end)
    if (status.ahead or 0) + (status.behind or 0) > 0 then
      right = self:button(row, style.font, "↓" .. status.behind .. " ↑" .. status.ahead, right, y, h, function() selected_repo = repo; command.perform("scm:sync") end)
    end
    local branch = (status.branch or "") .. (change_count(repo) > 0 and "*" or "")
    local bw = text_w(style.font, branch)
    right = right - bw - pad * 0.5
    common.draw_text(style.font, style.text, branch, nil, right, y, bw, h)
    local gs = math.floor(14 * SCALE)
    local gx, gy = right - gs - 4 * SCALE, y + (h - gs) / 2
    local t = math.max(1, math.floor(SCALE))
    renderer.draw_rect(gx + gs * 0.3, gy + gs * 0.15, t, gs * 0.7, style.dim)
    renderer.draw_rect(gx + gs * 0.7, gy + gs * 0.15, t, gs * 0.4, style.dim)
    renderer.draw_rect(gx + gs * 0.3, gy + gs * 0.55, gs * 0.4 + t, t, style.dim)
    right = gx - pad * 0.5
    common.draw_text(style.icon_font, selected and style.accent or style.dim, "d", nil, x + pad * 1.5, y, 0, h)
    core.push_clip_rect(x, y, math.max(0, right - x), h)
    common.draw_text(style.font, selected and style.accent or style.text, repo.name, nil, x + pad * 1.5 + 22 * SCALE, y, 0, h)
    core.pop_clip_rect()
  elseif row.kind == "message" then
    local repo = row.repo
    local bx, by, bw, bh = x + pad, y + 3 * SCALE, w - pad * 2, h - 6 * SCALE
    renderer.draw_rect(bx, by, bw, bh, hovered and style.selection or style.line_highlight)
    renderer.draw_rect(bx, by + bh - math.max(1, SCALE), bw, math.max(1, SCALE), hovered and style.caret or style.divider)
    local text = repo.message:match("[^\r\n]*") or ""
    core.push_clip_rect(bx, by, bw, bh)
    common.draw_text(style.font, text ~= "" and style.accent or style.dim, text ~= "" and text or 'Message (Enter to commit on "' .. (repo.status.branch or "HEAD") .. '")', nil, bx + pad * 0.75, by, 0, bh)
    core.pop_clip_rect()
    row.buttons[1] = {x1 = bx, x2 = bx + bw, fn = function() command.perform("scm:commit") end}
  elseif row.kind == "commit" then
    local repo = row.repo
    local bx, by, bw, bh = x + pad, y + 4 * SCALE, w - pad * 2, h - 8 * SCALE
    local enabled = change_count(repo) > 0
    local color = enabled and style.caret or style.selection
    renderer.draw_rect(bx, by, bw, bh, color)
    if hovered and enabled then renderer.draw_rect(bx, by, bw, bh, {255, 255, 255, 30}) end
    local label = #repo.status.staged == 0 and #repo.status.changes > 0 and "Commit All" or "Commit"
    common.draw_text(style.font, enabled and style.background2 or style.dim, label, "center", bx, by, bw, bh)
    row.buttons[1] = {x1 = bx, x2 = bx + bw, fn = function() if enabled then command.perform("scm:commit") end end}
  elseif row.kind == "group" then
    if hovered then renderer.draw_rect(x, y, w, h, style.line_highlight) end
    common.draw_text(style.icon_font, style.text, collapsed[row.key] and "+" or "-", nil, x + pad, y, 0, h)
    common.draw_text(style.font, style.text, row.text, nil, x + pad + 18 * SCALE, y, 0, h)
    local label = tostring(row.count)
    local pw, ph = math.max(lh() * 0.9, text_w(style.font, label) + 10 * SCALE), lh() * 0.8
    renderer.draw_rect(right - pw, y + (h - ph) / 2, pw, ph, style.selection)
    common.draw_text(style.font, style.accent, label, "center", right - pw, y, pw, h)
    right = right - pw - 4 * SCALE
    if hovered and row.text ~= "Merge Changes" then
      local repo = row.repo
      self:button(row, style.font, row.staged and "−" or "+", right, y, h, function() if row.staged then unstage_all(repo) else stage_all(repo) end end)
    end
  elseif row.kind == "file" then
    local entry = row.entry
    if entry == selected_file then renderer.draw_rect(x, y, w, h, style.selection) elseif hovered then renderer.draw_rect(x, y, w, h, style.line_highlight) end
    local letter = entry.status == "?" and "U" or entry.status
    local color = status_color(entry.status)
    local lw = text_w(style.code_font, "M") + pad * 0.5
    common.draw_text(style.code_font, color, letter, "center", right - lw, y, lw, h)
    right = right - lw
    if hovered and entry.status ~= "!" then
      local repo = row.repo
      right = self:button(row, style.font, entry.staged and "−" or "+", right, y, h, function() if entry.staged then unstage(repo, entry) else stage(repo, entry) end end)
      if not entry.staged then right = self:button(row, style.icon_font, "C", right, y, h, function() discard(repo, entry) end) end
    end
    local name = entry.path:match("[^/]+$") or entry.path
    local dir = entry.path:sub(1, #entry.path - #name - 1)
    local fx = x + pad * 2
    core.push_clip_rect(x, y, math.max(0, right - x - 4 * SCALE), h)
    fx = common.draw_text(style.font, entry.status == "D" and style.dim or style.accent, name, nil, fx, y, 0, h)
    if dir ~= "" then common.draw_text(style.font, style.dim, dir, nil, fx + pad * 0.6, y, 0, h) end
    core.pop_clip_rect()
  elseif row.kind == "graph" then
    local c = row.commit
    if hovered then renderer.draw_rect(x, y, w, h, style.line_highlight) end
    local color = lane_colors[((c.lane or 1) - 1) % #lane_colors + 1]
    local cx, t = x + pad * 1.5, math.max(1, math.floor(2 * SCALE))
    renderer.draw_rect(cx - t / 2, row.first and y + h / 2 or y, t, (row.first or row.last) and h / 2 or h, color)
    local d = math.floor(8 * SCALE)
    renderer.draw_rect(cx - d / 2, y + (h - d) / 2, d, d, row.first and style.background2 or color)
    if row.first then
      renderer.draw_rect(cx - d / 2, y + (h - d) / 2, d, t, color); renderer.draw_rect(cx - d / 2, y + (h + d) / 2 - t, d, t, color)
      renderer.draw_rect(cx - d / 2, y + (h - d) / 2, t, d, color); renderer.draw_rect(cx + d / 2 - t, y + (h - d) / 2, t, d, color)
    end
    local ref = c.refs:match("HEAD %-> ([^,]+)") or (c.refs:match("^tag: ([^,]+)"))
    if ref then
      local rw = text_w(style.font, ref) + pad
      renderer.draw_rect(right - rw, y + 3 * SCALE, rw, h - 6 * SCALE, style.selection)
      common.draw_text(style.font, style.accent, ref, "center", right - rw, y, rw, h)
      right = right - rw - 4 * SCALE
    end
    core.push_clip_rect(x, y, math.max(0, right - x), h)
    local sx = cx + pad
    if row.repo.unpushed and row.repo.unpushed[c.hash] then
      local s = math.floor(6 * SCALE); renderer.draw_rect(sx, y + (h - s) / 2, s, s, style.accent); sx = sx + s + pad * 0.5
    end
    local tx = common.draw_text(style.font, row.first and style.accent or style.text, c.subject, nil, sx, y, 0, h)
    common.draw_text(style.font, style.dim, c.author, nil, tx + pad * 0.6, y, 0, h)
    core.pop_clip_rect()
  elseif row.kind == "more" then
    common.draw_text(style.font, hovered and style.accent or style.text, row.text, nil, x + pad * 1.5, y, 0, h)
  else
    core.push_clip_rect(x, y, w, h)
    common.draw_text(style.font, row.color or style.dim, row.text, nil, x + pad * 2, y, 0, h)
    core.pop_clip_rect()
  end
end
function Sidebar:draw()
  if not self.visible then return end
  self:draw_background(style.background2)
  local x, w, top = self.position.x, self.size.x, self.position.y + header_h()
  common.draw_text(style.font, style.text, "SOURCE CONTROL", nil, x + style.padding.x, self.position.y, 0, header_h())
  self.header = {row = {}}; self.header.row.buttons = {}
  self:button(self.header.row, style.font, "…", x + w - style.padding.x, self.position.y, header_h(), function() command.perform("scm:actions") end)
  core.push_clip_rect(x, top, w, self.size.y - header_h())
  local origin = top - self.scroll.y
  for _, row in ipairs(self.rows) do
    local ry = origin + row.y
    if ry > self.position.y + self.size.y then break end
    if ry + row.h >= top then
      if row.kind == "section" and row ~= self.rows[1] then renderer.draw_rect(x, ry, w, math.max(1, SCALE), style.divider) end
      self:draw_row(row, x, ry, w)
    end
  end
  core.pop_clip_rect(); self:draw_scrollbar()
end
function Sidebar:row_at(y)
  local top = self.position.y + header_h()
  if y < top then return end
  local offset = y - top + self.scroll.y
  for _, row in ipairs(self.rows) do if offset >= row.y and offset < row.y + row.h then return row end end
end
function Sidebar:on_mouse_moved(x, y, ...)
  Sidebar.super.on_mouse_moved(self, x, y, ...)
  local row = self:row_at(y)
  if y < self.position.y + header_h() then row = self.header and self.header.row end
  if row ~= self.hover_row or x ~= self.hover_x then self.hover_row, self.hover_x = row, x; core.redraw = true end
end
function Sidebar:on_mouse_left()
  Sidebar.super.on_mouse_left(self); self.hover_row, self.hover_x = nil, nil; core.redraw = true
end
function Sidebar:on_mouse_pressed(button, x, y, clicks)
  if Sidebar.super.on_mouse_pressed(self, button, x, y, clicks) then return true end
  local row = y < self.position.y + header_h() and self.header and self.header.row or self:row_at(y)
  if not row then return true end
  for _, b in ipairs(row.buttons or {}) do if x >= b.x1 and x < b.x2 then b.fn(); return true end end
  if row.kind == "section" or row.kind == "group" then collapsed[row.key] = not collapsed[row.key]; self.generation = -1
  elseif row.kind == "repo" then selected_repo, selected_file = row.repo, nil; if row.repo.dirty or not row.repo.status.head then git.refresh(row.repo) end
  elseif row.kind == "file" then
    selected_repo, selected_file = row.repo, row.entry
    if clicks > 1 then core.root_view:open_doc(core.open_doc(row.repo.root .. PATHSEP .. row.entry.path))
    elseif button == "right" then command.perform("scm:file-actions")
    else diff(row.repo, row.entry) end
  elseif row.kind == "graph" then inspect(row.repo, row.commit)
  elseif row.kind == "more" then if row.action then command.perform(row.action) else history(row.repo) end end
  core.redraw = true
  return true
end
-- Background sync: runs from startup, not only while the panel is open.
-- Every second it checks each repository's .git files for changes made by
-- any tool; status is also refreshed on an interval and on window focus,
-- and remotes are fetched quietly so incoming/outgoing counts stay current.
core.add_thread(function()
  coroutine.yield(1)
  git.discover()
  local index, focused = 0, false
  while true do
    local has_focus = system.window_has_focus(core.window)
    if has_focus and not focused then for _, repo in ipairs(git.repositories) do repo.dirty = true end end
    focused = has_focus
    local now, active = system.get_time(), current()
    for _, repo in ipairs(git.repositories) do
      local signature = git.signature(repo)
      if repo.signature and signature ~= repo.signature then repo.dirty = true end
      repo.signature = signature
    end
    -- In the background, poll slower; .git changes are still caught every second.
    local interval = has_focus and options.refresh_interval or math.max(15, options.refresh_interval * 3)
    if active and not active.worker and (active.dirty or now - active.last_refresh > interval) then git.refresh(active) end
    if #git.repositories > 0 then
      index = index % #git.repositories + 1
      local repo = git.repositories[index]
      if repo ~= active and not repo.worker and (repo.dirty or now - repo.last_refresh > (has_focus and math.max(15, options.refresh_interval * 3) or 30)) then git.refresh(repo) end
    end
    -- Start at most one fetch per tick: the stalest repository with an upstream.
    local stalest
    for _, repo in ipairs(options.fetch_interval > 0 and git.repositories or {}) do
      if repo.status.upstream and not repo.fetching and (not stalest or (repo.last_fetch or 0) < (stalest.last_fetch or 0)) then stalest = repo end
    end
    if stalest and now - (stalest.last_fetch or 0) > options.fetch_interval then git.fetch(stalest) end
    coroutine.yield(1)
  end
end)
local function ensure_panel()
  if panel then return panel end
  panel = Sidebar(); set_visible(panel, true); panel.node = core.root_view:get_primary_node():split("left", panel, {x = true}, true)
  return panel
end
local commands = {
  ["scm:toggle"] = function() local existed = panel; local p = ensure_panel(); if existed then set_visible(p, not p.visible) end; core.redraw = true end,
  ["scm:refresh"] = function() with_repo(git.refresh) end,
  ["scm:add-repository"] = function()
    prompt("Repository folder", function(path) core.add_thread(function() local repo, err = git.add(path); if repo then selected_repo = repo; git.refresh(repo) else core.error("%s", err) end end) end, core.root_project().path)
  end,
  ["scm:scan-repositories"] = function()
    core.add_thread(function()
      git.discover()
      core.log("Tracking %d repositories", #git.repositories)
    end)
  end,
  ["scm:remove-repository"] = function() with_repo(function(repo)
    git.by_root[repo.root] = nil; for i, item in ipairs(git.repositories) do if item == repo then table.remove(git.repositories, i); break end end
    selected_repo, selected_file = nil, nil; git.generation = git.generation + 1; core.redraw = true
  end) end,
  ["scm:select-repository"] = function()
    local roots = {}; for _, repo in ipairs(git.repositories) do roots[#roots + 1] = repo.root end
    prompt("Repository", function(root) selected_repo = git.by_root[root]; selected_file = nil; core.redraw = true end, "", roots)
  end,
  ["scm:clone"] = function() prompt("Clone URL", function(url)
    prompt("Destination folder", function(path)
      core.add_thread(function()
        local out, err = git.exec(core.root_project().path, "git", {"clone", "--", url, path}, nil, 300)
        if out then local repo = git.add(path); if repo then selected_repo = repo; core.add_project(repo.root); git.refresh(repo) end else core.error("%s", err) end
      end)
    end)
  end) end,
  ["scm:init"] = function() prompt("Initialize repository in folder", function(path)
    core.add_thread(function() local out, err = git.git(path, {"init"}); if out then local repo = git.add(path); if repo then selected_repo = repo; git.refresh(repo) end else core.error("%s", err) end end)
  end, core.root_project().path) end,
  ["scm:history"] = function() with_repo(history) end,
  ["scm:toggle-checkpoints"] = function()
    options.show_checkpoints = not options.show_checkpoints
    for _, repo in ipairs(git.repositories) do repo.graph_head = nil; git.history(repo, nil, true) end
    core.log("T3 checkpoints %s in history", options.show_checkpoints and "shown" or "hidden")
  end,
  ["scm:review"] = function() with_repo(function(repo) review.open(repo.root) end) end,
  ["scm:stage-all"] = function() with_repo(stage_all) end,
  ["scm:unstage-all"] = function() with_repo(unstage_all) end,
  ["scm:commit"] = function() with_repo(function(repo)
    if #repo.status.conflicts > 0 then core.error("Resolve and stage conflicts before committing"); return end
    prompt("Commit message", function(message)
      repo.message = message
      if not message:match("%S") then return end
      -- Nothing staged: commit every change, like the "Commit All" button says.
      local all = #repo.status.staged == 0
      git.enqueue(repo, "Commit", function()
        if all then local out, err = git.git(repo, {"add", "--all", "--", "."}); if not out then return nil, err end end
        return git.git(repo, {"commit", "-F", "-"}, message .. "\n")
      end, function(out) git.refresh(repo); if out then repo.message = "" end end)
    end, repo.message)
  end) end,
  ["scm:amend"] = function() with_repo(function(repo)
    confirm("Amend commit", "Rewrite the latest commit on " .. (repo.status.branch or repo.name) .. "?", function()
      prompt("Amended commit message", function(message) if message:match("%S") then operation(repo, "Amend", {"commit", "--amend", "-F", "-"}, message .. "\n") end end, repo.message)
    end)
  end) end,
  ["scm:fetch"] = function() with_repo(function(repo) operation(repo, "Fetch", {"fetch", "--all", "--prune"}) end) end,
  ["scm:pull"] = function() with_repo(function(repo) operation(repo, "Pull", {"pull", "--ff-only"}) end) end,
  ["scm:push"] = function() with_repo(function(repo) operation(repo, "Push", {"push"}) end) end,
  ["scm:push-set-upstream"] = function() with_repo(function(repo)
    prompt("Remote", function(remote) operation(repo, "Push and set upstream", {"push", "--set-upstream", remote, "HEAD"}) end, "origin")
  end) end,
  ["scm:sync"] = function() with_repo(function(repo)
    git.enqueue(repo, "Sync", function() local out, err = git.git(repo, {"pull", "--ff-only"}); if not out then return nil, err end; return git.git(repo, {"push"}) end, function(out) if out then git.refresh(repo) end end)
  end) end,
  ["scm:branch-create"] = function() with_repo(function(repo) prompt("New branch", function(name) operation(repo, "Create branch", {"switch", "-c", name}) end) end) end,
  ["scm:branch-switch"] = function() with_repo(function(repo)
    operation(repo, "List branches", {"for-each-ref", "--format=%(refname:short)", "refs/heads"}, nil, function(out)
      local names = {}; for name in out:gmatch("[^\r\n]+") do names[#names + 1] = name end
      prompt("Switch branch", function(name) operation(repo, "Switch branch", {"switch", name}) end, "", names)
    end)
  end) end,
  ["scm:merge"] = function() with_repo(function(repo) prompt("Branch to merge", function(name) operation(repo, "Merge", {"merge", "--no-edit", name}) end) end) end,
  ["scm:rebase"] = function() with_repo(function(repo) prompt("Rebase onto branch", function(name)
    confirm("Rebase", "Rebase the current branch onto " .. name .. "? This rewrites local commits.", function() operation(repo, "Rebase", {"rebase", name}) end)
  end) end) end,
  ["scm:abort-merge"] = function() with_repo(function(repo) operation(repo, "Abort merge", {"merge", "--abort"}) end) end,
  ["scm:continue-rebase"] = function() with_repo(function(repo) operation(repo, "Continue rebase", {"-c", "core.editor=true", "rebase", "--continue"}) end) end,
  ["scm:abort-rebase"] = function() with_repo(function(repo) operation(repo, "Abort rebase", {"rebase", "--abort"}) end) end,
  ["scm:stash"] = function() with_repo(function(repo) prompt("Stash description", function(text) operation(repo, "Stash", {"stash", "push", "--include-untracked", "-m", text}) end, "Lite XL stash") end) end,
  ["scm:stash-list"] = function() with_repo(function(repo)
    operation(repo, "List stashes", {"stash", "list", "--format=%gd %s"}, nil, function(out)
      local rows = {}; for line in out:gmatch("[^\r\n]+") do rows[#rows + 1] = line end
      views.open(views.List("Stashes: " .. repo.name, rows, function(row)
        local ref = row:match("^%S+")
        prompt("Stash action", function(action)
          if action == "Show" then show_git(repo, "Stash diff", {"stash", "show", "--patch", ref})
          elseif action == "Apply" then operation(repo, "Apply stash", {"stash", "apply", ref})
          elseif action == "Pop" then operation(repo, "Pop stash", {"stash", "pop", ref})
          elseif action == "Drop" then confirm("Drop stash", "Delete " .. ref .. "?", function() operation(repo, "Drop stash", {"stash", "drop", ref}) end) end
        end, "", {"Show", "Apply", "Pop", "Drop"})
      end))
    end)
  end) end,
  ["scm:tag"] = function() with_repo(function(repo) prompt("Tag name", function(name) operation(repo, "Create tag", {"tag", name}) end) end) end,
  ["scm:push-tags"] = function() with_repo(function(repo) operation(repo, "Push tags", {"push", "--tags"}) end) end,
  ["scm:remotes"] = function() with_repo(function(repo) show_git(repo, "Remotes", {"remote", "-v"}) end) end,
  ["scm:remote-add"] = function() with_repo(function(repo) prompt("Remote name", function(name) prompt("Remote URL", function(url) operation(repo, "Add remote", {"remote", "add", name, url}) end) end, "origin") end) end,
  ["scm:worktrees"] = function() with_repo(function(repo) show_git(repo, "Worktrees", {"worktree", "list"}) end) end,
  ["scm:worktree-add"] = function() with_repo(function(repo) prompt("Worktree folder", function(path) prompt("Existing branch", function(branch)
    operation(repo, "Add worktree", {"worktree", "add", path, branch}, nil, function() local target = system.absolute_path(path) or repo.root .. PATHSEP .. path; core.add_thread(function() local added = git.add(target); if added then core.add_project(added.root); git.refresh(added) end end) end)
  end) end) end) end,
  ["scm:terminal"] = function() with_repo(function(repo) require("plugins.terminal").open(repo.root) end) end,
  ["scm:file-history"] = function() with_repo(function(repo)
    if selected_file then show_git(repo, "File history", {"log", "--follow", "--max-count=100", "--patch", "--", selected_file.path}) end
  end) end,
  ["scm:file-actions"] = function() with_repo(function(repo)
    local entry = selected_file; if not entry then return end
    prompt(entry.path, function(action)
      if action == "Review diff" then diff(repo, entry)
      elseif action == "Stage" then stage(repo, entry)
      elseif action == "Unstage" then unstage(repo, entry)
      elseif action == "Discard" then discard(repo, entry)
      elseif action == "Open file" then core.root_view:open_doc(core.open_doc(repo.root .. PATHSEP .. entry.path))
      elseif action == "History" then show_git(repo, "File history", {"log", "--follow", "--max-count=100", "--patch", "--", entry.path})
      elseif action == "Conflict base" then show_git(repo, "Conflict base", {"show", ":1:" .. entry.path})
      elseif action == "Conflict current" then show_git(repo, "Conflict current", {"show", ":2:" .. entry.path})
      elseif action == "Conflict incoming" then show_git(repo, "Conflict incoming", {"show", ":3:" .. entry.path})
      elseif action == "Use current" or action == "Use incoming" then
        confirm("Resolve conflict", "Replace " .. entry.path .. " with the " .. (action == "Use current" and "current" or "incoming") .. " version? Review and stage it afterwards.", function()
          operation(repo, "Resolve conflict", {"checkout", action == "Use current" and "--ours" or "--theirs", "--", entry.path})
        end)
      end
    end, "", entry.status == "!" and {"Open file", "Conflict base", "Conflict current", "Conflict incoming", "Use current", "Use incoming", "Stage"} or {"Review diff", "Stage", "Unstage", "Open file", "Discard", "History"})
  end) end,
}
local function gh(repo, label, args, done)
  git.enqueue(repo, label, function()
    local out, err = git.exec(repo.root, "gh", args)
    if out then return out .. (err and err ~= "" and "\n" .. err or "") end
    return nil, err
  end, function(out, err)
    if out then if done then done(out) elseif out ~= "" then show_output(label, out) end
    elseif args[1] == "pr" and args[2] == "checks" then show_output(label, err or "No check results") end
  end)
end
commands["github:sign-in"] = function() require("plugins.terminal").open(core.root_project().path, git.executable("gh"), {"auth", "login", "--web", "--git-protocol", "https"}) end
commands["github:auth-status"] = function() with_repo(function(repo) gh(repo, "GitHub authentication", {"auth", "status"}) end) end
commands["github:open-repository"] = function() with_repo(function(repo) gh(repo, "Open GitHub repository", {"browse"}) end) end
commands["github:publish"] = function() with_repo(function(repo)
  prompt("GitHub repository name", function(name)
    prompt("Visibility", function(visibility)
      if visibility ~= "private" and visibility ~= "public" then core.error("Choose private or public"); return end
      confirm("Publish repository", "Create " .. visibility .. " GitHub repository " .. name .. " and push the current branch?", function()
        gh(repo, "Publish to GitHub", {"repo", "create", name, "--" .. visibility, "--source", ".", "--remote", "origin", "--push"}, function(out) git.refresh(repo); show_output("Published to GitHub", out) end)
      end)
    end, "private", {"private", "public"})
  end, repo.name)
end) end
commands["github:pull-requests"] = function() with_repo(function(repo)
  gh(repo, "GitHub pull requests", {"pr", "list", "--limit", "50", "--json", "number,title,headRefName", "--template", '{{range .}}{{.number}}\t{{.title}}\t{{.headRefName}}{{"\n"}}{{end}}'}, function(out)
    local rows = {}; for line in out:gmatch("[^\n]+") do rows[#rows + 1] = line end
    views.open(views.List("Pull requests: " .. repo.name, rows, function(row)
      local number = row:match("^(%d+)")
      if not number then return end
      prompt("Pull request #" .. number, function(action)
        if action == "Details" then gh(repo, "Pull request #" .. number, {"pr", "view", number})
        elseif action == "Diff" then gh(repo, "Pull request diff", {"pr", "diff", number})
        elseif action == "Checks" then gh(repo, "Pull request checks", {"pr", "checks", number})
        elseif action == "Open on GitHub" then gh(repo, "Open pull request", {"pr", "view", number, "--web"})
        elseif action == "Checkout" then gh(repo, "Checkout pull request", {"pr", "checkout", number}, function() git.refresh(repo) end)
        elseif action == "Review" then prompt("Review action", function(review)
          local flag = review == "Approve" and "--approve" or review == "Request changes" and "--request-changes" or "--comment"
          prompt("Review comment", function(body) gh(repo, "Submit review", {"pr", "review", number, flag, "--body", body}) end)
        end, "", {"Comment", "Approve", "Request changes"}) end
      end, "", {"Details", "Diff", "Checks", "Checkout", "Open on GitHub", "Review"})
    end))
  end)
end) end
commands["github:create-pull-request"] = function() with_repo(function(repo)
  prompt("Pull request title", function(title) prompt("Pull request description", function(body)
    gh(repo, "Create pull request", {"pr", "create", "--title", title, "--body", body})
  end) end)
end) end
commands["github:issues"] = function() with_repo(function(repo)
  gh(repo, "GitHub issues", {"issue", "list", "--limit", "50", "--json", "number,title", "--template", '{{range .}}{{.number}}\t{{.title}}{{"\n"}}{{end}}'}, function(out)
    local rows = {}; for line in out:gmatch("[^\n]+") do rows[#rows + 1] = line end
    views.open(views.List("Issues: " .. repo.name, rows, function(row) local number = row:match("^(%d+)"); if number then gh(repo, "Issue #" .. number, {"issue", "view", number}) end end))
  end)
end) end
commands["github:create-issue"] = function() with_repo(function(repo) prompt("Issue title", function(title) prompt("Issue description", function(body) gh(repo, "Create issue", {"issue", "create", "--title", title, "--body", body}) end) end) end) end
commands["scm:actions"] = function()
  local names, actions = {}, {}
  for name in pairs(commands) do
    if name ~= "scm:actions" and name ~= "scm:toggle" then local label = name:gsub("scm:", "Git: "):gsub("github:", "GitHub: "):gsub("%-", " "); names[#names + 1] = label; actions[label] = name end
  end
  table.sort(names)
  prompt("Source control action", function(label) if actions[label] then command.perform(actions[label]) end end, "", names)
end
command.add(nil, commands)
command.add(views.Graph, {
  ["scm:history-down"] = function(v) v:select(v.selected + 1) end,
  ["scm:history-up"] = function(v) v:select(v.selected - 1) end,
  ["scm:history-open"] = function(v) local c = v.repo.history[v.selected]; if c then v.on_select(c, 1) end end,
})
keymap.add({down = "scm:history-down", up = "scm:history-up", ["return"] = "scm:history-open"})
keymap.add({["ctrl+shift+g"] = "scm:toggle"})
keymap.add({[PLATFORM == "Mac OS X" and "cmd+shift+r" or "ctrl+shift+r"] = "scm:review"})
local old_add = core.add_project
function core.add_project(...)
  local project = old_add(...)
  core.add_thread(function() git.discover() end)
  return project
end
local Doc = require "core.doc"
local old_save = Doc.save
function Doc:save(...)
  local result = old_save(self, ...)
  for _, repo in ipairs(git.repositories) do if self.abs_filename and common.path_belongs_to(self.abs_filename, repo.root) then repo.dirty = true end end
  return result
end
return {git = git, open = ensure_panel, panel = function() return panel end, history = history,
  change_count = function() local n = 0; for _, repo in ipairs(git.repositories) do n = n + change_count(repo) end; return n end}
