package.path = './data/?.lua;./data/?/init.lua;' .. package.path
PLATFORM = 'Mac OS X'
PATHSEP = '/'
local threads, errors = {}, {}
local core = {projects = {}}
function core.add_thread(fn) threads[#threads + 1] = coroutine.create(fn) end
function core.error(fmt, ...) errors[#errors + 1] = string.format(fmt, ...) end
package.loaded.core = core
package.loaded['core.config'] = {fps = 60}
package.loaded['core.common'] = {}
local git = require 'plugins.scm.git'
local parse = require 'plugins.scm.parse'
local terminal = require 'terminal'
local checks = 0
local function check(value, message) assert(value, message); checks = checks + 1 end
local function run(fn)
  local co = coroutine.create(fn)
  local deadline = system.get_time() + 30
  while coroutine.status(co) ~= 'dead' do
    local ok, result = coroutine.resume(co); assert(ok, result)
    assert(system.get_time() < deadline, 'Coroutine timed out')
    if coroutine.status(co) ~= 'dead' then system.sleep(5) end
  end
end
local function drain()
  while #threads > 0 do
    local batch = threads; threads = {}
    for _, co in ipairs(batch) do
      while coroutine.status(co) ~= 'dead' do
        local ok, err = coroutine.resume(co); assert(ok, err)
        if coroutine.status(co) ~= 'dead' then system.sleep(5) end
      end
    end
  end
end
local tmp = os.tmpname(); os.remove(tmp)
assert(os.execute('mkdir -p ' .. tmp))
tmp = assert(system.absolute_path(tmp))
local function g(repo, args, input)
  local out, err = git.git(repo, args, input); assert(out, err); return out
end
run(function()
  for _, name in ipairs({'one', 'two'}) do
    local root = tmp .. '/' .. name
    assert(os.execute('mkdir -p ' .. root))
    g(root, {'init', '-b', 'main'}); g(root, {'config', 'user.name', 'IDE Test'}); g(root, {'config', 'user.email', 'ide@example.test'})
    local fp = assert(io.open(root .. '/hello.txt', 'w')); fp:write('first\nsecond\nthird\n'); fp:close()
    g(root, {'add', '.'}); g(root, {'commit', '-m', 'initial'})
    local repo = assert(git.add(root)); check(repo.root == root, 'Repository discovery')
  end
  local repo = git.repositories[1]; local root = repo.root
  check(#git.repositories == 2, 'Multiple repositories')
  check(git.add(root) == repo and #git.repositories == 2, 'Deduplicated discovery')
  local fp = assert(io.open(root .. '/hello.txt', 'w')); fp:write('changed\nsecond\nthird\n'); fp:close()
  local odd = 'space \t tab\nline.txt'
  fp = assert(io.open(root .. '/' .. odd, 'w')); fp:write('new'); fp:close()
  local status = parse.status(g(root, {'status', '--porcelain=v2', '--branch', '-z'}))
  check(status.branch == 'main' and #status.changes == 2, 'Branch and changes')
  local found; for _, entry in ipairs(status.changes) do if entry.path == odd then found = entry end end
  check(found and found.untracked, 'NUL-delimited unusual filenames')
  local diff = g(root, {'diff', '--no-ext-diff', '--', 'hello.txt'})
  local hunks = parse.hunks(diff); check(#hunks == 1, 'Hunk parsing')
  g(root, {'apply', '--cached', '-'}, hunks[1].patch)
  status = parse.status(g(root, {'status', '--porcelain=v2', '--branch', '-z'}))
  check(#status.staged == 1 and status.staged[1].path == 'hello.txt', 'Hunk staging')
  g(root, {'apply', '--cached', '--reverse', '-'}, hunks[1].patch)
  status = parse.status(g(root, {'status', '--porcelain=v2', '-z'})); check(#status.staged == 0, 'Hunk unstaging')
  g(root, {'add', '--', 'hello.txt'}); g(root, {'commit', '-F', '-'}, 'message through stdin\n')
  g(root, {'mv', 'hello.txt', 'renamed.txt'})
  status = parse.status(g(root, {'status', '--porcelain=v2', '-z'}))
  check(status.staged[1].original == 'hello.txt' and status.staged[1].path == 'renamed.txt', 'Rename parsing')
  g(root, {'commit', '-m', 'rename'})
  g(root, {'switch', '-c', 'feature'}); fp = assert(io.open(root .. '/feature.txt', 'w')); fp:write('feature'); fp:close()
  g(root, {'add', 'feature.txt'}); g(root, {'commit', '-m', 'feature'})
  g(root, {'switch', 'main'}); fp = assert(io.open(root .. '/main.txt', 'w')); fp:write('main'); fp:close()
  g(root, {'add', 'main.txt'}); g(root, {'commit', '-m', 'main'})
  g(root, {'merge', '--no-edit', 'feature'})
  local log = parse.log(g(root, {'log', '--all', '--date-order', '--format=%H%x00%P%x00%an%x00%aI%x00%D%x00%s%x00'}))
  parse.graph(log); check(#log == 6 and #log[1].parents == 2, 'Merge commit history')
  check(#log[1].edges == 2 and log[1].lane == 1, 'Commit graph merge lanes')
  g(root, {'worktree', 'add', tmp .. '/worktree', 'feature'}); local worktree = assert(git.add(tmp .. '/worktree'))
  check(worktree.root == tmp .. '/worktree', 'Git-file worktree discovery')
  g(tmp, {'init', '--bare', 'remote.git'}); g(root, {'remote', 'add', 'origin', tmp .. '/remote.git'}); g(root, {'push', '--set-upstream', 'origin', 'main'})
  status = parse.status(g(root, {'status', '--porcelain=v2', '--branch', '-z'}))
  check(status.upstream == 'origin/main' and status.ahead == 0 and status.behind == 0, 'Remote tracking')
  g(root, {'fetch', '--all', '--prune'}); g(root, {'pull', '--ff-only'})
  local out, err = git.git(root, {'definitely-invalid-command'}); check(not out and err:find('not a git command', 1, true), 'Git errors shown')
  local unborn = tmp .. '/unborn'; assert(os.execute('mkdir ' .. unborn)); g(unborn, {'init'})
  local unborn_status = parse.status(g(unborn, {'status', '--porcelain=v2', '--branch', '-z'})); check(unborn_status.head == '(initial)', 'Unborn branch')
  g(root, {'switch', '-c', 'conflicting'}); fp = assert(io.open(root .. '/renamed.txt', 'w')); fp:write('conflicting\n'); fp:close(); g(root, {'commit', '-am', 'conflicting'})
  g(root, {'switch', 'main'}); fp = assert(io.open(root .. '/renamed.txt', 'w')); fp:write('main change\n'); fp:close(); g(root, {'commit', '-am', 'main conflicting'})
  local merged = git.git(root, {'merge', 'conflicting'}); check(not merged, 'Conflict raised')
  status = parse.status(g(root, {'status', '--porcelain=v2', '-z'})); check(#status.conflicts == 1 and status.conflicts[1].path == 'renamed.txt', 'Conflict parsing')
  g(root, {'merge', '--abort'})
end)
git.refresh(git.repositories[1]); drain(); check(#errors == 0, table.concat(errors, '\n'))
check(git.repositories[1].status.branch == 'main', 'Queued status refresh')
git.history(git.repositories[1]); drain(); check(#git.repositories[1].history > 0, 'Queued history')
local function screen_text(term, offset)
  local screen, lines = term:screen(offset), {}
  for _, runs in ipairs(screen) do local text = {}; for _, run in ipairs(runs) do text[#text + 1] = run[1] end; lines[#lines + 1] = table.concat(text) end
  return table.concat(lines, '\n'), screen
end
local function wait_for(term, needle)
  local deadline = system.get_time() + 5
  repeat
    term:poll(); local text = screen_text(term)
    if text:find(needle, 1, true) then return text end
    system.sleep(10)
  until system.get_time() > deadline
  error('Terminal output missing: ' .. needle .. '\n' .. screen_text(term))
end
local many = {}
for i = 1, 10001 do many[i] = '? file-' .. i .. '\0' end
local limited = parse.status(table.concat(many))
check(#limited.changes == 10000 and limited.limited, 'Bounded status preview')
local term = terminal.start{shell = '/bin/sh', args = {}, cwd = tmp, cols = 80, rows = 12, scrollback = 30}
term:write("stty -echo; printf '\\033]0;test-shell\\007'\n")
local ready_deadline = system.get_time() + 5
repeat term:poll(); system.sleep(10) until term:screen().title == 'test-shell' or system.get_time() > ready_deadline
check(term:screen().title == 'test-shell', 'Terminal title and startup synchronization')
term:write("printf 'READY\\n'; test -t 0 && printf 'PTY_OK\\n'\n"); wait_for(term, 'PTY_OK'); check(true, 'Interactive PTY')
term:write("printf '\\033[31mRED\\033[0m UTF:界 é\\n'\n"); wait_for(term, 'UTF:界 é'); check(true, 'UTF-8 and wide characters')
local _, screen = screen_text(term); local red
for _, runs in ipairs(screen) do for _, run in ipairs(runs) do if run[1]:find('RED', 1, true) and run[4] ~= -1 then red = true end end end
check(red, 'ANSI color rendering')
check(term:copy(0, 0, 0, #screen - 1, 80):find('UTF:界 é', 1, true), 'Wide-character clipboard selection')
term:resize(100, 15); term:write("stty size\n"); wait_for(term, '15 100'); check(true, 'PTY resize')
term:write("printf '\\033[?1049hALTSCREEN'; sleep 0.2; printf '\\033[?1049lRESTORED\\n'\n"); wait_for(term, 'ALTSCREEN'); wait_for(term, 'RESTORED'); check(true, 'Alternate screen')
term:write("i=0; while [ $i -lt 500 ]; do printf 'LINE_%s\\n' \"$i\"; i=$((i+1)); done; printf 'FLOOD_DONE\\n'\n"); wait_for(term, 'FLOOD_DONE')
_, screen = screen_text(term); check(screen.history <= 30 and screen.history_bytes <= 4 * 1024 * 1024, 'Bounded scrollback')
local old = screen_text(term, 10); check(not old:find('FLOOD_DONE', 1, true), 'Scrollback navigation')
term:write('sleep 30\n'); system.sleep(100); term:char(99, 4); system.sleep(50); term:write("printf 'INTERRUPTED\\n'\n"); wait_for(term, 'INTERRUPTED'); check(true, 'Ctrl+C foreground process')
term:write('exit 7\n'); local code, deadline = nil, system.get_time() + 5
repeat local dirty; dirty, code = term:poll(); if not code then system.sleep(10) end until code or system.get_time() > deadline
check(code == 7, 'Shell exit status'); local _, _, pending = term:poll(); check(not pending, 'Exited terminal finishes background polling'); term:close(); term:close(); check(true, 'Idempotent terminal cleanup')
local closed = pcall(term.poll, term); check(not closed, 'Closed terminal rejected')
local capped = terminal.start{shell = '/bin/sh', args = {'-c', "i=0; while [ $i -lt 3000 ]; do printf 'row %s\\n' \"$i\"; i=$((i+1)); done; printf 'CAP_DONE\\n'"}, cwd = tmp, cols = 500, rows = 10, scrollback = 10000}
wait_for(capped, 'CAP_DONE')
local capped_screen = capped:screen()
check(capped_screen.history_bytes <= 4 * 1024 * 1024 and capped_screen.history < 3000, 'Hard 4 MiB scrollback cap')
capped:close()
assert(os.execute('rm -rf ' .. tmp))
print(string.format('PASS: %d checks against real Git repositories and a native PTY', checks))
