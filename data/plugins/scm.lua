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

config.plugins.scm = common.merge({width = 320, refresh_interval = 5, discovery_depth = 3, discovery_limit = 100}, config.plugins.scm)
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
local function prompt(label, submit, text, choices)
  core.command_view:enter(label, {text = text or "", submit = submit,
    suggest = choices and function(input)
      local result = {}; for _, choice in ipairs(choices) do if choice:lower():find(input:lower(), 1, true) then result[#result + 1] = choice end end
      return result
    end or nil})
end
local function confirm(label, message, fn)
  core.nag_view:show(label, message, {{text = "Cancel"}, {text = "Continue", default_yes = true}}, function(item) if item.text == "Continue" then fn() end end)
end
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
      return content
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
local function history(repo)
  git.history(repo, function()
    views.open(views.Graph(repo, git, function(commit)
      git.enqueue(repo, "Inspect commit", function()
        return git.git(repo, {"show", "--no-ext-diff", "--no-textconv", "--format=fuller", "--stat", "--patch", commit.hash, "--"})
      end, function(out)
        if out then show_output(commit.hash:sub(1, 8) .. ": " .. commit.subject, out, {
          {text = "Copy hash", fn = function() system.set_clipboard(commit.hash) end},
          {text = "Compare with HEAD", fn = function() show_git(repo, "Compare commit", {"diff", "--no-ext-diff", "--no-textconv", commit.hash, "HEAD", "--"}) end},
          {text = "Open on GitHub", fn = function()
            git.enqueue(repo, "Open commit on GitHub", function() return git.exec(repo.root, "gh", {"browse", commit.hash}) end)
          end},
          {text = "Revert", fn = function()
            confirm("Revert commit", "Create a commit reverting " .. commit.hash:sub(1, 8) .. "?", function() operation(repo, "Revert", {"revert", "--no-edit", commit.hash}) end)
          end},
          {text = "Cherry-pick", fn = function() confirm("Cherry-pick", "Apply " .. commit.hash:sub(1, 8) .. " to the current branch?", function() operation(repo, "Cherry-pick", {"cherry-pick", commit.hash}) end) end},
        }) end
      end)
    end))
  end, true)
end
local Sidebar = View:extend()
function Sidebar:new()
  Sidebar.super.new(self); self.visible = true; self.scrollable = true; self.rows = {}; self.generation = -1; self.size.x = options.width * SCALE
end
function Sidebar:get_name() return "Source Control" end
function Sidebar:get_size() return self.visible and options.width * SCALE or 0, 0 end
function Sidebar:set_target_size(axis, width)
  if axis == "x" then options.width = math.max(200, width / SCALE); core.redraw = true; return true end
end
local function lh() return style.font:get_height() + style.padding.y end
function Sidebar:get_scrollable_size() return (#self.rows + 5) * lh() end
function Sidebar:get_h_scrollable_size() return self.size.x end
function Sidebar:on_mouse_wheel(y) self.scroll.to.y = self.scroll.to.y - y * lh() * 3; return true end
function Sidebar:update()
  local width = self.visible and options.width * SCALE or 0
  if self.size.x ~= width then self.size.x = width; core.redraw = true end
  Sidebar.super.update(self)
  if self.generation == git.generation then return end
  self.generation = git.generation; self.rows = {}
  for _, repo in ipairs(git.repositories) do
    local status = repo.status
    self.rows[#self.rows + 1] = {kind = "repo", repo = repo, text = repo.name .. "  " .. (status.branch or "") .. "  +" .. (status.ahead or 0) .. "/-" .. (status.behind or 0)}
    if status.limited then self.rows[#self.rows + 1] = {kind = "error", repo = repo, text = "Preview limited to 10,000 files. Use terminal for more."} end
    if repo.busy then self.rows[#self.rows + 1] = {kind = "label", repo = repo, text = repo.busy .. "..."} end
    if repo.error then self.rows[#self.rows + 1] = {kind = "error", repo = repo, text = repo.error:match("[^\r\n]+") or repo.error} end
    for _, group in ipairs({{"Conflicts", status.conflicts}, {"Staged Changes", status.staged}, {"Changes", status.changes}}) do
      if #group[2] > 0 then
        self.rows[#self.rows + 1] = {kind = "label", repo = repo, text = group[1] .. " (" .. #group[2] .. ")"}
        for _, entry in ipairs(group[2]) do self.rows[#self.rows + 1] = {kind = "file", repo = repo, entry = entry, text = entry.status .. "  " .. entry.path} end
      end
    end
    if #status.changes + #status.staged + #status.conflicts == 0 and not repo.busy then self.rows[#self.rows + 1] = {kind = "label", repo = repo, text = "Working tree clean"} end
  end
end
function Sidebar:draw()
  if not self.visible then return end
  self:draw_background(style.background2)
  local x, y = self.position.x + style.padding.x, self.position.y + style.padding.y
  renderer.draw_text(style.font, "SOURCE CONTROL", x, y, style.text)
  self.buttons = {}; y = y + lh(); local bx = x
  for _, b in ipairs({{"Commit", "scm:commit"}, {"Pull", "scm:pull"}, {"Push", "scm:push"}, {"Graph", "scm:history"}, {"...", "scm:actions"}}) do
    local w = style.font:get_width(b[1]) + style.padding.x
    renderer.draw_text(style.font, b[1], bx, y, style.accent); self.buttons[#self.buttons + 1] = {x = bx, w = w, cmd = b[2]}; bx = bx + w
  end
  local start_y = self.position.y + lh() * 3 - self.scroll.y
  core.push_clip_rect(self.position.x, self.position.y + lh() * 3, self.size.x, self.size.y - lh() * 3)
  local first = math.max(1, math.floor(self.scroll.y / lh()))
  local last = math.min(#self.rows, first + math.ceil(self.size.y / lh()))
  for i = first, last do
    local row = self.rows[i]; local ry = start_y + (i - 1) * lh()
    if row.repo == selected_repo and (row.kind == "repo" or row.entry == selected_file) then renderer.draw_rect(self.position.x, ry, self.size.x, lh(), style.line_highlight) end
    local color = row.kind == "repo" and style.accent or row.kind == "error" and {230, 120, 120} or row.kind == "label" and style.dim or style.text
    renderer.draw_text(style.font, row.text, x + (row.kind == "file" and 8 * SCALE or 0), ry, color)
    if row.kind == "file" and row.entry.status ~= "!" then
      renderer.draw_rect(self.position.x + self.size.x - 28 * SCALE, ry, 28 * SCALE, lh(), style.background2)
      renderer.draw_text(style.font, row.entry.staged and "-" or "+", self.position.x + self.size.x - 20 * SCALE, ry, style.accent)
    end
  end
  if #git.repositories == 0 then renderer.draw_text(style.font, "Use ... to add or clone a repository", x, start_y, style.dim) end
  core.pop_clip_rect(); self:draw_scrollbar()
end
function Sidebar:on_mouse_pressed(button, x, y, clicks)
  if Sidebar.super.on_mouse_pressed(self, button, x, y, clicks) then return true end
  if y >= self.position.y + lh() and y < self.position.y + lh() * 2 then
    for _, b in ipairs(self.buttons or {}) do if x >= b.x and x < b.x + b.w then command.perform(b.cmd); return true end end
  end
  local row = self.rows[math.floor((y - self.position.y - lh() * 3 + self.scroll.y) / lh()) + 1]
  if row then
    selected_repo, selected_file = row.repo, row.entry; core.redraw = true
    if row.entry then
      if x > self.position.x + self.size.x - 28 * SCALE and row.entry.status ~= "!" then
        if row.entry.staged then unstage(row.repo, row.entry) else stage(row.repo, row.entry) end
      elseif clicks > 1 then core.root_view:open_doc(core.open_doc(row.repo.root .. PATHSEP .. row.entry.path))
      elseif button == "right" then command.perform("scm:file-actions")
      else diff(row.repo, row.entry) end
    end
  end
  return true
end
local function ensure_panel()
  if panel then return panel end
  panel = Sidebar(); set_visible(panel, true); panel.node = core.root_view:get_primary_node():split("left", panel, {x = true}, true)
  core.add_thread(function()
    git.discover()
    local index = 0
    while panel do
      if panel.visible and system.window_has_focus(core.window) and #git.repositories > 0 then
        local active = current()
        if active and not active.worker and (active.dirty or system.get_time() - active.last_refresh > options.refresh_interval) then git.refresh(active) end
        index = index % #git.repositories + 1
        local repo = git.repositories[index]
        if repo ~= active and not repo.worker and (repo.dirty or system.get_time() - repo.last_refresh > math.max(15, options.refresh_interval * 3)) then git.refresh(repo) end
      end
      coroutine.yield(1)
    end
  end)
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
      local count = 0
      local function scan(path, depth)
        if count >= options.discovery_limit then return end
        count = count + 1
        git.add(path)
        if depth >= options.discovery_depth then return end
        for _, name in ipairs(system.list_dir(path) or {}) do
          if not name:match("^%.") and name ~= "node_modules" and name ~= "vendor" and name ~= "build" then
            local child = path .. PATHSEP .. name; local info = system.get_file_info(child)
            if info and info.type == "dir" then scan(child, depth + 1); coroutine.yield(0) end
          end
        end
      end
      for _, project in ipairs(core.projects) do scan(project.path, 0) end
      core.log("Scanned %d folders; tracking %d repositories", count, #git.repositories)
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
  ["scm:stage-all"] = function() with_repo(function(repo) operation(repo, "Stage all", {"add", "--all", "--", "."}) end) end,
  ["scm:unstage-all"] = function() with_repo(function(repo)
    if repo.status.head == "(initial)" then operation(repo, "Unstage all", {"rm", "--cached", "-r", "--", "."})
    else operation(repo, "Unstage all", {"restore", "--staged", "--", "."}) end
  end) end,
  ["scm:commit"] = function() with_repo(function(repo)
    if #repo.status.conflicts > 0 then core.error("Resolve and stage conflicts before committing"); return end
    prompt("Commit message", function(message)
      repo.message = message
      if message:match("%S") then operation(repo, "Commit", {"commit", "-F", "-"}, message .. "\n", function() repo.message = "" end) end
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
keymap.add({["ctrl+shift+g"] = "scm:toggle"})
local old_add = core.add_project
function core.add_project(...)
  local project = old_add(...)
  if panel then core.add_thread(function() local repo = git.add(project.path); if repo then git.refresh(repo) end end) end
  return project
end
local Doc = require "core.doc"
local old_save = Doc.save
function Doc:save(...)
  local result = old_save(self, ...)
  for _, repo in ipairs(git.repositories) do if self.abs_filename and common.path_belongs_to(self.abs_filename, repo.root) then repo.dirty = true end end
  return result
end
return {git = git, open = ensure_panel}
