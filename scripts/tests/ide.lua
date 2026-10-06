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
local r1 = git.repositories[1]
run(function()
  local hash = g(r1.root, {'commit-tree', 'HEAD^{tree}', '-p', 'HEAD', '-m', 't3 checkpoint'}):gsub('%s+$', '')
  g(r1.root, {'update-ref', 'refs/t3/x', hash})
  local stash = g(r1.root, {'commit-tree', 'HEAD^{tree}', '-p', 'HEAD', '-m', 'WIP on main: stash'}):gsub('%s+$', '')
  g(r1.root, {'update-ref', 'refs/stash', stash})
end)
local function has_checkpoint() for _, c in ipairs(r1.history) do if c.subject == 't3 checkpoint' then return true end end return false end
git.history(r1, nil, true); drain(); check(#r1.history > 0 and not has_checkpoint(), 'Checkpoints hidden from history')
local stashed = false; for _, c in ipairs(r1.history) do if c.subject == 'WIP on main: stash' then stashed = true end end
check(not stashed, 'Stash commits hidden from history')
local ahead = {}
run(function() for h in g(r1.root, {'rev-list', '@{upstream}..HEAD'}):gmatch('%x+') do ahead[#ahead + 1] = h end end)
local marked = 0; for _ in pairs(r1.unpushed) do marked = marked + 1 end
check(#ahead == 1 and r1.unpushed[ahead[1]] and marked == 1, 'Unpushed commits marked')
package.loaded['core.config'].plugins = {scm = {show_checkpoints = true}}
git.history(r1, nil, true); drain(); check(has_checkpoint(), 'Checkpoints shown when enabled')
package.loaded['core.config'].plugins = nil
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
  write(main .. '/s p.txt', 'spaced\n')
  check(ops.dirty_paths(t, {'s p.txt'})[1] == 's p.txt' and ops.commit_fixes(t, {'s p.txt'}, 'fix: spaced'), 'Commit fixes with a spaced path')
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
  check(not ops.remove(w, false) and read(wt .. '/.trex/review.md'), 'Failed removal keeps the review')
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
  check(ops.unmerged(y) == 1 and ops.unmerged({root = wy, branch = 'agent/y'}) == 1, 'Unmerged count with and without base')
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
-- Language servers: JSON, framing, columns, URIs, roots, server table, diagnostics.
system.get_file_info = system.get_file_info or function(path)
  local f = io.open(path, 'rb'); if f then f:close(); return {type = 'file'} end
end
do
  local json = require 'plugins.lsp.json'
  local util = require 'plugins.lsp.util'
  local rpc = require 'plugins.lsp.rpc'
  local servers = require 'plugins.lsp.servers'
  local t = json.decode(json.encode({a = {1, 2}, s = 'é "q"\n', n = json.null, e = {}}))
  check(t.a[2] == 2 and t.s == 'é "q"\n' and t.n == nil and next(t.e) == nil, 'JSON round-trip')
  local feed = rpc.parser()
  local frame = rpc.frame({id = 1, result = 'héllo'})
  check(#feed(frame:sub(1, 10)) == 0, 'Partial frame waits')
  local got = feed(frame:sub(11) .. frame .. 'Content-Length: 7\r\n\r\n{"a"')
  check(#got == 2 and json.decode(got[2]).result == 'héllo', 'Split and merged frames, byte lengths')
  got = feed(':1}')
  check(#got == 1 and json.decode(got[1]).a == 1, 'Frame completed by a later chunk')
  check(#feed('X-Junk: 1\r\n\r\n' .. rpc.frame({id = 2})) == 1, 'Malformed header resyncs')
  check(util.byte_col('a😀b', 3) == 6 and util.utf16_col('a😀b', 6) == 3 and util.byte_col('é', 1) == 3, 'UTF-16 columns')
  check(util.uri_to_path(util.path_to_uri('/a b/é.ts')) == '/a b/é.ts' and util.path_to_uri('/a b') == 'file:///a%20b', 'File URIs')
  local tsx = servers.find('/x/app.tsx')
  check(tsx.name == 'typescript' and servers.language_id(tsx, '/x/app.tsx') == 'typescriptreact'
    and servers.find('/x/Dockerfile').name == 'docker' and servers.find('/x/a.txt') == nil, 'Server lookup by file name')
  local d = util.diagnostics({
    {range = {start = {line = 2, character = 1}, ['end'] = {line = 2, character = 3}}, severity = 2, message = 'w'},
    {range = {start = {line = 0, character = 2}, ['end'] = {line = 0, character = 4}}, message = 'e', source = 'ts', code = 2322},
  }, {'é = 1\n', '\n', 'xyz\n'})
  check(d[1].line1 == 1 and d[1].col1 == 4 and d[1].severity == 1 and util.describe(d[1]) == 'ts(2322): e' and d[2].line1 == 3, 'Diagnostics normalised and ordered')
  check(util.hover_text({kind = 'markdown', value = '```ts\nconst x: number\n```\n\nDocs'}) == 'const x: number\n\nDocs', 'Hover markdown to text')
  local times = {}
  check(util.may_restart(times, 0) and util.may_restart(times, 1) and util.may_restart(times, 2)
    and not util.may_restart(times, 3) and util.may_restart(times, 61), 'Crash restarts limited per minute')
  local root = tmp .. '/lsp-root'
  assert(os.execute("mkdir -p '" .. root .. "/pkg/src'"))
  io.open(root .. '/pkg/package.json', 'w'):close()
  check(util.find_root(root .. '/pkg/src/a.ts', {'package.json'}) == root .. '/pkg', 'Root marker found')
  check(util.find_root(root .. '/x.ts', {'nope.json'}, '/fallback') == '/fallback', 'Root falls back')
  local problems = util.problems({['/b'] = {{severity = 2, line1 = 1}, {severity = 1, line1 = 9}}, ['/a'] = {{severity = 1, line1 = 3}}, ['/c'] = {}})
  check(#problems == 2 and problems[1].path == '/a' and problems[2].items[1].line1 == 9, 'Problems grouped, errors first')
  local locs = util.locations({{targetUri = 'file:///a', targetSelectionRange = {start = {line = 1, character = 2}, ['end'] = {line = 1, character = 5}}}})
  local syms = util.symbols({{name = 'A', range = {}, selectionRange = {start = {line = 3, character = 0}, ['end'] = {line = 3, character = 1}},
    children = {{name = 'b', selectionRange = {start = {line = 4, character = 2}, ['end'] = {line = 4, character = 3}}}}}}, 'file:///s')
  check(locs[1].uri == 'file:///a' and locs[1].end_character == 5 and syms[2].name == 'A.b' and syms[2].line == 4 and syms[2].uri == 'file:///s', 'Locations and symbols flattened')
end
-- Language server client against the fake server.
do
  local client = require 'plugins.lsp.client'
  local util = require 'plugins.lsp.util'
  core.log = core.log or function() end
  local function wait(cond, what)
    local limit = system.get_time() + 15
    while not cond() do
      for _, co in ipairs(threads) do
        if coroutine.status(co) == 'suspended' then local ok, err = coroutine.resume(co); assert(ok, err) end
      end
      assert(system.get_time() < limit, what)
      system.sleep(5)
    end
  end
  local spec = {name = 'fake', label = 'Fake', short = 'fake', files = {'%.ts$'}, id = 'typescript', roots = {},
    cmd = {system.absolute_path(os.getenv('IDE_TEST_RUNNER') or 'build/src/ide-test-runner'), system.absolute_path('scripts/tests/fake-lsp.lua')},
    env = {TREX_DATA = system.absolute_path('data')}}
  local root = tmp .. '/lsp-root/pkg'
  local doc = {abs_filename = root .. '/src/a é.ts', lines = {'const answer = 42\n', '\n', 'const answer2 = answer\n'}}
  local c = client.get(spec, root)
  client.open(c, doc)
  wait(function() return c.state == 'ready' and client.diagnostics[doc.abs_filename] end, 'Fake server ready with diagnostics')
  local d = client.diagnostics[doc.abs_filename][1]
  check(d.line1 == 1 and d.col1 == 7 and d.col2 == 13 and d.message == 'answer is not a question', 'Diagnostics from server')
  wait(function() for _, l in ipairs(c.log) do if l == 'configured 1' then return true end end end, 'Server request not answered')
  check(true, 'Server request answered')
  local hover
  client.request(c, 'textDocument/hover', {textDocument = {uri = util.path_to_uri(doc.abs_filename)}, position = {line = 0, character = 7}},
    function(r) hover = r end)
  wait(function() return hover end, 'Hover not answered')
  check(util.hover_text(hover.contents) == 'const answer: number', 'Hover result')
  local old = c.rpc
  client.diagnostics[doc.abs_filename] = nil
  old:kill()
  wait(function() return c.state == 'ready' and c.rpc ~= old and client.diagnostics[doc.abs_filename] end, 'Not restarted after crash')
  check(#c.crashes == 1, 'Crash restart reopens documents')
  local gen = client.generation
  client.close(c, doc)
  check(client.diagnostics[doc.abs_filename] == nil and client.generation > gen, 'Closing a document drops its diagnostics')
  client.stop(c)
  wait(function() return c.rpc == nil end, 'Server not shut down')
  check(client.clients[c.key] == nil, 'Stopped client forgotten')
  local rpc = require 'plugins.lsp.rpc'
  local exits, failed = 0, nil
  local dead = assert(rpc.start({'/bin/sh', '-c', 'exit 0'}, {stderr = function() end, notify = function() end,
    request = function() end, exit = function() exits = exits + 1 end}))
  dead:notify('big', {text = string.rep('x', 1 << 20)})
  dead:request('never', nil, function(_, err) failed = err end)
  wait(function() return exits > 0 and failed end, 'Dead server never reported')
  check(exits == 1 and not dead.alive, 'Writing to an exited server ends the session once')
  local real, link = tmp .. '/lsp-real', tmp .. '/lsp-link'
  assert(os.execute("mkdir -p '" .. real .. "' && ln -s '" .. real .. "' '" .. link .. "'"))
  io.open(real .. '/b.ts', 'w'):close()
  local ldoc = {abs_filename = link .. '/b.ts', lines = {'const é = 42\n'}}
  local lc = client.get(spec, link)
  client.open(lc, ldoc)
  wait(function() return client.diagnostics[real .. '/b.ts'] or client.diagnostics[ldoc.abs_filename] end, 'No diagnostics via symlink')
  local ld = client.diagnostics[real .. '/b.ts']
  check(ld and ld[1].col2 == 14 and client.diagnostics_for(ldoc.abs_filename) == ld, 'Symlinked paths share one diagnostics entry')
  client.close(lc, ldoc)
  check(client.diagnostics_for(ldoc.abs_filename) == nil, 'Closing a symlinked document drops its diagnostics')
  client.stop(lc)
  wait(function() return lc.rpc == nil end, 'Symlinked server not shut down')
  local servers = require 'plugins.lsp.servers'
  servers.dir = tmp .. '/lsp-install'
  assert(os.execute("mkdir -p '" .. servers.dir .. "'"))
  local busy = 0
  for _ = 1, 2 do core.add_thread(function() busy = busy + 1; git.exec(tmp, 'sleep', {'3'}); busy = busy - 1 end) end
  wait(function() return busy == 2 end, 'Source control slots not taken')
  local ok_run, bad_run
  local started = system.get_time()
  core.add_thread(function()
    ok_run = {servers.install({install = {cmd = {'sh', '-c', 'exit 0'}}})}
    bad_run = {servers.install({install = {cmd = {'sh', '-c', 'echo no network >&2; exit 3'}}})}
  end)
  wait(function() return bad_run end, 'Install never finished')
  check(ok_run[1] and system.get_time() - started < 2, 'Installs do not queue behind source control')
  check(not bad_run[1] and bad_run[2]:find('no network', 1, true), 'Failed install reports its output')
  wait(function() return busy == 0 end, 'Source control commands never finished')
end
do
  local gh = require 'plugins.github.data'
  local function utc(y, m, d) return os.date('!%Y-%m-%dT%H:%M:%SZ', os.time({year = y, month = m, day = d, hour = 0})) end
  local w = gh.windows(os.time({year = 2026, month = 10, day = 14, hour = 15}))
  check(#w == 4 and w[1].label == 'Today' and w[4].label == 'This year', 'GitHub windows are ordered')
  check(w[1].from == utc(2026, 10, 14) and w[2].from == utc(2026, 10, 12) and w[3].from == utc(2026, 10, 1) and w[4].from == utc(2026, 1, 1), 'GitHub windows start at local midnight, Monday, the 1st and Jan 1st')
  check(gh.query(w):find('w4: contributionsCollection(from: "' .. w[4].from .. '")', 1, true), 'GitHub query aliases each window')
  local function days(counts)
    local result = {}
    for i, n in ipairs(counts) do result[i] = {date = string.format('2026-01-%02d', i), count = n} end
    return result
  end
  local s = gh.streak(days({1, 1, 1, 0, 2, 2}), '2026-01-06')
  check(s.current == 2 and s.longest == 3, 'Streak ending today, longest picks the longest run')
  s = gh.streak(days({0, 1, 1, 1, 0}), '2026-01-05')
  check(s.current == 3, 'Streak counts back from yesterday when today is 0')
  s = gh.streak(days({1, 1, 0, 0, 0}), '2026-01-05')
  check(s.current == 0 and s.longest == 2, 'Gap resets the current streak')
  local function window(c, r) return string.format('{"totalCommitContributions":%d,"totalPullRequestContributions":1,"totalIssueContributions":1,"totalPullRequestReviewContributions":1,"restrictedContributionsCount":%d}', c, r) end
  local graphql = '{"data":{"viewer":{"login":"me","w1":' .. window(0, 85) .. ',"w2":' .. window(2, 100) .. ',"w3":' .. window(3, 200)
    .. ',"w4":{"totalCommitContributions":4,"totalPullRequestContributions":1,"totalIssueContributions":1,"totalPullRequestReviewContributions":1,"restrictedContributionsCount":300,'
    .. '"contributionCalendar":{"weeks":[{"contributionDays":[{"date":"2026-01-01","contributionCount":3},{"date":"2026-01-02","contributionCount":0}]},{"contributionDays":[{"date":"2026-01-03","contributionCount":5}]}]}}}}}'
  local model = assert(gh.parse(graphql))
  check(model.login == 'me' and model.windows[1].label == 'Today' and model.windows[1].contributions == 88 and model.windows[1].commits == 0, 'GitHub contributions include restricted ones')
  check(model.windows[4].contributions == 307 and model.windows[4].commits == 4, 'GitHub year totals and commit counts')
  check(#model.days == 3 and model.days[3].date == '2026-01-03' and model.days[3].count == 5, 'GitHub calendar flattened oldest first')
  check(model.prs == nil and model.reviews == nil and model.pushes == nil and not gh.query(w):find('pullRequests', 1, true), 'GitHub no longer fetches PR, review or push lists')
  check(not gh.parse('{"errors":[{"message":"Bad credentials"}]}'), 'GitHub API errors fail the parse')
  local holes = '{"data":{"viewer":{"login":"me","w4":{"contributionCalendar":{"weeks":[null,{"contributionDays":[null,{"date":"2026-01-01"},{"date":"2026-01-02","contributionCount":2}]}]}}}}}'
  local ok_holes, holed = pcall(gh.parse, holes)
  check(ok_holes, 'GitHub parse tolerates missing fields: ' .. tostring(holed))
  check(ok_holes and holed and #holed.days == 1 and holed.days[1].count == 2, 'GitHub calendar skips null and incomplete days')
  check(gh.thousands(0) == '0' and gh.thousands(1486) == '1,486' and gh.thousands(6183) == '6,183' and gh.thousands(1234567) == '1,234,567' and gh.thousands(999) == '999', 'GitHub numbers get thousands separators')
end
assert(os.execute('rm -rf ' .. tmp))
print(string.format('PASS: %d checks against real Git repositories and a native PTY', checks))
