-- Commit review: walk unpushed commits (main checkout) or an agent worktree
-- branch file by file, mark files viewed, leave line notes in .trex/review.md
-- for the agent, commit own fixes, then push, merge or discard.
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local View = require "core.view"
local Doc = require "core.doc"
local DocView = require "core.docview"
local git = require "plugins.scm.git"
local views = require "plugins.scm.views"
local notes = require "plugins.scm.review_notes"
local ops = require "plugins.scm.review_ops"

local Review = views.Text:extend()
Review.persistent = true -- opening a diff must not close the review tab
local M = {Review = Review, saved = {}, save_tick = 0}

local function tint(c, a) return {c[1], c[2], c[3], a} end
local function pane_lh() return style.font:get_height() + style.padding.y end
local function saved_list(root)
  local list = {}
  for path in pairs(M.saved[root] or {}) do list[#list + 1] = path end
  table.sort(list)
  return list
end

function Review:new(target)
  Review.super.new(self, "Review", "")
  self.target, self.mode, self.commits, self.fixes, self.dirty, self.state = target, "all", {}, {}, 0, {}
  self.doc, self.viewed, self.blobs, self.all_rows = {notes = {}, extra = {}}, {}, {}, {}
  self:reload()
end
function Review:get_name() return "Review: " .. (self.target.branch or self.target.root:match("[^/]+$")) end

function Review:reload()
  if self.loading then self.reload_again = true; return end
  self.loading = true
  core.add_thread(function()
    local ok, err = pcall(self.load, self)
    self.loading = false
    if not ok then core.error("Review: %s", tostring(err)) end
    if self.reload_again then self.reload_again = false; self:reload() end
    core.redraw = true
  end)
end

function Review:load()
  local t = self.target
  self.state = ops.state(t)
  local text, err = "", nil
  if t.base then
    if self.mode == "all" then text, err = ops.diff(t) else text, err = ops.show(t, self.mode) end
    if not text then core.error("Review: %s", err or "git failed") end
  end
  self.commits = t.base and ops.commits(t) or {}
  self.dirty = ops.dirty_count(t)
  self.fixes = ops.dirty_paths(t, saved_list(t.root))
  local doc, viewed = ops.load(t)
  local keep = self:current_file()
  keep = keep and keep.path
  self:set_text(text or "")
  self.all_rows = self.rows
  local paths = {}
  for _, f in ipairs(self.files) do paths[#paths + 1] = f.path end
  self.blobs = #paths > 0 and ops.blobs(t, paths) or {}
  local heads, moved = {}, false
  for _, n in ipairs(doc.notes) do
    if n.path then
      if heads[n.path] == nil then heads[n.path] = ops.head_lines(t, n.path) or false end
      local from = n.from
      notes.reanchor(n, heads[n.path] or nil)
      moved = moved or n.from ~= from
    end
  end
  self.doc, self.viewed = doc, viewed
  if moved then ops.save(t, doc) end
  self:build()
  self:update_actions()
  for _, f in ipairs(self.files) do
    if f.path == keep then self.scroll.y, self.scroll.to.y = f.row.y, f.row.y end
  end
  self.sig, self.sig_git = self:signature()
end

-- Cheap change detector for the target: commits, index, notes file and saves from TreX.
-- Returns the signature and its git part; pass `git_part` to refresh only
-- the notes file after our own write, so a commit landing meanwhile still reloads.
function Review:signature(git_part)
  local function stat(path) local info = system.get_file_info(path); return info and (info.modified .. ":" .. info.size) or "-" end
  if not git_part then
    local gitdir = self.state.gitdir or ""
    git_part = table.concat({M.save_tick, stat(gitdir .. "/HEAD"), stat(gitdir .. "/index"), stat(gitdir .. "/logs/HEAD")}, "|")
  end
  return git_part .. "|" .. stat(self.target.root .. "/.trex/review.md"), git_part
end

function Review:update()
  Review.super.update(self)
  local now = system.get_time()
  if self.sig and not self.loading and now - (self.checked or 0) > 1 then
    self.checked = now
    if self:signature() ~= self.sig then self:reload() end
  end
end

function Review:is_viewed(path) return self.viewed[path] ~= nil and self.viewed[path] == self.blobs[path] end
function Review:open_notes(path)
  local count = 0
  for _, n in ipairs(self.doc.notes) do if not n.done and (path == nil or n.path == path) then count = count + 1 end end
  return count
end
function Review:complete()
  for _, f in ipairs(self.files) do if not self:is_viewed(f.path) then return false end end
  return self:open_notes() == 0
end
function Review:current_file()
  local cur
  for _, f in ipairs(self.files or {}) do if f.row and f.row.y and f.row.y <= self.scroll.y + 1 then cur = f end end
  return cur or (self.files and self.files[1])
end

-- Visible rows from the parsed diff: banners, collapsed viewed files, and
-- note rows under the line they point at.
function Review:build()
  local rows, t = {}, self.target
  local function add(row) rows[#rows + 1] = row end
  if self.state.busy then add({kind = "banner", color = style.warn, text = "A " .. self.state.busy .. " is in progress: finish it before pushing or merging"}) end
  if not t.branch then add({kind = "banner", color = style.warn, text = "Detached HEAD: check out a branch to push or merge"}) end
  if #self.fixes > 0 then
    add({kind = "banner", text = "Uncommitted fixes: " .. #self.fixes .. (#self.fixes == 1 and " file" or " files"), button = "Commit fixes", fn = function() self:commit_fixes() end})
  end
  if self.dirty > #self.fixes then
    add({kind = "banner", color = style.warn, text = "Agent left uncommitted changes: " .. (self.dirty - #self.fixes) .. " files (not part of this review)", button = "Show", fn = function() self:show_uncommitted() end})
  end
  if #self.all_rows == 0 then
    add({kind = "banner", color = style.dim, text = t.base and ("Nothing to review: " .. (t.branch or "HEAD") .. " has no commits ahead of " .. t.base) or "No base branch: pick one from the target menu"})
  end
  local by_path, lines_in, file = {}, {}, nil
  for _, n in ipairs(self.doc.notes) do
    if n.path then by_path[n.path] = by_path[n.path] or {}; table.insert(by_path[n.path], n)
    else add({kind = "rnote", note = n}) end
  end
  for _, row in ipairs(self.all_rows) do
    if row.kind == "file" then file = row.file; lines_in[file.path] = lines_in[file.path] or {}
    elseif file and row.new then lines_in[file.path][row.new] = true end
  end
  local placed = {}
  file = nil
  for _, row in ipairs(self.all_rows) do
    if row.kind == "file" then
      file = row.file
      add(row)
      -- Notes outside the diff hunks (or in single-commit mode) sit under the file header.
      for _, n in ipairs(by_path[file.path] or {}) do
        if self.mode ~= "all" or n.outdated or not lines_in[file.path][n.to] or self:is_viewed(file.path) then add({kind = "rnote", note = n}); placed[n] = true end
      end
    elseif not (file and self:is_viewed(file.path)) then
      add(row)
      if file and row.new and self.mode == "all" then
        for _, n in ipairs(by_path[file.path] or {}) do
          if not placed[n] and n.to == row.new then add({kind = "rnote", note = n}); placed[n] = true end
        end
      end
    end
  end
  for _, n in ipairs(self.doc.notes) do
    if n.path and not placed[n] and not lines_in[n.path] then add({kind = "rnote", note = n}) end
  end
  self.rows = rows
  self:layout()
  core.redraw = true
end

function Review:update_actions()
  local t, a = self.target, {}
  a[#a + 1] = {text = (t.branch or "detached") .. " vs " .. (t.base or "?"), fn = function() self:pick_target() end}
  a[#a + 1] = {text = self.mode == "all" and "All changes" or self.mode:sub(1, 8), fn = function() self:pick_commit() end}
  a[#a + 1] = {text = "Note", fn = function() self:general_note() end}
  a[#a + 1] = {text = "Copy notes", fn = function() self:copy_notes() end}
  if #self.all_rows > 0 and t.branch and not self.state.busy then
    local done = self:complete()
    if t.main then
      a[#a + 1] = {text = "Push", primary = done, fn = function() self:finish("push") end}
    else
      a[#a + 1] = {text = "Merge into " .. t.base, primary = done, fn = function() self:finish("merge") end}
      a[#a + 1] = {text = "Push branch", fn = function() self:finish("push") end}
    end
  end
  if not t.main and not t.locked then a[#a + 1] = {text = "Discard", fn = function() self:discard() end} end
  self.actions = a
end

function Review:persist(doc_changed, viewed_changed)
  core.add_thread(function()
    local ok, err = ops.save(self.target, doc_changed and self.doc or nil, viewed_changed and self.viewed or nil)
    if not ok then core.error("Review: %s", err) end
    self.sig = (self:signature(self.sig_git))
  end)
end

function Review:toggle_viewed(path, value)
  if value == nil then value = not self:is_viewed(path) end
  self.viewed[path] = value and self.blobs[path] or nil
  self:build(); self:update_actions(); self:persist(false, true)
end

function Review:viewed_next()
  local cur = self:current_file()
  if not cur then return end
  self:toggle_viewed(cur.path, true)
  local after = false
  for _, f in ipairs(self.files) do
    if after and not self:is_viewed(f.path) then self.scroll.to.y = f.row.y; return end
    after = after or f == cur
  end
  for _, f in ipairs(self.files) do if not self:is_viewed(f.path) then self.scroll.to.y = f.row.y; return end end
end

function Review:retarget(t)
  M.saved[t.root] = M.saved[t.root] or {}
  self.target, self.mode, self.sel_from, self.sel_to = t, "all", nil, nil
  self.scroll.y, self.scroll.to.y = 0, 0
  self:reload()
end

function Review:pick_commit()
  local labels, by = {"All changes"}, {["All changes"] = "all"}
  for _, c in ipairs(self.commits) do
    local label = c.hash:sub(1, 8) .. "  " .. c.subject
    labels[#labels + 1] = label; by[label] = c.hash
  end
  views.prompt("Show", function(label) if by[label] then self.mode = by[label]; self:reload() end end, "", labels)
end

function Review:pick_target()
  core.add_thread(function()
    local list, err = ops.targets(self.target.main_root)
    if not list then core.error("Review: %s", err); return end
    local labels, by = {}, {}
    for _, t in ipairs(list) do local label = M.label(t); labels[#labels + 1] = label; by[label] = t end
    local change = "Change base (" .. (self.target.base or "none") .. ")..."
    labels[#labels + 1] = change
    views.prompt("Review target", function(label)
      if label == change then
        views.prompt("Base ref", function(ref) if ref ~= "" then self.target.base = ref; self:reload() end end, self.target.base or "")
      elseif by[label] then self:retarget(by[label]) end
    end, "", labels)
  end)
end

-- Nearest new-side line in the same file: deleted lines have no HEAD line.
function Review:anchor_row(row)
  if row.new then return row end
  local index
  for i, r in ipairs(self.rows) do if r == row then index = i; break end end
  if not index then return nil end
  for i = index + 1, #self.rows do
    local r = self.rows[i]
    if r.file and r.file ~= row.file then break end
    if r.new then return r end
  end
  for i = index - 1, 1, -1 do
    local r = self.rows[i]
    if r.file and r.file ~= row.file then break end
    if r.new then return r end
  end
end

function Review:add_note(row, text)
  local a = self:anchor_row(self.sel_from or row)
  local b = self:anchor_row(self.sel_to or self.sel_from or row)
  if not a or not b or a.file ~= b.file then core.error("Pick lines from one file, or add a general note"); return end
  if a.new > b.new then a, b = b, a end
  local function save(body)
    body = body:gsub("[\r\n]+", " ")
    if body:match("^%s*$") then return end
    local n = {done = false, path = a.file.path, from = a.new, to = b.new, text = body, snapshot = a.text}
    table.insert(self.doc.notes, n)
    self.sel_from, self.sel_to = nil, nil
    if self.mode == "all" then self:build(); self:update_actions(); self:persist(true); return end
    core.add_thread(function() -- commit line numbers -> HEAD line numbers
      notes.reanchor(n, ops.head_lines(self.target, n.path))
      self:build(); self:update_actions(); self:persist(true)
    end)
  end
  if text then save(text)
  else views.prompt("Note on " .. a.file.path .. ":" .. a.new .. (b.new ~= a.new and "-" .. b.new or ""), save) end
end

function Review:edit_note(n)
  views.prompt("Edit note", function(body)
    if body:match("^%s*$") then return end
    n.text = body:gsub("[\r\n]+", " ")
    self:build(); self:persist(true)
  end, n.text)
end

function Review:delete_note(n)
  for i, x in ipairs(self.doc.notes) do if x == n then table.remove(self.doc.notes, i); break end end
  self:build(); self:update_actions(); self:persist(true)
end

function Review:general_note(text)
  local function save(body)
    body = body:gsub("[\r\n]+", " ")
    if body:match("^%s*$") then return end
    table.insert(self.doc.notes, {done = false, text = body})
    self:build(); self:update_actions(); self:persist(true)
  end
  if text then save(text) else views.prompt("General note", save) end
end

function Review:copy_notes()
  local count = self:open_notes()
  if count == 0 then core.log("No open review notes"); return end
  system.set_clipboard(notes.copy_text(self.doc))
  core.log("Copied %d review note%s", count, count == 1 and "" or "s")
end

-- Opens the real file at the line in a split to the right; the review tab stays.
function Review:open_at(row)
  local anchor = self:anchor_row(row)
  local ok, doc = pcall(core.open_doc, self.target.root .. "/" .. row.file.path)
  if not ok then core.error("Cannot open %s", row.file.path); return end
  local dv = DocView(doc)
  local side = self.side_node
  if side and side.active_view and core.root_view.root_node:get_node_for_view(side.active_view) == side then
    side:add_view(dv)
  else
    self.side_node = core.root_view.root_node:get_node_for_view(self):split("right", dv)
  end
  core.set_active_view(dv)
  local line = anchor and anchor.new or 1
  doc:set_selection(line, 1)
  dv:scroll_to_line(line, true, true)
end

function Review:commit_fixes(message)
  local function run(msg)
    if msg:match("^%s*$") then return end
    core.add_thread(function()
      local ok, err = ops.commit_fixes(self.target, self.fixes, msg)
      if not ok then core.error("Commit fixes: %s", err); return end
      M.saved[self.target.root] = {}
      local repo = git.by_root[self.target.root]
      if repo then git.refresh(repo) end
      self:reload()
    end)
  end
  if message then run(message) else views.prompt("Commit message", run, "fix: address review") end
end

function Review:show_uncommitted()
  core.add_thread(function()
    local out, err = git.git(self.target.root, {"diff", "--no-ext-diff", "--no-textconv", "HEAD", "--"})
    if not out then core.error("Review: %s", err); return end
    views.open(views.Text("Uncommitted: " .. (self.target.branch or "HEAD"), out ~= "" and out or "Only untracked files. Open the worktree to see them."))
  end)
end

-- After a worktree is merged or discarded: next target with work, else the main checkout.
function Review:next_target()
  local list = ops.targets(self.target.main_root) or {}
  local t = M.candidates(list)[1] or list[1]
  if t then self:retarget(t) end
end

function Review:finish(kind, yes)
  local t = self.target
  local unviewed = 0
  for _, f in ipairs(self.files) do if not self:is_viewed(f.path) then unviewed = unviewed + 1 end end
  local warn = {}
  if unviewed > 0 or self:open_notes() > 0 then warn[#warn + 1] = string.format("%d files unviewed, %d open notes.", unviewed, self:open_notes()) end
  if self.dirty > 0 then warn[#warn + 1] = string.format("%d uncommitted files are not included.", self.dirty) end
  local verb = kind == "merge" and "Merge" or "Push"
  local function run()
    core.add_thread(function()
      -- A load in flight may re-save review.md after archive() moved it.
      while self.loading do coroutine.yield(0.05) end
      local ok, err, conflict
      if kind == "merge" then ok, err, conflict = ops.merge(t) else ok, err = ops.push(t) end
      local repo = git.by_root[t.main_root]
      if repo then git.refresh(repo) end
      if not ok then
        core.error("%s: %s", verb, err or "failed")
        if conflict then require("plugins.scm").open() end
        return
      end
      if kind == "push" then
        if t.main then ops.archive(t); self:reload() end
        core.log("Pushed %s", t.branch)
        return
      end
      local function remove()
        core.add_thread(function()
          local removed, rerr = ops.remove(t, false)
          if not removed then core.error("Remove worktree: %s", rerr); return end
          self:next_target()
        end)
      end
      if yes then remove()
      else views.confirm("Merged " .. t.branch, "Remove worktree " .. t.root .. " and delete branch " .. t.branch .. "?", remove) end
    end)
  end
  if #warn > 0 and not yes then views.confirm(verb .. " anyway?", table.concat(warn, " ") .. " " .. verb .. " anyway?", run)
  else run() end
end

function Review:discard(yes)
  local t = self.target
  local function run()
    core.add_thread(function()
      while self.loading do coroutine.yield(0.05) end
      local ok, err = ops.remove(t, true)
      if not ok then core.error("Discard: %s", err); return end
      core.log("Discarded %s", t.branch or t.root)
      self:next_target()
    end)
  end
  if yes then return run() end
  core.add_thread(function()
    local n = ops.unmerged(t)
    views.confirm("Discard worktree", string.format("Delete worktree %s and branch %s with %d unmerged commit%s? This cannot be undone.",
      t.root, t.branch or "(detached)", n, n == 1 and "" or "s"), run)
  end)
end

-- ponytail: the diff renderer is reused by narrowing the view rect around
-- Text calls; switch to a split container if the review grows more panes.
local function in_diff(self, fn, ...)
  local pw = self:pane_w()
  self.position.x, self.size.x = self.position.x + pw, self.size.x - pw
  local result = table.pack(pcall(fn, self, ...))
  self.position.x, self.size.x = self.position.x - pw, self.size.x + pw
  if not result[1] then error(result[2], 0) end
  return table.unpack(result, 2, result.n)
end

function Review:pane_w() return math.floor(240 * SCALE) end

function Review:draw()
  in_diff(self, views.Text.draw)
  self:draw_pane()
end

function Review:draw_pane()
  local x, y, w, h = self.position.x, self.position.y, self:pane_w(), self.size.y
  local tb, lh, px = self:toolbar_height(), pane_lh(), style.padding.x
  local line = math.max(1, math.floor(SCALE))
  renderer.draw_rect(x, y, w, h, style.background2)
  renderer.draw_rect(x + w - line, y, line, h, style.divider)
  local done = 0
  for _, f in ipairs(self.files) do if self:is_viewed(f.path) then done = done + 1 end end
  local open = self:open_notes()
  common.draw_text(style.font, (done == #self.files and #self.files > 0) and style.good or style.text,
    string.format("%d/%d reviewed  ·  %d note%s", done, #self.files, open, open == 1 and "" or "s"), nil, x + px, y, 0, tb)
  renderer.draw_rect(x, y + tb - line, w, line, style.divider)
  core.push_clip_rect(x, y + tb, w, h - tb)
  local box, current = math.floor(10 * SCALE), self:current_file()
  for i, f in ipairs(self.files) do
    local ry = y + tb + (i - 1) * lh - (self.pane_scroll or 0)
    if ry + lh >= y + tb and ry <= y + h then
      if f == current then renderer.draw_rect(x, ry, w, lh, style.selection)
      elseif self:hovered(x, ry, w, lh) then renderer.draw_rect(x, ry, w, lh, style.line_highlight) end
      local bx, by = x + px, ry + (lh - box) / 2
      local viewed = self:is_viewed(f.path)
      if viewed then renderer.draw_rect(bx, by, box, box, style.good)
      else
        renderer.draw_rect(bx, by, box, line, style.dim); renderer.draw_rect(bx, by + box - line, box, line, style.dim)
        renderer.draw_rect(bx, by, line, box, style.dim); renderer.draw_rect(bx + box - line, by, line, box, style.dim)
      end
      local stat = "+" .. f.adds .. " −" .. f.dels
      local right = x + w - px - style.font:get_width(stat)
      common.draw_text(style.font, style.dim, stat, nil, right, ry, 0, lh)
      if self:open_notes(f.path) > 0 then
        local d = math.floor(6 * SCALE)
        right = right - d - px / 2
        renderer.draw_rect(right, ry + (lh - d) / 2, d, d, style.accent)
      end
      local nx = bx + box + px / 2
      core.push_clip_rect(nx, ry, math.max(0, right - nx - px / 2), lh)
      common.draw_text(style.font, viewed and style.dim or style.text, f.path:match("[^/]+$") or f.path, nil, nx, ry, 0, lh)
      core.pop_clip_rect()
    end
  end
  core.pop_clip_rect()
end

function Review:row_button(row, label, right, y, h, fn)
  local bw = style.font:get_width(label) + style.padding.x
  local bx = right - bw
  local hovered = self:hovered(bx, y, bw, h)
  renderer.draw_rect(bx, y + math.floor(2 * SCALE), bw, h - math.floor(4 * SCALE), hovered and style.selection or style.background3)
  common.draw_text(style.font, hovered and style.accent or style.text, label, "center", bx, y, bw, h)
  row.buttons[#row.buttons + 1] = {x1 = bx, x2 = bx + bw, fn = fn}
  return bx
end

function Review:draw_row(row, x, y, w)
  local px, h = style.padding.x, row.h
  row.buttons = {}
  if row.kind == "banner" then
    renderer.draw_rect(x, y, w, h, style.background2)
    common.draw_text(style.font, row.color or style.text, row.text, nil, x + px, y, 0, h)
    if row.button then self:row_button(row, row.button, x + w - px, y, h, row.fn) end
  elseif row.kind == "rnote" then
    local n, g = row.note, self:gutter()
    renderer.draw_rect(x, y, w, h, tint(style.accent, 18))
    renderer.draw_rect(x + g - px / 2, y, math.floor(3 * SCALE), h, n.done and style.dim or n.outdated and style.warn or style.accent)
    local gap = math.floor(4 * SCALE)
    local right = self:row_button(row, "del", x + w - px, y, h, function() self:delete_note(n) end)
    right = self:row_button(row, "edit", right - gap, y, h, function() self:edit_note(n) end)
    right = self:row_button(row, n.done and "reopen" or "resolve", right - gap, y, h, function()
      n.done = not n.done; self:build(); self:update_actions(); self:persist(true)
    end)
    local label = (n.done and "resolved  " or "") .. (n.outdated and "outdated  " or "") .. (n.path and "" or "general  ") .. n.text
    core.push_clip_rect(x + g, y, math.max(0, right - x - g), h)
    common.draw_text(style.font, n.done and style.dim or style.text, label, nil, x + g + px / 2, y, 0, h)
    core.pop_clip_rect()
  else
    views.Text.draw_row(self, row, x, y, w)
    local a, b = self.sel_from, self.sel_to or self.sel_from
    if a and row.file and row.file == a.file and row.y >= math.min(a.y, b.y) and row.y <= math.max(a.y, b.y) then
      renderer.draw_rect(x, y, w, h, tint(style.accent, 30))
    end
    if (row.kind == "add" or row.kind == "ctx" or row.kind == "del") and self:hovered(x, y, self:gutter(), h) then
      local s = math.floor(h * 0.8)
      renderer.draw_rect(x + math.floor(2 * SCALE), y + (h - s) / 2, s, s, style.accent)
      common.draw_text(style.code_font, style.background, "+", "center", x + math.floor(2 * SCALE), y, s, h)
    end
  end
end

function Review:on_mouse_pressed(button, x, y, clicks)
  if x < self.position.x + self:pane_w() then return self:pane_pressed(x, y) end
  if in_diff(self, View.on_mouse_pressed, button, x, y, clicks) then return true end
  local tb = self:toolbar_height()
  if y >= self.position.y + tb then
    local row = self.rows[self:row_at(y - self.position.y - tb + self.scroll.y)]
    for _, b in ipairs(row and row.buttons or {}) do
      if x >= b.x1 and x < b.x2 then b.fn(); return true end
    end
    if row and (row.kind == "add" or row.kind == "ctx" or row.kind == "del") then
      if clicks > 1 then self:open_at(row); return true end
      if keymap.modkeys.shift and self.sel_from then self.sel_to = row else self.sel_from, self.sel_to = row, nil end
      -- Clicking the line-number gutter adds a note, like GitHub's "+".
      if x < self.position.x + self:pane_w() + self:gutter() then self:add_note(row) end
      core.redraw = true
      return true
    end
  end
  return in_diff(self, views.Text.on_mouse_pressed, button, x, y, clicks)
end

function Review:pane_pressed(x, y)
  local tb = self:toolbar_height()
  if y < self.position.y + tb then return true end
  local f = self.files[math.floor((y - self.position.y - tb + (self.pane_scroll or 0)) / pane_lh()) + 1]
  if not f then return true end
  if x < self.position.x + style.padding.x * 1.5 + math.floor(10 * SCALE) then self:toggle_viewed(f.path)
  else self.scroll.to.y = f.row.y end
  core.redraw = true
  return true
end

function Review:on_mouse_moved(x, y, ...) return in_diff(self, views.Text.on_mouse_moved, x, y, ...) end
function Review:on_mouse_released(...) return in_diff(self, View.on_mouse_released, ...) end
function Review:on_mouse_wheel(dy, dx)
  if self.mouse_x and self.mouse_x < self.position.x + self:pane_w() then
    local max = math.max(0, #self.files * pane_lh() - (self.size.y - self:toolbar_height()))
    self.pane_scroll = common.clamp((self.pane_scroll or 0) - dy * pane_lh() * 3, 0, max)
    core.redraw = true
    return true
  end
  return views.Text.on_mouse_wheel(self, dy, dx)
end

function M.label(t)
  return string.format("%s  ·  %d commit%s%s  ·  %s", t.branch or "detached", t.ahead, t.ahead == 1 and "" or "s",
    t.dirty > 0 and "  ·  dirty" or "", t.root)
end

function M.candidates(list)
  local out = {}
  for _, t in ipairs(list) do if t.ahead > 0 or (not t.main and t.dirty > 0) then out[#out + 1] = t end end
  return out
end

-- One review tab: an open one is retargeted instead of opening another.
function M.show(t)
  M.saved[t.root] = M.saved[t.root] or {}
  for _, v in ipairs(core.root_view.root_node:get_children()) do
    if v:is(Review) then
      v:retarget(t)
      core.root_view.root_node:get_node_for_view(v):set_active_view(v)
      return v
    end
  end
  return views.open(Review(t))
end

-- Reviews `root`'s main checkout or one of its worktrees.
function M.open(root)
  core.add_thread(function()
    local list, err = ops.targets(root)
    if not list then core.error("Review: %s", err); return end
    local c = M.candidates(list)
    if #c == 0 then
      local main = list[1]
      if main and not main.base then
        views.prompt("No upstream. Review against base ref", function(ref)
          if ref ~= "" then main.base = ref; M.show(main) end
        end, "main")
      else
        core.log("Nothing to review: no unpushed commits or agent worktrees")
      end
      return
    end
    if #c == 1 then M.show(c[1]); return end
    local labels, by = {}, {}
    for _, t in ipairs(c) do local label = M.label(t); labels[#labels + 1] = label; by[label] = t end
    views.prompt("Review", function(label) if by[label] then M.show(by[label]) end end, "", labels)
  end)
end

-- Files saved from TreX while a review is open count as own fixes.
local doc_save = Doc.save
function Doc:save(...)
  local result = doc_save(self, ...)
  local path = self.abs_filename
  for root, set in pairs(M.saved) do
    if path and common.path_belongs_to(path, root) then set[path:sub(#root + 2)] = true; M.save_tick = M.save_tick + 1 end
  end
  return result
end

command.add(Review, {
  ["review:add-note"] = function(v) if v.sel_from then v:add_note(v.sel_from) else core.error("Click a diff line first") end end,
  ["review:general-note"] = function(v) v:general_note() end,
  ["review:copy-notes"] = function(v) v:copy_notes() end,
  ["review:viewed-and-next"] = function(v) v:viewed_next() end,
})
keymap.add({c = "review:add-note", v = "review:viewed-and-next"})

return M
