local core = require 'core'
local init = core.init
function core.init(...)
  init(...)
  local config = require 'core.config'
  local command = require 'core.command'
  local keymap = require 'core.keymap'
  config.plugins.terminal.shell, config.plugins.terminal.args = '/bin/sh', {}
  local function verify()
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
    local tree = require 'plugins.treeview'
    assert(#tree.toolbar.toolbar_commands == 1 and tree.toolbar.toolbar_commands[1].command == 'scm:toggle', 'Git toolbar missing')
    assert(core.compose_window_title('') == 'TreX', 'Window branding missing')
    assert(command.perform('scm:toggle'))
    assert(command.perform('terminal:new'))
    local panel = core.active_view
    local session = assert(panel:session())
    panel:on_text_input("printf 'UI_TEST_OK\\n'")
    assert(keymap.on_key_pressed('return'))
    local deadline = system.get_time() + 5
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
    assert(scm.open().size.x > 0, 'Source control pane has zero width')
    command.perform('terminal:split')
    coroutine.yield(0.2)
    assert(#panel.sessions == 2 and panel.split, 'Split terminal did not create a second shell')
    command.perform('terminal:close')
    command.perform('terminal:close')
    assert(#panel.sessions == 0, 'Closed terminal session retained')
    command.perform('scm:toggle')
    coroutine.yield(0.1)
    for _, item in ipairs(core.log_items) do assert(not item.text:match('stack traceback'), item.text) end
    print('PASS: nested workspace repositories, Git toolbar, TreX branding, pane layout, terminal input, splits, and cleanup')
    core.quit(true)
  end
  core.add_thread(function()
    local ok, err = pcall(verify)
    if not ok then io.stderr:write(tostring(err) .. '\n'); os.exit(1) end
  end)
  core.add_thread(function() coroutine.yield(10); io.stderr:write('Editor UI test timed out\n'); os.exit(1) end)
end
return core
