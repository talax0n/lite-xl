local core = require "core"
local process = require "core.process"
local parse = require "plugins.scm.parse"
local config = require "core.config"
local M = {repositories = {}, by_root = {}, generation = 0}
local OUTPUT_LIMIT = 8 * 1024 * 1024
function M.executable(name)
  local settings = config.plugins and config.plugins.scm or {}
  local configured = settings[name .. "_path"]
  if configured then return configured end
  if PLATFORM == "Mac OS X" and system.get_file_info then
    for _, prefix in ipairs({"/opt/homebrew/bin/", "/usr/local/bin/"}) do
      if system.get_file_info(prefix .. name) then return prefix .. name end
    end
  end
  return name
end

local function execute(cwd, executable, args, input, timeout, extra_env)
  local argv = {M.executable(executable)}; for _, value in ipairs(args) do argv[#argv + 1] = value end
  -- process.start merges this over the inherited environment, so PATH survives.
  local env = {
    GIT_OPTIONAL_LOCKS = "0", GIT_TERMINAL_PROMPT = "0", GIT_PAGER = "cat", GH_PAGER = "cat", GH_PROMPT_DISABLED = "1",
    LC_ALL = "C", GIT_LITERAL_PATHSPECS = "1",
  }
  for k, v in pairs(extra_env or {}) do env[k] = v end
  local ok, proc = pcall(process.start, argv, {cwd = cwd, env = env})
  if not ok then return nil, tostring(proc) end
  if not proc or not proc.process then return nil, "Could not start " .. executable end
  local stdout, stderr, size, written, started = {}, {}, 0, 0, system.get_time()
  if not input then proc:close_stream(process.STREAM_STDIN) end
  local closed_input = not input
  local function read(stream, dest)
    local data = proc:read(stream, 65536)
    if data and #data > 0 then dest[#dest + 1] = data; size = size + #data; return true end
    return false
  end
  while true do
    if input and not closed_input then
      if written < #input then
        local n, err = proc:write(input:sub(written + 1, written + 65536))
        if not n then proc:kill(); return nil, err or "Process input failed" end
        written = written + n
      else proc:close_stream(process.STREAM_STDIN); closed_input = true end
    end
    local out = read(process.STREAM_STDOUT, stdout)
    local err = read(process.STREAM_STDERR, stderr)
    if size > OUTPUT_LIMIT then proc:kill(); return nil, "Output exceeds 8 MiB. Narrow the selection or use the terminal." end
    if system.get_time() - started > (timeout or 120) then proc:kill(); return nil, executable .. " timed out" end
    if not proc:running() and not out and not err then break end
    coroutine.yield(0.02)
  end
  local result, errors = table.concat(stdout), table.concat(stderr)
  if proc:returncode() ~= 0 then return nil, errors ~= "" and errors or result ~= "" and result or executable .. " failed" end
  return result, errors
end
local running = 0
function M.exec(cwd, executable, args, input, timeout, env)
  while running >= 2 do coroutine.yield(0.05) end
  running = running + 1
  core.background_tasks = (core.background_tasks or 0) + 1
  local ok, result, err = pcall(execute, cwd, executable, args, input, timeout, env)
  running = running - 1
  core.background_tasks = core.background_tasks - 1
  if not ok then return nil, tostring(result) end
  return result, err
end
function M.git(repo, args, input)
  local argv = {"-c", "core.quotepath=false", "-c", "color.ui=false", "--no-pager"}
  for _, arg in ipairs(args) do argv[#argv + 1] = arg end
  return M.exec(type(repo) == "table" and repo.root or repo, "git", argv, input)
end
function M.add(path)
  local output, err = M.git(path, {"rev-parse", "--show-toplevel"})
  if not output then return nil, err end
  local root = output:gsub("[\r\n]+$", "")
  root = system.absolute_path(root) or root
  if M.by_root[root] then return M.by_root[root] end
  local repo = {root = root, name = root:match("[^/\\]+$"), dirty = true, message = "", status = {staged = {}, changes = {}, conflicts = {}}, history = {}, queue = {}, last_refresh = 0}
  M.by_root[root] = repo; M.repositories[#M.repositories + 1] = repo; M.generation = M.generation + 1
  return repo
end
function M.discover()
  if M.discovering then return end
  M.discovering = true
  local ok, err = pcall(function()
    local settings = config.plugins.scm or {}
    local limit, max_depth = settings.discovery_limit or 100, settings.discovery_depth or 3
    local queue, seen = {}, {}
    for _, project in ipairs(core.projects) do
      M.add(project.path)
      queue[#queue + 1] = {path = project.path, depth = 0}
    end
    local index, count = 1, 0
    local excluded = {node_modules = true, vendor = true, build = true, dist = true, target = true}
    while index <= #queue and count < limit do
      local entry = queue[index]; index = index + 1
      local path = system.absolute_path(entry.path) or entry.path
      if not seen[path] then
        seen[path] = true; count = count + 1
        if system.get_file_info(path .. PATHSEP .. ".git") then M.add(path) end
        if entry.depth < max_depth then
          for _, name in ipairs(system.list_dir(path) or {}) do
            if not name:match("^%.") and not excluded[name] and #queue < limit then
              local child = path .. PATHSEP .. name
              local info = system.get_file_info(child)
              if info and info.type == "dir" then queue[#queue + 1] = {path = child, depth = entry.depth + 1} end
            end
          end
        end
        coroutine.yield(0)
      end
    end
    M.discovery_limited = index <= #queue
    M.generation = M.generation + 1; core.redraw = true
  end)
  M.discovering = false
  if not ok then core.error("Repository discovery: %s", tostring(err)) end
end
-- Quiet tasks (background fetch) neither show as busy nor report errors.
function M.enqueue(repo, label, operation, done, quiet)
  repo.queue[#repo.queue + 1] = {label = label, operation = operation, done = done, quiet = quiet}
  if repo.worker then return end
  repo.worker = true
  core.add_thread(function()
    while #repo.queue > 0 do
      local task = table.remove(repo.queue, 1)
      repo.busy = not task.quiet and task.label or nil; M.generation = M.generation + 1; core.redraw = true
      local ok, result, err = pcall(task.operation)
      if not ok then err, result = result, nil end
      if not task.quiet then repo.error = result == nil and err or nil end
      repo.dirty = true
      if task.done then
        local callback_ok, callback_err = pcall(task.done, result, err)
        if not callback_ok then core.error("%s: %s", task.label, tostring(callback_err)) end
      end
      if result == nil and not task.quiet then core.error("%s: %s", task.label, err or "Operation failed") end
      repo.busy = nil; M.generation = M.generation + 1; core.redraw = true
    end
    repo.worker = false
  end)
end
function M.refresh(repo)
  if repo.refresh_queued then return end
  repo.refresh_queued = true
  M.enqueue(repo, "Refreshing", function()
    local out, err = M.git(repo, {"status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"})
    if not out then return nil, err end
    repo.status = parse.status(out); repo.dirty = false; repo.last_refresh = system.get_time()
    return true
  end, function() repo.refresh_queued = false; repo.dirty = false; repo.last_refresh = system.get_time() end)
end
-- Cheap change detector: HEAD, index and reflog move on commit, stage,
-- checkout, pull and push from any tool, including the terminal.
function M.signature(repo)
  local dir = repo.root .. PATHSEP .. ".git"
  local parts = {}
  for _, name in ipairs({"HEAD", "index", "logs" .. PATHSEP .. "HEAD", "FETCH_HEAD"}) do
    local info = system.get_file_info(dir .. PATHSEP .. name)
    parts[#parts + 1] = info and (info.modified .. ":" .. info.size) or "-"
  end
  return table.concat(parts, "|")
end
function M.fetch(repo)
  repo.last_fetch, repo.fetching = system.get_time(), true
  M.enqueue(repo, "Fetching", function() return M.git(repo, {"fetch", "--prune", "--quiet"}) end,
    function() repo.fetching, repo.last_fetch = nil, system.get_time(); repo.graph_head = nil; M.refresh(repo) end, true)
end
function M.history(repo, done, reset)
  if reset then repo.history = {}; repo.history_done = false end
  if repo.history_done or #repo.history >= 2000 then if done then done() end; return end
  M.enqueue(repo, "Loading history", function()
    repo.unpushed = repo.unpushed or {}
    if repo.status.head == "(initial)" then repo.history_done = true; return true end
    local settings = config.plugins and config.plugins.scm or {}
    -- Stash entries are local commits ("WIP on", "index on", "untracked files on").
    local args = {"log", "--exclude=refs/stash", "--all", "--date-order", "--max-count=100", "--skip=" .. #repo.history, "--format=%H%x00%P%x00%an%x00%aI%x00%D%x00%s%x00"}
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
return M
