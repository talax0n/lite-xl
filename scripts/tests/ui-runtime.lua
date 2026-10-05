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
    write(root .. '/a.lua', '-- header\nlocal a = 10\nlocal b = 2\nreturn a + b\n'); commit(root, 'header')
    wait(function() return not rv.loading and (read(root .. '/.trex/review.md') or ''):find('`a.lua:3` rename b', 1, true) end, 'Note did not follow moved code')
    assert(require('plugins.scm.review_notes').copy_text(rv.doc):find('a.lua:3', 1, true), 'Copy text missing note')
    rv:open_at(find_row('a.lua', 'local b = 2'))
    local dv = core.active_view
    assert(dv.doc and dv.doc.abs_filename:match('a%.lua$') and dv.doc:get_selection() == 3, 'Open at line failed')
    core.set_active_view(rv)
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
