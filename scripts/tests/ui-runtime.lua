local core = require 'core'
local init = core.init
function core.init(...)
  init(...)
  local config = require 'core.config'
  local command = require 'core.command'
  local keymap = require 'core.keymap'
  local style = require 'core.style'
  config.plugins.terminal.shell, config.plugins.terminal.args = '/bin/sh', {}
  local function verify()
    local deadline
    local scm = require 'plugins.scm'
    local workspace = assert(os.getenv('LITE_USERDIR')) .. '/workspace'
    assert(system.mkdir(workspace))
    workspace = assert(system.absolute_path(workspace))
    for _, name in ipairs({'first', 'second'}) do
      assert(system.mkdir(workspace .. '/' .. name))
      local out, err = scm.git.exec(workspace, 'git', {'init', '-b', 'main', name})
      assert(out, err)
    end
    -- A non-repository parent is the workspace shown in the reported failure.
    core.add_project(workspace)
    scm.git.discover()
    assert(scm.git.by_root[workspace .. '/first'], 'First nested repository missing')
    assert(scm.git.by_root[workspace .. '/second'], 'Second nested repository missing')
    local total = #scm.git.repositories
    scm.git.discover()
    assert(#scm.git.repositories == total, 'Repeated discovery duplicated repositories')
    -- Background sync without opening the panel: a push from another clone
    -- must show up as an incoming commit after the automatic fetch.
    config.plugins.scm.fetch_interval = 1
    local function run(cwd, args) local out, err = scm.git.exec(cwd, 'git', args); assert(out, err) end
    run(workspace, {'init', '--bare', '-b', 'main', 'remote.git'})
    run(workspace, {'clone', 'remote.git', 'mine'}); run(workspace, {'clone', 'remote.git', 'theirs'})
    for _, name in ipairs({'theirs'}) do
      run(workspace .. '/' .. name, {'-c', 'user.name=T', '-c', 'user.email=t@x', 'commit', '--allow-empty', '-m', 'base'})
      run(workspace .. '/' .. name, {'push', 'origin', 'main'})
    end
    run(workspace .. '/mine', {'pull'})
    local mine = assert(scm.git.add(workspace .. '/mine'))
    run(workspace .. '/theirs', {'-c', 'user.name=T', '-c', 'user.email=t@x', 'commit', '--allow-empty', '-m', 'incoming'})
    run(workspace .. '/theirs', {'push', 'origin', 'main'})
    deadline = system.get_time() + 6
    repeat coroutine.yield(0.2) until mine.status.behind == 1 or system.get_time() > deadline
    assert(mine.status.behind == 1, 'Background fetch did not detect incoming commit: ' .. tostring(mine.status.upstream) .. ' ' .. tostring(mine.last_fetch) .. ' ' .. #scm.git.repositories .. ' ' .. tostring(mine.error))
    run(workspace .. '/mine', {'-c', 'user.name=T', '-c', 'user.email=t@x', 'commit', '--allow-empty', '-m', 'local'})
    deadline = system.get_time() + 4
    repeat coroutine.yield(0.2) until mine.status.ahead == 1 or system.get_time() > deadline
    assert(mine.status.ahead == 1, 'Commit from terminal not detected')
    local tree = require 'plugins.treeview'
    local has_scm = false
    for _, item in ipairs(tree.toolbar.toolbar_commands) do has_scm = has_scm or item.command == 'scm:toggle' end
    assert(has_scm and tree.toolbar.size.x > 0, 'Activity bar missing')
    assert(core.compose_window_title('') == 'TreX', 'Window branding missing')
    assert(command.perform('scm:toggle'))
    assert(command.perform('terminal:new'))
    local panel = core.active_view
    local session = assert(panel:session())
    panel:on_text_input("printf 'UI_TEST_OK\\n'")
    assert(keymap.on_key_pressed('return'))
    deadline = system.get_time() + 5
    local found = false
    repeat
      coroutine.yield(0.1)
      for _, row in ipairs(session.term:screen()) do
        for _, run in ipairs(row) do if run[1]:find('UI_TEST_OK', 1, true) then found = true end end
      end
    until found or system.get_time() > deadline
    assert(found, 'Terminal UI input did not reach the shell')
    assert(panel.size.y > 0, 'Terminal pane has zero height')
    local scm = require 'plugins.scm'
    local sidebar = scm.open()
    assert(sidebar.size.x > 0, 'Source control pane has zero width')
    sidebar:rebuild()
    local kinds = {}
    for _, row in ipairs(sidebar.rows) do kinds[row.kind] = true end
    assert(kinds.section and kinds.repo and kinds.message and kinds.commit, 'Source control sections missing')
    command.perform('terminal:split')
    coroutine.yield(0.2)
    assert(#panel.sessions == 2 and panel.split, 'Split terminal did not create a second shell')
    command.perform('terminal:close')
    command.perform('terminal:close')
    assert(#panel.sessions == 0, 'Closed terminal session retained')
    command.perform('scm:toggle')
    coroutine.yield(0.1)
    local backlog = require 'plugins.backlog'
    local path = config.plugins.backlog.path
    local fp = assert(io.open(path, 'wb'))
    fp:write('# BACKLOG\nnotes stay\n## TODO\n- [ ] first\n- [x] second\n\n## DONE\n\n## CONFIG\nAPI_KEY=secret\n')
    fp:close()
    command.perform('backlog:open-markdown'); command.perform('backlog:toggle')
    coroutine.yield(1.2)
    assert(backlog.open_count() == 1, 'Backlog did not load items')
    command.perform('backlog:archive-completed')
    fp = assert(io.open(path, 'rb')); local saved = fp:read('*a'); fp:close()
    assert(saved == '# BACKLOG\nnotes stay\n## TODO\n- [ ] first\n\n## DONE\n- [x] second\n\n## CONFIG\nAPI_KEY=secret\n', 'Backlog archive wrote: ' .. saved)
    local bp = backlog.panel(); bp:on_mouse_pressed('left', bp.position.x + 20, bp.position.y + bp.size.y - 1, 1)
    for _, row in ipairs(bp.rows) do if row.kind == 'heading' and row.line.text == 'CONFIG' then
      bp:on_mouse_pressed('left', bp.position.x + 20, bp.position.y + math.floor((style.font:get_height() + style.padding.y) * 1.5) + row.y + 2 - bp.scroll.y, 1)
    end end
    bp:rebuild()
    local secret_row = false
    for _, row in ipairs(bp.rows) do secret_row = secret_row or (row.kind == 'text' and row.secret) end
    assert(secret_row, 'CONFIG entries not shown as secrets')
    for _, row in ipairs(bp.rows) do bp.hover_row = row; bp:draw_row(row, 0, 0, bp.size.x) end
    assert(bp.visible and bp.size.x > 0 and bp.position.x > tree.position.x, 'Backlog not docked on the right')
    command.perform('backlog:toggle')
    assert(not bp.visible, 'Backlog did not hide')
    local views = require 'plugins.scm.views'
    local tv = views.Text('t', 'diff --git a/f.lua b/f.lua\n@@ -1 +1 @@\n-old\n+new\n')
    assert(#tv.files == 1 and tv.rows[#tv.rows].file == tv.files[1], 'Diff rows not linked to files')
    tv:set_text('')
    assert(#tv.files == 0 and #tv.rows == 0, 'Text view did not reset')
    local function first_add(v) for _, r in ipairs(v.rows) do if r.kind == 'add' then return r end end end
    local lua_diff = views.Text('t', 'diff --git a/f.lua b/f.lua\n@@ -1 +1 @@\n-old\n+local x = 1\n')
    local toks = lua_diff:tokens(first_add(lua_diff))
    assert(toks and toks[1] == 'keyword' and toks[2] == 'local', 'Diff line not highlighted')
    local plain_diff = views.Text('t', 'diff --git a/f.zzz b/f.zzz\n@@ -1 +1 @@\n+local x = 1\n')
    assert(plain_diff:tokens(first_add(plain_diff)) == nil, 'Plain file got syntax tokens')
    local sides = views.Text('t', 'diff --git a/f.lua b/f.lua\n@@ -1 +1 @@\n---[[ old\n+local x = 1\n@@ -9 +9 @@\n return x\n')
    toks = sides:tokens(first_add(sides))
    assert(toks and toks[1] == 'keyword', 'Deleted line state leaked into the added line: ' .. tostring(toks and toks[1]))
    for _, r in ipairs(sides.rows) do assert(not (r.kind == 'ctx' and r.tokens), 'Undrawn hunk was tokenized') end
    assert(views.prompt and views.confirm, 'Shared prompt helpers missing')
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
    scm.git.refresh(mine)
    wait(function() return (mine.status.ahead or 0) >= 2 and not mine.worker end, 'Ahead count not refreshed')
    local loaded = false
    scm.git.history(mine, function() loaded = true end, true)
    wait(function() return loaded end, 'History not loaded')
    local head = (scm.git.exec(root, 'git', {'rev-parse', 'HEAD'})):gsub('%s+$', '')
    assert(mine.unpushed[head], 'HEAD not marked unpushed')
    assert(command.map['scm:toggle-checkpoints'], 'Toggle checkpoints command missing')
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
    rv:toggle_viewed('a.lua', true)
    local kept = false
    for _, row in ipairs(rv.rows) do kept = kept or (row.kind == 'rnote' and row.note.text == 'rename b') end
    assert(kept, 'Note hidden when its file is viewed')
    rv:toggle_viewed('a.lua', false)
    write(root .. '/a.lua', '-- header\nlocal a = 10\nlocal b = 2\nreturn a + b\n'); commit(root, 'header')
    wait(function() return not rv.loading and (read(root .. '/.trex/review.md') or ''):find('`a.lua:3` rename b', 1, true) end, 'Note did not follow moved code')
    assert(require('plugins.scm.review_notes').copy_text(rv.doc):find('a.lua:3', 1, true), 'Copy text missing note')
    rv:open_at(find_row('a.lua', 'local b = 2'))
    local dv = core.active_view
    assert(dv.doc and dv.doc.abs_filename:match('a%.lua$') and dv.doc:get_selection() == 3, 'Open at line failed')
    core.set_active_view(rv)
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
    write(wz .. '/f.lua', 'return 6\n'); commit(wz, 'z more')
    for _, t in ipairs(assert(require('plugins.scm.review_ops').targets(root))) do if t.branch == 'agent/z' then rv:retarget(t) end end
    wait(function() return not rv.loading and rv.target.branch == 'agent/z' and #rv.files == 2 end, 'Worktree z with two commits not opened')
    local pane = rv:pane_rows()
    local idx
    for i, r in ipairs(pane) do if r.kind == 'commit' and r.text == 'z more' then idx = i end end
    assert(pane[1].kind == 'heading' and pane[2].mode == 'all' and idx, 'Commit list missing from review pane')
    rv:draw_pane()
    local plh = style.font:get_height() + style.padding.y
    rv:pane_pressed(rv.position.x + 20, rv.position.y + rv:toolbar_height() + (idx - 1) * plh + 2)
    wait(function() return not rv.loading and #rv.files == 1 and rv.files[1].path == 'f.lua' end, 'Pane commit click did not filter the diff')
    for _, a in ipairs(rv.actions) do assert(a.text ~= 'All changes', 'Old commit picker still in toolbar') end
    scm.history(mine)
    local gv
    wait(function() gv = core.active_view; return gv:is(views.Graph) and #mine.history > 2 end, 'History tab did not open')
    keymap.on_key_pressed('down'); keymap.on_key_pressed('down'); keymap.on_key_pressed('up')
    assert(gv.selected == 1, 'Arrow keys did not move History selection: ' .. tostring(gv.selected))
    gv:draw()
    os.remove(root .. '/.trex/viewed')
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
    local loaded_count, oldest = #mine.history, table.remove(mine.history)
    mine.history_done = false
    review.show_commit(mine, mine.history[#mine.history].hash)
    wait(function() return cv.target.commit == mine.history[#mine.history].hash and not cv.loading end, 'Last loaded commit not shown')
    keymap.on_key_pressed(']')
    wait(function() return cv.target.commit == oldest.hash and not cv.loading end, '] past the loaded page did not load the next one')
    assert(#mine.history == loaded_count, 'Next page not appended: ' .. #mine.history)
    keymap.on_key_pressed('v'); cv:add_note(cv.rows[#cv.rows], 'x')
    assert(not read(root .. '/.trex/review.md') and not read(root .. '/.trex/viewed'), 'Commit tab wrote review state')
    review.show_commit(mine, string.rep('0', 40))
    wait(function() return cv.target.commit == string.rep('0', 40) and not cv.loading end, 'Unknown commit not shown in the same tab')
    assert(cv.missing and cv.rows[1].kind == 'banner' and cv.rows[1].text:find('Commit not found', 1, true), 'Missing commit banner absent')
    for _, a in ipairs(cv.actions) do assert(a.text ~= 'Previous' and a.text ~= 'Next', 'Unknown commit offers ' .. a.text) end
    local reviews_after = 0
    for _, v in ipairs(core.root_view.root_node:get_children()) do if v:is(review.Review) then reviews_after = reviews_after + 1 end end
    assert(reviews_after == reviews_before + 1, 'Commit tab not reused: ' .. reviews_before .. ' -> ' .. reviews_after)
    assert(rv.target.branch == 'agent/z' and not rv.target.commit and rv.mode ~= 'all', 'Review tab state changed by commit browsing')
    local checkpoint = scm.git.exec(root, 'git', {'-c', 'user.name=T', '-c', 'user.email=t@x', 'commit-tree', 'HEAD^{tree}', '-m', 'checkpoint'})
    run(root, {'update-ref', 'refs/t3/cp', (assert(checkpoint):gsub('%s+$', ''))})
    local without = #mine.history
    command.perform('scm:toggle-checkpoints')
    wait(function() return #mine.history == without + 1 and not mine.worker end, 'Checkpoint not shown in history')
    gv:select(#mine.history)
    command.perform('scm:toggle-checkpoints')
    wait(function() return #mine.history == without and not mine.worker end, 'Checkpoint not hidden again')
    assert(gv.selected == without, 'History selection not clamped after reload: ' .. gv.selected .. ' of ' .. without)
    local syntax = require 'core.syntax'
    for file, name in pairs({['a.ts'] = 'TypeScript', ['a.tsx'] = 'TypeScript with JSX', ['a.jsx'] = 'JSX', ['a.json'] = 'JSON',
      ['a.rs'] = 'Rust', ['a.go'] = 'Go', ['a.zig'] = 'Zig', ['a.sh'] = 'Shell script', ['a.yaml'] = 'YAML', ['a.toml'] = 'TOML',
      ['Makefile'] = 'Makefile', ['a.diff'] = 'Diff', ['.env'] = '.env', ['a.scss'] = 'Sass', ['a.sql'] = 'PostgreSQL',
      ['Dockerfile'] = 'Dockerfile'}) do
      local got = syntax.get(workspace .. '/' .. file).name
      assert(got == name, file .. ' highlighted as ' .. tostring(got))
    end
    -- Language servers, using the fake server for .ts files.
    local lsp = require 'plugins.lsp'
    local src = assert(os.getenv('TREX_SOURCE'), 'TREX_SOURCE not set')
    table.insert(lsp.servers.list, 1, {name = 'fake', label = 'Fake', short = 'fake', files = {'%.ts$'}, id = 'typescript', roots = {},
      cmd = {assert(os.getenv('TREX_RUNNER'), 'TREX_RUNNER not set'), src .. '/scripts/tests/fake-lsp.lua'}, env = {TREX_DATA = src .. '/data'}})
    local ts = workspace .. '/app.ts'
    write(ts, 'const answer = 42\n\nconst answer2 = answer\n')
    local tdv = core.root_view:open_doc(core.open_doc(ts))
    wait(function() return tdv.doc.lsp and tdv.doc.lsp.state == 'ready' and #lsp.line_diagnostics(tdv.doc, 1) == 1 end, 'Diagnostics not shown', 15)
    local draw_rect, red = renderer.draw_rect, {}
    renderer.draw_rect = function(x, y, w, h, color, ...) if color == style.error then red[h] = true end; return draw_rect(x, y, w, h, color, ...) end
    core.redraw = true
    local s = math.max(1, math.floor(SCALE))
    wait(function() return red[s] and red[math.floor(6 * SCALE)] and red[math.floor(8 * SCALE)] end, 'Squiggle, gutter dot or error count not drawn')
    renderer.draw_rect = draw_rect
    assert(core.status_view:get_item('lsp:diagnostics').active and core.status_view:get_item('lsp:server').active, 'Status items hidden')
    local version = tdv.doc.lsp.docs[tdv.doc].version
    tdv.doc:insert(2, 1, '-- typed\n')
    wait(function() return tdv.doc.lsp.docs[tdv.doc].version == version + 1 end, 'Edit not synced')
    tdv.doc:remove(2, 1, 3, 1)
    coroutine.yield(0.5)
    command.perform('lsp:problems')
    local pv = core.active_view
    assert(pv.name == 'Problems' and #pv.rows == 2 and pv.rows[2].target.line == 1, 'Problems tab missing the diagnostic')
    core.set_active_view(tdv)
    local c = tdv.doc.lsp
    local old = c.rpc
    old:kill()
    wait(function() return c.state == 'ready' and c.rpc ~= old and #lsp.line_diagnostics(tdv.doc, 1) == 1 end, 'Server not restarted after crash', 15)
    tdv.doc:set_selection(1, 8)
    lsp.definition(tdv.doc, 1, 8)
    wait(function() local l, c1 = tdv.doc:get_selection(true); return core.active_view == tdv and l == 3 and c1 == 7 end, 'Definition not opened')
    tdv.doc:set_selection(2, 1)
    local mod = PLATFORM == 'Mac OS X' and 'cmd' or 'ctrl'
    local cx, cy = tdv:get_line_screen_position(1, 8)
    keymap.modkeys[mod] = true
    keymap.on_mouse_pressed('left', cx, cy + tdv:get_line_height() / 2, 1)
    keymap.modkeys[mod] = false
    wait(function() local l, c1 = tdv.doc:get_selection(true); return l == 3 and c1 == 7 end, 'Modifier-click did not go to definition')
    lsp.references(tdv.doc, 1, 8)
    wait(function() return core.active_view.name == 'References' and #core.active_view.rows == 3 end, 'References tab missing')
    assert(core.active_view.rows[3].target.line == 3, 'Reference row target wrong')
    core.set_active_view(tdv)
    local text
    lsp.hover(tdv.doc, 1, 8, function(t) text = t end)
    wait(function() return text end, 'Hover not answered')
    assert(text:find('answer is not a question', 1, true) and text:find('const answer: number', 1, true), 'Hover text: ' .. text)
    tdv.doc:set_selection(3, 1)
    lsp.next_problem(tdv, 1)
    assert(select(1, tdv.doc:get_selection()) == 1 and lsp.hover_state().text:find('fake(7)', 1, true), 'Next problem did not wrap to line 1')
    local published = lsp.client.diagnostics_for(ts)
    tdv.doc:remove(2, 1, 3, math.huge)
    wait(function() return lsp.client.diagnostics_for(ts) ~= published end, 'Shrink not synced')
    local stale = {line1 = 5, col1 = 3, line2 = 5, col2 = 40, severity = 1, message = 'stale'}
    lsp.client.diagnostics[ts] = {{line1 = 2, col1 = 1, line2 = 2, col2 = 40, severity = 2, message = 'past the end'}, stale}
    lsp.client.generation = lsp.client.generation + 1
    core.redraw = true
    coroutine.yield(0.1)
    tdv.doc:set_selection(2, 1)
    lsp.next_problem(tdv, 1)
    local l, c1 = tdv.doc:get_selection()
    assert(#tdv.doc.lines == 2 and l == 2 and c1 == #tdv.doc.lines[2], 'Stale problem not clamped into the text')
    local renamed = workspace .. '/renamed.ts'
    tdv.doc:save(renamed, renamed)
    wait(function() return lsp.client.diagnostics_for(renamed) and not lsp.client.diagnostics_for(ts) end, 'Save-as did not reopen under the new path')
    local notes = workspace .. '/notes.txt'
    tdv.doc:save(notes, notes)
    assert(tdv.doc.lsp == nil and not lsp.client.diagnostics_for(renamed), 'Saving as a file without a server kept the server')
    for _, name in ipairs({'lsp:goto-definition', 'lsp:goto-definition-at-mouse', 'lsp:find-references', 'lsp:hover',
      'lsp:document-symbols', 'lsp:workspace-symbols', 'lsp:next-problem', 'lsp:previous-problem'}) do
      assert(command.map[name], name .. ' missing')
    end
    for _, item in ipairs(core.log_items) do assert(not item.text:match('stack traceback'), item.text) end
    print('PASS: nested workspace repositories, activity bar, source control sections, backlog, background sync, TreX branding, pane layout, terminal input, splits, and cleanup')
    core.quit(true)
  end
  core.add_thread(function()
    local ok, err = pcall(verify)
    if not ok then io.stderr:write(tostring(err) .. '\n'); os.exit(1) end
  end)
  core.add_thread(function() coroutine.yield(90); io.stderr:write('Editor UI test timed out\n'); os.exit(1) end)
end
return core
