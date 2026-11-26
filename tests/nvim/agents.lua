-- Agents smoke tests, loaded by tests/nvim-smoke-test.lua with the shared helpers.
local H = ...
local uv = H.uv
local terminal_io = H.terminal_io
local agent_socket = H.agent_socket
local temp_root = H.temp_root
local agent_cli_commands = H.agent_cli_commands
local fail = H.fail
local assert_true = H.assert_true
local realpath = H.realpath
local require_command = H.require_command
local run = H.run
local write = H.write
local child_nvim_luafile_command = H.child_nvim_luafile_command
local write_executable = H.write_executable
local wait_until = H.wait_until
local read_lines = H.read_lines
local read_log = H.read_log
local visible_agent_window_count = H.visible_agent_window_count
local assert_agent_float = H.assert_agent_float
local close_agent_terminals = H.close_agent_terminals
local invoke_map = H.invoke_map
local agent_bufnr = H.agent_bufnr
local plugin_loaded = H.plugin_loaded
local worktree_test_api = H.worktree_test_api
local open_agent_test_shell = H.open_agent_test_shell

local function is_macos_ci_workspace()
  return vim.env.IS_CI_WORKSPACE == "1" and uv.os_uname().sysname == "Darwin"
end

vim.notify = function(message, level)
  if level and level >= vim.log.levels.WARN then
    io.stderr:write(tostring(message) .. "\n")
  end
end

local function log_has_prefix(path, prefix)
  for _, line in ipairs(read_log(path)) do
    if line:sub(1, #prefix) == prefix then
      return true
    end
  end
  return false
end

local function ensure_lazy_key_ready(lhs, plugin, mode)
  mode = mode or "n"
  if plugin_loaded(plugin) then
    return
  end
  local lazy_map = vim.fn.maparg(lhs, mode, false, true)
  assert_true(type(lazy_map) == "table" and type(lazy_map.callback) == "function", lhs .. " is not a lazy callback mapping")
  local lazy_callback = lazy_map.callback
  lazy_callback()
  wait_until(plugin .. " lazy load", function()
    return plugin_loaded(plugin)
  end, 3000)
  wait_until(lhs .. " real callback", function()
    local map = vim.fn.maparg(lhs, mode, false, true)
    return type(map) == "table" and type(map.callback) == "function" and map.callback ~= lazy_callback
  end, 3000)
end

local function invoke_lazy_map(lhs, plugin, mode)
  ensure_lazy_key_ready(lhs, plugin, mode)
  invoke_map(lhs, mode)
end

local function start_agent_fixture(buffers, name, cwd, title)
  local buf = vim.api.nvim_create_buf(false, true)
  buffers[#buffers + 1] = buf
  local command = "exec sleep 30"
  if title then
    command = "printf '\\033]2;%s\\007' " .. vim.fn.shellescape(title) .. "; " .. command
  end
  local ok, err = require("luanphan.agents.tmux").launch(buf, { "sh", "-c", command }, {
    kind = name,
    cwd = cwd,
    workspace = require("luanphan.plugins.worktree").agent_workspace(cwd),
    label = name,
  }, 80, 24)
  assert_true(ok, "failed to start agent fixture: " .. tostring(err))
  return buf
end

local function close_agent_fixtures(buffers)
  for _, buf in ipairs(buffers) do
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(terminal_io.stop, buf)
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
end

local function test_active_agent_discovery(repo, worktree)
  local api = worktree_test_api()
  local original_buf = vim.api.nvim_get_current_buf()
  local original_cwd = vim.fn.getcwd()
  local buffers = {}
  local agents_module
  local original_focus

  local ok, err = xpcall(function()
    local repo_codex_buf = start_agent_fixture(buffers, "codex", repo, "Review example parser")
    local worktree_codex_buf = start_agent_fixture(buffers, "codex", worktree, "Fix test failures")
    local worktree_cursor_buf = start_agent_fixture(buffers, "cursor", worktree)
    vim.b[repo_codex_buf].luanphan_view_last_used = 3
    vim.b[worktree_codex_buf].luanphan_view_last_used = 2
    vim.b[worktree_cursor_buf].luanphan_view_last_used = 1
    wait_until("agent terminal titles", function()
      return vim.b[repo_codex_buf].term_title == "Review example parser"
        and vim.b[worktree_codex_buf].term_title == "Fix test failures"
    end, 3000)

    local function live_agents()
      local instances = api.list_agent_sessions()
      assert_true(#instances == 3, "agent session discovery returned an unexpected instance count")
      local by_buffer = {}
      for _, instance in ipairs(instances) do
        by_buffer[instance.bufnr] = instance
      end
      return by_buffer
    end

    local instances = live_agents()
    local codex, peer, cursor = instances[repo_codex_buf], instances[worktree_codex_buf], instances[worktree_cursor_buf]
    assert_true(codex and codex.workspace == realpath(repo), "Codex session has the wrong workspace")
    assert_true(peer and peer.workspace == realpath(worktree), "worktree session has the wrong workspace")
    assert_true(codex.label == "Review example parser", "agent sessions ignored the terminal title")
    assert_true(cursor and cursor.label == "cursor", "untitled agent did not retain its fallback label")
    vim.b[repo_codex_buf].term_title = "Renamed parser review"
    assert_true(live_agents()[repo_codex_buf].label == "Renamed parser review", "agent session kept a stale title")

    agents_module = require("luanphan.agents.main")
    original_focus = agents_module.focus
    local focused = nil
    agents_module.focus = function(name)
      focused = name
      return true
    end
    api.activate_agent({ kind = "codex", path = original_cwd })
    assert_true(focused == "codex", "agent selection did not focus its terminal")
  end, debug.traceback)

  if agents_module and original_focus then
    agents_module.focus = original_focus
  end
  close_agent_fixtures(buffers)
  if vim.api.nvim_buf_is_valid(original_buf) then
    pcall(vim.api.nvim_set_current_buf, original_buf)
  end
  vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
  assert_true(ok, tostring(err))
end

local function test_agent_switch_replaces_visible_repo_buffer(repo, worktree)
  local api = worktree_test_api()
  local original_cwd = vim.fn.getcwd()
  local original_buf = vim.api.nvim_get_current_buf()
  local agents = require("luanphan.agents.main")
  local original_focus = agents.focus
  local buffers = {}
  local panel = agents.container

  local function window_for_buffer(bufnr)
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(win) == bufnr then
        return win
      end
    end
    return nil
  end

  local ok, err = xpcall(function()
    vim.cmd("cd " .. vim.fn.fnameescape(repo))
    local old_buf = start_agent_fixture(buffers, "codex", repo)
    local target_buf = start_agent_fixture(buffers, "cursor", worktree)
    vim.b[old_buf].luanphan_view_last_used = 1
    vim.b[target_buf].luanphan_view_last_used = 2

    panel:open_float(panel.opts.layout(), old_buf, true)
    assert_true(window_for_buffer(old_buf) ~= nil, "old repository agent fixture is not visible")

    agents.focus = function(name, bufnr)
      assert_true(name == "cursor", "agent switch focused the wrong agent type")
      assert_true(bufnr == target_buf, "agent switch did not focus the selected workspace terminal")
      if not window_for_buffer(target_buf) then
        panel:open_float(panel.opts.layout(), target_buf, true)
      end
      return true
    end

    api.activate_agent({ kind = "cursor", path = worktree, bufnr = target_buf })
    assert_true(realpath(vim.fn.getcwd()) == realpath(worktree), "agent switch did not change repositories")
    assert_true(window_for_buffer(old_buf) == nil, "old repository agent window remained visible")
    assert_true(window_for_buffer(target_buf) ~= nil, "selected repository agent window was not focused")
    assert_true(visible_agent_window_count() == 1, "agent switch left multiple agent windows visible")

    api.switch_to(repo, "worktree")
    assert_true(realpath(vim.fn.getcwd()) == realpath(repo), "workspace switch did not return to the repository")
    assert_true(window_for_buffer(target_buf) == nil, "previous workspace agent remained visible")
    assert_true(visible_agent_window_count() == 0, "workspace switch kept an agent from another cwd visible")
  end, debug.traceback)

  agents.focus = original_focus
  close_agent_fixtures(buffers)
  if vim.api.nvim_buf_is_valid(original_buf) then
    pcall(vim.api.nvim_set_current_buf, original_buf)
  end
  if vim.fn.isdirectory(original_cwd) == 1 then
    vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
  end
  assert_true(ok, tostring(err))
end

local function test_default_agent_setting()
  local agents = require("luanphan.agents.main")
  local container = require("luanphan.view_container")
  local original_file = vim.g.luanphan_default_agent_file
  local original_select = container.select
  local original_open = agents.open
  local setting_file = temp_root .. "/default-agent"
  vim.g.luanphan_default_agent_file = setting_file
  vim.fn.delete(setting_file)
  close_agent_terminals()

  local ok, err = xpcall(function()
    assert_true(agents.default_agent() == "codex", "missing default-agent setting did not fall back to Codex")

    local selected = false
    container.select = function(title, choices, on_select)
      assert_true(title == "Default Agent", "default-agent picker has the wrong title")
      assert_true(#choices == 3, "default-agent picker did not list every agent")
      assert_true(choices[1].id == "codex", "default-agent picker did not list Codex first")
      assert_true(choices[2].id == "cursor", "default-agent picker omitted Cursor")
      assert_true(choices[3].id == "claude", "default-agent picker omitted Claude")
      assert_true(choices[1].display == "codex (current)", "default-agent picker did not mark the current agent")
      selected = true
      on_select(choices[2])
    end

    local map = vim.fn.maparg("<leader>sad", "n", false, true)
    assert_true(type(map) == "table" and type(map.callback) == "function", "<leader>sad is missing its picker")
    assert_true(map.desc == "Default agent", "<leader>sad has the wrong description")
    map.callback()
    assert_true(selected, "<leader>sad did not open the default-agent picker")
    assert_true(agents.default_agent() == "cursor", "selected default agent was not persisted")
    assert_true(read_lines(setting_file)[1] == "cursor", "default-agent setting file has the wrong value")
    assert_true(vim.fn.maparg("<leader>sa", "n") == "", "<leader>sa still shadows the agent settings group")
    assert_true(vim.fn.maparg("<leader>sap", "n") == "", "old agent position shortcut is still mapped")

    local opened
    agents.open = function(name, bufnr)
      opened = { name = name, bufnr = bufnr }
      return true
    end
    agents.toggle()
    assert_true(opened and opened.name == "cursor", "empty workspace did not launch the default agent")
    assert_true(opened.bufnr == nil, "empty workspace unexpectedly reused an agent buffer")

    write(setting_file, { "unknown" })
    assert_true(agents.default_agent() == "codex", "invalid default-agent setting did not fall back to Codex")
  end, debug.traceback)

  agents.open = original_open
  container.select = original_select
  vim.g.luanphan_default_agent_file = original_file
  vim.fn.delete(setting_file)
  assert_true(ok, tostring(err))
end

local function test_filetype_refire_uses_target_buffer()
  local api = worktree_test_api()
  local original_cwd = vim.fn.getcwd()
  local original_buf = vim.api.nvim_get_current_buf()
  local fixture = temp_root .. "/filetype-context"
  local markdown_path = fixture .. "/context.md"
  local other_path = fixture .. "/other.txt"
  write(markdown_path, { "# Context" })
  write(other_path, { "other" })
  vim.cmd("cd " .. vim.fn.fnameescape(fixture))
  vim.cmd("edit " .. vim.fn.fnameescape(markdown_path))
  local markdown_buf = vim.api.nvim_get_current_buf()
  vim.cmd("edit " .. vim.fn.fnameescape(other_path))
  local other_buf = vim.api.nvim_get_current_buf()
  local group = vim.api.nvim_create_augroup("SmokeFileTypeBufferContext", { clear = true })
  local callback_buf = nil

  local ok, err = xpcall(function()
    vim.bo[markdown_buf].filetype = "markdown"
    vim.api.nvim_create_autocmd("FileType", {
      group = group,
      pattern = "markdown",
      callback = function(args)
        if args.buf == markdown_buf then
          callback_buf = vim.api.nvim_get_current_buf()
        end
      end,
    })

    api.refire_filetype_all()
    assert_true(callback_buf == markdown_buf, "FileType ran outside its target buffer context")
  end, debug.traceback)

  pcall(vim.api.nvim_del_augroup_by_id, group)
  if vim.api.nvim_buf_is_valid(original_buf) then
    pcall(vim.api.nvim_set_current_buf, original_buf)
  end
  if vim.fn.isdirectory(original_cwd) == 1 then
    vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
  end
  for _, buf in ipairs({ markdown_buf, other_buf }) do
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  assert_true(ok, err)
end

local function test_agent_cli_commands_available()
  for _, item in ipairs(agent_cli_commands) do
    if not (item.optional_in_macos_ci and is_macos_ci_workspace()) then
      require_command(item.command, { item.command, "--version" })
    end
  end
end

local function test_neovide_command_v_pastes_text_without_image_probe()
  local original_neovide = vim.g.neovide
  local original_getreg = vim.fn.getreg
  local original_paste = vim.api.nvim_paste
  local remote = require("luanphan.remote_tunnel")
  local original_clipboard_paste = remote.paste_clipboard_item
  local pasted

  local ok, err = xpcall(function()
    vim.g.neovide = true
    vim.api.nvim_exec_autocmds("UIEnter", {})
    remote.paste_clipboard_item = function()
      fail("Cmd+V attempted a tunnel clipboard request")
    end
    vim.fn.getreg = function(register)
      assert_true(register == "+", "Cmd+V read the wrong clipboard register")
      return "clipboard text"
    end
    vim.api.nvim_paste = function(text, crlf, phase)
      pasted = { text = text, crlf = crlf, phase = phase }
      return true
    end

    local mapping = vim.fn.maparg("<D-v>", "n", false, true)
    assert_true(type(mapping.callback) == "function", "Cmd+V mapping is missing")
    mapping.callback()
    assert_true(pasted and pasted.text == "clipboard text", "Cmd+V did not paste clipboard text")
    assert_true(pasted.crlf == true and pasted.phase == -1, "Cmd+V used unexpected paste semantics")
  end, debug.traceback)

  vim.g.neovide = original_neovide
  vim.fn.getreg = original_getreg
  vim.api.nvim_paste = original_paste
  remote.paste_clipboard_item = original_clipboard_paste
  assert_true(ok, err)
end

local function test_remote_clipboard_references()
  local remote = require("luanphan.remote_tunnel")
  local image, image_kind, image_path = remote.clipboard_reference("image\t/tmp/clipboard.png\n")
  assert_true(image == "[Image: /tmp/clipboard.png] ", "remote image reference is malformed")
  assert_true(image_kind == "image" and image_path == "/tmp/clipboard.png", "remote image metadata is malformed")

  local path, path_kind, remote_path = remote.clipboard_reference("directory\t/tmp/example directory\r\n")
  assert_true(path == "/tmp/example directory ", "remote directory reference is malformed")
  assert_true(path_kind == "directory" and remote_path == "/tmp/example directory", "remote path metadata is malformed")
  assert_true(remote.clipboard_reference("unknown\t/tmp/item\n") == nil, "unknown clipboard kind was accepted")
end

local function test_neovide_detach_clears_option_callbacks()
  local original_neovide = vim.g.neovide
  local original_channel = vim.g.neovide_channel_id
  local original_mousemoveevent = vim.o.mousemoveevent
  local group = vim.api.nvim_create_augroup("NvimSmokeNeovideDetach", { clear = true })
  local unrelated_id = vim.api.nvim_create_autocmd("OptionSet", {
    group = group,
    pattern = "mousemoveevent",
    callback = function() end,
  })

  vim.g.neovide = true
  vim.g.neovide_channel_id = 424242
  local injected = assert(loadstring([[
    local option_setting = "mousemoveevent"
    local function rpcnotify(method, ...)
      vim.rpcnotify(vim.g.neovide_channel_id, method, ...)
    end
    return vim.api.nvim_create_autocmd("OptionSet", {
      pattern = option_setting,
      callback = function()
        rpcnotify("option_changed", option_setting, vim.o[option_setting])
      end,
    })
  ]], "<nvim>"))
  local injected_id = injected()

  vim.api.nvim_exec_autocmds("UILeave", { data = { chan = 434343 } })
  local other_ui_preserved = vim.g.neovide
    and vim.g.neovide_channel_id == 424242
    and #vim.api.nvim_get_autocmds({ id = injected_id }) == 1
  vim.api.nvim_exec_autocmds("UILeave", { data = { chan = 424242 } })
  local lifecycle_cleared = not vim.g.neovide and vim.g.neovide_channel_id == nil
  local injected_removed = #vim.api.nvim_get_autocmds({ id = injected_id }) == 0
  local unrelated_survived = #vim.api.nvim_get_autocmds({ id = unrelated_id }) == 1
  local changed, change_error = pcall(function()
    vim.o.mousemoveevent = not original_mousemoveevent
  end)
  pcall(function()
    vim.o.mousemoveevent = original_mousemoveevent
  end)

  pcall(vim.api.nvim_del_autocmd, injected_id)
  pcall(vim.api.nvim_del_augroup_by_id, group)
  vim.g.neovide = original_neovide
  vim.g.neovide_channel_id = original_channel

  assert_true(other_ui_preserved, "another UI detach cleared the active Neovide callbacks")
  assert_true(lifecycle_cleared, "Neovide detach left stale UI state")
  assert_true(injected_removed, "Neovide detach left its OptionSet callback registered")
  assert_true(changed, "detached Neovide callback survived: " .. tostring(change_error))
  assert_true(unrelated_survived, "Neovide detach removed an unrelated OptionSet callback")
end

local function test_neovide_detach_restores_tmux_clipboard()
  local original_clipboard = vim.g.clipboard
  local original_neovide = vim.g.neovide
  local original_channel = vim.g.neovide_channel_id
  local original_env = {}
  for _, name in ipairs({ "HOME", "PATH", "SSH_CONNECTION", "TMUX" }) do
    original_env[name] = vim.env[name]
  end
  local fixture = temp_root .. "/clipboard-detach"
  local copied = fixture .. "/copied"
  write_executable(fixture .. "/bin/tmux-copy-osc52", {
    "#!/bin/sh",
    "cat > " .. vim.fn.shellescape(copied),
  })
  write_executable(fixture .. "/bin/tmux", {
    "#!/bin/sh",
    '[ "$1" = save-buffer ] || exit 1',
    "printf 'terminal clipboard\\n'",
  })

  local ok, err = xpcall(function()
    vim.env.HOME = fixture
    vim.env.PATH = fixture .. "/bin:" .. original_env.PATH
    vim.env.SSH_CONNECTION = "127.0.0.1 10000 127.0.0.1 22"
    vim.env.TMUX = fixture .. "/socket,1,0"
    local gui_copies = 0
    local function attach()
      vim.g.neovide = true
      vim.g.neovide_channel_id = 424242
      local function copy()
        assert_true(vim.g.neovide_channel_id == 424242, "copy called a detached Neovide channel")
        gui_copies = gui_copies + 1
      end
      vim.g.clipboard = {
        name = "neovide",
        copy = { ["+"] = copy, ["*"] = copy },
        paste = { ["+"] = function() return { "GUI clipboard" } end, ["*"] = function() return {} end },
        cache_enabled = 0,
      }
      vim.g.loaded_clipboard_provider = nil
      vim.cmd.runtime("autoload/provider/clipboard.vim")
      vim.api.nvim_exec_autocmds("UIEnter", { data = { chan = 424242 } })
    end

    for cycle = 1, 2 do
      attach()
      vim.api.nvim_exec_autocmds("UILeave", { data = { chan = 434343 } })
      vim.fn.setreg("+", "GUI yank")
      assert_true(gui_copies == cycle, "another UI detach replaced the Neovide provider")
      vim.api.nvim_exec_autocmds("UILeave", { data = { chan = 424242 } })
      for _, register in ipairs({ "+", "*" }) do
        local text = "terminal yank " .. cycle .. register
        vim.fn.setreg(register, text)
        assert_true(table.concat(read_lines(copied), "\n") == text, "terminal yank did not reach the copy helper")
      end
      assert_true(vim.trim(vim.fn.getreg("+")) == "terminal clipboard", "terminal paste retained the GUI callback")
      assert_true(gui_copies == cycle, "terminal yank called the stale Neovide provider")
    end
  end, debug.traceback)

  for _, name in ipairs({ "HOME", "PATH", "SSH_CONNECTION", "TMUX" }) do
    vim.env[name] = original_env[name]
  end
  vim.g.clipboard = original_clipboard
  vim.g.neovide = original_neovide
  vim.g.neovide_channel_id = original_channel
  vim.g.loaded_clipboard_provider = nil
  vim.cmd.runtime("autoload/provider/clipboard.vim")
  assert_true(ok, err)
end

local function test_terminal_reference_links()
  local root = temp_root .. "/terminal-references"
  local first_path = root .. "/example-repo/main.go"
  local second_path = root .. "/example-repo/other.go"
  write(first_path, { "package main" })
  write(second_path, { "package main" })

  local buf = vim.api.nvim_create_buf(false, true)
  local references = require("luanphan.terminal_references")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "line example-repo/main.go:7 plain example-repo/other.go labelled @example-repo/main.go:L11 missing.go:2 https://example.com/docs?q=1#part.",
  })
  local original_neovide = vim.g.neovide
  vim.g.neovide = true
  local namespace = references.attach(buf, root)
  local previous_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_win_set_buf(0, buf)
  assert_true(
    #vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, {}) == 0,
    "terminal references scanned output before a click"
  )

  local click_map = vim.fn.maparg("<M-LeftMouse>", "n", false, true)
  local command_click_map = vim.fn.maparg("<D-LeftMouse>", "n", false, true)
  local terminal_click_map = vim.fn.maparg("<M-LeftMouse>", "t", false, true)
  assert_true(
    type(click_map) == "table" and type(click_map.callback) == "function",
    "terminal reference normal-mode click mapping is missing"
  )
  assert_true(
    type(terminal_click_map) == "table" and type(terminal_click_map.callback) == "function",
    "terminal reference terminal-mode click mapping is missing"
  )
  assert_true(
    type(command_click_map) == "table" and type(command_click_map.callback) == "function",
    "terminal reference command-click mapping is missing"
  )

  local clicked_target = nil
  local clicked_url = nil
  local original_open = references.open
  local original_open_url = references.open_url
  local original_getmousepos = vim.fn.getmousepos
  references.open = function(path, line, column)
    clicked_target = { path = path, line = line, column = column }
    return true
  end
  vim.fn.getmousepos = function()
    return {
      winid = vim.api.nvim_get_current_win(),
      line = 1,
      column = assert((vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""):find("example%-repo")),
    }
  end
  local click_result = click_map.callback()
  vim.wait(50, function()
    return clicked_target ~= nil
  end)
  assert_true(click_result == "<Ignore>", "terminal reference click was not consumed")
  assert_true(clicked_target and clicked_target.path == first_path, "terminal reference click opened the wrong file")
  assert_true(clicked_target.line == 7 and clicked_target.column == 1, "terminal reference click lost its position")

  clicked_target = nil
  vim.fn.getmousepos = function()
    return {
      winid = vim.api.nvim_get_current_win(),
      line = 1,
      column = assert((vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""):find("plain")) + 6,
    }
  end
  assert_true(click_map.callback() == "<Ignore>", "plain terminal file reference was not consumed")
  vim.wait(50, function()
    return clicked_target ~= nil
  end)
  assert_true(clicked_target and clicked_target.path == second_path, "plain terminal file reference opened the wrong file")
  assert_true(clicked_target.line == 1 and clicked_target.column == 1, "plain terminal file reference lost its position")

  clicked_target = nil
  vim.fn.getmousepos = function()
    return {
      winid = vim.api.nvim_get_current_win(),
      line = 1,
      column = assert((vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""):find("@example%-repo")),
    }
  end
  assert_true(click_map.callback() == "<Ignore>", "L-prefixed terminal reference was not consumed")
  vim.wait(50, function()
    return clicked_target ~= nil
  end)
  assert_true(clicked_target and clicked_target.path == first_path, "L-prefixed terminal reference opened the wrong file")
  assert_true(clicked_target.line == 11 and clicked_target.column == 1, "L-prefixed terminal reference lost its position")

  vim.g.neovide = false
  references.open_url = function(url)
    clicked_url = url
    return true
  end
  vim.fn.getmousepos = function()
    return {
      winid = vim.api.nvim_get_current_win(),
      line = 1,
      column = assert((vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""):find("https://", 1, true)),
    }
  end
  assert_true(click_map.callback() == "<Ignore>", "terminal URL click was not consumed")
  vim.wait(50, function()
    return clicked_url ~= nil
  end)
  assert_true(clicked_url == "https://example.com/docs?q=1#part", "terminal URL click opened the wrong URL")

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "https://google.com",
    "workspace %",
  })
  clicked_url = nil
  vim.fn.getmousepos = function()
    return { winid = vim.api.nvim_get_current_win(), line = 1, column = 1 }
  end
  assert_true(click_map.callback() == "<Ignore>", "URL before a shell prompt was not consumed")
  vim.wait(50, function()
    return clicked_url ~= nil
  end)
  assert_true(clicked_url == "https://google.com", "shell prompt was appended to URL: " .. tostring(clicked_url))

  local reference_win = vim.api.nvim_get_current_win()
  local narrow_win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = 1,
    col = 1,
    width = 10,
    height = 6,
    style = "minimal",
  })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "https://go",
    "ogle.com",
    "workspace",
    "%",
  })
  clicked_url = nil
  vim.fn.getmousepos = function()
    return { winid = narrow_win, line = 1, column = 1 }
  end
  assert_true(click_map.callback() == "<Ignore>", "narrow wrapped URL was not consumed")
  vim.wait(50, function()
    return clicked_url ~= nil
  end)
  assert_true(clicked_url == "https://google.com", "narrow prompt was appended to URL: " .. tostring(clicked_url))

  vim.api.nvim_win_set_width(narrow_win, 20)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "wrapped https://exam",
    "ple.com/a/very/long/",
    "path/to/resource?query=value&other=yes#part.   ",
  })
  clicked_url = nil
  vim.fn.getmousepos = function()
    return { winid = narrow_win, line = 1, column = 9 }
  end
  assert_true(click_map.callback() == "<Ignore>", "wrapped URL first line was not consumed")
  vim.wait(50, function()
    return clicked_url ~= nil
  end)
  assert_true(
    clicked_url == "https://example.com/a/very/long/path/to/resource?query=value&other=yes#part",
    "wrapped URL first line opened the wrong URL: " .. tostring(clicked_url)
  )

  clicked_url = nil
  vim.fn.getmousepos = function()
    return { winid = narrow_win, line = 2, column = 4 }
  end
  assert_true(click_map.callback() == "<Ignore>", "wrapped URL continuation was not consumed")
  vim.wait(50, function()
    return clicked_url ~= nil
  end)
  assert_true(
    clicked_url == "https://example.com/a/very/long/path/to/resource?query=value&other=yes#part",
    "wrapped URL continuation opened the wrong URL: " .. tostring(clicked_url)
  )

  vim.api.nvim_win_set_width(narrow_win, 70)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "apply (https://example.invalid/access?payload=%7B%22auth_typ",
    "    e%22%3A%22person%22%2C%22role%22%3A%22tester%22%7D). See details.",
  })
  assert_true(
    vim.fn.strdisplaywidth(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]) < vim.api.nvim_win_get_width(narrow_win),
    "hard-wrapped URL fixture unexpectedly fills the window"
  )
  local click_remote = require("luanphan.remote_tunnel")
  local original_click_remote_enabled = click_remote.enabled
  local original_click_ui_open = vim.ui.open
  click_remote.enabled = function()
    return false
  end
  vim.ui.open = function(url)
    clicked_url = url
    return true
  end
  references.open_url = original_open_url
  vim.g.neovide = true
  clicked_url = nil
  vim.fn.getmousepos = function()
    return { winid = narrow_win, line = 2, column = 8 }
  end
  assert_true(command_click_map.callback() == "<Ignore>", "hard-wrapped command-click URL was not consumed")
  vim.wait(50, function()
    return clicked_url ~= nil
  end)
  assert_true(
    clicked_url == "https://example.invalid/access?payload=%7B%22auth_type%22%3A%22person%22%2C%22role%22%3A%22tester%22%7D",
    "hard-wrapped command-click opened the wrong URL: " .. tostring(clicked_url)
  )
  assert_true(not clicked_url:find("%s"), "hard-wrapped command-click URL contains whitespace")

  local wrapped_paths = {
    { lines = { "See tracker (example-repo/    ", "    other.go). See details." },
      columns = { 14, 5 }, line = 1, column = 1 },
    { lines = { "Trace (example-", "  repo/    ", "  other.go:L7:2)." },
      columns = { 8, 3, 3 }, line = 7, column = 2 },
  }
  for _, example in ipairs(wrapped_paths) do
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, example.lines)
    for row, col in ipairs(example.columns) do
      clicked_target = nil
      vim.api.nvim_win_set_buf(reference_win, previous_buf)
      vim.api.nvim_set_current_win(reference_win)
      vim.fn.getmousepos = function() return { winid = narrow_win, line = row, column = col } end
      local mapping = vim.fn.maparg("<D-LeftMouse>", "n", false, true)
      assert_true(mapping.callback and mapping.callback() == "<Ignore>", "wrapped path in an unfocused pane was not consumed")
      vim.wait(50, function() return clicked_target ~= nil end)
      assert_true(clicked_target and clicked_target.path == second_path and clicked_target.line == example.line
        and clicked_target.column == example.column, "wrapped path opened the wrong file or position")
    end
  end
  vim.api.nvim_win_set_buf(reference_win, buf)
  vim.g.neovide = false
  click_remote.enabled = original_click_remote_enabled
  vim.ui.open = original_click_ui_open
  vim.api.nvim_win_close(narrow_win, true)
  vim.api.nvim_set_current_win(reference_win)
  references.open = original_open
  references.open_url = original_open_url

  local remote = require("luanphan.remote_tunnel")
  local original_remote_enabled = remote.enabled
  local original_ui_open = vim.ui.open
  remote.enabled = function()
    return false
  end
  vim.ui.open = function(url)
    clicked_url = url
    return true
  end
  clicked_url = nil
  assert_true(references.open_url("https://example.com/from-terminal"), "terminal URL did not open locally")
  assert_true(clicked_url == "https://example.com/from-terminal", "terminal URL used the wrong local opener")
  remote.enabled = original_remote_enabled
  vim.ui.open = original_ui_open

  vim.fn.getmousepos = function()
    return { winid = vim.api.nvim_get_current_win(), line = 1, column = 1 }
  end
  local plain_click_result = click_map.callback()
  vim.fn.getmousepos = original_getmousepos
  assert_true(plain_click_result == "<M-LeftMouse>", "plain terminal click was not passed through")

  for index = 1, 20 do
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "update-" .. index .. " example-repo/other.go:1:1",
    })
  end
  assert_true(
    #vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, {}) == 0,
    "terminal output updates created reference extmarks"
  )

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "wrapped example-repo/",
    "  other.go:L1:1",
  })

  clicked_target = nil
  references.open = function(path, line, column)
    clicked_target = { path = path, line = line, column = column }
    return true
  end
  vim.fn.getmousepos = function()
    return { winid = vim.api.nvim_get_current_win(), line = 1, column = 9 }
  end
  assert_true(click_map.callback() == "<Ignore>", "wrapped reference first line was not consumed")
  vim.wait(50, function()
    return clicked_target ~= nil
  end)
  assert_true(clicked_target and clicked_target.path == second_path, "wrapped reference first line opened the wrong file")

  clicked_target = nil
  vim.fn.getmousepos = function()
    return { winid = vim.api.nvim_get_current_win(), line = 2, column = 3 }
  end
  assert_true(click_map.callback() == "<Ignore>", "wrapped reference second line was not consumed")
  vim.wait(50, function()
    return clicked_target ~= nil
  end)
  references.open = original_open
  vim.fn.getmousepos = original_getmousepos
  assert_true(clicked_target and clicked_target.path == second_path, "wrapped reference second line opened the wrong file")

  local toggle_map = vim.fn.maparg("<leader>sl", "n", false, true)
  assert_true(type(toggle_map) == "table" and type(toggle_map.callback) == "function", "terminal reference toggle is missing")
  toggle_map.callback()
  vim.fn.getmousepos = function()
    return { winid = vim.api.nvim_get_current_win(), line = 2, column = 3 }
  end
  assert_true(click_map.callback() == "<M-LeftMouse>", "disabled terminal reference click was consumed")
  vim.fn.getmousepos = original_getmousepos
  toggle_map.callback()
  assert_true(
    #vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, {}) == 0,
    "enabling terminal references scanned existing output"
  )
  vim.api.nvim_win_set_buf(0, previous_buf)
  vim.g.neovide = original_neovide

  vim.api.nvim_buf_delete(buf, { force = true })

  vim.cmd("tabnew")
  vim.cmd("edit " .. vim.fn.fnameescape(first_path))
  local editor_win = vim.api.nvim_get_current_win()
  local terminal_buf = vim.api.nvim_create_buf(false, true)
  local terminal_win = vim.api.nvim_open_win(terminal_buf, true, {
    relative = "editor",
    row = 1,
    col = 1,
    width = 20,
    height = 5,
    style = "minimal",
  })
  vim.fn.termopen({ "sh", "-c", "sleep 30" })
  vim.b[terminal_buf].luanphan_persist_term = true

  assert_true(references.open(second_path, 1, 1), "terminal reference did not open")
  assert_true(vim.api.nvim_get_current_win() == editor_win, "terminal reference did not focus the editor window")
  assert_true(realpath(vim.api.nvim_buf_get_name(0)) == realpath(second_path), "terminal reference replaced the wrong buffer")
  assert_true(not vim.api.nvim_win_is_valid(terminal_win), "terminal reference left its agent float open")
  assert_true(vim.api.nvim_buf_is_valid(terminal_buf), "terminal reference deleted the persistent agent buffer")

  local job = vim.fn.getbufvar(terminal_buf, "terminal_job_id")
  if type(job) == "number" and job > 0 then
    pcall(vim.fn.jobstop, job)
    pcall(vim.fn.jobwait, { job }, 1000)
  end
  pcall(vim.api.nvim_buf_delete, terminal_buf, { force = true })
  vim.cmd("tabclose!")
end

local function test_agent_terminal_reference_restores_view(repo)
  vim.cmd("cd " .. vim.fn.fnameescape(repo))
  local target_path = repo .. "/terminal-reference-target.txt"
  write(target_path, { "target" })
  vim.cmd("edit " .. vim.fn.fnameescape(target_path))
  local source_win = vim.api.nvim_get_current_win()

  local agents = require("luanphan.agents.main")
  open_agent_test_shell(agents)
  wait_until("agent terminal for reference view", function()
    return visible_agent_window_count() == 1
  end, 1000)

  local function assert_resize_restores_float(win, label)
    local width = vim.api.nvim_win_get_width(win)
    vim.api.nvim_win_set_config(win, { width = width - 1 })
    vim.api.nvim_exec_autocmds("VimResized", {})
    wait_until(label .. " restores its width", function()
      return vim.api.nvim_win_get_width(win) == width
    end, 1000)
  end

  local terminal_buf = vim.api.nvim_get_current_buf()
  local terminal_win = vim.api.nvim_get_current_win()
  assert_true(vim.api.nvim_win_get_config(terminal_win).zindex == 45, "agent terminal has the wrong float layer")
  assert_resize_restores_float(terminal_win, "new agent terminal")
  assert_true(not vim.wo[terminal_win].wrap, "agent terminal enabled editor line wrapping")
  assert_true(vim.b[terminal_buf].matchparen_timeout == 0, "agent terminal enabled matchparen scans")
  assert_true(vim.b[terminal_buf].matchparen_insert_timeout == 0, "agent terminal enabled insert matchparen scans")
  terminal_io.send(terminal_buf, "i=1; while [ $i -le 80 ]; do echo line-$i; i=$((i + 1)); done\n")
  wait_until("agent terminal scrollback", function()
    return vim.api.nvim_buf_line_count(terminal_buf) > 60
  end, 1000)
  local function top_line()
    local top = vim.fn.winsaveview().topline
    return vim.trim(vim.api.nvim_buf_get_lines(terminal_buf, top - 1, top, false)[1] or "")
  end
  terminal_io.send(terminal_buf, "printf '\\033[2J\\033[HVIEWPORT_PROMPT\\n'\n")
  local prompt_row
  wait_until("agent live prompt output", function()
    for row, line in ipairs(vim.api.nvim_buf_get_lines(terminal_buf, 0, -1, false)) do
      if line == "VIEWPORT_PROMPT" then
        prompt_row = row
        return true
      end
    end
  end, 3000)
  vim.fn.winrestview({ topline = prompt_row, lnum = prompt_row + 1, col = 0 })
  vim.wait(30)
  vim.cmd("stopinsert")
  vim.defer_fn(function() vim.api.nvim_input("<Esc>") end, 20)
  vim.api.nvim_feedkeys("i", "xt!", false)
  assert_true(agents.hide(), "could not hide the live agent")
  open_agent_test_shell(agents, terminal_buf)
  wait_until("agent prompt after input mode and reopening", function()
    return top_line() == "VIEWPORT_PROMPT"
  end, 3000)

  assert_true(agents.hide(), "could not hide the agent before background output")
  terminal_io.send(terminal_buf, "seq 1 70; printf '\\033[2J\\033[HVIEWPORT_HIDDEN_OUTPUT\\n'\n")
  wait_until("agent output while hidden", function()
    local lines = vim.api.nvim_buf_get_lines(terminal_buf, -30, -1, false)
    return vim.tbl_contains(lines, "VIEWPORT_HIDDEN_OUTPUT")
  end, 3000)
  open_agent_test_shell(agents, terminal_buf)
  wait_until("agent follows output received while hidden", function()
    local visible = vim.api.nvim_buf_get_lines(terminal_buf, vim.fn.line("w0") - 1, vim.fn.line("w$"), false)
    return vim.tbl_contains(visible, "VIEWPORT_HIDDEN_OUTPUT")
  end, 3000)
  terminal_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_cursor(terminal_win, { 10, 0 })
  vim.api.nvim_win_call(terminal_win, function()
    vim.cmd("normal! zt")
  end)
  local saved_view = vim.api.nvim_win_call(terminal_win, vim.fn.winsaveview)

  local references = require("luanphan.terminal_references")
  assert_true(references.open(target_path, 1, 1), "agent terminal reference did not open")
  local editor = require("luanphan.view_container.editor")
  assert_true(editor.window(terminal_win) == vim.api.nvim_get_current_win(), "reference did not open in an editor tile")
  agents.toggle()
  assert_true(not vim.api.nvim_win_is_valid(terminal_win), "toggling Agents left the terminal visible")
  assert_true(vim.api.nvim_get_current_win() == source_win, "toggling Agents did not restore the main editor")

  open_agent_test_shell(agents, terminal_buf)
  wait_until("agent terminal reopened with saved view", function()
    return visible_agent_window_count() == 1
  end, 1000)
  vim.wait(30)
  local reopened_win = vim.api.nvim_get_current_win()
  assert_true(vim.api.nvim_win_get_config(reopened_win).zindex == 45, "reopened agent terminal has the wrong float layer")
  assert_resize_restores_float(reopened_win, "reopened agent terminal")
  local restored_view = vim.api.nvim_win_call(reopened_win, vim.fn.winsaveview)
  assert_true(restored_view.lnum == saved_view.lnum, "agent terminal cursor returned to the end")
  assert_true(restored_view.topline == saved_view.topline, "agent terminal viewport returned to the end")

  vim.cmd("stopinsert")
  assert_true(editor.focus(reopened_win), "could not focus the reopened editor tile")
  vim.cmd.quit()
  close_agent_terminals()
  local target_buf = vim.fn.bufnr(target_path)
  if target_buf >= 0 and vim.api.nvim_buf_is_valid(target_buf) then
    pcall(vim.api.nvim_buf_delete, target_buf, { force = true })
  end
end

local function test_agent_keys_invoke_cli_commands()
  local shim_dir = temp_root .. "/agent-cli-shims"
  local log = temp_root .. "/agent-cli-invocations.log"
  vim.fn.mkdir(shim_dir, "p")
  write(log, {})

  for _, item in ipairs(agent_cli_commands) do
    write_executable(shim_dir .. "/" .. item.command, {
      "#!/bin/sh",
      "printf '%s|%s|%s\\n' \"$(basename \"$0\")\" \"$PWD\" \"$*\" >> \"$NVIM_AGENT_SMOKE_LOG\"",
      "sleep 30",
    })
  end

  local old_path = vim.env.PATH
  local old_log = vim.env.NVIM_AGENT_SMOKE_LOG
  local agents = require("luanphan.agents.main")
  local original_default_file = vim.g.luanphan_default_agent_file
  local default_file = temp_root .. "/agent-cli-default"
  vim.env.PATH = shim_dir .. ":" .. old_path
  vim.env.NVIM_AGENT_SMOKE_LOG = log
  vim.g.luanphan_default_agent_file = default_file
  vim.fn.delete(vim.g.luanphan_recent_paths_file)
  vim.fn.delete(default_file)
  local expected_recent_folder = vim.fn.getcwd()

  local ok, err = xpcall(function()
    local normal_map = vim.fn.maparg("<leader>a", "n", false, true)
    local visual_map = vim.fn.maparg("<leader>a", "x", false, true)
    local select_map = vim.fn.maparg("<leader>a", "s", false, true)
    assert_true(type(normal_map) == "table" and normal_map.desc == "Toggle agents", "<leader>a normal should toggle agents")
    assert_true(type(visual_map) == "table" and visual_map.desc == "Send to active agent", "<leader>a visual should send to the active agent")
    assert_true(type(select_map) == "table" and select_map.desc == "Send to active agent", "<leader>a select should send to the active agent")

    for _, lhs in ipairs({ "<leader>;", "<leader>ac", "<leader>af", "<leader>as", "<leader>xc", "<leader>xf", "<leader>xs", "<leader>cf" }) do
      assert_true(
        vim.fn.maparg(lhs, "n") == "" and vim.fn.maparg(lhs, "x") == "" and vim.fn.maparg(lhs, "s") == "",
        lhs .. " should be removed"
      )
    end

    for index, item in ipairs(agent_cli_commands) do
      assert_true(agents.set_default_agent(item.name), "could not select " .. item.name .. " as default agent")
      if index == 1 then
        invoke_lazy_map("<leader>a", "luanphan-codex-agent")
      else
        invoke_map("<leader>a")
      end
      wait_until(item.command .. " invocation", function()
        return log_has_prefix(log, item.command .. "|")
      end, 3000)
      assert_agent_float(vim.api.nvim_get_current_win(), item.command .. " terminal")
      close_agent_terminals()
    end
    assert_true(plugin_loaded("luanphan-codex-agent"), "shared agent mapping did not lazy-load")
    local recent = require("luanphan.recent_paths").entries()
    assert_true(
      recent[1] and realpath(recent[1]) == realpath(expected_recent_folder),
      "<leader>a did not cache current folder"
    )
    local cursor_regular = false
    local plugin_args = "--plugin-dir " .. vim.fn.stdpath("config") .. "/lua/luanphan/agents/plugins/cursor"
    for _, line in ipairs(read_log(log)) do
      local command, _, args = line:match("^([^|]+)|([^|]*)|(.*)$")
      if command == "cursor-agent" and args == plugin_args then
        cursor_regular = true
      end
    end
    assert_true(cursor_regular, "Cursor agent did not start the regular native TUI")
  end, debug.traceback)

  vim.env.PATH = old_path
  vim.env.NVIM_AGENT_SMOKE_LOG = old_log
  vim.g.luanphan_default_agent_file = original_default_file
  vim.fn.delete(default_file)
  close_agent_terminals()
  assert_true(ok, tostring(err))
end

local function test_leader_a_sends_visual_selection_to_active_agent()
  local shim_dir = temp_root .. "/codex-send-shim"
  local invoke_log = temp_root .. "/codex-send-invocations.log"
  local file = temp_root .. "/codex-send-buffer.txt"
  vim.fn.mkdir(shim_dir, "p")
  write(invoke_log, {})
  write_executable(shim_dir .. "/mcodex", {
    "#!/bin/sh",
    "printf '%s|%s|%s\\n' \"$(basename \"$0\")\" \"$PWD\" \"$*\" >> \"$NVIM_AGENT_SMOKE_LOG\"",
    "sleep 30",
  })

  local old_cwd = vim.fn.getcwd()
  local old_path = vim.env.PATH
  local old_log = vim.env.NVIM_AGENT_SMOKE_LOG
  local original_default_file = vim.g.luanphan_default_agent_file
  local default_file = temp_root .. "/codex-send-default"
  vim.env.PATH = shim_dir .. ":" .. old_path
  vim.env.NVIM_AGENT_SMOKE_LOG = invoke_log
  vim.g.luanphan_default_agent_file = default_file
  write(default_file, { "codex" })

  local ok, err = xpcall(function()
    vim.cmd("cd " .. vim.fn.fnameescape(temp_root))
    write(file, {
      "selected payload line",
      "unselected payload line",
    })
    vim.cmd("edit " .. vim.fn.fnameescape(file))

    local normal_map = vim.fn.maparg("<leader>a", "n", false, true)
    local visual_map = vim.fn.maparg("<leader>a", "x", false, true)
    local select_map = vim.fn.maparg("<leader>a", "s", false, true)
    assert_true(type(normal_map) == "table" and normal_map.desc == "Toggle agents", "<leader>a normal should toggle agents")
    assert_true(type(visual_map) == "table" and visual_map.desc == "Send to active agent", "<leader>a visual should send to the active agent")
    assert_true(type(select_map) == "table" and select_map.desc == "Send to active agent", "<leader>a select should send to the active agent")
    assert_true(vim.fn.maparg("<leader>cc", "n") == "", "<leader>cc should be removed")
    assert_true(vim.fn.maparg("<leader>cs", "x") == "", "<leader>cs should be removed")

    vim.cmd("normal! ggV")
    ensure_lazy_key_ready("<leader>a", "luanphan-codex-agent", "x")
    vim.cmd("normal! ggV")
    invoke_map("<leader>a", "x")
    wait_until("codex invocation", function()
      return log_has_prefix(invoke_log, "mcodex|")
    end, 3000)

    wait_until("codex selection marker", function()
      local bufnr = agent_bufnr("codex")
      if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
        return false
      end
      local terminal_text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "")
      return terminal_text:find("codex-send-buffer.txt:1-1", 1, true) ~= nil
    end, 3000)
    assert_true(plugin_loaded("luanphan-codex-agent"), "codex agent did not lazy-load")
  end, debug.traceback)

  vim.env.PATH = old_path
  vim.env.NVIM_AGENT_SMOKE_LOG = old_log
  vim.g.luanphan_default_agent_file = original_default_file
  vim.fn.delete(default_file)
  pcall(vim.cmd, "cd " .. vim.fn.fnameescape(old_cwd))
  close_agent_terminals()
  local file_buf = vim.fn.bufnr(file)
  if file_buf >= 0 and vim.api.nvim_buf_is_valid(file_buf) then
    pcall(vim.api.nvim_buf_delete, file_buf, { force = true })
  end
  assert_true(ok, tostring(err))
end

local function test_agent_sidebar_restore(repo, agent)
  local root = temp_root .. "/" .. agent .. "-sidebar"
  local first = "00000000-0001-4000-8000-000000000001"
  local second = "00000000-0002-4000-8000-000000000002"
  if agent == "codex" then
    for _, id in ipairs({ first, second }) do
      write(root .. "/codex/sessions/rollout-example-" .. id .. ".jsonl", {})
    end
    write_executable(root .. "/bin/mcodex", {
      "#!/bin/sh",
      'id="$2"',
      '[ "$id" != "-c" ] || id="$TEST_AGENT_THREAD"',
      'printf "%s|%s|%s\\n" "$1" "$(pwd -P)" "$2" >> "$TEST_AGENT_LOG"',
      'title="Example ${id##*-}"',
      'case "$*" in *project-name*) title="$title | $(basename "$PWD")";; esac',
      'printf "\\033]0;%.29s... | %s\\007" "$id" "$title"',
      "exec cat",
    })
  else
    write_executable(root .. "/bin/cursor-agent", {
      "#!/bin/sh",
      '[ "$1" = "--plugin-dir" ] || exit 1',
      'hook="$2/hooks/record-session"',
      "shift 2",
      'id="${2:-$TEST_AGENT_THREAD}"',
      'printf "%s|%s|%s\\n" "$1" "$(pwd -P)" "$2" >> "$TEST_AGENT_LOG"',
      'printf "\\033]0;Example %s - ✅ Ready\\007" "${id##*-}"',
      [[printf '{"conversation_id":"%s"}\n' "$id" | "$hook" >/dev/null]],
      "while IFS= read -r phase; do",
      [[  case "$phase" in submit) state="⏳ Working ..." ;; stop) state="✅ Ready" ;; esac]],
      '  printf "\\033]0;Example %s - %s\\007" "${id##*-}" "$state"',
      "done",
    })
  end
  local script = root .. "/session.lua"
  local setup = {
    "local root = " .. string.format("%q", root),
    "local agent = " .. string.format("%q", agent),
    "local resume = " .. string.format("%q", agent == "codex" and "resume" or "--resume"),
    "local first, second = " .. string.format("%q, %q", first, second),
    "vim.g.luanphan_codex_sessions_dir = root .. '/codex-state'",
    "vim.g.luanphan_cursor_sessions_dir = root .. '/cursor-state'",
    "vim.g.luanphan_terminal_sessions_dir = root .. '/terminal-state'",
    "vim.g.luanphan_default_agent_file = root .. '/default'",
    "vim.g.luanphan_recent_paths_file = root .. '/recent'",
    "vim.g.luanphan_global_settings_path = root .. '/settings.toml'",
    "vim.env.CODEX_HOME = root .. '/codex'",
    "vim.env.CODEX_SQLITE_HOME = root .. '/codex'",
    "vim.env.TEST_AGENT_LOG = root .. '/invocations'",
    "vim.env.PATH = root .. '/bin:' .. vim.env.PATH",
    "vim.o.columns = 160",
    "local agents = require('luanphan.agents.main')",
    "assert(agents.set_default_agent('codex'))",
  }
  local function run(lines)
    write(script, vim.list_extend(vim.list_slice(setup), lines))
    local output = vim.fn.systemlist(child_nvim_luafile_command(repo, script))
    assert_true(vim.v.shell_error == 0, table.concat(output, "\n"))
  end
  run({
    "local sessions = require('luanphan.agents.main').sessions",
    "for _, id in ipairs({ first, second }) do",
    "  vim.env.TEST_AGENT_THREAD = id",
    "  local buf = assert(agents.new(agent))",
    "  assert(vim.wait(3000, function() return vim.b[buf].luanphan_view_thread_id == id end), 'missing exact thread ID')",
    "end",
    "assert(#sessions.list() == 2, 'both same-directory threads should be saved')",
    "local socket = vim.env.LUANPHAN_AGENT_TMUX_SOCKET",
    "assert(vim.wait(3000, function()",
    "  local listing = vim.system({'tmux', '-S', socket, 'list-panes', '-a', '-F', '#{@luanphan-agent}'}, { text = true }):wait()",
    "  return listing.stdout:find(first, 1, true) and listing.stdout:find(second, 1, true)",
    "end), 'tmux did not store both agent identities')",
    "os.exit(0)",
  })
  run({
    "agents.toggle()",
    "assert(vim.b.luanphan_view_thread_id == second, 'reattach did not select the most recent running thread')",
    "assert(#require('luanphan.agents.main').sessions.instances(false) == 2, 'reattach lost a running pane')",
    "assert(#vim.fn.readfile(root .. '/invocations') == 2, 'reattach relaunched an existing thread')",
  })
  assert_true(vim.system({ "tmux", "-S", agent_socket(script), "kill-server" }):wait().code == 0,
    "could not stop the isolated agent server")
  run({
    "agents.toggle()",
    "local main = vim.api.nvim_get_current_win()",
    "local sidebar = assert(vim.w[main].luanphan_window_bar)",
    "local second_buf = vim.api.nvim_get_current_buf()",
    "assert(vim.b.luanphan_view_thread_id == second, 'did not resume the most recent thread')",
    "local rows = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(sidebar), 0, -1, false)",
    "local selected",
    "for i, line in ipairs(rows) do",
    "  if vim.trim(line) == 'Example 000000000001' then selected = i end",
    "end",
    "assert(selected, 'saved thread was missing from the sidebar')",
    "vim.cmd.stopinsert()",
    "vim.api.nvim_set_current_win(sidebar)",
    "vim.api.nvim_win_set_cursor(sidebar, { selected, 0 })",
    "vim.fn.maparg('o', 'n', false, true).callback()",
    "assert(vim.api.nvim_get_current_win() == main and vim.b.luanphan_view_thread_id == first, 'wrong sidebar thread resumed')",
    "assert(vim.wait(3000, function()",
    "  return (vim.b.term_title or ''):find('Example', 1, true)",
    "end), 'missing agent title')",
    "assert(require('luanphan.view_container').tab_label(vim.api.nvim_get_current_buf()) == 'Example 000000000001', 'unexpected agent tab label')",
    "if agent == 'cursor' then",
    "  local send = require('luanphan.view_container.terminal').send",
    "  local buf = vim.api.nvim_get_current_buf()",
    "  assert(vim.wait(3000, function() return vim.b.luanphan_view_status == 'idle' end), 'Cursor has no startup status')",
    "  send(buf, 'submit\\n')",
    "  assert(vim.wait(3000, function() return vim.b.luanphan_view_status == 'working' end), 'Cursor has no working status')",
    "  assert(vim.b[second_buf].luanphan_view_status == 'idle', 'another Cursor terminal was marked working')",
    "  send(buf, 'stop\\n')",
    "  assert(vim.wait(3000, function() return vim.b.luanphan_view_status == 'done' end), 'Cursor kept its working status')",
    "end",
    "local cwd = vim.uv.fs_realpath(vim.fn.getcwd())",
    "assert(vim.wait(3000, function()",
    "  local lines = vim.fn.readfile(root .. '/invocations')",
    "  return vim.tbl_contains(lines, resume .. '|' .. cwd .. '|' .. first)",
    "    and vim.tbl_contains(lines, resume .. '|' .. cwd .. '|' .. second)",
    "end), 'agent did not receive the exact IDs and original directory')",
    "vim.cmd('quit')",
    "local sessions = require('luanphan.agents.main').sessions",
    "assert(vim.wait(3000, function()",
    "  local saved = sessions.list()",
    "  return #saved == 1 and saved[1].thread_id == second",
    "end), 'closing one agent should remove only its saved record')",
  })
  run({
    "local saved = require('luanphan.agents.main').sessions.list()",
    "assert(#saved == 1 and saved[1].thread_id == second, 'editor exit should preserve the remaining agent')",
  })
  if agent == "cursor" then
    write(root .. "/settings.toml", { "[agent_float]", 'display_style = "tile"' })
    write(script, vim.list_extend(vim.list_slice(setup), {
      "local open = agents.open",
      "agents.open = function(...) vim.g.smoke_shared_agent_open = 1; return open(...) end",
    }))
    local reference = repo .. "/local_workspaces/example-workspace/logs/example.json"
    write(reference, { '{"fixture": true}' })
    local socket = vim.fn.tempname() .. ".sock"
    local child = vim.fn.jobstart({
      "nvim", "--headless", "--embed", "--listen", socket, "-c", "luafile " .. vim.fn.fnameescape(script),
    }, {
      cwd = repo,
      env = { LUANPHAN_AGENT_TMUX_SOCKET = agent_socket(script) },
      on_stdout = function() end,
    })
    assert_true(child > 0, "could not start embedded Neovim")
    local ok, err = xpcall(function()
      vim.api.nvim_chan_send(child, vim.mpack.encode({
        0, 1, "nvim_ui_attach", { 160, 40, { rgb = true, ext_linegrid = true } },
      }))
      wait_until("the embedded Neovim socket", function() return uv.fs_stat(socket) ~= nil end, 3000)
      local rpc = vim.fn.sockconnect("pipe", socket, { rpc = true })
      assert_true(rpc > 0, "could not connect to embedded Neovim")
      wait_until("the first UI restores the saved Cursor terminal", function()
        return vim.rpcrequest(rpc, "nvim_eval", "get(b:, 'luanphan_view_thread_id', '')") == second
      end, 4000)
      assert_true(vim.rpcrequest(rpc, "nvim_eval", "get(g:, 'smoke_shared_agent_open', 0)") == 1,
        "the first UI restored the pane through a second agent controller")
      vim.rpcrequest(rpc, "nvim_exec_lua", [[
        local file, thread = ...
        local agents = require('luanphan.agents.main')
        local views = require('luanphan.view_container')
        local startup_buf = vim.api.nvim_get_current_buf()
        local peer = assert(agents.new('cursor', { thread_id = thread, view_mode = true }))
        assert(agents.focus('cursor', startup_buf, { view_mode = true }))
        local anchor = views.group_anchor(vim.api.nvim_get_current_win())
        assert(require('luanphan.terminal_references').open(file), 'startup pane could not open its reference')
        local editor = require('luanphan.view_container.editor').window(anchor)
        assert(editor == vim.api.nvim_get_current_win() and vim.uv.fs_realpath(vim.api.nvim_buf_get_name(0)) == vim.uv.fs_realpath(file),
          'the reference did not open in an editor tile')
        assert(views.group_anchor(vim.fn.bufwinid(peer)) == anchor and #views.group_windows(anchor) == 4,
          'opening the reference lost a pane or the sidebar')
      ]], { reference, first })
    end, debug.traceback)
    pcall(vim.api.nvim_chan_send, child, vim.mpack.encode({ 2, "nvim_command", { "qa!" } }))
    if vim.fn.jobwait({ child }, 1000)[1] == -1 then vim.fn.jobstop(child) end
    assert_true(ok, tostring(err))
  end
end

local function test_panel_shell_sessions(repo)
  local root = temp_root .. "/panel-shell"
  write_executable(root .. "/bin/mcodex", {
    "#!/bin/sh",
    [[printf 'pty=%s/%s/%s/%s/%s/%s\n' "$TERM" "$COLORTERM" "${NO_COLOR-unset}" "${TMUX-unset}" "${TMUX_PANE-unset}" "${TERM_PROGRAM-unset}"]],
    "exec cat",
  })
  write(root .. "/settings.toml", { "[agent_float]", 'display_style = "tile"' })
  local editor_lines = { "first", "second", "third" }
  for line = 4, 80 do editor_lines[line] = "line " .. line end
  write(root .. "/editor-source.txt", editor_lines)
  write(root .. "/editor-linked.txt", { "example", "reference" })
  local script = root .. "/session.lua"
  local terminal_socket = agent_socket(root .. "/floating")
  local setup = {
    "local root = " .. string.format("%q", root),
    "local terminal_socket = " .. string.format("%q", terminal_socket),
    "vim.g.luanphan_global_settings_path = root .. '/settings.toml'",
    "vim.g.luanphan_recent_paths_file = root .. '/recent.json'",
    "vim.g.luanphan_codex_sessions_dir = root .. '/codex-state'",
    "vim.g.luanphan_cursor_sessions_dir = root .. '/cursor-state'",
    "vim.g.luanphan_terminal_sessions_dir = root .. '/terminal-state'",
    "vim.env.PATH = root .. '/bin:' .. vim.env.PATH",
    "vim.env.ENV = nil",
    "vim.env.COLORTERM = nil",
    "vim.env.NO_COLOR = '1'",
    "vim.env.TMUX = '/example/socket,1,0'",
    "vim.env.TMUX_PANE = '%0'",
    "vim.env.TERM_PROGRAM = 'tmux'",
    "vim.env.TERM_PROGRAM_VERSION = '3.8'",
    "vim.o.termguicolors = true",
    "vim.o.shell = '/bin/sh'",
    "vim.o.columns = 160",
    "vim.o.lines = 48",
    "vim.cmd.cd(root)",
    "local agents = require('luanphan.agents.main')",
    "local sessions = require('luanphan.agents.main').sessions",
    "local terminal = require('luanphan.view_container.terminal')",
    "local agent_id = '00000000-0000-4000-8000-000000000001'",
    "local function press(key) vim.fn.maparg(key, 'n', false, true).callback() end",
  }
  local function run(body)
    write(script, vim.list_extend(vim.list_slice(setup), vim.split(body, "\n", { plain = true })))
    local output = vim.fn.systemlist(child_nvim_luafile_command(repo, script))
    assert_true(vim.v.shell_error == 0, table.concat(output, "\n"))
  end
  run([=[
local api = vim.api
local main_win = api.nvim_get_current_win()
local original_path = vim.fn.getcwd() .. '/editor-source.txt'
vim.cmd.edit(vim.fn.fnameescape(original_path))
local main_buf = api.nvim_get_current_buf()
api.nvim_win_set_cursor(main_win, { 2, 1 })
vim.wo[main_win].number, vim.wo[main_win].relativenumber, vim.wo[main_win].cursorline = true, true, true
vim.wo[main_win].signcolumn, vim.wo[main_win].statuscolumn = 'yes:2', '%s%l '
vim.wo[main_win].winhighlight = 'Normal:Visual'
local editors = require('luanphan.editor_window')
local main_appearance = editors.appearance(main_win)
local function check_tile_appearance(win)
  local appearance = editors.appearance(win)
  for _, option in ipairs({ 'number', 'relativenumber', 'cursorline', 'signcolumn', 'statuscolumn' }) do
    assert(appearance[option] == main_appearance[option], 'editor tile lost ' .. option)
  end
  assert(appearance.winhighlight:find('NormalFloat:Visual', 1, true), 'editor tile lost its editor background')
  assert(appearance.winbar ~= '' and appearance.winbar:find(vim.fs.basename(api.nvim_buf_get_name(api.nvim_win_get_buf(win))), 1, true),
    'editor tile lost its filename bar')
end
local agent = assert(agents.new('codex', { thread_id = agent_id, view_mode = true }))
assert(vim.wait(3000, function()
  return vim.tbl_contains(vim.api.nvim_buf_get_lines(agent, 0, -1, false),
    'pty=xterm-256color/truecolor/unset/unset/unset/unset')
end), 'the native agent inherited the GUI launcher terminal environment')
assert(vim.env.NO_COLOR == '1' and vim.env.TMUX == '/example/socket,1,0', 'starting an agent changed the editor environment')
vim.defer_fn(function() api.nvim_input('CTRL_L_PROBE<C-l>_KEPT<CR><Esc>') end, 20)
api.nvim_feedkeys('i', 'xt!', false)
assert(vim.wait(3000, function()
  return vim.tbl_contains(api.nvim_buf_get_lines(agent, 0, -1, false), 'CTRL_L_PROBE_KEPT')
end), 'Ctrl+L reached the agent in terminal input mode')
vim.cmd("normal! m'")
press('<leader>ne')
local editor = api.nvim_get_current_win()
assert(editor ~= main_win and api.nvim_get_current_buf() == main_buf, 'editor tile did not share the main buffer')
api.nvim_feedkeys(vim.keycode('<C-o>'), 'xt', false)
assert(api.nvim_get_current_win() == editor and api.nvim_get_current_buf() == main_buf,
  'Ctrl+O followed an inherited jump out of the editor buffer')
vim.cmd('normal! G')
api.nvim_feedkeys(vim.keycode('<C-o>'), 'xt', false)
assert(vim.wo[editor].number and vim.deep_equal(api.nvim_win_get_cursor(editor), { 2, 1 }), 'editor tile lost source options or position')
check_tile_appearance(editor)
assert(api.nvim_win_get_config(editor).border[1][2] == 'DiagnosticOk', 'focused editor tile has no green border')
local function tile_key(key, condition)
  api.nvim_feedkeys(vim.keycode(key), 'xt', false)
  assert(vim.wait(1000, condition), 'editor tile did not handle ' .. key)
end
tile_key('<C-h>', function() return api.nvim_get_current_buf() == agent end)
assert(api.nvim_win_get_config(editor).border[1] == '┌', 'unfocused editor tile kept its focus border')
tile_key('<C-l>', function() return api.nvim_get_current_win() == editor end)
local function editor_sidebar_row()
  local anchor = require('luanphan.view_container').group_anchor(vim.fn.bufwinid(agent))
  local bar = vim.w[anchor].luanphan_window_bar
  local lines = api.nvim_buf_get_lines(api.nvim_win_get_buf(bar), 0, -1, false)
  for index, line in ipairs(lines) do
    if vim.trim(line) == 'Editor · editor-source.txt' then return index, bar end
  end
end
local row, bar = editor_sidebar_row()
assert(row and api.nvim_win_get_cursor(bar)[1] == row, 'agent sidebar did not follow the editor tile')
tile_key('<C-h>', function() return api.nvim_get_current_buf() == agent end)
press('<leader>e')
api.nvim_win_set_cursor(bar, { row, 0 })
press('<CR>')
assert(api.nvim_get_current_win() == editor, 'agent sidebar row did not focus the editor tile')
local right = api.nvim_win_get_config(editor).col
tile_key('<C-S-h>', function() return api.nvim_win_get_config(editor).col < right end)
assert(api.nvim_get_current_win() == editor, 'moving editor tile lost focus')
tile_key('<C-S-l>', function() return api.nvim_win_get_config(editor).col == right end)
tile_key('<Tab>', function() return api.nvim_get_current_buf() == agent end)
tile_key('<S-Tab>', function() return api.nvim_get_current_win() == editor end)
local insert_border
vim.defer_fn(function()
  insert_border = api.nvim_win_get_config(editor).border[1][2]
  api.nvim_input('<Esc>')
end, 20)
api.nvim_feedkeys('i', 'xt!', false)
assert(insert_border == 'LuanphanTileInputBorder', 'editor insert mode has no orange border')
api.nvim_buf_set_lines(main_buf, 2, 3, false, { 'shared edit' })
vim.fn.winrestview({ lnum = 20, col = 1, topline = 15 })
local saved_view = vim.fn.winsaveview()
agents.toggle()
assert(api.nvim_get_current_win() == main_win and not api.nvim_win_is_valid(editor), 'hiding agents left its editor tile open')
assert(vim.deep_equal(api.nvim_win_get_cursor(main_win), { 2, 1 }) and api.nvim_get_current_line() == 'second',
  'editor tile moved the main cursor')
assert(api.nvim_buf_get_lines(main_buf, 2, 3, false)[1] == 'shared edit', 'editor tile did not share edits')
local editor_tiles = require('luanphan.view_container.editor')
local views = require('luanphan.view_container')
local function current_editor_tile()
  local term_win = vim.fn.bufwinid(agent)
  if term_win ~= -1 then return editor_tiles.window(views.group_anchor(term_win)) end
end
agents.toggle()
local reopened = assert(current_editor_tile(), 'reopening agents did not restore the editor tile')
local reopened_view = api.nvim_win_call(reopened, vim.fn.winsaveview)
assert(api.nvim_win_get_buf(reopened) == main_buf and reopened_view.lnum == saved_view.lnum
  and reopened_view.col == saved_view.col and reopened_view.topline == saved_view.topline,
  'reopening agents lost the editor file, cursor, or scroll position')
api.nvim_set_current_win(reopened)
vim.cmd.quit()
vim.wait(30, function() return false end)
assert(not current_editor_tile(), 'closing the editor tile immediately recreated it')
assert(not editor_sidebar_row(), 'closing the editor tile left its sidebar entry behind')
agents.toggle()
local unnamed = api.nvim_create_buf(true, false)
api.nvim_set_current_buf(unnamed)
agents.toggle()
press('<leader>ne')
assert(api.nvim_get_current_buf() == unnamed and current_editor_tile(), 'could not open an unnamed editor tile')
agents.toggle()
api.nvim_win_set_buf(main_win, main_buf)
api.nvim_buf_delete(unnamed, {})
agents.toggle()
assert(not current_editor_tile(), 'a deleted unnamed buffer restored an editor tile')
local sidebar = vim.w[views.group_anchor(vim.fn.bufwinid(agent))].luanphan_window_bar
for _, text in ipairs(api.nvim_buf_get_lines(api.nvim_win_get_buf(sidebar), 0, -1, false)) do
  assert(vim.trim(text) ~= 'Editor', 'a deleted unnamed buffer left an editor row in the sidebar')
end
local linked = vim.fn.getcwd() .. '/editor-linked.txt'
local function command_click(path, line, col)
  assert(agents.focus('codex', agent, { view_mode = true }))
  local term_win = api.nvim_get_current_win()
  local reference = ('./%s:%d:%d'):format(vim.fs.basename(path), line, col)
  require('luanphan.view_container.terminal').send(agent, '\n' .. reference .. '\n')
  local row
  assert(vim.wait(3000, function()
    for index, text in ipairs(api.nvim_buf_get_lines(agent, 0, -1, false)) do
      if vim.trim(text) == reference then row = index end
    end
    return row ~= nil
  end), 'terminal did not print a reference')
  local mouse = vim.fn.getmousepos
  vim.fn.getmousepos = function() return { winid = term_win, line = row, column = 1 } end
  local result = vim.fn.maparg('<D-LeftMouse>', 'n', false, true).callback()
  vim.fn.getmousepos = mouse
  assert(result == '<Ignore>', 'Cmd+click did not consume the terminal reference')
  assert(vim.wait(3000, function() return api.nvim_buf_get_name(0) == path end), 'file link did not open')
  assert(api.nvim_win_get_config(0).relative == 'editor' and api.nvim_win_is_valid(term_win), 'file link closed the agents')
  assert(vim.deep_equal(api.nvim_win_get_cursor(0), { line, col - 1 }), 'file link lost its location')
  check_tile_appearance(api.nvim_get_current_win())
  return api.nvim_get_current_win()
end
local linked_tile = command_click(linked, 2, 3)
assert(command_click(original_path, 1, 2) == linked_tile, 'Cmd+click opened a second editor tile')
assert(command_click(linked, 2, 3) == linked_tile)
api.nvim_feedkeys(vim.keycode(vim.g.mapleader .. 'o'), 'xt', false)
assert(api.nvim_get_current_win() == main_win and api.nvim_buf_get_name(0) == linked
  and vim.deep_equal(api.nvim_win_get_cursor(0), { 2, 2 }), 'open in main editor lost the tile file or position')
assert(not api.nvim_win_is_valid(linked_tile), 'open in main editor left the tile visible')
assert(vim.deep_equal(editors.appearance(main_win), main_appearance), 'the reused editor window took on tile options')
agents.toggle()
local returned = assert(current_editor_tile(), 'open in main editor discarded the saved tile')
assert(api.nvim_win_get_buf(returned) == vim.fn.bufnr(linked)
  and vim.deep_equal(api.nvim_win_get_cursor(returned), { 2, 2 }), 'open in main editor lost the tile file or cursor')
agents.toggle()
local special = api.nvim_create_buf(false, true)
api.nvim_open_win(special, false, { split = 'left', win = main_win })
vim.cmd.quit()
assert(not api.nvim_win_is_valid(main_win), 'fixture did not close the last regular editor window')
agents.toggle()
api.nvim_set_current_win(assert(current_editor_tile()))
api.nvim_feedkeys(vim.keycode(vim.g.mapleader .. 'o'), 'xt', false)
assert(require('luanphan.editor_window').is_editor(api.nvim_get_current_win())
  and api.nvim_buf_get_name(0) == linked and vim.deep_equal(api.nvim_win_get_cursor(0), { 2, 2 }),
  'open in main editor did not create a regular editor window')
assert(vim.deep_equal(editors.appearance(api.nvim_get_current_win()), main_appearance), 'the new split took on tile options')
agents.toggle()
api.nvim_set_current_win(assert(current_editor_tile()))
vim.cmd.quit()
assert(vim.wait(1000, function() return not current_editor_tile() end))
press('<leader>nt')
local first = vim.api.nvim_get_current_buf()
assert(vim.b[first].luanphan_view_kind == 'terminal', 'new terminal did not create a shell')
press('<leader>e')
assert(vim.bo.filetype == 'agent-window-bar', 'could not focus the sidebar from the shell')
press('<leader>nt')
local second = vim.api.nvim_get_current_buf()
assert(first ~= second and vim.b[second].luanphan_view_kind == 'terminal', 'sidebar reused the first shell')
for _, buf in ipairs({ agent, first, second }) do
  local win = vim.fn.bufwinid(buf)
  assert(win ~= -1 and vim.w[win].luanphan_view_anchor, 'shell and agent do not share the tiled panel')
  press('<Tab>')
  assert(vim.api.nvim_get_current_buf() == buf, 'Tab did not follow shell and agent order')
end
assert(agents.send_selection('terminal') == false, 'shell was accepted as an agent prompt destination')
local marker = 'PANEL_SHELL_OUTPUT'
local send = require('luanphan.view_container.terminal').send
send(first, [==[stty -icanon min 1 time 0 -echo; printf '\neditor-runtime=%s/%s\n' "${VIM-unset}" "${VIMRUNTIME-unset}"; dd bs=1 count=1 2>/dev/null | od -An -tu1; stty icanon echo]==] .. '\n')
assert(vim.wait(3000, function()
  return vim.tbl_contains(api.nvim_buf_get_lines(first, 0, -1, false), 'editor-runtime=unset/unset')
end), 'plain shell inherited the parent editor runtime')
api.nvim_set_current_win(vim.fn.bufwinid(first))
vim.defer_fn(function() api.nvim_input('<C-l><Esc>') end, 20)
api.nvim_feedkeys('i', 'xt!', false)
assert(vim.wait(3000, function()
  return vim.iter(api.nvim_buf_get_lines(first, 0, -1, false)):any(function(line) return vim.trim(line) == '12' end)
end), 'Ctrl+L did not reach the plain shell')
send(first,
  "printf '\\n%s\\n' " .. marker .. "; seq 1 150 | sed 's/^/history-line-/'\n")
assert(vim.wait(3000, function()
  return vim.tbl_contains(vim.api.nvim_buf_get_lines(first, 0, -1, false), 'history-line-150')
end, 20), 'plain shell could not execute a command')
send(second, [[seq 1 60 | sed 's/^/primary-line-/'; printf '\033[?1049h\033[2J\033[H%s\n' alternate-view]] .. '\n')
assert(vim.wait(3000, function()
  return vim.tbl_contains(vim.api.nvim_buf_get_lines(second, 0, -1, false), 'alternate-view')
end, 20), 'shell did not switch to its alternate screen')
local ids = { vim.b[first].luanphan_view_thread_id, vim.b[second].luanphan_view_thread_id }
assert(#sessions.list('terminal') == 2 and ids[1] ~= ids[2], 'shell slots were not saved independently')
local session_file = vim.g.luanphan_terminal_sessions_dir .. '/' .. ids[1] .. '.json'
local function saved_use()
  return vim.json.decode(vim.fn.readfile(session_file)[1]).last_used
end
local initial_use = saved_use()
assert(agents.focus('terminal', first, { view_mode = true }))
assert(agents.focus('terminal', second, { view_mode = true }))
assert(agents.focus('terminal', first, { view_mode = true }))
local last_focus = vim.b[first].luanphan_view_used_at
assert(saved_use() == initial_use, 'moving tile focus wrote the session file inline')
assert(vim.wait(2000, function() return saved_use() == last_focus end), 'last tile focus was not persisted')
local previous_use = vim.b[second].luanphan_view_last_used
api.nvim_set_current_win(vim.fn.bufwinid(second))
assert(vim.wait(1000, function() return vim.b[second].luanphan_view_last_used > previous_use end),
  'native window focus did not record the selected tile')
local second_file = vim.g.luanphan_terminal_sessions_dir .. '/' .. ids[2] .. '.json'
local function saved_position()
  return vim.json.decode(vim.fn.readfile(second_file)[1]).pane_order
end
local initial_position = saved_position()
press('<C-S-k>')
press('<C-S-h>')
assert(api.nvim_win_get_config(vim.fn.bufwinid(second)).col < api.nvim_win_get_config(vim.fn.bufwinid(agent)).col,
  'reordering did not move the shell to the left tile')
assert(saved_position() == initial_position, 'moving tiles saved their positions inline')
vim.fn.writefile(ids, root .. '/ids')
assert(agents.open('codex', agent, { view_mode = true }))
vim.cmd('qa!')
]=])
  local positions = vim.system({ "tmux", "-S", agent_socket(script), "list-panes", "-a", "-F", "#{@luanphan-pane-order}" },
    { text = true }):wait()
  assert_true(positions.code == 0 and vim.deep_equal(vim.fn.sort(vim.split(vim.trim(positions.stdout), "\n")), { "1", "2", "3" }),
    "quitting before the debounce did not save all three pane positions to tmux")
  run([=[
agents.toggle()
assert(vim.b.luanphan_view_thread_id == agent_id, 'restored shells took focus from the agent')
local shells = {}
for _, item in ipairs(sessions.instances(false)) do
  if item.kind == 'terminal' then shells[vim.b[item.bufnr].luanphan_view_thread_id] = item end
end
local ids = vim.fn.readfile(root .. '/ids')
assert(vim.tbl_count(shells) == 2, 'panel did not recreate both shell slots')
local function is_left_of_agent(buf)
  local shell = vim.api.nvim_win_get_config(vim.fn.bufwinid(buf))
  return shell.col < vim.api.nvim_win_get_config(0).col
end
assert(is_left_of_agent(assert(shells[ids[2]]).bufnr), 'reattach lost the shell tile position')
for _, id in ipairs(ids) do
  local item = assert(shells[id], 'restored shell lost its saved ID')
  assert(item.path == vim.fn.getcwd() and terminal.running(item.bufnr), 'restored shell has the wrong working directory')
  assert(vim.fn.bufwinid(item.bufnr) ~= -1, 'restored shell was missing from the tiled panel')
  if id == ids[1] then
    assert(vim.wait(4000, function()
      local lines = vim.tbl_map(vim.trim, vim.api.nvim_buf_get_lines(item.bufnr, 0, -1, false))
      return vim.tbl_contains(lines, 'PANEL_SHELL_OUTPUT') and vim.tbl_contains(lines, 'history-line-150')
    end), 'reattaching lost shell scrollback')
  else
    local function has_line(text)
      local lines = vim.tbl_map(vim.trim, vim.api.nvim_buf_get_lines(item.bufnr, 0, -1, false))
      return vim.tbl_contains(lines, text)
    end
    assert(vim.wait(4000, function() return has_line('alternate-view') end), 'reattaching lost the alternate screen')
    require('luanphan.view_container.terminal').send(item.bufnr, [[printf '\033[?1049l']] .. '\n')
    assert(vim.wait(4000, function() return has_line('primary-line-1') and has_line('primary-line-60') end),
      'reattaching while in the alternate screen lost primary scrollback')
  end
end
require('luanphan.view_container.terminal').send(shells[ids[1]].bufnr, 'exit\n')
assert(vim.wait(3000, function() return #sessions.list('terminal') == 1 end, 20),
  'exiting a shell did not remove its saved slot')

vim.g.luanphan_floating_tmux_socket = terminal_socket
vim.g.luanphan_floating_tmux_config = '/dev/null'
local floating = require('luanphan.view_container.floating')
floating.toggle()
assert(vim.wait(3000, function() return vim.b.luanphan_tmux_pane ~= nil end), 'floating terminal did not attach')
local floating_win = vim.api.nvim_get_current_win()
for _, item in ipairs(sessions.instances(false)) do
  assert(vim.fn.bufwinid(item.bufnr) == -1, 'opening Floating Terminal left an Agents window visible')
end
local function tmux(socket, ...)
  local result = vim.system(vim.list_extend({ 'tmux', '-S', socket }, { ... }), { text = true }):wait()
  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout)
end
local terminal_pid = tmux(terminal_socket, 'list-panes', '-a', '-F', '#{pane_pid}')
assert(terminal_pid:match('^%d+$'), 'agent processes appeared in the floating terminal server')
agents.toggle()
assert(vim.b.luanphan_view_thread_id == agent_id, 'could not reopen the agent panel')
assert(not vim.api.nvim_win_is_valid(floating_win), 'opening Agents left a Floating Terminal window visible')
tmux(vim.env.LUANPHAN_AGENT_TMUX_SOCKET, 'kill-server')
assert(vim.wait(3000, function() return #sessions.instances(false) == 0 end), 'server loss left stale agent panes')
assert(#sessions.list('codex') == 1 and #sessions.list('terminal') == 1, 'server loss removed active session records')
assert(tmux(terminal_socket, 'list-panes', '-a', '-F', '#{pane_pid}') == terminal_pid, 'server loss affected the floating terminal')
agents.toggle()
assert(vim.wait(3000, function()
  return #sessions.instances(false) == 2 and vim.b.luanphan_view_thread_id == agent_id
end), 'same editor could not recover the original agent and shell slots')
local shell = assert(vim.iter(sessions.instances(false)):find(function(item) return item.kind == 'terminal' end))
assert(is_left_of_agent(shell.bufnr), 'recovering the server lost the shell tile position')
]=])
end

return {
  test_active_agent_discovery = test_active_agent_discovery,
  test_agent_switch_replaces_visible_repo_buffer = test_agent_switch_replaces_visible_repo_buffer,
  test_default_agent_setting = test_default_agent_setting,
  test_filetype_refire_uses_target_buffer = test_filetype_refire_uses_target_buffer,
  test_agent_cli_commands_available = test_agent_cli_commands_available,
  test_neovide_command_v_pastes_text_without_image_probe = test_neovide_command_v_pastes_text_without_image_probe,
  test_remote_clipboard_references = test_remote_clipboard_references,
  test_neovide_detach_clears_option_callbacks = test_neovide_detach_clears_option_callbacks,
  test_neovide_detach_restores_tmux_clipboard = test_neovide_detach_restores_tmux_clipboard,
  test_terminal_reference_links = test_terminal_reference_links,
  test_agent_terminal_reference_restores_view = test_agent_terminal_reference_restores_view,
  test_agent_keys_invoke_cli_commands = test_agent_keys_invoke_cli_commands,
  test_leader_a_sends_visual_selection_to_active_agent = test_leader_a_sends_visual_selection_to_active_agent,
  test_agent_sidebar_restore = test_agent_sidebar_restore,
  test_panel_shell_sessions = test_panel_shell_sessions,
}
