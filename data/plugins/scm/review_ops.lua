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
  local out = git.git(t.root, {"log", "--format=%H%x00%s%x00%ar", t.base .. "..HEAD"}) or ""
  local list = {}
  for hash, subject, time in out:gmatch("(%x+)\0([^\0\n]*)\0([^\n]*)") do list[#list + 1] = {hash = hash, subject = subject, time = (time:gsub(" ago$", ""))} end
  return list
end

function M.show(t, hash)
  return git.git(t.root, {"show", "--no-ext-diff", "--no-textconv", "--diff-merges=first-parent", "--decorate", "--format=fuller", "--stat", "--patch", hash, "--"})
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
  -- -z: plain porcelain quotes paths with spaces or quotes.
  local out = git.git(t.root, append({"status", "--porcelain", "-z", "--untracked-files=all", "--"}, paths)) or ""
  local list, skip = {}, false
  for entry in out:gmatch("([^\0]*)\0") do
    if skip then skip = false
    else list[#list + 1] = entry:sub(4); skip = entry:match("^[RC]") ~= nil end -- rename source follows
  end
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
  -- git would refuse later; check first so the review is not archived away.
  if not force and M.dirty_count(t) > 0 then return nil, "Worktree has uncommitted changes; commit them or use Discard" end
  local ok, err = M.archive(t)
  if not ok then return nil, err end
  ok, err = git.git(t.main_root, append({"worktree", "remove"}, force and {"--force", t.root} or {t.root}))
  if not ok then return nil, err end
  if t.branch then return git.git(t.main_root, {"branch", force and "-D" or "-d", t.branch}) end
  return true
end

-- Commits on the target not reachable from any other branch or remote.
function M.unmerged(t)
  local args = {"rev-list", "--count", "HEAD", "--not"}
  -- --exclude is relative to refs/heads/ when it precedes --branches.
  if t.branch then args[#args + 1] = "--exclude=" .. t.branch end
  return tonumber(q(t.root, append(args, {"--branches", "--remotes"}))) or 0
end

function M.state(t)
  local gitdir = q(t.root, {"rev-parse", "--absolute-git-dir"})
  local busy
  if read(gitdir .. "/MERGE_HEAD") then busy = "merge"
  elseif read(gitdir .. "/rebase-merge/head-name") or read(gitdir .. "/rebase-apply/head-name") then busy = "rebase" end
  return {gitdir = gitdir, busy = busy}
end

return M
