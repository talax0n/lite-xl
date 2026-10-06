# Commit Browsing and Review Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make commits easy to check: History without T3 checkpoints and with readable rows, any commit opened in the review layout with syntax-colored diffs, and a commit list in the review pane.

**Architecture:** A review target gains an optional `commit` field; `Review` (data/plugins/scm/review.lua) renders such a target read-only in its own tab. `git.lua` filters `refs/t3/*` and records unpushed hashes. `views.lua` redraws Graph rows, adds keyboard selection, and tokenizes diff lines with the editor's syntax tokenizer.

**Tech Stack:** Lua 5.4 plugins on the TreX lite-xl fork (mod-version 4), git CLI.

**Spec:** `docs/superpowers/specs/2026-10-06-commit-browsing-design.md`

## Global Constraints

- Plugin code style: match surrounding files (dense, short locals, comments only for non-obvious why).
- `config.plugins.scm.show_checkpoints` default `false`.
- Checkpoint refs are exactly `refs/t3/*`.
- One commit tab and one review tab at most; opening a commit never retargets the review tab.
- Commit target is read-only: no notes, viewed state, fixes, push/merge/discard; nothing written under `.trex/`.
- Never commit `subprojects/.wraplock`; never `git add -A` in the repo.
- Tests: `build/src/ide-test-runner scripts/tests/ide.lua` (from repo root) and `PATH=/tmp/lite-xl-build-tools/bin:$PATH ./scripts/test-ide.sh build`.

## Review Focus

1. Pressing `v`, `c`, or clicking a line number in a commit tab must not write `.trex/review.md` or `.trex/viewed` (Task 4 guards + test).
2. `]` on the last loaded History commit must load the next page and move, not stop (Task 4 `step`; covered by code path, test uses mid-list).
3. Up/Down/Enter bindings must not steal keys from the editor (predicate is the Graph class; Task 2 test presses keys with a Graph active and the editor still works in later tests).
4. A merge commit shows its first-parent diff, not an empty combined diff (Task 4 `--diff-merges=first-parent`).
5. Toggling checkpoints with a History tab open must not leave a stale selection pointing past the list (Task 2 `select` clamps).

## Deviations from the spec

- Syntax token test lives in the UI runtime, not native: `views.lua` needs `renderer`/`style`, which the native runner lacks.
- Graph rows draw refs pills before the subject (so the subject, not the branch name, is what gets cut with `…`).
- Commit actions (Copy hash, …) are passed as a function `actions(hash)` so they follow Previous/Next.

---

### Task 1: Hide checkpoints, record unpushed commits

**Files:**
- Modify: `data/plugins/scm/git.lua` (`M.history`)
- Modify: `data/plugins/scm.lua` (config defaults, `scm:toggle-checkpoints`)
- Test: `scripts/tests/ide.lua`, `scripts/tests/ui-runtime.lua`

**Interfaces:**
- Produces: `repo.unpushed` — set `{[hash] = true}`, empty without upstream. Read-only for views.
- Produces: command `scm:toggle-checkpoints`.

- [ ] **Step 1: Write the failing native test.** In `scripts/tests/ide.lua`, right after the line `git.history(git.repositories[1]); drain(); check(#git.repositories[1].history > 0, 'Queued history')`, add:

```lua
local r1 = git.repositories[1]
run(function()
  local hash = g(r1.root, {'commit-tree', 'HEAD^{tree}', '-p', 'HEAD', '-m', 't3 checkpoint'}):gsub('%s+$', '')
  g(r1.root, {'update-ref', 'refs/t3/x', hash})
end)
local function has_checkpoint() for _, c in ipairs(r1.history) do if c.subject == 't3 checkpoint' then return true end end return false end
git.history(r1, nil, true); drain(); check(#r1.history > 0 and not has_checkpoint(), 'Checkpoints hidden from history')
check(r1.unpushed and next(r1.unpushed) == nil, 'No unpushed marks without upstream')
package.loaded['core.config'].plugins = {scm = {show_checkpoints = true}}
git.history(r1, nil, true); drain(); check(has_checkpoint(), 'Checkpoints shown when enabled')
package.loaded['core.config'].plugins = nil
```

- [ ] **Step 2: Run, expect FAIL** `Checkpoints hidden from history`.

Run: `build/src/ide-test-runner scripts/tests/ide.lua`

- [ ] **Step 3: Implement in `git.lua`.** Replace the worker body of `M.history`:

```lua
function M.history(repo, done, reset)
  if reset then repo.history = {}; repo.history_done = false end
  if repo.history_done or #repo.history >= 2000 then if done then done() end; return end
  M.enqueue(repo, "Loading history", function()
    repo.unpushed = repo.unpushed or {}
    if repo.status.head == "(initial)" then repo.history_done = true; return true end
    local settings = config.plugins and config.plugins.scm or {}
    local args = {"log", "--all", "--date-order", "--max-count=100", "--skip=" .. #repo.history, "--format=%H%x00%P%x00%an%x00%aI%x00%D%x00%s%x00"}
    -- T3 Code records a checkpoint commit per agent turn under refs/t3/.
    if not settings.show_checkpoints then table.insert(args, 2, "--exclude=refs/t3/*") end
    local out, err = M.git(repo, args)
    if not out then return nil, err end
    local page = parse.log(out)
    for _, commit in ipairs(page) do repo.history[#repo.history + 1] = commit end
    repo.history_done = #page < 100; parse.graph(repo.history)
    local unpushed = {}
    for hash in ((repo.status.upstream and M.git(repo, {"rev-list", "@{upstream}..HEAD"})) or ""):gmatch("%x+") do unpushed[hash] = true end
    repo.unpushed = unpushed
    return true
  end, function(result) if result and done then done() end end)
end
```

- [ ] **Step 4: Run native, expect PASS** (count grows by 3).

- [ ] **Step 5: Add option and command in `scm.lua`.** Change the defaults line to include `show_checkpoints = false`:

```lua
config.plugins.scm = common.merge({width = 320, refresh_interval = 5, fetch_interval = 180, discovery_depth = 3, discovery_limit = 100, show_checkpoints = false}, config.plugins.scm)
```

Add to the `commands` table (after `["scm:history"]`):

```lua
  ["scm:toggle-checkpoints"] = function()
    options.show_checkpoints = not options.show_checkpoints
    for _, repo in ipairs(git.repositories) do repo.graph_head = nil; git.history(repo, nil, true) end
    core.log("T3 checkpoints %s in history", options.show_checkpoints and "shown" or "hidden")
  end,
```

- [ ] **Step 6: UI test for unpushed.** In `scripts/tests/ui-runtime.lua`, right after `write(root .. '/b.lua', 'return 1\n'); commit(root, 'add b')`, add:

```lua
    scm.git.refresh(mine)
    wait(function() return (mine.status.ahead or 0) >= 2 and not mine.worker end, 'Ahead count not refreshed')
    local loaded = false
    scm.git.history(mine, function() loaded = true end, true)
    wait(function() return loaded end, 'History not loaded')
    local head = (scm.git.exec(root, 'git', {'rev-parse', 'HEAD'})):gsub('%s+$', '')
    assert(mine.unpushed[head], 'HEAD not marked unpushed')
    assert(command.map['scm:toggle-checkpoints'], 'Toggle checkpoints command missing')
```

- [ ] **Step 7: Run UI runtime, expect PASS.**

Run: `PATH=/tmp/lite-xl-build-tools/bin:$PATH ./scripts/test-ide.sh build`

- [ ] **Step 8: Commit.**

```bash
git add data/plugins/scm/git.lua data/plugins/scm.lua scripts/tests/ide.lua scripts/tests/ui-runtime.lua
git commit -m "feat(scm): hide T3 checkpoints from history and mark unpushed commits"
```

---

### Task 2: Readable History rows and keyboard selection

**Files:**
- Modify: `data/plugins/scm/views.lua` (`relative`, `Graph`)
- Modify: `data/plugins/scm.lua` (sidebar graph dot, Graph commands/keys, export `history`)
- Test: `scripts/tests/ui-runtime.lua`

**Interfaces:**
- Consumes: `repo.unpushed` (Task 1).
- Produces: `Graph:select(i)`; commands `scm:history-down`, `scm:history-up`, `scm:history-open`; `require("plugins.scm").history(repo)`.

- [ ] **Step 1: Write the failing UI test.** In `ui-runtime.lua`, directly after the line `run(root, {'worktree', 'unlock', wz})`, add:

```lua
    scm.history(mine)
    local gv
    wait(function() gv = core.active_view; return gv:is(views.Graph) and #mine.history > 2 end, 'History tab did not open')
    keymap.on_key_pressed('down'); keymap.on_key_pressed('down'); keymap.on_key_pressed('up')
    assert(gv.selected == 1, 'Arrow keys did not move History selection: ' .. tostring(gv.selected))
    gv:draw()
```

(`views` is already required above this point in the file; if not, add `local views = require 'plugins.scm.views'` before it.)

- [ ] **Step 2: Run, expect FAIL** (`scm.history` is nil).

- [ ] **Step 3: Relative dates for ISO in `views.lua`.** Replace the `relative` function with:

```lua
local function ago(t)
  local s = os.time() - t
  if s < 60 then return "just now" end
  if s < 3600 then return (s // 60) .. " min ago" end
  if s < 86400 then return (s // 3600) .. (s < 7200 and " hour ago" or " hours ago") end
  if s < 86400 * 14 then return (s // 86400) .. (s < 172800 and " day ago" or " days ago") end
  return os.date("%b %d, %Y", t)
end
local function to_time(y, mo, d, H, Mi, S, sign, oh, om)
  local t = os.time({year = tonumber(y), month = mo, day = tonumber(d), hour = tonumber(H), min = tonumber(Mi), sec = tonumber(S)})
  return t + (os.time() - os.time(os.date("!*t"))) - ((tonumber(oh) or 0) * 3600 + (tonumber(om) or 0) * 60) * (sign == "-" and -1 or 1)
end
-- Accepts git's default date ("Tue Oct 6 15:58:00 2026 +0700") and ISO 8601 (%aI).
local function relative(date)
  date = date or ""
  local mon, d, H, Mi, S, y, sign, oh, om = date:match("%a+ (%a+) (%d+) (%d+):(%d+):(%d+) (%d+) ([%+%-])(%d%d)(%d%d)")
  if mon and MONTHS[mon] then return ago(to_time(y, MONTHS[mon], d, H, Mi, S, sign, oh, om)) end
  local iy, imo, id, iH, iMi, iS, isign, ioh, iom = date:match("^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)([%+%-]?)(%d*):?(%d*)")
  if iy then return ago(to_time(iy, tonumber(imo), id, iH, iMi, iS, isign, ioh, iom)) end
  return date
end
```

- [ ] **Step 4: Redraw Graph rows in `views.lua`.** Add above `local Graph = List:extend()`:

```lua
local function fit(font, text, w)
  if font:get_width(text) <= w then return text end
  while #text > 0 and font:get_width(text .. "…") > w do text = text:usub(1, -2) end
  return text .. "…"
end
```

Replace `Graph:draw` and add `get_h_scrollable_size` and `select`:

```lua
function Graph:get_h_scrollable_size() return 0 end
function Graph:draw()
  self:draw_background(style.background)
  local x, y = self:get_content_offset(); x = x + style.padding.x
  local lh, gap, px = line_height(), 15 * SCALE, style.padding.x
  local right, d = self.position.x + self.size.x - px, math.floor(6 * SCALE)
  local unpushed = self.repo.unpushed or {}
  local first, last = math.max(1, math.floor(self.scroll.y / lh)), math.min(#self.repo.history, math.ceil((self.scroll.y + self.size.y) / lh) + 1)
  for i = first, last do
    local c = self.repo.history[i]; local ty = y + (i - 1) * lh; local cy = ty + lh / 2
    if i == self.selected then renderer.draw_rect(self.position.x, ty, self.size.x, lh, style.line_highlight) end
    for _, edge in ipairs(c.edges) do
      local color = palette[(edge[1] - 1) % #palette + 1]
      graph_line(x + (edge[1] - 1) * gap, edge[3] and cy or cy - lh / 2, x + (edge[2] - 1) * gap, cy + lh / 2, color)
    end
    local color = palette[(c.lane - 1) % #palette + 1]
    if c.incoming then graph_line(x + (c.lane - 1) * gap, cy - lh / 2, x + (c.lane - 1) * gap, cy, color) end
    renderer.draw_rect(x + (c.lane - 1) * gap - 3 * SCALE, cy - 3 * SCALE, 7 * SCALE, 7 * SCALE, color)
    local date = relative(c.date)
    local dx = right - style.font:get_width(date)
    common.draw_text(style.font, style.dim, date, nil, dx, ty, 0, lh)
    local author = fit(style.font, c.author, 140 * SCALE)
    local ax = dx - px - style.font:get_width(author)
    common.draw_text(style.font, style.dim, author, nil, ax, ty, 0, lh)
    local tx = x + math.max(4, c.lanes) * gap
    if unpushed[c.hash] then renderer.draw_rect(tx, cy - d / 2, d, d, style.accent); tx = tx + d + px / 2 end
    tx = common.draw_text(style.code_font, style.dim, c.hash:sub(1, 8), nil, tx, ty, 0, lh) + px
    for ref in c.refs:gmatch("[^,]+") do
      tx = pill(style.font, (ref:gsub("^%s+", ""):gsub("^HEAD %-> ", "")), tx, ty, lh, tint(style.caret, 50), style.caret)
    end
    local subject = c.subject .. (c.graph_limited and "  [additional graph lanes omitted]" or "")
    common.draw_text(style.font, style.text, fit(style.font, subject, math.max(0, ax - px - tx)), nil, tx, ty, 0, lh)
  end
  local footer = self.repo.history_done and "End of history" or #self.repo.history >= 2000 and "History display limit reached (2,000 commits)" or "Load next 100 commits"
  renderer.draw_text(style.font, footer, x, y + #self.repo.history * lh, style.accent)
  self:draw_scrollbar()
end
function Graph:select(i)
  local lh = line_height()
  self.selected = common.clamp(i, 1, math.max(1, #self.repo.history))
  local top = (self.selected - 1) * lh
  if top < self.scroll.to.y then self.scroll.to.y = top
  elseif top + lh > self.scroll.to.y + self.size.y then self.scroll.to.y = top + lh - self.size.y end
  core.redraw = true
end
```

- [ ] **Step 5: Wire keys, sidebar dot, export in `scm.lua`.** After `command.add(nil, commands)` add:

```lua
command.add(views.Graph, {
  ["scm:history-down"] = function(v) v:select(v.selected + 1) end,
  ["scm:history-up"] = function(v) v:select(v.selected - 1) end,
  ["scm:history-open"] = function(v) local c = v.repo.history[v.selected]; if c then v.on_select(c, 1) end end,
})
keymap.add({down = "scm:history-down", up = "scm:history-up", ["return"] = "scm:history-open"})
```

In `Sidebar:draw_row`, `graph` branch, replace the two lines starting `local tx = common.draw_text(style.font, row.first and style.accent ...` with:

```lua
    local sx = cx + pad
    if row.repo.unpushed and row.repo.unpushed[c.hash] then
      local s = math.floor(6 * SCALE); renderer.draw_rect(sx, y + (h - s) / 2, s, s, style.accent); sx = sx + s + pad * 0.5
    end
    local tx = common.draw_text(style.font, row.first and style.accent or style.text, c.subject, nil, sx, y, 0, h)
    common.draw_text(style.font, style.dim, c.author, nil, tx + pad * 0.6, y, 0, h)
```

Change the module's final `return` to include `history = history`:

```lua
return {git = git, open = ensure_panel, panel = function() return panel end, history = history,
  change_count = function() local n = 0; for _, repo in ipairs(git.repositories) do n = n + change_count(repo) end; return n end}
```

- [ ] **Step 6: Run UI runtime, expect PASS.**

- [ ] **Step 7: Commit.**

```bash
git add data/plugins/scm/views.lua data/plugins/scm.lua scripts/tests/ui-runtime.lua
git commit -m "feat(scm): readable history rows with keyboard selection"
```

---

### Task 3: Syntax-colored diff lines

**Files:**
- Modify: `data/plugins/scm/views.lua` (`Text:set_text`, `Text:tokens`, `Text:draw_row`)
- Test: `scripts/tests/ui-runtime.lua`

**Interfaces:**
- Produces: `Text:tokens(row)` → flat `{type, text, type, text, ...}` or `nil`. `self.parsed` = rows as parsed (Review filters `self.rows`, so tokens walk `self.parsed`).

- [ ] **Step 1: Failing test.** In `ui-runtime.lua`, after `assert(#tv.files == 0 and #tv.rows == 0, 'Text view did not reset')`, add:

```lua
    local function first_add(v) for _, r in ipairs(v.rows) do if r.kind == 'add' then return r end end end
    local lua_diff = views.Text('t', 'diff --git a/f.lua b/f.lua\n@@ -1 +1 @@\n-old\n+local x = 1\n')
    local toks = lua_diff:tokens(first_add(lua_diff))
    assert(toks and toks[1] == 'keyword' and toks[2] == 'local', 'Diff line not highlighted')
    local plain_diff = views.Text('t', 'diff --git a/f.zzz b/f.zzz\n@@ -1 +1 @@\n+local x = 1\n')
    assert(plain_diff:tokens(first_add(plain_diff)) == nil, 'Plain file got syntax tokens')
```

- [ ] **Step 2: Run, expect FAIL** (`tokens` nil).

- [ ] **Step 3: Implement.** In `views.lua` add requires at the top:

```lua
local syntax = require "core.syntax"
local tokenizer = require "core.tokenizer"
```

At the end of `Text:set_text`, before `self:layout()`, add `self.parsed = rows`.

Add after `Text:count_hunks`:

```lua
-- Syntax tokens for a diff line. A file's lines are tokenized together on
-- first use, carrying tokenizer state line to line and restarting per hunk.
-- ponytail: whole file at once (diffs cap at 20,000 lines); go per hunk if big files stutter.
function Text:tokens(row)
  local file = row.file
  if not file or row.kind == "file" then return nil end
  if file.tokenized == nil then
    local syn = syntax.get(file.path)
    file.tokenized = syn ~= syntax.plain_text_syntax and #syn.patterns > 0
    local start
    for i, r in ipairs(self.parsed) do if r == file.row then start = i; break end end
    local state
    for i = (start or #self.parsed) + 1, #self.parsed do
      local r = self.parsed[i]
      if r.kind == "file" then break end
      if r.kind == "hunk" then state = nil
      elseif file.tokenized and (r.kind == "add" or r.kind == "del" or r.kind == "ctx") then r.tokens, state = tokenizer.tokenize(syn, r.text, state) end
    end
  end
  return row.tokens
end
```

In `Text:draw_row`, `add/del/ctx` branch, replace the single line
`common.draw_text(style.code_font, style.syntax.normal, row.text, nil, x + g - self.scroll.x, y, 0, h)` with:

```lua
    local toks, tx = self:tokens(row), x + g - self.scroll.x
    if toks then
      for i = 1, #toks, 2 do tx = common.draw_text(style.code_font, style.syntax[toks[i]] or style.syntax.normal, toks[i + 1], nil, tx, y, 0, h) end
    else common.draw_text(style.code_font, style.syntax.normal, row.text, nil, tx, y, 0, h) end
```

- [ ] **Step 4: Run UI runtime, expect PASS.** Also run native (unchanged, must stay green).

- [ ] **Step 5: Commit.**

```bash
git add data/plugins/scm/views.lua scripts/tests/ui-runtime.lua
git commit -m "feat(scm): syntax colors in diffs"
```

---

### Task 4: Commit tab (commit target in Review)

**Files:**
- Modify: `data/plugins/scm/review.lua`
- Modify: `data/plugins/scm/review_ops.lua` (`M.show`)
- Modify: `data/plugins/scm.lua` (`inspect`)
- Test: `scripts/tests/ui-runtime.lua`

**Interfaces:**
- Consumes: `repo.history`, `git.history(repo, done)`, `Graph` keys (Task 2).
- Produces: `review.commit_target(repo, hash, actions)`, `review.show_commit(repo, hash, actions)`, `Review:step(d)`; commands `review:previous-commit` (`[`) and `review:next-commit` (`]`). `actions` is `function(hash) -> {{text=, fn=}, ...}`.

- [ ] **Step 1: Failing test.** In `ui-runtime.lua`, directly after the Task 2 block (History tab open, `gv.selected == 1`), add `os.remove(root .. '/.trex/viewed')` and then:

```lua
    local reviews_before = 0
    for _, v in ipairs(core.root_view.root_node:get_children()) do if v:is(review.Review) then reviews_before = reviews_before + 1 end end
    keymap.on_key_pressed('down'); keymap.on_key_pressed('return')
    local cv
    wait(function() cv = core.active_view; return cv:is(review.Review) and cv.target.commit == mine.history[2].hash and not cv.loading end, 'Commit tab did not open')
    assert(#cv.files > 0 and cv:get_name():find(mine.history[2].hash:sub(1, 8), 1, true), 'Commit tab empty or misnamed')
    keymap.on_key_pressed(']')
    wait(function() return cv.target.commit == mine.history[3].hash and not cv.loading end, '] did not move to the older commit')
    keymap.on_key_pressed('[')
    wait(function() return cv.target.commit == mine.history[2].hash and not cv.loading end, '[ did not move back')
    keymap.on_key_pressed('v'); cv:add_note(cv.rows[#cv.rows], 'x')
    assert(not read(root .. '/.trex/review.md') and not read(root .. '/.trex/viewed'), 'Commit tab wrote review state')
    review.show_commit(mine, string.rep('0', 40))
    wait(function() return cv.target.commit == string.rep('0', 40) and not cv.loading end, 'Unknown commit not shown in the same tab')
    assert(cv.missing and cv.rows[1].kind == 'banner' and cv.rows[1].text:find('Commit not found', 1, true), 'Missing commit banner absent')
    local reviews_after = 0
    for _, v in ipairs(core.root_view.root_node:get_children()) do if v:is(review.Review) then reviews_after = reviews_after + 1 end end
    assert(reviews_after == reviews_before + 1, 'Commit tab not reused: ' .. reviews_before .. ' -> ' .. reviews_after)
```

The earlier push archived `review.md`; removing `viewed` first makes the assertion check only this block's writes.

- [ ] **Step 2: Run, expect FAIL** (commit tab not opened).

- [ ] **Step 3: `review_ops.lua`.** Merge commits show their first-parent diff:

```lua
function M.show(t, hash)
  return git.git(t.root, {"show", "--no-ext-diff", "--no-textconv", "--diff-merges=first-parent", "--decorate", "--format=fuller", "--stat", "--patch", hash, "--"})
end
```

- [ ] **Step 4: `review.lua`.** Add helpers after `saved_list`:

```lua
local function history_index(t)
  for i, c in ipairs(t.repo and t.repo.history or {}) do if c.hash == t.commit then return i end end
end
```

Replace `Review:get_name`:

```lua
function Review:get_name()
  local t = self.target
  if t.commit then
    local i = history_index(t)
    return "Commit: " .. t.commit:sub(1, 8) .. (i and "  " .. t.repo.history[i].subject or "")
  end
  return "Review: " .. (t.branch or t.root:match("[^/]+$"))
end
```

At the top of `Review:load`, after `local t = self.target`:

```lua
  if t.commit then
    local text = ops.show(t, t.commit)
    self.missing, self.state = not text, {}
    self:set_text(text or "")
    self.all_rows = self.rows
    self.scroll.y, self.scroll.to.y = 0, 0
    self:build(); self:update_actions()
    return
  end
```

At the top of `Review:build`, after `local function add(row) ... end`:

```lua
  if t.commit then
    if self.missing then add({kind = "banner", color = style.warn, text = "Commit not found: " .. t.commit:sub(1, 8)}) end
    for _, row in ipairs(self.all_rows) do add(row) end
    self.rows = rows; self:layout(); core.redraw = true
    return
  end
```

At the top of `Review:update_actions`, after `local t, a = self.target, {}`:

```lua
  if t.commit then
    a[1] = {text = "Previous", fn = function() self:step(-1) end}
    a[2] = {text = "Next", fn = function() self:step(1) end}
    if not self.missing and t.actions then for _, x in ipairs(t.actions(t.commit)) do a[#a + 1] = x end end
    self.actions = a
    return
  end
```

Read-only guards: first line of `Review:toggle_viewed`, `Review:add_note`, and `Review:general_note`:

```lua
  if self.target.commit then return end
```

In `Review:retarget`, replace `M.saved[t.root] = M.saved[t.root] or {}` with:

```lua
  if not t.commit then M.saved[t.root] = M.saved[t.root] or {} end
```

Add after `Review:retarget`:

```lua
-- Previous = newer, Next = older, in History order; Next past the loaded
-- page loads the next one first.
function Review:step(d)
  local t = self.target
  local i = history_index(t)
  if not i or i + d < 1 then return end
  local function go() local c = t.repo.history[i + d]; if c then self:retarget(M.commit_target(t.repo, c.hash, t.actions)) end end
  if i + d > #t.repo.history then
    if not t.repo.history_done then git.history(t.repo, go) end
  else go() end
end
```

In `M.show`, change `if v:is(Review) then` to `if v:is(Review) and not v.target.commit then`. Add after `M.show`:

```lua
function M.commit_target(repo, hash, actions) return {root = repo.root, main_root = repo.root, repo = repo, commit = hash, actions = actions} end

-- One commit tab, separate from the review tab so browsing keeps review state.
function M.show_commit(repo, hash, actions)
  local t = M.commit_target(repo, hash, actions)
  for _, v in ipairs(core.root_view.root_node:get_children()) do
    if v:is(Review) and v.target.commit then
      v:retarget(t)
      core.root_view.root_node:get_node_for_view(v):set_active_view(v)
      return v
    end
  end
  return views.open(Review(t))
end
```

Extend the command table and keymap at the bottom:

```lua
command.add(Review, {
  ["review:add-note"] = function(v) if v.sel_from then v:add_note(v.sel_from) else core.error("Click a diff line first") end end,
  ["review:general-note"] = function(v) v:general_note() end,
  ["review:copy-notes"] = function(v) v:copy_notes() end,
  ["review:viewed-and-next"] = function(v) v:viewed_next() end,
  ["review:previous-commit"] = function(v) v:step(-1) end,
  ["review:next-commit"] = function(v) v:step(1) end,
})
keymap.add({c = "review:add-note", v = "review:viewed-and-next", ["["] = "review:previous-commit", ["]"] = "review:next-commit"})
```

`viewed_next` calls `toggle_viewed`, which is guarded; `current_file` stays usable.

- [ ] **Step 5: `scm.lua`.** Replace `inspect` with:

```lua
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
```

- [ ] **Step 6: Run UI runtime + native, expect PASS.**

- [ ] **Step 7: Commit.**

```bash
git add data/plugins/scm/review.lua data/plugins/scm/review_ops.lua data/plugins/scm.lua scripts/tests/ui-runtime.lua
git commit -m "feat(scm): open commits in the review layout with previous/next"
```

---

### Task 5: Commit list in the review pane, docs, screenshots

**Files:**
- Modify: `data/plugins/scm/review.lua` (`pane_rows`, `draw_pane`, `pane_pressed`, `on_mouse_wheel`, remove `pick_commit` and its toolbar item)
- Modify: `data/plugins/scm/review_ops.lua` (`M.commits` returns `time`)
- Modify: `docs/ide-features.md`
- Test: `scripts/tests/ui-runtime.lua`

**Interfaces:**
- Consumes: commit target (Task 4).
- Produces: `Review:pane_rows()` → list of `{kind = "heading"|"commit"|"file", text?, mode?, time?, file?}`.

- [ ] **Step 1: Failing test.** In `ui-runtime.lua`, insert this block between the line `run(root, {'worktree', 'unlock', wz})` and the Task 2 block:

```lua
    write(wz .. '/f.lua', 'return 6\n'); commit(wz, 'z more')
    for _, t in ipairs(assert(require('plugins.scm.review_ops').targets(root))) do if t.branch == 'agent/z' then rv:retarget(t) end end
    wait(function() return not rv.loading and rv.target.branch == 'agent/z' and #rv.files == 2 end, 'Worktree z with two commits not opened')
    local pane = rv:pane_rows()
    local idx
    for i, r in ipairs(pane) do if r.kind == 'commit' and r.text == 'z more' then idx = i end end
    assert(pane[1].kind == 'heading' and pane[2].mode == 'all' and idx, 'Commit list missing from review pane')
    local plh = style.font:get_height() + style.padding.y
    rv:pane_pressed(rv.position.x + 20, rv.position.y + rv:toolbar_height() + (idx - 1) * plh + 2)
    wait(function() return not rv.loading and #rv.files == 1 and rv.files[1].path == 'f.lua' end, 'Pane commit click did not filter the diff')
    for _, a in ipairs(rv.actions) do assert(a.text ~= 'All changes', 'Old commit picker still in toolbar') end
```

Then, at the end of the Task 4 block (which now runs after this one), add the review-state check:

```lua
    assert(rv.target.branch == 'agent/z' and not rv.target.commit and rv.mode ~= 'all', 'Review tab state changed by commit browsing')
```

Resulting order: unlock line → Task 5 block → Task 2 block → Task 4 block.

- [ ] **Step 2: Run, expect FAIL** (`pane_rows` nil).

- [ ] **Step 3: `review_ops.lua`.**

```lua
function M.commits(t)
  local out = git.git(t.root, {"log", "--format=%H%x00%s%x00%ar", t.base .. "..HEAD"}) or ""
  local list = {}
  for hash, subject, time in out:gmatch("(%x+)\0([^\0\n]*)\0([^\n]*)") do list[#list + 1] = {hash = hash, subject = subject, time = (time:gsub(" ago$", ""))} end
  return list
end
```

- [ ] **Step 4: `review.lua`.** Delete `Review:pick_commit`. In `update_actions` delete the line adding `self.mode == "all" and "All changes" or ...`. Add before `draw_pane`:

```lua
-- Left pane rows: in a review, the commit list (it filters the diff) above the files.
function Review:pane_rows()
  local rows = {}
  if not self.target.commit and #self.commits > 0 then
    rows[1] = {kind = "heading", text = "COMMITS"}
    rows[2] = {kind = "commit", mode = "all", text = "All changes"}
    for _, c in ipairs(self.commits) do rows[#rows + 1] = {kind = "commit", mode = c.hash, text = c.subject, time = c.time} end
    rows[#rows + 1] = {kind = "heading", text = "FILES"}
  end
  for _, f in ipairs(self.files) do rows[#rows + 1] = {kind = "file", file = f} end
  return rows
end
```

Replace `draw_pane`:

```lua
function Review:draw_pane()
  local x, y, w, h = self.position.x, self.position.y, self:pane_w(), self.size.y
  local tb, lh, px = self:toolbar_height(), pane_lh(), style.padding.x
  local line = math.max(1, math.floor(SCALE))
  local read_only = self.target.commit
  renderer.draw_rect(x, y, w, h, style.background2)
  renderer.draw_rect(x + w - line, y, line, h, style.divider)
  local header, color
  if read_only then header, color = #self.files .. (#self.files == 1 and " file changed" or " files changed"), style.text
  else
    local done = 0
    for _, f in ipairs(self.files) do if self:is_viewed(f.path) then done = done + 1 end end
    local open = self:open_notes()
    header = string.format("%d/%d reviewed  ·  %d note%s", done, #self.files, open, open == 1 and "" or "s")
    color = (done == #self.files and #self.files > 0) and style.good or style.text
  end
  common.draw_text(style.font, color, header, nil, x + px, y, 0, tb)
  renderer.draw_rect(x, y + tb - line, w, line, style.divider)
  core.push_clip_rect(x, y + tb, w, h - tb)
  local box, current = math.floor(10 * SCALE), self:current_file()
  for i, row in ipairs(self:pane_rows()) do
    local ry = y + tb + (i - 1) * lh - (self.pane_scroll or 0)
    if ry + lh >= y + tb and ry <= y + h then
      if row.kind == "heading" then
        common.draw_text(style.font, style.dim, row.text, nil, x + px, ry, 0, lh)
      elseif row.kind == "commit" then
        local active = row.mode == self.mode
        if active then renderer.draw_rect(x, ry, w, lh, style.selection)
        elseif self:hovered(x, ry, w, lh) then renderer.draw_rect(x, ry, w, lh, style.line_highlight) end
        local right = x + w - px
        if row.time then right = right - style.font:get_width(row.time); common.draw_text(style.font, style.dim, row.time, nil, right, ry, 0, lh) end
        core.push_clip_rect(x + px, ry, math.max(0, right - x - px * 1.5), lh)
        common.draw_text(style.font, active and style.accent or style.text, row.text, nil, x + px, ry, 0, lh)
        core.pop_clip_rect()
      else
        local f = row.file
        if f == current then renderer.draw_rect(x, ry, w, lh, style.selection)
        elseif self:hovered(x, ry, w, lh) then renderer.draw_rect(x, ry, w, lh, style.line_highlight) end
        local nx, viewed = x + px, self:is_viewed(f.path)
        if not read_only then
          local bx, by = x + px, ry + (lh - box) / 2
          if viewed then renderer.draw_rect(bx, by, box, box, style.good)
          else
            renderer.draw_rect(bx, by, box, line, style.dim); renderer.draw_rect(bx, by + box - line, box, line, style.dim)
            renderer.draw_rect(bx, by, line, box, style.dim); renderer.draw_rect(bx + box - line, by, line, box, style.dim)
          end
          nx = bx + box + px / 2
        end
        local stat = "+" .. f.adds .. " −" .. f.dels
        local right = x + w - px - style.font:get_width(stat)
        common.draw_text(style.font, style.dim, stat, nil, right, ry, 0, lh)
        if self:open_notes(f.path) > 0 then
          local d = math.floor(6 * SCALE)
          right = right - d - px / 2
          renderer.draw_rect(right, ry + (lh - d) / 2, d, d, style.accent)
        end
        core.push_clip_rect(nx, ry, math.max(0, right - nx - px / 2), lh)
        common.draw_text(style.font, viewed and style.dim or style.text, f.path:match("[^/]+$") or f.path, nil, nx, ry, 0, lh)
        core.pop_clip_rect()
      end
    end
  end
  core.pop_clip_rect()
end
```

Replace `pane_pressed`:

```lua
function Review:pane_pressed(x, y)
  local tb = self:toolbar_height()
  if y < self.position.y + tb then return true end
  local row = self:pane_rows()[math.floor((y - self.position.y - tb + (self.pane_scroll or 0)) / pane_lh()) + 1]
  if not row or row.kind == "heading" then return true end
  if row.kind == "commit" then
    if row.mode ~= self.mode then self.mode = row.mode; self.scroll.to.y = 0; self:reload() end
  elseif not self.target.commit and x < self.position.x + style.padding.x * 1.5 + math.floor(10 * SCALE) then self:toggle_viewed(row.file.path)
  else self.scroll.to.y = row.file.row.y end
  core.redraw = true
  return true
end
```

In `on_mouse_wheel`, change `#self.files * pane_lh()` to `#self:pane_rows() * pane_lh()`.

- [ ] **Step 5: Run UI runtime + native, expect PASS.**

- [ ] **Step 6: Docs.** In `docs/ide-features.md`:
  - Source control section: replace the **Graph** paragraph's sentence "Select a commit to inspect its patch, compare it with HEAD, copy its hash, revert it, or cherry-pick it." with: "Click a commit, or move with Up/Down and press Enter, to open it in the commit tab: changed files on the left, its message and syntax-colored diff on the right, and Copy hash, Compare with HEAD, Revert, Cherry-pick and GitHub in the toolbar. **[** and **]** (or Previous/Next) step to the newer and older commit. A dot marks commits not pushed yet. T3 Code checkpoint commits (`refs/t3/*`) are hidden; **Toggle checkpoints** shows them."
  - Commit review section: replace "The toolbar switches between all changes and a single commit." with "The **Commits** list at the top of the left pane filters the diff to one commit; **All changes** shows the whole range."

- [ ] **Step 7: Rebuild app and screenshot.** Run `ninja -C build-release && ./scripts/package-custom-macos.sh build-release`, copy to `/Applications/TreX.app`, then a `LITE_USERDIR=/tmp/scm-shot-user LITE_XL_RUNTIME=shot` script that opens History on this repo, Enter on a commit, and a review tab; `screencapture` each to `/tmp/scm-history.png`, `/tmp/scm-commit.png`, `/tmp/scm-review-pane.png`. Read each image: no checkpoints in History, colored diff in the commit tab, Commits list in the review pane.

- [ ] **Step 8: Commit.**

```bash
git add data/plugins/scm/review.lua data/plugins/scm/review_ops.lua scripts/tests/ui-runtime.lua docs/ide-features.md
git commit -m "feat(scm): commit list in the review pane"
```
