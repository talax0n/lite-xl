# Commit Review Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A review tab in TreX for unpushed commits and agent worktree branches: per-file viewed tracking, line notes stored in `.trex/review.md`, own-fix commits, and push / merge / discard.

**Architecture:** Three new modules under `data/plugins/scm/`:
- `review_notes.lua` is pure: the notes file format, re-anchoring, viewed state and worktree-list parsing.
- `review_ops.lua` holds the git operations; it has no UI and runs inside coroutines.
- `review.lua` holds the `Review` view, a subclass of the existing `views.Text` diff renderer, with a file pane on the left.

`scm.lua` gets the `scm:review` command, a keybinding and a sidebar entry.

**Tech Stack:** Lua 5.4 on lite-xl (SDL3). Git is run through `plugins.scm.git` (`git.git(root, args)`, which yields). Tests use the native runner `build/src/ide-test-runner scripts/tests/ide.lua` and the UI runtime `scripts/tests/ui-runtime.lua` via `./scripts/test-ide.sh build`.

**Spec:** `docs/superpowers/specs/2026-10-05-commit-review-design.md`

**Spec deviations (simplifications; the spec is updated to match):**
- Git operations live in a third file, `review_ops.lua`, so they can be tested in the native runner without UI.
- The review tab watches its own target for changes (git-dir `HEAD`/`index`/`logs/HEAD` plus `review.md` mtime, once per second, inside `Review:update`). It doesn't hook into the Source Control poll, because worktree targets are not SCM repositories.
- The keybinding is added in `scm.lua` next to `ctrl+shift+g`, not in the keymap files.
- In single-commit mode, notes are listed under their file header instead of under the exact line, because line numbers there belong to the commit, not HEAD.
- The review tab shows plain-text status marks (filled or outlined boxes, an accent dot), not Unicode glyphs. The UI font has no ✓ glyph.

## Global Constraints

- Notes file: `<target root>/.trex/review.md`. Viewed state: `<target root>/.trex/viewed`, one `path<TAB>blob-sha` per line.
- `.trex/` is appended to `$(git rev-parse --git-common-dir)/info/exclude`. Never touch `.gitignore`. Never commit `.trex/`.
- Note line format: ``- [ ] `path:42` text`` or ``- [ ] `path:42-48` text``, followed by an optional `  > snapshot` line. General notes are written `- [ ] (general) text`. `[x]` means resolved.
- Re-anchor window: ±50 lines; the nearest match wins. If nothing matches, the note is marked `outdated`; it is never deleted.
- Fix commit default message: `fix: address review`. Only files saved from TreX since the review opened are committed (`git add -A -- <paths>` and `git commit -m <msg> -- <paths>`).
- Archive name: `.trex/reviews/<YYYY-MM-DD>-<shortsha>.md` for the main checkout, and `<main root>/.trex/reviews/<YYYY-MM-DD>-<branch with / → ->-<shortsha>.md` for worktrees.
- Keybinding: `cmd+shift+r` on macOS, `ctrl+shift+r` elsewhere, mapped to `scm:review`.
- Discard confirmation text: `Delete worktree <root> and branch <branch> with N unmerged commits? This cannot be undone.`
- Never commit `subprojects/.wraplock`.
- Commit messages follow Conventional Commits.

## Review Focus

1. **Paths with spaces or non-ASCII characters** (`data/a b/é.lua`, worktree folder `agent wt`): note locations must parse back to the same path, and git commands must get them as single arguments. Covered in Task 1 (parse round-trip), Task 2 (worktree with a space) and Task 6 (UI worktree `agent wt`).
2. **Note text containing newlines** (pasted text): it must be stored on one line so the file stays parseable. Covered in Task 1.
3. **Blank-line snapshot or deleted file**: a blank snapshot must not jump to an arbitrary blank line, and a note on a file deleted from HEAD becomes outdated. Covered in Task 1.
4. **Dirty main checkout on merge, or a dirty agent worktree when committing fixes**: merge must refuse with a clear message, and fixes must never sweep in the agent's files. Covered in Task 2 and Task 6.
5. **Repository with no upstream and no `origin`**: the target has `base == nil` and `ahead == 0`, and the UI asks for a base ref instead of crashing. Covered in Task 2.

---

### Task 1: Notes format, re-anchoring, viewed state, worktree parsing

**Files:**
- Create: `data/plugins/scm/review_notes.lua`
- Test: `scripts/tests/ide.lua` (add a block before the final `assert(os.execute('rm -rf ' .. tmp))`)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `notes.parse(text|nil) -> doc`, where `doc = {header = string|nil, notes = {note...}, extra = {string...}}` and `note = {done = bool, path = string|nil, from = int|nil, to = int|nil, text = string, snapshot = string|nil, outdated = bool|nil}`
  - `notes.serialize(doc) -> string`
  - `notes.location(note) -> string`, for example ``"`a.lua:3`"`` or `"(general)"`
  - `notes.reanchor(note, lines|nil) -> note`, which mutates `from`, `to` and `outdated`
  - `notes.viewed_parse(text|nil) -> {[path] = sha}` and `notes.viewed_serialize(map) -> string`
  - `notes.copy_text(doc) -> string`
  - `notes.parse_worktrees(porcelain) -> {{root, head, branch|nil, bare, detached, locked, prunable}...}`

- [ ] **Step 1: Write the failing test**

In `scripts/tests/ide.lua`, insert before the final `assert(os.execute('rm -rf ' .. tmp))` line:

```lua
-- Commit review notes: file format, re-anchoring, viewed state, worktree list.
do
  local notes = require 'plugins.scm.review_notes'
  local md = '# Review: main · origin/main..HEAD\n\n- [ ] `data/a b/é.lua:42` rename this\n  > local x = foo()\n- [ ] `src/x.lua:10-12` cache it\n  > function f()\n- [x] `src/main.c:3` drop include\n  > #include <string.h>\n- [ ] (general) add tests\n\nagent wrote this\n'
  local doc = notes.parse(md)
  check(#doc.notes == 4 and doc.notes[1].path == 'data/a b/é.lua' and doc.notes[1].from == 42 and doc.notes[1].snapshot == 'local x = foo()', 'Review note parsing')
  check(doc.notes[2].from == 10 and doc.notes[2].to == 12 and doc.notes[3].done and not doc.notes[4].path, 'Range, resolved and general notes')
  check(notes.serialize(doc) == md, 'Review file round-trip keeps unknown lines')
  doc.notes[4].text = 'two\nlines'
  check(notes.serialize(doc):find('(general) two lines', 1, true), 'Note text kept on one line')
  local lines = {'a', 'b', 'c', 'd', 'e', '  local x = foo()'}
  local n = notes.reanchor({path = 'f', from = 1, to = 2, snapshot = 'local x = foo()'}, lines)
  check(n.from == 6 and n.to == 7 and not n.outdated, 'Note follows moved code')
  n = notes.reanchor({path = 'f', from = 1, to = 1, snapshot = 'gone'}, lines)
  check(n.outdated, 'Note outdated when code removed')
  n = notes.reanchor({path = 'f', from = 4, to = 4, snapshot = 'x'}, {'x', 'y', 'y', 'y', 'y', 'x'})
  check(n.from == 6, 'Nearest duplicate wins')
  n = notes.reanchor({path = 'f', from = 2, to = 2, snapshot = ''}, {'a', '', 'c'})
  check(n.from == 2 and not n.outdated, 'Blank snapshot keeps position')
  n = notes.reanchor({path = 'f', from = 2, to = 2, snapshot = 'a'}, nil)
  check(n.outdated, 'Deleted file outdates notes')
  local viewed = notes.viewed_parse('a.lua\tabc\nb c.lua\tdef\n')
  check(viewed['b c.lua'] == 'def' and notes.viewed_serialize(viewed) == 'a.lua\tabc\nb c.lua\tdef\n', 'Viewed state round-trip')
  local copy = notes.copy_text(notes.parse('- [ ] (general) tests\n- [ ] `z.lua:1` z\n- [ ] `a.lua:9` a\n- [x] `a.lua:1` finished\n'))
  check(copy:find('^Address these review notes') and copy:find('a%.lua:9.-z%.lua:1.-%(general%) tests') and not copy:find('finished', 1, true), 'Copy text order and filtering')
  local wts = notes.parse_worktrees('worktree /r/main\nHEAD aaa\nbranch refs/heads/main\n\nworktree /r/wt one\nHEAD bbb\nbranch refs/heads/agent/x\nlocked busy\n\nworktree /r/det\nHEAD ccc\ndetached\nprunable gitdir file points to non-existent location\n\nworktree /r/bare\nbare\n')
  check(#wts == 4 and wts[2].root == '/r/wt one' and wts[2].branch == 'agent/x' and wts[2].locked and wts[3].detached and wts[3].prunable and not wts[3].branch and wts[4].bare, 'Worktree porcelain parsing')
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /Users/theo/Documents/PROJECT/lite-xl && build/src/ide-test-runner scripts/tests/ide.lua`
Expected: FAIL with `module 'plugins.scm.review_notes' not found`.

- [ ] **Step 3: Write the implementation**

Create `data/plugins/scm/review_notes.lua`:

```lua
-- Commit review notes: the `.trex/review.md` format, re-anchoring notes to
-- moved code, viewed-file state and `git worktree list --porcelain`.
-- Pure functions: no UI, no git, tested in scripts/tests/ide.lua.
local M = {}

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
local function one_line(s) return (s:gsub("[\r\n]+", " ")) end

function M.location(n)
  if not n.path then return "(general)" end
  return "`" .. n.path .. ":" .. n.from .. ((n.to and n.to ~= n.from) and "-" .. n.to or "") .. "`"
end

function M.parse(text)
  local doc, last = {notes = {}, extra = {}}, nil
  for line in ((text or "") .. "\n"):gmatch("([^\n]*)\n") do
    local mark, body = line:match("^%- %[([ xX])%] (.*)$")
    if mark then
      last = {done = mark ~= " "}
      local path, from, to, rest = body:match("^`([^`]+):(%d+)%-?(%d*)`%s?(.*)$")
      if path then
        last.path, last.from, last.to, last.text = path, tonumber(from), tonumber(to) or tonumber(from), rest
      else
        last.text = body:match("^%(general%)%s?(.*)$") or body
      end
      doc.notes[#doc.notes + 1] = last
    elseif last and line:match("^  > ") then
      last.snapshot = line:sub(5)
    elseif not doc.header and line:match("^# ") then
      doc.header = line
    else
      -- Anything else (agent comments, prose) is kept verbatim at the end.
      if line ~= "" then doc.extra[#doc.extra + 1] = line end
      last = nil
    end
  end
  return doc
end

function M.serialize(doc)
  local out = {doc.header or "# Review", ""}
  for _, n in ipairs(doc.notes) do
    out[#out + 1] = "- [" .. (n.done and "x" or " ") .. "] " .. M.location(n) .. " " .. one_line(n.text)
    if n.snapshot and n.snapshot ~= "" then out[#out + 1] = "  > " .. n.snapshot end
  end
  if #doc.extra > 0 then
    out[#out + 1] = ""
    for _, line in ipairs(doc.extra) do out[#out + 1] = line end
  end
  return table.concat(out, "\n") .. "\n"
end

-- Moves `n` to where its snapshot line now is in `lines` (HEAD content of
-- n.path), searching ±50 lines nearest first; marks it outdated otherwise.
function M.reanchor(n, lines)
  n.outdated = nil
  if not n.path then return n end
  if not lines then n.outdated = true; return n end
  local want = n.snapshot and trim(n.snapshot) or ""
  -- ponytail: a blank snapshot can't be tracked, the note keeps its line.
  if want == "" then
    if n.from > #lines then n.outdated = true end
    return n
  end
  local span = n.to - n.from
  for d = 0, 50 do
    for _, i in ipairs(d == 0 and {n.from} or {n.from - d, n.from + d}) do
      if lines[i] and trim(lines[i]) == want then n.from, n.to = i, i + span; return n end
    end
  end
  n.outdated = true
  return n
end

function M.viewed_parse(text)
  local map = {}
  for path, sha in (text or ""):gmatch("([^\t\n]+)\t([^\n]+)") do map[path] = sha end
  return map
end

function M.viewed_serialize(map)
  local paths = {}
  for path in pairs(map) do paths[#paths + 1] = path end
  table.sort(paths)
  local out = {}
  for _, path in ipairs(paths) do out[#out + 1] = path .. "\t" .. map[path] .. "\n" end
  return table.concat(out)
end

-- Clipboard text for the agent: open notes in file order, general notes last.
function M.copy_text(doc)
  local located, general = {}, {}
  for _, n in ipairs(doc.notes) do
    if not n.done then
      if n.path then located[#located + 1] = n else general[#general + 1] = n end
    end
  end
  table.sort(located, function(a, b) if a.path ~= b.path then return a.path < b.path end; return a.from < b.from end)
  local out = {"Address these review notes (also in .trex/review.md; tick [x] when done):"}
  for _, n in ipairs(located) do
    out[#out + 1] = "- " .. M.location(n) .. " " .. one_line(n.text) .. (n.outdated and " (code changed since this note)" or "")
    if n.snapshot and n.snapshot ~= "" then out[#out + 1] = "  > " .. n.snapshot end
  end
  for _, n in ipairs(general) do out[#out + 1] = "- (general) " .. one_line(n.text) end
  return table.concat(out, "\n") .. "\n"
end

function M.parse_worktrees(text)
  local list, cur = {}, nil
  for line in ((text or "") .. "\n"):gmatch("([^\n]*)\n") do
    local key, value = line:match("^(%S+) ?(.*)$")
    if key == "worktree" then cur = {root = value}; list[#list + 1] = cur
    elseif cur and key == "HEAD" then cur.head = value
    elseif cur and key == "branch" then cur.branch = (value:gsub("^refs/heads/", ""))
    elseif cur and (key == "bare" or key == "detached" or key == "locked" or key == "prunable") then cur[key] = true end
  end
  return list
end

return M
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd /Users/theo/Documents/PROJECT/lite-xl && build/src/ide-test-runner scripts/tests/ide.lua`
Expected: `PASS: 49 checks against real Git repositories and a native PTY` (37 before, plus 12 new).

- [ ] **Step 5: Commit**

```bash
git add data/plugins/scm/review_notes.lua scripts/tests/ide.lua
git commit -m "feat(review): add review notes format and re-anchoring"
```

---

### Task 2: Git operations for review targets

**Files:**
- Create: `data/plugins/scm/review_ops.lua`
- Test: `scripts/tests/ide.lua` (add a `run(function() ... end)` block after the Task 1 block)

**Interfaces:**
- Consumes: `notes.parse`, `notes.serialize`, `notes.viewed_parse`, `notes.viewed_serialize`, `notes.parse_worktrees` (Task 1), and `git.git(root, args) -> out | nil, err` from `plugins.scm.git`.
- Produces. Every function runs inside a coroutine. A target is `{root, branch|nil, base|nil, locked, main = bool, main_root, ahead = int, dirty = int}`.
  - `ops.targets(root) -> {target...} | nil, err`. The main checkout comes first.
  - `ops.dirty_count(t) -> int`
  - `ops.diff(t) -> text | nil, err`, which is `git diff <base>...HEAD`
  - `ops.commits(t) -> {{hash, subject}...}`
  - `ops.show(t, hash) -> text | nil, err`
  - `ops.head_lines(t, path) -> {string...} | nil`
  - `ops.blobs(t, paths) -> {[path] = sha | "-"}`
  - `ops.trex(t) -> dir`, which creates `.trex/` and the exclude entry
  - `ops.load(t) -> doc, viewed`
  - `ops.save(t, doc|nil, viewed|nil) -> true | nil, err`
  - `ops.dirty_paths(t, paths) -> {path...}`
  - `ops.commit_fixes(t, paths, message) -> out | nil, err`
  - `ops.push(t) -> out | nil, err`
  - `ops.merge(t) -> true | nil, err, conflict`
  - `ops.archive(t) -> true | nil, err`
  - `ops.remove(t, force) -> out | nil, err`
  - `ops.state(t) -> {gitdir, busy = "merge"|"rebase"|nil}`

- [ ] **Step 1: Write the failing test**

In `scripts/tests/ide.lua`, directly after the Task 1 `do ... end` block, add:

```lua
-- Commit review git operations against real repositories and worktrees.
system.mkdir = system.mkdir or function(path) return os.execute("mkdir -p '" .. path .. "'") end
run(function()
  local ops = require 'plugins.scm.review_ops'
  local notes = require 'plugins.scm.review_notes'
  local function write(path, text) local f = assert(io.open(path, 'wb')); f:write(text); f:close() end
  local function read(path) local f = io.open(path, 'rb'); if not f then return nil end; local s = f:read('*a'); f:close(); return s end
  local function ls(dir) local p = io.popen("ls '" .. dir .. "' 2>/dev/null"); local s = p:read('*a'); p:close(); return s end
  local main = tmp .. '/review-main'
  g(tmp, {'init', '--bare', '-b', 'main', 'review-remote.git'})
  g(tmp, {'clone', 'review-remote.git', 'review-main'})
  g(main, {'config', 'user.name', 'R'}); g(main, {'config', 'user.email', 'r@example.test'})
  write(main .. '/a.txt', 'one\ntwo\nthree\n'); g(main, {'add', '.'}); g(main, {'commit', '-m', 'base'}); g(main, {'push', 'origin', 'main'})
  write(main .. '/a.txt', 'one\nTWO\nthree\n'); g(main, {'commit', '-am', 'change a'})
  local t = assert(ops.targets(main))[1]
  check(t.main and t.base == 'origin/main' and t.ahead == 1 and t.branch == 'main', 'Review target for unpushed commits')
  check(ops.diff(t):find('+TWO', 1, true), 'Review range diff')
  local commits = ops.commits(t)
  check(#commits == 1 and commits[1].subject == 'change a' and #commits[1].hash == 40, 'Review commit list')
  check(ops.head_lines(t, 'a.txt')[2] == 'TWO' and ops.head_lines(t, 'missing.txt') == nil, 'HEAD file lines')
  local blobs = ops.blobs(t, {'a.txt', 'gone.txt'})
  check(#blobs['a.txt'] == 40 and blobs['gone.txt'] == '-', 'HEAD blobs')
  local doc = notes.parse('')
  doc.notes[1] = {done = false, path = 'a.txt', from = 2, to = 2, text = 'why caps', snapshot = 'TWO'}
  assert(ops.save(t, doc, {['a.txt'] = blobs['a.txt']}))
  local loaded, viewed = ops.load(t)
  check(loaded.notes[1].text == 'why caps' and loaded.header:find('origin/main', 1, true) and viewed['a.txt'] == blobs['a.txt'], 'Review state persisted')
  check(g(main, {'status', '--porcelain'}) == '' and not read(main .. '/.gitignore'), '.trex hidden without touching .gitignore')
  assert(ops.save(t, doc))
  check(select(2, read(main .. '/.git/info/exclude'):gsub('%.trex/', '')) == 1, 'Exclude entry written once')
  -- Own fixes: only the edited file is committed.
  write(main .. '/a.txt', 'one\nTwo\nthree\n'); write(main .. '/other.txt', 'agent wip\n')
  check(#ops.dirty_paths(t, {'a.txt'}) == 1 and #ops.dirty_paths(t, {}) == 0 and ops.dirty_count(t) == 2, 'Dirty fix detection')
  assert(ops.commit_fixes(t, {'a.txt'}, 'fix: address review'))
  check(g(main, {'show', '--name-only', '--format=', 'HEAD'}) == 'a.txt\n', 'Commit fixes only includes edited files')
  check(g(main, {'status', '--porcelain'}) == '?? other.txt\n', 'Unrelated dirty file untouched')
  os.remove(main .. '/other.txt')
  check(not ops.state(t).busy, 'No merge in progress')
  write(ops.state(t).gitdir .. '/MERGE_HEAD', 'x\n'); check(ops.state(t).busy == 'merge', 'Merge in progress detected'); os.remove(ops.state(t).gitdir .. '/MERGE_HEAD')
  -- Push empties the range and archives the review.
  assert(ops.push(t)); assert(ops.archive(t))
  check(ops.targets(main)[1].ahead == 0, 'Push empties range')
  check(not read(main .. '/.trex/review.md') and not read(main .. '/.trex/viewed') and ls(main .. '/.trex/reviews'):find('%.md'), 'Review archived after push')
  -- Agent worktree (path with a space): merge into main, then remove.
  local wt = tmp .. '/review wt'
  g(main, {'worktree', 'add', '-b', 'agent/x', wt})
  write(wt .. '/b.txt', 'bee\n'); g(wt, {'add', '.'}); g(wt, {'commit', '-m', 'agent work'})
  write(wt .. '/dirty.txt', 'left\n')
  local targets = ops.targets(main)
  local w = targets[2]
  check(#targets == 2 and w.root == wt and w.branch == 'agent/x' and w.base == 'main' and w.ahead == 1 and w.dirty == 1 and not w.main and w.main_root == main, 'Worktree target')
  check(ops.diff(w):find('+bee', 1, true), 'Worktree range from merge-base')
  assert(ops.save(w, notes.parse('- [ ] `b.txt:1` name it\n  > bee\n')))
  write(main .. '/a.txt', 'dirty main\n')
  local ok, err = ops.merge(w)
  check(not ok and err:find('uncommitted', 1, true), 'Merge refuses dirty main checkout')
  g(main, {'checkout', '--', 'a.txt'})
  assert(ops.merge(w)); check(read(main .. '/b.txt') == 'bee\n', 'Merge into base')
  os.remove(wt .. '/dirty.txt')
  assert(ops.remove(w, false))
  check(not read(wt .. '/b.txt') and not g(main, {'branch', '--list', 'agent/x'}):find('agent', 1, true), 'Worktree and branch removed')
  check(ls(main .. '/.trex/reviews'):find('agent%-x'), 'Worktree review archived in main checkout')
  -- Discard an unmerged worktree; a locked one is refused.
  local wy, wz = tmp .. '/wt-y', tmp .. '/wt-z'
  g(main, {'worktree', 'add', '-b', 'agent/y', wy}); write(wy .. '/c.txt', 'c\n'); g(wy, {'add', '.'}); g(wy, {'commit', '-m', 'y'})
  g(main, {'worktree', 'add', '-b', 'agent/z', wz}); g(main, {'worktree', 'lock', wz})
  local y, z
  for _, x in ipairs(ops.targets(main)) do if x.branch == 'agent/y' then y = x elseif x.branch == 'agent/z' then z = x end end
  check(z.locked and not ops.remove(z, true), 'Locked worktree not removed')
  assert(ops.remove(y, true))
  check(not g(main, {'branch', '--list', 'agent/y'}):find('agent', 1, true) and not read(wy .. '/c.txt'), 'Discard deletes worktree and unmerged branch')
  g(main, {'worktree', 'unlock', wz})
  -- No upstream and no origin: no base, nothing ahead.
  local solo = tmp .. '/review-solo'
  assert(os.execute('mkdir -p ' .. solo))
  g(solo, {'init', '-b', 'main'}); g(solo, {'config', 'user.name', 'R'}); g(solo, {'config', 'user.email', 'r@example.test'})
  g(solo, {'commit', '--allow-empty', '-m', 'only'})
  local s = ops.targets(solo)[1]
  check(s.base == nil and s.ahead == 0, 'No upstream gives no base')
end)
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /Users/theo/Documents/PROJECT/lite-xl && build/src/ide-test-runner scripts/tests/ide.lua`
Expected: FAIL with `module 'plugins.scm.review_ops' not found`.

- [ ] **Step 3: Write the implementation**

Create `data/plugins/scm/review_ops.lua`:

```lua
-- Git side of commit review. Runs inside coroutines (git.git yields); each
-- function returns a value, or nil and an error message. No UI.
local git = require "plugins.scm.git"
local notes = require "plugins.scm.review_notes"
local M = {}

local function trim(s) return ((s or ""):gsub("%s+$", "")) end
local function q(root, args) return trim((git.git(root, args))) end -- "" on failure
local function read(path) local fp = io.open(path, "rb"); if not fp then return nil end; local s = fp:read("*a"); fp:close(); return s end
local function write(path, text) local fp, err = io.open(path, "wb"); if not fp then return nil, err end; fp:write(text); fp:close(); return true end
local function append(list, items) for _, item in ipairs(items) do list[#list + 1] = item end; return list end

function M.dirty_count(t)
  local out = git.git(t.root, {"status", "--porcelain", "--untracked-files=all"}) or ""
  return select(2, out:gsub("\n", ""))
end

-- Main checkout first (compared with its upstream), then every worktree
-- (compared with the main checkout's branch).
function M.targets(root)
  local out, err = git.git(root, {"worktree", "list", "--porcelain"})
  if not out then return nil, err end
  local trees, list = notes.parse_worktrees(out), {}
  local main = trees[1]
  for i, wt in ipairs(trees) do
    if not wt.bare and not wt.prunable then
      local t = {root = wt.root, branch = wt.branch, locked = wt.locked, main = i == 1, main_root = main.root}
      if t.main then
        t.base = q(t.root, {"rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"})
        if t.base == "" then t.base = q(t.root, {"rev-parse", "--abbrev-ref", "origin/HEAD"}) end
        if t.base == "" then t.base = nil end
      else
        t.base = main.branch
      end
      t.ahead = t.base and tonumber(q(t.root, {"rev-list", "--count", t.base .. "..HEAD"})) or 0
      t.dirty = M.dirty_count(t)
      list[#list + 1] = t
    end
  end
  return list
end

function M.diff(t) return git.git(t.root, {"diff", "--no-ext-diff", "--no-textconv", t.base .. "...HEAD", "--"}) end

function M.commits(t)
  local out = git.git(t.root, {"log", "--format=%H%x00%s", t.base .. "..HEAD"}) or ""
  local list = {}
  for hash, subject in out:gmatch("(%x+)\0([^\n]*)") do list[#list + 1] = {hash = hash, subject = subject} end
  return list
end

function M.show(t, hash)
  return git.git(t.root, {"show", "--no-ext-diff", "--no-textconv", "--decorate", "--format=fuller", "--stat", "--patch", hash, "--"})
end

function M.head_lines(t, path)
  local out = git.git(t.root, {"show", "HEAD:" .. path})
  if not out then return nil end
  local lines = {}
  for line in (out:sub(-1) == "\n" and out or out .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
  return lines
end

-- Blob of each path at HEAD; "-" when the path is gone (deleted file).
function M.blobs(t, paths)
  local out = git.git(t.root, append({"ls-tree", "-r", "HEAD", "--"}, paths)) or ""
  local map = {}
  for sha, path in out:gmatch("%S+ %S+ (%x+)\t([^\n]+)") do map[path] = sha end
  for _, path in ipairs(paths) do map[path] = map[path] or "-" end
  return map
end

-- `.trex/` in the target root, hidden through the info/exclude file that all
-- worktrees of the repository share.
function M.trex(t)
  local dir = t.root .. "/.trex"
  system.mkdir(dir)
  local common = q(t.root, {"rev-parse", "--git-common-dir"})
  if common ~= "" then
    if not common:match("^/") then common = t.root .. "/" .. common end
    system.mkdir(common .. "/info")
    local exclude = common .. "/info/exclude"
    local text = read(exclude) or ""
    if not ("\n" .. text .. "\n"):find("\n.trex/\n", 1, true) then
      write(exclude, text .. ((text == "" or text:sub(-1) == "\n") and "" or "\n") .. ".trex/\n")
    end
  end
  return dir
end

function M.load(t)
  return notes.parse(read(t.root .. "/.trex/review.md")), notes.viewed_parse(read(t.root .. "/.trex/viewed"))
end

function M.save(t, doc, viewed)
  local dir = M.trex(t)
  if doc then
    doc.header = doc.header or ("# Review: " .. (t.branch or "HEAD") .. " · " .. (t.base or "?") .. "..HEAD")
    local ok, err = write(dir .. "/review.md", notes.serialize(doc))
    if not ok then return nil, err end
  end
  if viewed then return write(dir .. "/viewed", notes.viewed_serialize(viewed)) end
  return true
end

-- Subset of `paths` with uncommitted changes.
function M.dirty_paths(t, paths)
  if #paths == 0 then return {} end
  local out = git.git(t.root, append({"status", "--porcelain", "--untracked-files=all", "--"}, paths)) or ""
  local list = {}
  for line in out:gmatch("[^\n]+") do list[#list + 1] = line:sub(4):match("%-> (.+)$") or line:sub(4) end
  return list
end

-- Commits only `paths`, even when the agent left other files staged.
function M.commit_fixes(t, paths, message)
  local ok, err = git.git(t.root, append({"add", "-A", "--"}, paths))
  if not ok then return nil, err end
  return git.git(t.root, append({"commit", "-m", message, "--"}, paths))
end

function M.push(t)
  if git.git(t.root, {"rev-parse", "--abbrev-ref", "@{upstream}"}) then return git.git(t.root, {"push"}) end
  if not t.branch then return nil, "Detached HEAD: check out a branch before pushing" end
  return git.git(t.root, {"push", "-u", "origin", t.branch})
end

-- Merges a worktree branch into its base inside the main checkout.
function M.merge(t)
  local main = t.main_root
  local branch = q(main, {"rev-parse", "--abbrev-ref", "HEAD"})
  if branch ~= t.base then return nil, "Main checkout is on " .. branch .. "; switch it to " .. t.base .. " first" end
  if q(main, {"status", "--porcelain", "--untracked-files=no"}) ~= "" then
    return nil, "Main checkout has uncommitted changes; commit or stash them first"
  end
  if git.git(main, {"merge", "--ff-only", t.branch}) then return true end
  if git.git(main, {"merge", "--no-edit", t.branch}) then return true end
  return nil, "Merge conflicts in " .. main .. ": resolve them in Source Control", true
end

-- Moves review.md into <main checkout>/.trex/reviews and clears viewed state.
function M.archive(t)
  local text = read(t.root .. "/.trex/review.md")
  os.remove(t.root .. "/.trex/viewed")
  if not text then return true end
  local dir = M.trex({root = t.main_root}) .. "/reviews"
  system.mkdir(dir)
  local branch = t.main and "" or "-" .. ((t.branch or "detached"):gsub("/", "-"))
  local name = os.date("%Y-%m-%d") .. branch .. "-" .. q(t.root, {"rev-parse", "--short", "HEAD"}) .. ".md"
  local ok, err = write(dir .. "/" .. name, text)
  if not ok then return nil, err end
  os.remove(t.root .. "/.trex/review.md")
  return true
end

-- Archives the review, removes the worktree and deletes its branch.
-- `force` discards unmerged commits and uncommitted files.
function M.remove(t, force)
  if t.main then return nil, "The main checkout cannot be removed" end
  if t.locked then return nil, "Worktree is locked; unlock it with git worktree unlock" end
  local ok, err = M.archive(t)
  if not ok then return nil, err end
  ok, err = git.git(t.main_root, append({"worktree", "remove"}, force and {"--force", t.root} or {t.root}))
  if not ok then return nil, err end
  if t.branch then return git.git(t.main_root, {"branch", force and "-D" or "-d", t.branch}) end
  return true
end

function M.state(t)
  local gitdir = q(t.root, {"rev-parse", "--absolute-git-dir"})
  local busy
  if read(gitdir .. "/MERGE_HEAD") then busy = "merge"
  elseif read(gitdir .. "/rebase-merge/head-name") or read(gitdir .. "/rebase-apply/head-name") then busy = "rebase" end
  return {gitdir = gitdir, busy = busy}
end

return M
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd /Users/theo/Documents/PROJECT/lite-xl && build/src/ide-test-runner scripts/tests/ide.lua`
Expected: `PASS: 73 checks ...` (49 plus 24 new).

- [ ] **Step 5: Commit**

```bash
git add data/plugins/scm/review_ops.lua scripts/tests/ide.lua
git commit -m "feat(review): add git operations for review targets and worktrees"
```

---

### Task 3: Prepare the diff view for reuse

**Files:**
- Modify: `data/plugins/scm/views.lua`:
  - lines 29-32: `Text:new` splits out `Text:set_text`
  - line 82: diff rows carry `file`
  - lines 254-255: primary toolbar pills
  - line 362: `views.open` keeps persistent views
  - add `M.prompt` and `M.confirm`
- Modify: `data/plugins/scm.lua:26-35` (use the shared `prompt`/`confirm`)
- Test: `scripts/tests/ui-runtime.lua`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `Text:set_text(text)`, which re-parses in place and resets `rows`, `files`, `hunks`, `meta` and `summary`
  - each diff row (`add`/`del`/`ctx`/`note`) has `row.file`, the file table also stored in `self.files`
  - an action with `primary = true` is drawn as an accent pill
  - a view with `persistent = true` is not closed by `views.open`
  - `views.prompt(label, submit, text, choices)` and `views.confirm(label, message, fn)`

- [ ] **Step 1: Write the failing test**

In `scripts/tests/ui-runtime.lua`, insert before `for _, item in ipairs(core.log_items) do` (around line 109):

```lua
    local views = require 'plugins.scm.views'
    local tv = views.Text('t', 'diff --git a/f.lua b/f.lua\n@@ -1 +1 @@\n-old\n+new\n')
    assert(#tv.files == 1 and tv.rows[#tv.rows].file == tv.files[1], 'Diff rows not linked to files')
    tv:set_text('')
    assert(#tv.files == 0 and #tv.rows == 0, 'Text view did not reset')
    assert(views.prompt and views.confirm, 'Shared prompt helpers missing')
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /Users/theo/Documents/PROJECT/lite-xl && PATH=/tmp/lite-xl-build-tools/bin:$PATH ./scripts/test-ide.sh build`
Expected: FAIL with `Diff rows not linked to files`.

- [ ] **Step 3: Write the implementation**

In `data/plugins/scm/views.lua`, replace:

```lua
function Text:new(name, text, actions)
  Text.super.new(self); self.name, self.actions = name, actions or {}; self.scrollable = true
  self.rows, self.width, self.hunk, self.files = {}, 0, 0, {}
  self.hunks = parse.hunks(text)
```

with:

```lua
function Text:new(name, text, actions)
  Text.super.new(self); self.name, self.actions = name, actions or {}; self.scrollable = true
  self:set_text(text)
end
-- Parses git output into rows; also reloads a view in place.
function Text:set_text(text)
  self.rows, self.width, self.hunk, self.files = {}, 0, 0, {}
  self.meta, self.summary, self.current_hunk = nil, nil, nil
  self.hunks = parse.hunks(text)
```

(The body continues unchanged and ends with `self:layout()` / `end`, which now closes `set_text`.)

Replace:

```lua
      local row = {text = l:sub(2), hunk = self.current_hunk}
```

with:

```lua
      local row = {text = l:sub(2), hunk = self.current_hunk, file = file}
```

Replace:

```lua
    renderer.draw_rect(bx, by + (bh - ph) / 2, w, ph, hovered and style.selection or style.background3)
    common.draw_text(style.font, hovered and style.accent or style.text, action.text, "center", bx, by, w, bh)
```

with:

```lua
    renderer.draw_rect(bx, by + (bh - ph) / 2, w, ph, action.primary and style.caret or hovered and style.selection or style.background3)
    common.draw_text(style.font, action.primary and style.background or hovered and style.accent or style.text, action.text, "center", bx, by, w, bh)
```

Replace:

```lua
    if view:is(Text) and old:is(Text) then node:close_view(core.root_view.root_node, old) end
```

with:

```lua
    if view:is(Text) and old:is(Text) and not old.persistent then node:close_view(core.root_view.root_node, old) end
```

Before `function M.open(view)`, add:

```lua
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
```

In `data/plugins/scm.lua`, replace the two local functions `prompt` and `confirm` (lines 26-35) with:

```lua
local prompt, confirm = views.prompt, views.confirm
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd /Users/theo/Documents/PROJECT/lite-xl && build/src/ide-test-runner scripts/tests/ide.lua && PATH=/tmp/lite-xl-build-tools/bin:$PATH ./scripts/test-ide.sh build`
Expected: both print `PASS: ...`. The UI runtime line ends with `...splits, and cleanup`.

- [ ] **Step 5: Commit**

```bash
git add data/plugins/scm/views.lua data/plugins/scm.lua scripts/tests/ui-runtime.lua
git commit -m "refactor(scm): make the diff view reloadable and share prompts"
```

---

### Task 4: Review view with targets, file pane, viewed state and command

**Files:**
- Create: `data/plugins/scm/review.lua`
- Modify: `data/plugins/scm.lua`:
  - add the require after `local views = ...` (line 10)
  - add a sidebar row in `Sidebar:rebuild` after the `commit` row
  - change the `more` click handler
  - add the command in the `commands` table
  - add the keybinding next to `keymap.add({["ctrl+shift+g"] = "scm:toggle"})`
- Test: `scripts/tests/ui-runtime.lua`

**Interfaces:**
- Consumes: everything from Tasks 1-3.
- Produces (used by Tasks 5-6):
  - `review.Review` (class)
  - `review.open(root)`, `review.show(target) -> view`, `review.candidates(list) -> list`, `review.label(t) -> string`
  - `review.saved` (`[root] = {[relpath] = true}`) and `review.save_tick`
  - view fields: `target`, `mode` (`"all"` or a commit hash), `files`, `commits`, `doc`, `viewed`, `blobs`, `all_rows`, `rows`, `fixes`, `dirty`, `state`, `loading`, `sig`, `actions`, `sel_from`, `sel_to`
  - view methods:
    - loading and state: `reload()`, `load()`, `build()`, `update_actions()`, `signature()`, `retarget(t)`, `persist(doc_changed, viewed_changed)`
    - viewed tracking and queries: `is_viewed(path)`, `open_notes(path|nil)`, `complete()`, `current_file()`, `toggle_viewed(path, value|nil)`, `viewed_next()`
    - pickers: `pick_commit()`, `pick_target()`

- [ ] **Step 1: Write the failing test**

In `scripts/tests/ui-runtime.lua`, insert before `for _, item in ipairs(core.log_items) do`:

```lua
    -- Commit review: unpushed commits on the main checkout.
    local review = require 'plugins.scm.review'
    local root = workspace .. '/mine'
    local function write(path, text) local f = assert(io.open(path, 'wb')); f:write(text); f:close() end
    local function read(path) local f = io.open(path, 'rb'); if not f then return nil end; local s = f:read('*a'); f:close(); return s end
    local function commit(cwd, message) run(cwd, {'add', '-A'}); run(cwd, {'-c', 'user.name=T', '-c', 'user.email=t@x', 'commit', '-m', message}) end
    local function wait(cond, message, seconds)
      local limit = system.get_time() + (seconds or 8)
      repeat coroutine.yield(0.1) until cond() or system.get_time() > limit
      assert(cond(), message)
    end
    local function ahead() return tonumber((scm.git.exec(root, 'git', {'rev-list', '--count', '@{upstream}..HEAD'}))) end
    run(root, {'-c', 'user.name=T', '-c', 'user.email=t@x', 'pull', '--rebase'})
    write(root .. '/a.lua', 'local a = 1\nlocal b = 2\nreturn a + b\n'); commit(root, 'add a')
    write(root .. '/b.lua', 'return 1\n'); commit(root, 'add b')
    assert(command.map['scm:review'], 'scm:review command missing')
    review.open(root)
    local rv
    wait(function() rv = core.active_view; return rv:is(review.Review) and rv.sig ~= nil end, 'Review did not open')
    assert(#rv.files == 2 and #rv.commits == ahead() and rv.target.main, 'Review range: ' .. #rv.files .. ' files, ' .. #rv.commits .. ' commits')
    rv:toggle_viewed('a.lua', true)
    wait(function() return (read(root .. '/.trex/viewed') or ''):find('a.lua', 1, true) end, 'Viewed state not saved')
    for _, row in ipairs(rv.rows) do assert(not (row.kind ~= 'file' and row.file and row.file.path == 'a.lua'), 'Viewed file not collapsed') end
    assert(not read(root .. '/.gitignore') and (read(root .. '/.git/info/exclude') or ''):find('.trex/', 1, true), '.trex not excluded')
    write(root .. '/a.lua', 'local a = 10\nlocal b = 2\nreturn a + b\n'); commit(root, 'tweak a')
    wait(function() return not rv.loading and #rv.commits == ahead() and not rv:is_viewed('a.lua') end, 'Changed file not reset to unviewed')
```

Also change the timeout at the bottom of the file from `coroutine.yield(25)` to `coroutine.yield(90)`.

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /Users/theo/Documents/PROJECT/lite-xl && PATH=/tmp/lite-xl-build-tools/bin:$PATH ./scripts/test-ide.sh build`
Expected: FAIL with `module 'plugins.scm.review' not found`.

- [ ] **Step 3: Write the implementation**

Create `data/plugins/scm/review.lua`:

```lua
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
  self.sig = self:signature()
end

-- Cheap change detector for the target: commits, index, notes file and saves from TreX.
function Review:signature()
  local parts, gitdir = {M.save_tick}, self.state.gitdir or ""
  for _, path in ipairs({gitdir .. "/HEAD", gitdir .. "/index", gitdir .. "/logs/HEAD", self.target.root .. "/.trex/review.md"}) do
    local info = system.get_file_info(path)
    parts[#parts + 1] = info and (info.modified .. ":" .. info.size) or "-"
  end
  return table.concat(parts, "|")
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
        if self.mode ~= "all" or n.outdated or not lines_in[file.path][n.to] then add({kind = "rnote", note = n}); placed[n] = true end
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
  self.actions = a
end

function Review:persist(doc_changed, viewed_changed)
  core.add_thread(function()
    local ok, err = ops.save(self.target, doc_changed and self.doc or nil, viewed_changed and self.viewed or nil)
    if not ok then core.error("Review: %s", err) end
    self.sig = self:signature()
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
  else
    views.Text.draw_row(self, row, x, y, w)
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
  ["review:viewed-and-next"] = function(v) v:viewed_next() end,
})
keymap.add({v = "review:viewed-and-next"})

return M
```

Note: `commit_fixes` and `show_uncommitted` are referenced by banner buttons here but are defined in Task 6. Until then those banners only show when fixes or dirty files exist, which the Task 4 test doesn't create. In Task 4 the test leaves no dirty files.

In `data/plugins/scm.lua`, after `local views = require "plugins.scm.views"`, add:

```lua
local review = require "plugins.scm.review"
```

In `Sidebar:rebuild`, directly after the line `add({kind = "commit", repo = repo, h = math.floor(lh() * 1.7)})`, add:

```lua
      if (status.ahead or 0) > 0 then
        add({kind = "more", repo = repo, action = "scm:review", text = "Review " .. status.ahead .. " unpushed commit" .. (status.ahead == 1 and "" or "s")})
      end
```

In `Sidebar:on_mouse_pressed`, replace:

```lua
  elseif row.kind == "more" then history(row.repo) end
```

with:

```lua
  elseif row.kind == "more" then if row.action then command.perform(row.action) else history(row.repo) end end
```

In the `commands` table, after the `["scm:history"]` entry, add:

```lua
  ["scm:review"] = function() with_repo(function(repo) review.open(repo.root) end) end,
```

After `keymap.add({["ctrl+shift+g"] = "scm:toggle"})`, add:

```lua
keymap.add({[PLATFORM == "Mac OS X" and "cmd+shift+r" or "ctrl+shift+r"] = "scm:review"})
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd /Users/theo/Documents/PROJECT/lite-xl && build/src/ide-test-runner scripts/tests/ide.lua && PATH=/tmp/lite-xl-build-tools/bin:$PATH ./scripts/test-ide.sh build`
Expected: both `PASS`.

- [ ] **Step 5: Commit**

```bash
git add data/plugins/scm/review.lua data/plugins/scm.lua scripts/tests/ui-runtime.lua
git commit -m "feat(review): add commit review tab with viewed tracking"
```

---

### Task 5: Line notes, general notes, copy and open at line

**Files:**
- Modify: `data/plugins/scm/review.lua`:
  - add methods `anchor_row`, `add_note`, `edit_note`, `delete_note`, `general_note`, `copy_notes`, `open_at`
  - extend `draw_row`, `on_mouse_pressed` and `update_actions`
  - add commands and keys
- Test: `scripts/tests/ui-runtime.lua`

**Interfaces:**
- Consumes: the Task 4 view (`rows`, `doc`, `persist`, `build`, `update_actions`, `in_diff`, `row_button`, `mode`, `target`) and `notes.reanchor` / `notes.copy_text`.
- Produces:
  - `Review:add_note(row, text|nil)`, which prompts when `text` is nil
  - `Review:general_note(text|nil)`
  - `Review:edit_note(n)` and `Review:delete_note(n)`
  - `Review:copy_notes()`
  - `Review:open_at(row)`, which opens the file at the anchored line in a split to the right and makes it the active view
  - `Review:anchor_row(row) -> row|nil`
  - `rnote` rows: `{kind = "rnote", note = n}`

- [ ] **Step 1: Write the failing test**

Append to the review block in `scripts/tests/ui-runtime.lua` (after the `Changed file not reset to unviewed` wait):

```lua
    -- Line notes follow moved code; open at line.
    local function find_row(path, text)
      for _, row in ipairs(rv.rows) do if row.kind == 'add' and row.file.path == path and row.text == text then return row end end
    end
    rv:add_note(assert(find_row('a.lua', 'local b = 2'), 'Diff line for note missing'), 'rename b')
    wait(function() return (read(root .. '/.trex/review.md') or ''):find('`a.lua:2` rename b', 1, true) end, 'Note not saved')
    local inline = false
    for _, row in ipairs(rv.rows) do inline = inline or (row.kind == 'rnote' and row.note.text == 'rename b') end
    assert(inline, 'Note not shown inline')
    rv:general_note('add tests')
    wait(function() return (read(root .. '/.trex/review.md') or ''):find('(general) add tests', 1, true) end, 'General note not saved')
    write(root .. '/a.lua', '-- header\nlocal a = 10\nlocal b = 2\nreturn a + b\n'); commit(root, 'header')
    wait(function() return not rv.loading and (read(root .. '/.trex/review.md') or ''):find('`a.lua:3` rename b', 1, true) end, 'Note did not follow moved code')
    assert(require('plugins.scm.review_notes').copy_text(rv.doc):find('a.lua:3', 1, true), 'Copy text missing note')
    rv:open_at(find_row('a.lua', 'local b = 2'))
    local dv = core.active_view
    assert(dv.doc and dv.doc.abs_filename:match('a%.lua$') and dv.doc:get_selection() == 3, 'Open at line failed')
    core.set_active_view(rv)
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /Users/theo/Documents/PROJECT/lite-xl && PATH=/tmp/lite-xl-build-tools/bin:$PATH ./scripts/test-ide.sh build`
Expected: FAIL with `attempt to call a nil value (method 'add_note')`.

- [ ] **Step 3: Write the implementation**

In `data/plugins/scm/review.lua`, add these methods before the `-- ponytail: the diff renderer is reused` comment:

```lua
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
```

In `Review:update_actions`, before `self.actions = a`, add:

```lua
  a[#a + 1] = {text = "Note", fn = function() self:general_note() end}
  a[#a + 1] = {text = "Copy notes", fn = function() self:copy_notes() end}
```

In `Review:draw_row`, replace:

```lua
  else
    views.Text.draw_row(self, row, x, y, w)
  end
end
```

with:

```lua
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
```

In `Review:on_mouse_pressed`, replace:

```lua
    for _, b in ipairs(row and row.buttons or {}) do
      if x >= b.x1 and x < b.x2 then b.fn(); return true end
    end
```

with:

```lua
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
```

Replace the command block at the bottom with:

```lua
command.add(Review, {
  ["review:add-note"] = function(v) if v.sel_from then v:add_note(v.sel_from) else core.error("Click a diff line first") end end,
  ["review:general-note"] = function(v) v:general_note() end,
  ["review:copy-notes"] = function(v) v:copy_notes() end,
  ["review:viewed-and-next"] = function(v) v:viewed_next() end,
})
keymap.add({c = "review:add-note", v = "review:viewed-and-next"})
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd /Users/theo/Documents/PROJECT/lite-xl && PATH=/tmp/lite-xl-build-tools/bin:$PATH ./scripts/test-ide.sh build`
Expected: `PASS`.

- [ ] **Step 5: Commit**

```bash
git add data/plugins/scm/review.lua scripts/tests/ui-runtime.lua
git commit -m "feat(review): add line notes that follow moved code"
```

---

### Task 6: Own fixes, push, merge, discard and banners

**Files:**
- Modify: `data/plugins/scm/review.lua`:
  - add `commit_fixes`, `show_uncommitted`, `finish`, `discard` and `next_target`
  - extend `update_actions`
- Test: `scripts/tests/ui-runtime.lua`

**Interfaces:**
- Consumes: `ops.commit_fixes`, `ops.push`, `ops.merge`, `ops.archive`, `ops.remove`, `ops.targets` and `M.candidates`.
- Produces:
  - `Review:commit_fixes(message|nil)`
  - `Review:finish(kind, yes)`, where `kind` is `"push"` or `"merge"` and `yes` skips the confirmations
  - `Review:discard(yes)`
  - `Review:next_target()`
  - `Review:show_uncommitted()`

- [ ] **Step 1: Write the failing test**

Append to the review block in `scripts/tests/ui-runtime.lua` (after `core.set_active_view(rv)`):

```lua
    -- Own fixes: only files saved from TreX are committed.
    dv.doc:insert(1, 1, '-- reviewed\n'); dv.doc:save()
    write(root .. '/wip.txt', 'agent wip\n')
    wait(function() return not rv.loading and #rv.fixes == 1 end, 'Saved fix not detected')
    rv:commit_fixes('fix: address review')
    wait(function() return scm.git.exec(root, 'git', {'log', '-1', '--format=%s'}) == 'fix: address review\n' end, 'Fix commit missing')
    assert(scm.git.exec(root, 'git', {'show', '--name-only', '--format=', 'HEAD'}) == 'a.lua\n', 'Fix commit included other files')
    os.remove(root .. '/wip.txt')
    -- Push empties the review and archives the notes.
    rv:finish('push', true)
    wait(function() return not rv.loading and #rv.all_rows == 0 end, 'Push did not empty the review', 15)
    local archived = false
    for _, name in ipairs(system.list_dir(root .. '/.trex/reviews') or {}) do archived = archived or name:match('%.md$') ~= nil end
    assert(archived and not read(root .. '/.trex/review.md'), 'Review not archived after push')
    -- Agent worktree (folder with a space): merge into main, worktree removed.
    local wt = workspace .. '/agent wt'
    run(root, {'worktree', 'add', '-b', 'agent/x', wt})
    write(wt .. '/c.lua', 'return 3\n'); commit(wt, 'agent work')
    review.open(root)
    wait(function() return rv.target.branch == 'agent/x' and not rv.loading and #rv.files == 1 end, 'Worktree target not opened')
    local labels = {}
    for _, a in ipairs(rv.actions) do labels[a.text] = true end
    assert(rv.target.base == 'main' and labels['Merge into main'] and labels['Push branch'] and labels['Discard'], 'Worktree actions missing')
    rv:finish('merge', true)
    wait(function() return read(root .. '/c.lua') == 'return 3\n' and not system.get_file_info(wt) end, 'Merge did not land or worktree not removed', 15)
    assert(not scm.git.exec(root, 'git', {'branch', '--list', 'agent/x'}):find('agent', 1, true), 'Merged branch not deleted')
    -- Discard an unmerged worktree; a locked one offers no Discard.
    local wy, wz = workspace .. '/wt-y', workspace .. '/wt-z'
    run(root, {'worktree', 'add', '-b', 'agent/y', wy}); write(wy .. '/d.lua', 'return 4\n'); commit(wy, 'y work')
    run(root, {'worktree', 'add', '-b', 'agent/z', wz}); write(wz .. '/e.lua', 'return 5\n'); commit(wz, 'z work')
    run(root, {'worktree', 'lock', wz})
    local list = assert(require('plugins.scm.review_ops').targets(root))
    for _, t in ipairs(list) do if t.branch == 'agent/z' then rv:retarget(t) end end
    wait(function() return not rv.loading and rv.target.branch == 'agent/z' end, 'Locked worktree not opened')
    for _, a in ipairs(rv.actions) do assert(a.text ~= 'Discard', 'Locked worktree offers Discard') end
    for _, t in ipairs(list) do if t.branch == 'agent/y' then rv:retarget(t) end end
    wait(function() return not rv.loading and rv.target.branch == 'agent/y' end, 'Worktree y not opened')
    rv:discard(true)
    wait(function() return not system.get_file_info(wy) end, 'Discard did not remove worktree', 15)
    assert(not scm.git.exec(root, 'git', {'branch', '--list', 'agent/y'}):find('agent', 1, true), 'Discarded branch not deleted')
    run(root, {'worktree', 'unlock', wz})
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /Users/theo/Documents/PROJECT/lite-xl && PATH=/tmp/lite-xl-build-tools/bin:$PATH ./scripts/test-ide.sh build`
Expected: FAIL with `attempt to call a nil value (method 'commit_fixes')`.

- [ ] **Step 3: Write the implementation**

In `data/plugins/scm/review.lua`, add before the `-- ponytail: the diff renderer is reused` comment:

```lua
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
      local ok, err = ops.remove(t, true)
      if not ok then core.error("Discard: %s", err); return end
      core.log("Discarded %s", t.branch or t.root)
      self:next_target()
    end)
  end
  if yes then return run() end
  views.confirm("Discard worktree", string.format("Delete worktree %s and branch %s with %d unmerged commit%s? This cannot be undone.",
    t.root, t.branch or "(detached)", #self.commits, #self.commits == 1 and "" or "s"), run)
end
```

In `Review:update_actions`, before `self.actions = a`, add:

```lua
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd /Users/theo/Documents/PROJECT/lite-xl && build/src/ide-test-runner scripts/tests/ide.lua && PATH=/tmp/lite-xl-build-tools/bin:$PATH ./scripts/test-ide.sh build`
Expected: both `PASS`.

- [ ] **Step 5: Commit**

```bash
git add data/plugins/scm/review.lua scripts/tests/ui-runtime.lua
git commit -m "feat(review): commit own fixes and push, merge or discard worktrees"
```

---

### Task 7: Visual check, docs, install

**Files:**
- Modify: `docs/ide-features.md` (append a section)

- [ ] **Step 1: Build, package and install**

```bash
cd /Users/theo/Documents/PROJECT/lite-xl
export PATH=/tmp/lite-xl-build-tools/bin:$PATH
ninja -C build-release && ./scripts/package-custom-macos.sh build-release
rm -rf /Applications/TreX.app && cp -R build-release/TreX.app /Applications/TreX.app
osascript -e 'quit app "TreX"' 2>/dev/null; open /Applications/TreX.app || (sleep 2; open /Applications/TreX.app)
```

Expected: TreX launches. If the package script writes the app somewhere else, use the path it prints.

- [ ] **Step 2: Make a review scenario and screenshot it**

```bash
cd /tmp && rm -rf trex-review-demo && git init -q -b main trex-review-demo && cd trex-review-demo
git commit -q --allow-empty -m base && git worktree add -q -b agent/demo ../trex-review-demo-wt
cd ../trex-review-demo-wt && printf 'local a = 1\nlocal b = 2\nreturn a + b\n' > a.lua && git add . && git commit -q -m "feat: add a"
open -a /Applications/TreX.app /tmp/trex-review-demo
```

In TreX, press `cmd+shift+r`. Add a note by clicking the line-number gutter of `local b = 2`, mark `a.lua` viewed with `v`, then run `screencapture -x /tmp/review.png` and look at it (Read tool).

Expected:
- a file pane on the left showing `1/1 reviewed · 1 note`
- the diff on the right with an accent note band under line 2
- a toolbar showing `agent/demo vs main`, `All changes`, `Note`, `Copy notes`, `Merge into main` (accent), `Push branch` and `Discard`

Fix any overlap or clipping before continuing.

- [ ] **Step 3: Write docs**

Append to `docs/ide-features.md`:

```markdown
## Commit review

Press **Cmd+Shift+R** (Ctrl+Shift+R elsewhere), or click **Review N unpushed
commits** in Source Control, to review work before it leaves your machine.
TreX lists the main checkout when it is ahead of its upstream, and every git
worktree with commits ahead of the main checkout's branch (agent worktrees from
t3code, Claude Code and others are found through `git worktree list`).

The left pane lists changed files. Click the box or press **v** to mark a file
viewed and jump to the next one; viewed files collapse, and become unviewed
again when a new commit changes them. The toolbar switches between all changes
and a single commit.

Click a line number (or select a line and press **c**; Shift+click selects a
range) to leave a note. Notes are saved to `.trex/review.md` in the checkout,
which git ignores through `info/exclude`. **Copy notes** puts the open notes
on the clipboard for your agent; the agent can also read the file and tick
`[x]` when done. Notes follow their code when it moves and are marked outdated
when it disappears.

Double-click a line to open the file beside the review. Files you save while
reviewing appear in an **Uncommitted fixes** banner; **Commit fixes** commits
only those files as `fix: address review`.

Finish with **Push** (main checkout), or for a worktree **Merge into
<branch>** (then remove the worktree), **Push branch**, or **Discard**, which
deletes the worktree and its branch. Finished reviews are archived to
`.trex/reviews/` in the main checkout.
```


- [ ] **Step 4: Run the full test suite one last time**

Run: `cd /Users/theo/Documents/PROJECT/lite-xl && PATH=/tmp/lite-xl-build-tools/bin:$PATH ./scripts/test-ide.sh build`
Expected: `PASS` from both runners.

- [ ] **Step 5: Commit**

```bash
git add docs/ide-features.md
git commit -m "docs(review): document commit review"
```
