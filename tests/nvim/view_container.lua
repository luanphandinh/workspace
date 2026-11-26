-- View container smoke tests, loaded by tests/nvim-smoke-test.lua with the shared helpers.
local H = ...
local terminal_io = H.terminal_io
local agent_socket = H.agent_socket
local temp_root = H.temp_root
local agent_cli_commands = H.agent_cli_commands
local assert_true = H.assert_true
local assert_nonrecursive_map = H.assert_nonrecursive_map
local rendered_winbar = H.rendered_winbar
local realpath = H.realpath
local write = H.write
local child_nvim_luafile_command = H.child_nvim_luafile_command
local write_executable = H.write_executable
local wait_until = H.wait_until
local read_log = H.read_log
local visible_agent_window_count = H.visible_agent_window_count
local assert_agent_float = H.assert_agent_float
local close_agent_terminals = H.close_agent_terminals
local invoke_map = H.invoke_map
local registered_agent_bufnrs = H.registered_agent_bufnrs
local agent_bufnr = H.agent_bufnr
local worktree_test_api = H.worktree_test_api

local function terminal_grid_size(bufnr)
  local pane = vim.b[bufnr].luanphan_tmux_pane
  local tty
  if pane then
    local result = vim.system({ "tmux", "-S", vim.env.LUANPHAN_AGENT_TMUX_SOCKET,
      "display-message", "-p", "-t", pane, "#{pane_tty}" }, { text = true }):wait()
    tty = vim.trim(result.stdout or "")
  else
    local job = vim.b[bufnr].terminal_job_id
    if type(job) ~= "number" or job <= 0 then return nil, nil end
    local pid = vim.fn.jobpid(job)
    local result = vim.system({ "ps", "-o", "tty=", "-p", tostring(pid) }, { text = true }):wait()
    tty = vim.trim(result.stdout or "")
  end
  if tty == "" or tty == "?" then return nil, nil end

  local device = vim.startswith(tty, "/") and tty or ("/dev/" .. tty)
  local flag = vim.fn.has("macunix") == 1 and "-f" or "-F"
  local result = vim.system({ "stty", flag, device, "size" }, { text = true }):wait()
  if result.code ~= 0 then
    return nil, nil
  end
  local rows, columns = (result.stdout or ""):match("(%d+)%s+(%d+)")
  return tonumber(rows), tonumber(columns)
end

local function assert_terminal_grid_matches(bufnr, win, label)
  wait_until(label .. " terminal grid", function()
    local rows, columns = terminal_grid_size(bufnr)
    local expected_rows = vim.api.nvim_win_get_height(win)
    if vim.api.nvim_get_option_value("winbar", { win = win }) ~= "" then
      expected_rows = expected_rows - 1
    end
    return rows == expected_rows and columns == vim.api.nvim_win_get_width(win)
  end, 3000)
end

local function test_agent_view_container(repo)
  local shim_dir = temp_root .. "/agent-view-shims"
  local invoke_log = temp_root .. "/agent-view-invocations.log"
  local input_log = temp_root .. "/agent-view-input"
  local source = repo .. "/agent-view.txt"
  vim.fn.mkdir(shim_dir, "p")
  write(invoke_log, {})
  for _, item in ipairs(agent_cli_commands) do
    write_executable(shim_dir .. "/" .. item.command, {
      "#!/bin/sh",
      "printf '%s|%s|%s\\n' \"$(basename \"$0\")\" \"$PWD\" \"$*\" >> \"$NVIM_AGENT_SMOKE_LOG\"",
      "stty -icanon min 1 time 0",
      "input_path=\"$NVIM_AGENT_SMOKE_INPUT.$(basename \"$0\")\"",
      "exec tee -a \"$input_path\"",
    })
  end

  local old_cwd = vim.fn.getcwd()
  local old_path = vim.env.PATH
  local old_log = vim.env.NVIM_AGENT_SMOKE_LOG
  local old_input = vim.env.NVIM_AGENT_SMOKE_INPUT
  local old_columns = vim.o.columns
  local old_lines = vim.o.lines
  local old_global_settings = vim.g.luanphan_global_settings_path
  local old_codex_sessions = vim.g.luanphan_codex_sessions_dir
  local old_cursor_sessions = vim.g.luanphan_cursor_sessions_dir
  local old_terminal_sessions = vim.g.luanphan_terminal_sessions_dir
  local settings_path = temp_root .. "/agent-view-settings.toml"
  local agents = require("luanphan.agents.main")
  vim.env.PATH = shim_dir .. ":" .. old_path
  vim.env.NVIM_AGENT_SMOKE_LOG = invoke_log
  vim.env.NVIM_AGENT_SMOKE_INPUT = input_log
  vim.g.luanphan_global_settings_path = settings_path
  vim.g.luanphan_codex_sessions_dir = temp_root .. "/agent-view-codex-sessions"
  vim.g.luanphan_cursor_sessions_dir = temp_root .. "/agent-view-cursor-sessions"
  vim.g.luanphan_terminal_sessions_dir = temp_root .. "/agent-view-terminal-sessions"
  write(settings_path, { "[recent_folder]", "max_cache_entry = 3" })
  close_agent_terminals()

  local ok, err = xpcall(function()
    vim.cmd("cd " .. vim.fn.fnameescape(repo))
    write(source, { "send this path" })
    vim.cmd("edit " .. vim.fn.fnameescape(source))

    assert_true(agents.open("codex"), "could not open the first terminal agent")
    wait_until("first agent tab", function()
      return visible_agent_window_count() == 1
        and agent_bufnr("codex") ~= nil
    end, 3000)
    local codex_buf = agent_bufnr("codex")
    local agent_win = vim.api.nvim_get_current_win()
    assert_agent_float(agent_win, "first agent container")
    local agent_height = vim.api.nvim_win_get_height(agent_win)
    local winbar = rendered_winbar(agent_win)
    assert_true(
      winbar:find("[codex]", 1, true) ~= nil,
      "single agent did not reserve its tab bar: " .. vim.inspect(winbar)
    )
    assert_terminal_grid_matches(codex_buf, agent_win, "first agent")
    local width = vim.api.nvim_win_get_width(agent_win)
    local columns = vim.o.columns
    vim.o.columns = columns + 20
    vim.api.nvim_exec_autocmds("VimResized", {})
    wait_until("agent panel resizes", function()
      return vim.api.nvim_win_get_width(agent_win) > width
    end, 3000)
    assert_terminal_grid_matches(codex_buf, agent_win, "resized agent")
    vim.o.columns = columns
    vim.api.nvim_exec_autocmds("VimResized", {})
    wait_until("agent panel restores its original width", function()
      return vim.api.nvim_win_get_width(agent_win) == width
    end, 3000)
    invoke_map("<S-Tab>")
    assert_true(vim.api.nvim_get_current_buf() == codex_buf, "backward cycling changed a single agent tab")

    assert_true(agents.open("cursor"), "could not open the second terminal agent")
    wait_until("second agent tab", function()
      return visible_agent_window_count() == 1
        and agent_bufnr("cursor") ~= nil
        and vim.api.nvim_get_current_buf() == agent_bufnr("cursor")
    end, 3000)
    local cursor_buf = agent_bufnr("cursor")
    local first_cursor_buf = cursor_buf
    assert_true(vim.api.nvim_buf_is_valid(codex_buf), "opening another tab deleted the first terminal")
    assert_true(vim.api.nvim_get_current_win() == agent_win, "opening another agent replaced the container window")
    assert_true(vim.api.nvim_win_get_height(agent_win) == agent_height, "opening another agent resized the container")
    assert_terminal_grid_matches(cursor_buf, agent_win, "second agent")
    winbar = rendered_winbar(agent_win)
    assert_true(winbar:find("codex", 1, true) ~= nil, "agent tab bar omitted the first terminal")
    assert_true(winbar:find("[cursor]", 1, true) ~= nil, "agent tab bar did not select the current terminal")

    vim.cmd("stopinsert")
    local next_map = vim.fn.maparg("<Tab>", "n", false, true)
    local new_map = vim.fn.maparg("<leader>na", "n", false, true)
    local select_map = vim.fn.maparg("<leader>nA", "n", false, true)
    assert_nonrecursive_map("<Tab>", "n", cursor_buf)
    assert_nonrecursive_map("<S-Tab>", "n", cursor_buf)
    assert_nonrecursive_map("<leader>na", "n", cursor_buf)
    assert_nonrecursive_map("<leader>nA", "n", cursor_buf)
    assert_nonrecursive_map("<leader>nt", "n", cursor_buf)
    assert_true(vim.fn.maparg("<leader>fn", "n") == "<Nop>" and vim.fn.maparg("<leader>fN", "n") == "",
      "old shortcuts are still active in the agent panel")
    assert_true(type(next_map) == "table" and type(next_map.callback) == "function", "agent view mode is missing tab cycling")
    assert_true(type(new_map) == "table" and type(new_map.callback) == "function" and new_map.desc == "New default terminal agent", "agent view mode is missing default-agent creation")
    assert_true(type(select_map) == "table" and type(select_map.callback) == "function" and select_map.desc == "Select terminal agent", "agent view mode is missing the new-agent picker")
    local original_default_agent = agents.default_agent
    local original_new = agents.new
    local created_agent
    agents.default_agent = function() return "cursor" end
    agents.new = function(agent_name)
      created_agent = agent_name
      return true
    end
    new_map.callback()
    agents.default_agent = original_default_agent
    agents.new = original_new
    assert_true(created_agent == "cursor", "<leader>na did not create the configured default agent")
    next_map.callback()
    wait_until("cycled agent tab", function()
      return visible_agent_window_count() == 1
        and vim.api.nvim_get_current_buf() == codex_buf
        and vim.api.nvim_get_mode().mode:sub(1, 1) ~= "t"
    end, 3000)
    assert_true(vim.api.nvim_buf_is_valid(cursor_buf), "cycling tabs deleted the hidden terminal")
    assert_true(vim.api.nvim_get_current_win() == agent_win, "cycling agents replaced the container window")
    assert_true(vim.api.nvim_win_get_height(agent_win) == agent_height, "cycling agents resized the container")
    assert_terminal_grid_matches(codex_buf, agent_win, "cycled agent")

    next_map = vim.fn.maparg("<Tab>", "n", false, true)
    next_map.callback()
    wait_until("cycled mixed agent tab again", function()
      return visible_agent_window_count() == 1
        and vim.api.nvim_get_current_buf() == cursor_buf
        and vim.api.nvim_get_mode().mode:sub(1, 1) ~= "t"
    end, 3000)
    assert_true(vim.api.nvim_get_current_win() == agent_win, "cycling mixed agents replaced the container window")
    assert_true(vim.api.nvim_win_get_height(agent_win) == agent_height, "cycling mixed agents resized the container")

    select_map = vim.fn.maparg("<leader>nA", "n", false, true)
    select_map.callback()
    local prompt_buf = nil
    wait_until("agent tab picker", function()
      for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].filetype == "TelescopePrompt" then
          prompt_buf = bufnr
          return true
        end
      end
      return false
    end, 3000)
    local action_state = require("telescope.actions.state")
    local picker = action_state.get_current_picker(prompt_buf)
    wait_until("registered agent choices", function()
      return picker.manager and picker.manager:num_results() == 3
    end, 3000)
    local prompt_win = vim.fn.bufwinid(prompt_buf)
    local results_win = -1
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].filetype == "TelescopeResults" then
        results_win = vim.fn.bufwinid(bufnr)
        if results_win ~= -1 then
          break
        end
      end
    end
    assert_true(prompt_win ~= -1 and vim.api.nvim_win_get_width(prompt_win) < vim.o.columns * 0.4, "agent picker is too wide")
    assert_true(results_win ~= -1 and vim.api.nvim_win_get_height(results_win) < vim.o.lines * 0.4, "agent picker is too tall")
    local selected = action_state.get_selected_entry()
    assert_true(selected and selected.value.id == "codex", "new-tab picker did not prioritize Codex")
    require("telescope.actions").select_default(prompt_buf)
    wait_until("second codex tab", function()
      return visible_agent_window_count() == 1
        and #registered_agent_bufnrs("codex", repo) == 2
        and vim.api.nvim_get_current_buf() == agent_bufnr("codex")
    end, 3000)
    local second_codex_buf = agent_bufnr("codex")
    assert_true(second_codex_buf ~= codex_buf, "new-tab picker reused the existing Codex terminal")
    assert_true(vim.api.nvim_get_current_win() == agent_win, "new agent tab replaced the container window")
    assert_true(vim.api.nvim_win_get_height(agent_win) == agent_height, "new agent tab resized the container")
    local function status_icon(win, bufnr)
      local sidebar = vim.w[win].luanphan_window_bar
      local sidebar_buf = vim.api.nvim_win_get_buf(sidebar)
      local ns = vim.api.nvim_create_namespace("LuanphanWindowBarStatus")
      local mark = vim.api.nvim_buf_get_extmark_by_id(sidebar_buf, ns, bufnr, { details = true })
      if mark[3] then return mark[3].virt_text[1][1], mark[3].virt_text_win_col end
    end
    terminal_io.send(codex_buf, "\27]7501;state=done:app=codex\27\\")
    terminal_io.send(second_codex_buf, "\27]7501;state=working:app=codex\27\\")
    wait_until("separate terminal status for sessions in the same folder", function()
      return vim.b[codex_buf].luanphan_view_status == "done"
        and vim.b[second_codex_buf].luanphan_view_status == "working"
    end, 3000)

    vim.cmd("stopinsert")
    for _, expected_buf in ipairs({ codex_buf, cursor_buf, second_codex_buf }) do
      invoke_map("<S-Tab>")
      wait_until("backward agent tab cycle", function()
        return visible_agent_window_count() == 1
          and vim.api.nvim_get_current_buf() == expected_buf
          and vim.api.nvim_get_mode().mode:sub(1, 1) ~= "t"
      end, 3000)
      assert_true(vim.api.nvim_get_current_win() == agent_win, "backward cycling replaced the agent container window")
      assert_true(vim.api.nvim_win_get_height(agent_win) == agent_height, "backward cycling resized the agent container")
    end

    assert_true(agents.open("codex", codex_buf, { view_mode = true }), "could not switch to the first Codex tab")
    wait_until("same-agent tab cycle", function()
      return vim.api.nvim_get_current_buf() == codex_buf
        and vim.api.nvim_get_mode().mode:sub(1, 1) ~= "t"
    end, 3000)
    assert_true(vim.api.nvim_get_current_win() == agent_win, "same-agent cycle replaced the container window")
    assert_true(vim.api.nvim_win_get_height(agent_win) == agent_height, "same-agent cycle resized the container")
    assert_true(agents.open("codex", second_codex_buf, { view_mode = true }), "could not restore the second Codex tab")
    wait_until("same-agent tab restore", function()
      return vim.api.nvim_get_current_buf() == second_codex_buf
    end, 3000)

    assert_true(agents.new("cursor"), "could not create a second Cursor terminal")
    wait_until("second cursor tab", function()
      return #registered_agent_bufnrs("cursor", repo) == 2
        and vim.api.nvim_get_current_buf() == agent_bufnr("cursor")
    end, 3000)
    local second_cursor_buf = agent_bufnr("cursor")
    assert_true(second_cursor_buf ~= cursor_buf, "new Cursor tab reused the existing terminal")
    cursor_buf = second_cursor_buf

    assert_true(agents.new("claude"), "could not create the first Claude terminal")
    assert_true(agents.new("claude"), "could not create the second Claude terminal")
    wait_until("duplicate agent tabs", function()
      return #registered_agent_bufnrs("claude", repo) == 2
        and vim.api.nvim_get_current_buf() == agent_bufnr("claude")
    end, 3000)

    winbar = rendered_winbar()
    for _, label in ipairs({ "codex 1", "codex 2", "cursor 1", "cursor 2", "claude 1", "claude 2" }) do
      assert_true(winbar:find(label, 1, true) ~= nil, "agent tab bar omitted " .. label)
    end
    local active_instances = worktree_test_api().list_agent_sessions()
    local repo_instances = 0
    for _, instance in ipairs(active_instances) do
      if realpath(instance.path) == realpath(repo) then
        repo_instances = repo_instances + 1
      end
    end
    assert_true(repo_instances == 6, "agent session discovery did not retain every terminal instance")

    local hidden = assert(agents.new("claude", { view_mode = true }))
    assert_true(agents.open("cursor"), "could not reactivate the selected terminal agent")
    wait_until("active agent before send", function()
      return vim.api.nvim_get_current_buf() == cursor_buf
    end, 3000)
    assert_true(rendered_winbar():find("claude 3", 1, true), "third terminal tab did not appear")
    terminal_io.stop(hidden)
    wait_until("hidden agent exit updates tabs", function()
      return not vim.api.nvim_buf_is_valid(hidden) and not rendered_winbar():find("claude 3", 1, true)
    end, 3000)
    assert_true(vim.api.nvim_get_current_buf() == cursor_buf, "hidden agent exit changed focus")

    local nearby = repo .. "/other-directory"
    vim.fn.mkdir(nearby, "p")
    vim.cmd.cd(nearby)
    assert_true(visible_agent_window_count() == 0, "changing directory kept the previous Agents panel visible")
    vim.cmd.cd(repo)
    wait_until("return to the same Agents pane", function()
      return visible_agent_window_count() == 1 and vim.api.nvim_get_current_buf() == cursor_buf
    end, 3000)

    agents.toggle()
    assert_true(visible_agent_window_count() == 0, "agent container did not hide")

    vim.cmd("edit " .. vim.fn.fnameescape(source))
    vim.cmd("normal! ggV")
    invoke_map("<leader>a", "x")
    local cursor_input = input_log .. ".cursor-agent"
    local codex_input = input_log .. ".mcodex"
    wait_until("active agent path delivery", function()
      return table.concat(read_log(cursor_input), ""):find("agent-view.txt:1-1", 1, true) ~= nil
    end, 3000)
    assert_true(table.concat(read_log(codex_input), ""):find("agent-view.txt:1-1", 1, true) == nil, "path was sent to the wrong agent tab")

    agents.toggle()
    assert_true(visible_agent_window_count() == 0, "shared toggle did not hide the active terminal")
    agents.toggle()
    wait_until("shared toggle restores active tab", function()
      return visible_agent_window_count() == 1
        and vim.api.nvim_get_current_buf() == cursor_buf
    end, 3000)
    local reopened_win = vim.api.nvim_get_current_win()
    assert_true(vim.api.nvim_win_get_height(reopened_win) == agent_height, "reopened agent container changed height")
    assert_agent_float(reopened_win, "toggled agent container")
    winbar = rendered_winbar(reopened_win)
    assert_true(winbar:find("[cursor", 1, true) ~= nil, "reopened agent container did not reserve its tab bar")

    terminal_io.send(codex_buf, "\27]2;Background agent thread\7")
    wait_until("background agent title", function()
      return vim.b[codex_buf].term_title == "Background agent thread"
    end, 3000)
    assert_true(rendered_winbar(reopened_win):find("Background agent thread", 1, true), "hidden agent title was not updated")
    for _, title in ipairs({ "Agent thread title", "Renamed agent thread" }) do
      terminal_io.send(cursor_buf, "\27]2;" .. title .. "\7")
      wait_until("agent terminal title", function()
        return vim.b[cursor_buf].term_title == title
      end, 3000)
      assert_true(rendered_winbar(reopened_win):find("[" .. title .. "]", 1, true), "agent tab ignored its updated terminal title")
      assert_true(vim.api.nvim_get_current_buf() == cursor_buf, "renaming changed the active agent tab")
    end

    vim.cmd("quit")
    wait_until("agent close focuses left tab", function()
      return visible_agent_window_count() == 1
        and vim.api.nvim_get_current_buf() == first_cursor_buf
    end, 3000)
    assert_true(not vim.api.nvim_buf_is_valid(cursor_buf), "agent terminal :q did not close its TUI")

    assert_true(agents.open("codex", codex_buf, { view_mode = true }), "could not focus the first agent tab before closing it")
    wait_until("first agent tab before close", function()
      return vim.api.nvim_get_current_buf() == codex_buf
    end, 3000)
    vim.cmd("quit")
    wait_until("first agent close focuses right tab", function()
      return visible_agent_window_count() == 1
        and vim.api.nvim_get_current_buf() == second_codex_buf
    end, 3000)
    assert_true(not vim.api.nvim_buf_is_valid(codex_buf), "closing the first agent tab kept its TUI")

    terminal_io.stop(second_codex_buf)
    wait_until("agent process exit focuses right tab", function()
      return visible_agent_window_count() == 1
        and vim.api.nvim_get_current_buf() == first_cursor_buf
    end, 3000)
    assert_true(not vim.api.nvim_buf_is_valid(second_codex_buf), "exited agent process kept its terminal buffer")

    do
      local win = vim.api.nvim_get_current_win()
      local last_claude = registered_agent_bufnrs("claude", repo)[2]
      local function assert_tab_order(first, second, third)
        local bar = rendered_winbar(win)
        local a, b, c = bar:find(first, 1, true), bar:find(second, 1, true), bar:find(third, 1, true)
        assert_true(a and b and c and a < b and b < c, "unexpected agent tab order: " .. bar)
      end

      invoke_map("<C-h>")
      local menu = vim.api.nvim_get_current_win()
      local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
      local cursor_row
      for row, line in ipairs(lines) do
        if line:match(" cursor$") then cursor_row = row end
      end
      assert_true(cursor_row, "sidebar omitted the Cursor session")
      vim.api.nvim_win_set_cursor(menu, { cursor_row, 0 })
      invoke_map("<C-S-j>")
      assert_tab_order("claude 1", "[cursor]", "claude 2")
      assert_true(vim.api.nvim_get_current_win() == menu, "reordering tabs moved focus out of the sidebar")

      invoke_map("<C-l>")
      invoke_map("<Tab>")
      assert_true(vim.api.nvim_get_current_buf() == last_claude, "Tab ignored the sidebar order")
      assert_tab_order("claude 1", "cursor", "[claude 2]")
      invoke_map("<S-Tab>")
      assert_true(vim.api.nvim_get_current_buf() == first_cursor_buf, "Shift-Tab ignored the sidebar order")

      invoke_map("<C-h>")
      invoke_map("<C-S-k>")
      assert_tab_order("[cursor]", "claude 1", "claude 2")
      invoke_map("<C-S-k>")
      assert_tab_order("claude 1", "claude 2", "[cursor]")
      invoke_map("<C-S-j>")
      assert_tab_order("[cursor]", "claude 1", "claude 2")
      invoke_map("<C-l>")
    end

    agents.hide()
    vim.o.columns = 160
    local other_workspace = temp_root .. "/local_workspaces/example-agent"
    local other_path = other_workspace .. "/nested folder"
    vim.fn.mkdir(other_path, "p")
    vim.cmd.cd({ args = { other_path } })
    local editor = vim.api.nvim_get_current_win()
    local other_buf = agents.new("codex")
    local main = vim.api.nvim_get_current_win()
    for _, key in ipairs({ "<Tab>", "<S-Tab>" }) do
      invoke_map(key)
      assert_true(vim.api.nvim_get_current_buf() == other_buf and realpath(vim.fn.getcwd()) == realpath(other_path),
        key .. " left the current agent workspace")
    end
    invoke_map("<C-h>")
    local sidebar = vim.api.nvim_get_current_win()
    local sidebar_buf = vim.api.nvim_get_current_buf()
    assert_true(sidebar ~= main and vim.bo[sidebar_buf].filetype == "agent-window-bar", "Ctrl+h did not focus the sidebar")
    local main_config = vim.api.nvim_win_get_config(main)
    local sidebar_config = vim.api.nvim_win_get_config(sidebar)
    local sidebar_lines = vim.api.nvim_buf_get_lines(sidebar_buf, 0, -1, false)
    local ns = vim.api.nvim_create_namespace("LuanphanWindowBar")
    local marks = vim.api.nvim_buf_get_extmarks(sidebar_buf, ns, 0, -1, { details = true })
    for session, icon in pairs({ codex = "\u{ec81}", cursor = "\u{ec5c}", ["claude 1"] = "\u{ec82}", ["claude 2"] = "\u{ec82}" }) do
      assert_true(vim.iter(marks):any(function(mark)
        local details = mark[4]
        return details.virt_text_win_col == sidebar_config.width - 2 and details.virt_text[1][1] == icon
          and vim.trim(sidebar_lines[mark[2] + 1]):gsub("^-?%d+%s+", "") == session
      end), "sidebar omitted right-aligned provider icon for " .. session)
    end
    assert_true(sidebar_config.width == 43, "sidebar did not use the remaining width at 160 columns")
    assert_true(sidebar_config.col + sidebar_config.width + 2 == main_config.col, "agent panes left a gap at 100% combined width")
    assert_true(sidebar_config.zindex == main_config.zindex, "agent panes are on different layers")
    local overlay_width = main_config.col + main_config.width + 2 - sidebar_config.col
    assert_true(overlay_width == 144 and sidebar_config.col == 8, "combined float did not center at 90% width")
    assert_true(main_config.width == 97, "centering changed the terminal width")
    wait_until("sidebar renders an idle dot", function()
      return status_icon(main, other_buf) == "·"
    end, 3000)
    terminal_io.send(first_cursor_buf, "\27]0;cursor - 🔄 working\7")
    wait_until("sidebar reads working status from the Cursor terminal title", function()
      return vim.b[first_cursor_buf].luanphan_view_status == "working"
    end, 3000)
    terminal_io.send(first_cursor_buf, "\27]0;cursor - ✅ ready\7")
    wait_until("Cursor terminal title completion becomes a checkmark", function()
      return status_icon(main, first_cursor_buf) == "✓"
    end, 3000)
    terminal_io.send(first_cursor_buf, "\27]7501;state=clear\27\\")
    wait_until("sidebar clears the terminal status icon", function()
      return status_icon(main, first_cursor_buf) == nil
    end, 3000)
    vim.api.nvim_set_current_win(main)
    vim.defer_fn(function() vim.api.nvim_input("<CR><Esc>") end, 20)
    vim.api.nvim_feedkeys("i", "xt!", false)
    vim.api.nvim_set_current_win(sidebar)
    local idle_icon, idle_col = status_icon(main, other_buf)
    assert_true(idle_icon == "·" and idle_col == sidebar_config.width - 4, "Enter changed the Codex sidebar status")
    terminal_io.send(other_buf, "\27]7501;state=working:app=codex\27\\")
    local frame
    wait_until("sidebar shows the native Codex working status", function()
      frame = status_icon(main, other_buf)
      return frame and vim.fn.char2nr(frame) >= 0x2800 and vim.fn.char2nr(frame) <= 0x28ff
    end, 3000)
    wait_until("running status spinner animates", function()
      local next_frame = status_icon(main, other_buf)
      return next_frame and next_frame ~= frame
    end, 3000)
    terminal_io.send(other_buf, "\27]7501;state=done:app=codex\27\\")
    wait_until("spinner turns into a checkmark", function()
      return status_icon(main, other_buf) == "✓"
    end, 3000)
    assert_true(vim.api.nvim_get_current_win() == sidebar, "status update moved focus")

    local function read_sidebar()
      return vim.api.nvim_buf_get_lines(sidebar_buf, 0, -1, false)
    end
    local function focus_sidebar_row(line)
      vim.api.nvim_win_set_cursor(sidebar, { line, 0 })
    end
    local function group_row(lines, title)
      for index, line in ipairs(lines) do
        if line:match("^ %[%d+%] (.*)$") == title then return index end
      end
    end
    local original_rows = read_sidebar()
    local example_row = assert(group_row(original_rows, "example-agent"), "sidebar fixture missing its workspace")
    local example_session = original_rows[example_row + 1]
    assert_true(example_row > 0 and example_session and example_session:match("codex$"), "sidebar fixture missing its session")
    focus_sidebar_row(example_row + 1)
    invoke_map("<C-S-j>")
    invoke_map("<C-S-k>")
    assert_true(vim.deep_equal(read_sidebar(), original_rows), "session moved outside its workspace")
    invoke_map("h")
    local folded_rows = vim.deepcopy(original_rows)
    table.remove(folded_rows, example_row + 1)
    folded_rows[example_row] = "▸" .. original_rows[example_row]
    assert_true(vim.deep_equal(read_sidebar(), folded_rows), "fold did not hide just the selected workspace's sessions")
    assert_true(vim.api.nvim_win_get_cursor(sidebar)[1] == example_row, "fold did not focus the workspace header")
    invoke_map("l")
    assert_true(vim.deep_equal(read_sidebar(), original_rows), "unfold did not restore the workspace's sessions")

    local repo_row = assert(group_row(original_rows, vim.fn.fnamemodify(repo, ":t")))
    assert_true(repo_row > 0, "sidebar fixture missing repository workspace")
    focus_sidebar_row(repo_row + 1)
    invoke_map("<C-S-j>")
    require("luanphan.agents.window_bar").bar:refresh(true)
    local swapped = vim.deepcopy(original_rows)
    swapped[repo_row + 1], swapped[repo_row + 2] = swapped[repo_row + 2], swapped[repo_row + 1]
    assert_true(vim.deep_equal(read_sidebar(), swapped), "session order did not survive sidebar refresh")
    assert_true(vim.api.nvim_win_get_cursor(sidebar)[1] == repo_row + 2, "cursor did not follow the moved session")
    invoke_map("<C-S-k>")
    assert_true(vim.deep_equal(read_sidebar(), original_rows), "moving the session back did not restore its order")

    local second_workspace = math.max(example_row, repo_row)
    local swapped_groups = vim.list_extend(vim.list_slice(original_rows, second_workspace),
      vim.list_slice(original_rows, 1, second_workspace - 1))
    local moved_row = #original_rows - second_workspace + 2
    swapped_groups[1] = swapped_groups[1]:gsub("^ %[%d+%]", " [1]")
    swapped_groups[moved_row] = swapped_groups[moved_row]:gsub("^ %[%d+%]", " [2]")
    focus_sidebar_row(1)
    invoke_map("<C-S-j>")
    assert_true(vim.deep_equal(read_sidebar(), swapped_groups), "workspace move did not carry all its sessions")
    assert_true(vim.api.nvim_win_get_cursor(sidebar)[1] == moved_row,
      "cursor did not follow the moved workspace")
    invoke_map("<C-S-k>")
    assert_true(vim.deep_equal(read_sidebar(), original_rows), "moving the workspace back did not restore its order")

    invoke_map("<C-l>")
    assert_true(vim.api.nvim_get_current_win() == main, "Ctrl+l did not return to the terminal")
    invoke_map("<leader>b")
    assert_true(vim.api.nvim_win_get_config(sidebar).hide, "<leader>b did not hide the sidebar")
    assert_true(vim.deep_equal(vim.api.nvim_win_get_config(main), main_config), "hiding the sidebar changed the agent float")
    invoke_map("<leader>b")
    assert_true(not vim.api.nvim_win_get_config(sidebar).hide, "<leader>b did not show the sidebar")
    assert_true(vim.api.nvim_get_current_win() == main, "toggling the sidebar took focus from the terminal")
    invoke_map("<leader>e")
    assert_true(vim.api.nvim_get_current_win() == sidebar, "<leader>e did not focus the sidebar")
    assert_true(vim.wo[sidebar].winhighlight:find("FloatBorder:DiagnosticOk", 1, true),
      "focused sidebar did not get a green border")
    invoke_map("<leader>e")
    assert_true(vim.api.nvim_get_current_win() == main, "<leader>e did not return from the sidebar to the terminal")
    assert_true(vim.wo[sidebar].winhighlight == "CursorLine:Visual", "sidebar kept its focus color after leaving")

    invoke_map("<leader>sg")
    local settings_buf = vim.api.nvim_get_current_buf()
    local defaults = vim.api.nvim_buf_get_lines(settings_buf, 0, -1, false)
    assert_true(vim.tbl_contains(defaults, "[agent_float]") and vim.tbl_contains(defaults, "max_cache_entry = 3"),
      "settings migration did not add the float section or preserve the existing setting")
    local custom = vim.tbl_map(function(line)
      return line:gsub("^total_width_percent = .+$", "total_width_percent = 80")
        :gsub("^sidebar_width_percent = .+$", "sidebar_width_percent = 20.5")
        :gsub("^terminal_width_percent = .+$", "terminal_width_percent = 60")
    end, defaults)
    vim.api.nvim_buf_set_lines(settings_buf, 0, -1, false, custom)
    invoke_map("q")
    local custom_main = vim.api.nvim_win_get_config(main)
    local custom_sidebar = vim.api.nvim_win_get_config(sidebar)
    assert_true(custom_sidebar.col == 16 and custom_sidebar.width == 24, "sidebar width did not use the configured percentage")
    assert_true(custom_main.col == 68 and custom_main.width == 74, "terminal width or gap did not use the configured percentages")
    assert_true(custom_main.col + custom_main.width + 2 - custom_sidebar.col == 128, "configured total width was not applied")

    invoke_map("<leader>sg")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.tbl_map(function(line)
      return line:gsub("^total_width_percent = .+$", "total_width_percent = 100")
    end, defaults))
    invoke_map("q")
    local full_main = vim.api.nvim_win_get_config(main)
    local full_sidebar = vim.api.nvim_win_get_config(sidebar)
    assert_true(type(full_main.border) == "table", "fullscreen terminal is missing its border")
    assert_true(vim.deep_equal(full_sidebar.border, sidebar_config.border), "fullscreen changed the sidebar border")
    assert_true(full_sidebar.col == 0 and full_sidebar.col + full_sidebar.width + 2 == full_main.col
      and full_main.col + full_main.width + 2 == vim.o.columns, "fullscreen panes did not fill the editor width")
    assert_true(full_sidebar.row == full_main.row and full_sidebar.height == full_main.height,
      "fullscreen terminal did not fill the sidebar's outer height")
    assert_terminal_grid_matches(other_buf, main, "fullscreen agent")

    invoke_map("<leader>sg")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, defaults)
    invoke_map("q")
    assert_true(vim.deep_equal(vim.api.nvim_win_get_config(main), main_config), "saving defaults did not restore the terminal size")

    local title = "Workspace switch thread"
    terminal_io.send(first_cursor_buf, "\27]2;" .. title .. "\7")
    local thread_row
    wait_until("sidebar thread title", function()
      local lines = vim.api.nvim_buf_get_lines(sidebar_buf, 0, -1, false)
      for index, line in ipairs(lines) do
        if line:find(title, 1, true) then thread_row = index end
      end
      return thread_row and group_row(lines, "example-agent")
    end, 3000)

    invoke_map("<leader>e")
    assert_true(vim.api.nvim_get_current_win() == sidebar, "<leader>e did not focus the sidebar")
    vim.api.nvim_win_set_cursor(sidebar, { thread_row, 0 })
    invoke_map("o")
    assert_true(realpath(vim.fn.getcwd()) == realpath(repo), "sidebar selection did not change workspace")
    assert_true(vim.api.nvim_get_current_win() == main, "workspace switch replaced the agent float")
    assert_true(vim.api.nvim_get_current_buf() == first_cursor_buf, "sidebar opened the wrong thread")
    assert_true(vim.api.nvim_win_get_buf(sidebar) == sidebar_buf, "workspace switch replaced the sidebar")
    assert_true(terminal_io.running(other_buf), "workspace switch stopped the previous terminal")
    assert_true(rendered_winbar(main):find(title, 1, true), "workspace switch lost the top tabs")
    local function has_jump_number(number, label)
      local lines = vim.api.nvim_buf_get_lines(sidebar_buf, 0, -1, false)
      return vim.tbl_contains(lines, string.format(" %2d %s", number, label))
    end
    assert_true(has_jump_number(0, title) and has_jump_number(-1, "codex"),
      "sidebar did not number the current and older sessions")
    vim.api.nvim_set_current_win(sidebar)
    invoke_map("<C-o>")
    assert_true(vim.api.nvim_win_get_buf(main) == other_buf, "sidebar Ctrl+o did not jump to the older agent")
    assert_true(has_jump_number(1, title), "sidebar did not number the newer session after a jump")
    local renamed = "Renamed thread 界界界界 with a long title"
    terminal_io.send(first_cursor_buf, "\27]2;" .. renamed .. "\7")
    wait_until("renamed sidebar thread keeps its jump number and fits", function()
      local line = vim.api.nvim_buf_get_lines(sidebar_buf, thread_row - 1, thread_row, false)[1]
      return vim.startswith(line, "  1 Renamed thread 界") and vim.endswith(line, "…")
        and vim.fn.strdisplaywidth(line) < vim.api.nvim_win_get_width(sidebar)
    end, 3000)
    invoke_map("<C-i>")
    assert_true(vim.api.nvim_win_get_buf(main) == first_cursor_buf, "sidebar Ctrl+i did not jump to the newer agent")
    assert_true(vim.api.nvim_get_current_win() == sidebar and vim.api.nvim_get_current_buf() == sidebar_buf,
      "agent jump moved focus or replaced the sidebar buffer")
    assert_true(not pcall(vim.cmd, "buffer " .. first_cursor_buf), "sidebar accepted a different buffer")
    invoke_map("<C-o>")
    assert_true(vim.api.nvim_win_get_buf(main) == other_buf, "agent history did not return to the workspace with one session")
    terminal_io.stop(other_buf)
    wait_until("last session exit selects the newer history entry", function()
      return not vim.api.nvim_buf_is_valid(other_buf) and vim.api.nvim_get_current_buf() == first_cursor_buf
    end, 3000)
    assert_true(vim.api.nvim_get_current_win() == main and vim.api.nvim_win_get_buf(sidebar) == sidebar_buf,
      "last session exit replaced the agent float")
    vim.api.nvim_set_current_win(editor)
    wait_until("agent float hides when editor gains focus", function()
      return not vim.api.nvim_win_is_valid(main) and not vim.api.nvim_win_is_valid(sidebar)
    end, 3000)
    assert_true(terminal_io.running(first_cursor_buf), "hiding the float stopped the agent")

    assert_true(agents.open("cursor", first_cursor_buf, { view_mode = true }), "could not reopen the agent float")
    main = vim.api.nvim_get_current_win()
    invoke_map("<C-h>")
    sidebar = vim.api.nvim_get_current_win()
    vim.api.nvim_win_close(sidebar, false)
    assert_true(not vim.api.nvim_win_is_valid(main), "closing the sidebar left the terminal visible")

    write(settings_path, { "[agent_float]", "total_width_percent = 3" })
    vim.cmd.cd({ args = { other_path } })
    local narrow = assert(agents.new("codex", { view_mode = true }))
    assert_true(not vim.w.luanphan_window_bar, "narrow agent panel unexpectedly displayed a sidebar")
    terminal_io.stop(narrow)
    wait_until("closing the last tile without a sidebar returns to the previous workspace", function()
      return not vim.api.nvim_buf_is_valid(narrow) and vim.api.nvim_get_current_buf() == first_cursor_buf
        and realpath(vim.fn.getcwd()) == realpath(repo)
    end, 3000)

    close_agent_terminals()
    vim.o.lines = 48
    write(settings_path, {
      "[agent_float]", 'display_style = "tile"', "total_width_percent = 100",
      "sidebar_width_percent = 20", "terminal_width_percent = 80",
    })
    local tile_buffers = { agents.new("codex", { view_mode = true }) }
    local function tile_window(buf)
      local win = vim.fn.bufwinid(buf)
      assert_true(win ~= -1 and vim.w[win].luanphan_view_anchor, "agent session is missing its tile")
      return win
    end
    local function tile_config(index)
      return vim.api.nvim_win_get_config(tile_window(tile_buffers[index]))
    end
    local single = tile_config(1)
    assert_true(vim.deep_equal(single.border[1], { "┏", "DiagnosticOk" }), "single fullscreen tile lacks the view mode border")
    for _, provider in ipairs({ "cursor", "codex", "claude" }) do
      tile_buffers[#tile_buffers + 1] = agents.new(provider, { view_mode = true })
    end
    local bottom = vim.o.lines - vim.o.cmdheight
    local cut = math.floor(bottom / 2)
    local bounds = { { 32, 0, 64, bottom }, { 96, 0, 64, cut }, { 96, cut, 32, bottom - cut }, { 128, cut, 32, bottom - cut } }
    for index, label in ipairs({ "codex 1", "cursor", "codex 2", "claude" }) do
      local cfg = tile_config(index)
      assert_true(cfg.border and cfg.border ~= "none", "multiple tiles need borders")
      assert_true(vim.deep_equal({ cfg.col, cfg.row, cfg.width + 2, cfg.height + 2 }, bounds[index]), "wrong bounds for tile " .. index)
      local win = tile_window(tile_buffers[index])
      assert_true(vim.trim(rendered_winbar(win)) == "[" .. label .. "]", "tile has the wrong single-session title")
      assert_terminal_grid_matches(tile_buffers[index], win, "tile " .. index)
    end

    assert_true(agents.focus("cursor", tile_buffers[2], { view_mode = true }), "could not focus the second tile")
    local inserted = assert(agents.new("codex", { view_mode = true }))
    local inserted_config = vim.api.nvim_win_get_config(tile_window(inserted))
    assert_true(vim.deep_equal({ inserted_config.col, inserted_config.row }, { 96, cut }),
      "the new tile did not take the third slot")
    local lower_cut = math.floor((bottom - cut) / 2)
    assert_true(tile_config(3).col == 128 and tile_config(3).row == cut and tile_config(3).height + 2 == lower_cut
      and tile_config(4).col == 128 and tile_config(4).row == cut + lower_cut,
      "the later tiles did not shift and split")
    invoke_map("<S-Tab>")
    assert_true(vim.api.nvim_get_current_buf() == tile_buffers[2], "new tile did not follow the focused tile")
    for _, buf in ipairs({ inserted, tile_buffers[3], tile_buffers[4], tile_buffers[1] }) do
      invoke_map("<Tab>")
      assert_true(vim.api.nvim_get_current_buf() == buf, "Tab did not follow the inserted tile order")
    end
    terminal_io.stop(inserted)
    wait_until("inserted tile closed", function()
      return not vim.api.nvim_buf_is_valid(inserted) and visible_agent_window_count() == 4
    end, 3000)
    agents.hide()
    assert_true(agents.open("claude", tile_buffers[4], { view_mode = true }), "could not reopen the original four tiles")

    local function assert_focused_tile(index)
      for i = 1, #tile_buffers do
        local highlights = vim.wo[tile_window(tile_buffers[i])].winhighlight
        local corner = tile_config(i).border[1]
        local expected = i == index and { "┏", "DiagnosticOk" } or "┌"
        assert_true(vim.deep_equal(corner, expected), "wrong focus border for tile " .. i)
        local muted = highlights:find("NormalFloat:LuanphanInactiveTile", 1, true) ~= nil
        assert_true(muted == (i ~= index), "wrong background for tile " .. i)
      end
    end
    assert_true(agents.focus("codex", tile_buffers[3], { view_mode = true }), "could not focus the tile to move")
    for _, move in ipairs({
      { "<C-S-h>", { 3, 1, 2, 4 } },
      { "<C-S-h>", { 3, 1, 2, 4 } },
      { "<C-S-l>", { 1, 3, 2, 4 } },
      { "<C-S-j>", { 1, 2, 3, 4 } },
      { "<C-S-k>", { 1, 3, 2, 4 } },
      { "<C-S-j>", { 1, 2, 3, 4 } },
    }) do
      invoke_map(move[1])
      assert_true(vim.api.nvim_get_current_buf() == tile_buffers[3], move[1] .. " changed the focused session")
      for slot, index in ipairs(move[2]) do
        local cfg = tile_config(index)
        assert_true(vim.deep_equal({ cfg.col, cfg.row, cfg.width + 2, cfg.height + 2 }, bounds[slot]),
          move[1] .. " put the wrong tile in slot " .. slot)
      end
      assert_focused_tile(3)
    end
    assert_true(agents.focus("claude", tile_buffers[4], { view_mode = true }), "could not focus the last tile")
    assert_focused_tile(4)
    assert_true(agents.focus("codex", tile_buffers[1], { view_mode = true }), "could not focus the left tile")
    local worktree = require("luanphan.plugins.worktree")
    local list_agents, scans = worktree.list_agent_sessions, 0
    worktree.list_agent_sessions = function(...)
      scans = scans + 1
      return list_agents(...)
    end
    local moved, move_error = pcall(invoke_map, "<C-l>")
    worktree.list_agent_sessions = list_agents
    assert_true(moved, tostring(move_error))
    assert_true(vim.api.nvim_get_current_win() == tile_window(tile_buffers[2]), "focus did not move to the visible agent tile")
    assert_true(scans == 0, "agent tile focus scanned the session list")
    local bar = require("luanphan.agents.window_bar").bar
    local sidebar_buf = vim.api.nvim_win_get_buf(bar.win)
    local function sidebar_lines() return vim.api.nvim_buf_get_lines(sidebar_buf, 0, -1, false) end
    local incremental = sidebar_lines()
    bar:redraw()
    assert_true(vim.deep_equal(sidebar_lines(), incremental), "tile focus left stale sidebar history numbers")
    invoke_map("<C-h>")
    for _, move in ipairs({ { "l", 2 }, { "j", 3 }, { "l", 4 }, { "k", 2 }, { "h", 1 } }) do
      local key, index = "<C-" .. move[1] .. ">", move[2]
      invoke_map(key)
      assert_true(vim.api.nvim_get_current_win() == tile_window(tile_buffers[index]), key .. " missed its neighboring tile")
      assert_focused_tile(index)
    end
    invoke_map("<C-l>")
    invoke_map("<C-j>")
    invoke_map("<C-h>")
    assert_true(vim.api.nvim_get_current_win() == tile_window(tile_buffers[1]), "Ctrl+h did not return from the lower tile")
    invoke_map("<C-h>")
    assert_true(vim.bo.filetype == "agent-window-bar", "Ctrl+h did not continue into the sidebar")
    for _, key in ipairs({ "<C-j>", "<C-k>", "<C-h>" }) do
      assert_true(vim.fn.maparg(key, "n") == "<Nop>", key .. " is active past the sidebar edge")
    end
    invoke_map("<C-l>")
    for _, key in ipairs({ "<C-j>", "<C-k>" }) do
      invoke_map(key)
      assert_true(vim.api.nvim_get_current_win() == tile_window(tile_buffers[1]), key .. " moved past the left tile edge")
    end
    assert_true(agents.focus("claude", tile_buffers[4], { view_mode = true }), "could not focus the last tile")
    for _, key in ipairs({ "<C-l>", "<C-j>" }) do
      invoke_map(key)
      assert_true(vim.api.nvim_get_current_win() == tile_window(tile_buffers[4]) and visible_agent_window_count() == 4,
        key .. " moved past the last tile edge")
    end
    for _, index in ipairs({ 1, 2, 3, 4 }) do
      invoke_map("<Tab>")
      assert_true(vim.api.nvim_get_current_win() == tile_window(tile_buffers[index]), "Tab ignored tile order")
      assert_focused_tile(index)
    end
    invoke_map("<S-Tab>")
    assert_true(vim.api.nvim_get_current_win() == tile_window(tile_buffers[3]), "Shift-Tab ignored tile order")
    invoke_map("<leader>e")
    local tile_sidebar = vim.api.nvim_get_current_win()
    assert_focused_tile(nil)
    vim.api.nvim_win_set_cursor(tile_sidebar, { 1, 0 })
    local tile_sidebar_buf = vim.api.nvim_win_get_buf(tile_sidebar)
    local active_ns = vim.api.nvim_create_namespace("LuanphanWindowBarActive")
    for _, pair in ipairs({ { 4, "claude" }, { 3, "codex 2" } }) do
      vim.api.nvim_set_current_win(tile_window(tile_buffers[pair[1]]))
      local row = vim.api.nvim_win_get_cursor(tile_sidebar)[1]
      local line = vim.api.nvim_buf_get_lines(tile_sidebar_buf, row - 1, row, false)[1]
      assert_true(vim.trim(line):gsub("^-?%d+%s+", "") == pair[2], "sidebar cursor did not follow the focused tile")
      local mark = vim.api.nvim_buf_get_extmark_by_id(tile_sidebar_buf, active_ns, 1, {})
      assert_true(mark[1] == row - 1, "sidebar highlight did not follow the focused tile")
    end
    invoke_map("<leader>e")
    invoke_map("<C-S-k>")
    assert_true(tile_config(3).row == 0 and tile_config(2).row == cut, "sidebar reorder did not move the tiles")
    assert_true(vim.api.nvim_get_current_win() == tile_sidebar, "tile reorder took focus from the sidebar")
    invoke_map("<C-l>")
    assert_true(vim.api.nvim_get_current_win() == tile_window(tile_buffers[3]), "sidebar did not return to its focused tile")
    invoke_map("<Tab>")
    assert_true(vim.api.nvim_get_current_win() == tile_window(tile_buffers[2]), "Tab reverted the tile order")

    terminal_io.stop(tile_buffers[4])
    wait_until("exited tile leaves a three-pane layout", function()
      return not vim.api.nvim_buf_is_valid(tile_buffers[4]) and visible_agent_window_count() == 3
        and tile_config(2).width == 62
    end, 3000)
    assert_true(vim.api.nvim_get_current_win() == tile_window(tile_buffers[2]), "background tile exit changed focus")

    local function display_style(style)
      invoke_map("<leader>sg")
      local settings_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
      vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.tbl_map(function(line)
        return line:gsub('^display_style = "[^"]+"$', 'display_style = "' .. style .. '"')
      end, settings_lines))
      invoke_map("q")
    end
    display_style("tabs")
    assert_true(visible_agent_window_count() == 1, "changing display style did not collapse the tiles")
    assert_true(vim.api.nvim_get_current_buf() == tile_buffers[2], "changing display style lost the active session")
    display_style("tile")
    assert_true(visible_agent_window_count() == 3, "saving tile style did not reopen the panes")

    agents.toggle()
    assert_true(visible_agent_window_count() == 0 and not vim.api.nvim_win_is_valid(tile_sidebar),
      "hiding the tiled panel left a pane or sidebar visible")
    assert_true(agents.open("cursor", tile_buffers[2], { view_mode = true }), "failed to reopen the tiled panel")
    assert_true(visible_agent_window_count() == 3, "reopening the panel did not restore all live panes")
    terminal_io.stop(tile_buffers[2])
    wait_until("focused tile exit", function()
      return not vim.api.nvim_buf_is_valid(tile_buffers[2]) and visible_agent_window_count() == 2
    end, 3000)
    assert_true(vim.api.nvim_get_current_buf() == tile_buffers[3], "tile exit did not focus its neighbor")
    invoke_map("<leader>e")
    for _, key in ipairs({ "<C-S-j>", "<C-S-k>" }) do
      invoke_map(key)
      assert_true(tile_config(3).col == bounds[1][1], key .. " did not move the selected tile to the first slot")
      invoke_map(key)
      assert_true(tile_config(3).col == bounds[2][1], key .. " did not move the selected tile back to the second slot")
    end
    invoke_map("<C-l>")
    terminal_io.stop(tile_buffers[3])
    wait_until("remaining tile expands", function()
      return not vim.api.nvim_buf_is_valid(tile_buffers[3]) and visible_agent_window_count() == 1
    end, 3000)
    local remaining = tile_config(1)
    assert_true(remaining.width == single.width and vim.deep_equal(remaining.border, single.border),
      "remaining tile did not fill the panel with its focus border")
    assert_true(not vim.wo[tile_window(tile_buffers[1])].winhighlight:find("LuanphanInactiveTile", 1, true),
      "the remaining tile stayed dimmed")


  end, debug.traceback)

  vim.env.PATH = old_path
  vim.env.NVIM_AGENT_SMOKE_LOG = old_log
  vim.env.NVIM_AGENT_SMOKE_INPUT = old_input
  vim.o.columns = old_columns
  vim.o.lines = old_lines
  vim.g.luanphan_global_settings_path = old_global_settings
  close_agent_terminals()
  vim.g.luanphan_codex_sessions_dir = old_codex_sessions
  vim.g.luanphan_cursor_sessions_dir = old_cursor_sessions
  vim.g.luanphan_terminal_sessions_dir = old_terminal_sessions
  local source_buf = vim.fn.bufnr(source)
  if source_buf >= 0 and vim.api.nvim_buf_is_valid(source_buf) then
    pcall(vim.api.nvim_buf_delete, source_buf, { force = true })
  end
  if vim.fn.isdirectory(old_cwd) == 1 then
    pcall(vim.cmd, "cd " .. vim.fn.fnameescape(old_cwd))
  end
  assert_true(ok, tostring(err))
end

local function test_tiled_agent_workspace_picker(repo, worktree)
  local fixture = temp_root .. "/tiled-workspace-picker"
  write_executable(fixture .. "/bin/mcodex", {
    "#!/bin/sh",
    'if [ "$2" != "-c" ]; then printf "\\033]0;%.29s... | Example background thread\\007" "$2"; fi',
    "exec cat",
  })
  write(fixture .. "/settings.toml", { "[agent_float]", 'display_style = "tile"' })
  local script = fixture .. "/picker.lua"
  local script_lines = {
    "vim.env.PATH = " .. string.format("%q", fixture .. "/bin:") .. " .. vim.env.PATH",
    "vim.g.luanphan_global_settings_path = " .. string.format("%q", fixture .. "/settings.toml"),
    "vim.g.luanphan_recent_paths_file = " .. string.format("%q", fixture .. "/recent.json"),
    "vim.g.luanphan_codex_sessions_dir = " .. string.format("%q", fixture .. "/codex-sessions"),
    "vim.g.luanphan_cursor_sessions_dir = " .. string.format("%q", fixture .. "/cursor-sessions"),
    "local destination = " .. string.format("%q", worktree),
  }
  local restart_setup = vim.list_slice(script_lines)
  vim.list_extend(script_lines, vim.split([[
vim.o.columns = 160
vim.o.lines = 48
require('lazy').load({ plugins = { 'luanphan-worktree' } })
local agents = require('luanphan.agents.main')
local terminal = require('luanphan.view_container.terminal')
local view = require('luanphan.view_container')
local actions = require('telescope.actions')
local action_state = require('telescope.actions.state')
local function new_agent(id)
  return agents.new('codex', { view_mode = true, thread_id = id, args = id and { 'resume', id } })
end
local home, home_peer = new_agent(), new_agent()
agents.hide()
vim.cmd.cd({ args = { destination } })
local id = '00000000-0001-4000-8000-000000000001'
local away, away_peer = new_agent(id), new_agent()
assert(vim.wait(3000, function()
  return (vim.b[away].term_title or ''):find('Example background thread', 1, true)
end), 'background pane did not receive its title')
local anchor = view.group_anchor(vim.api.nvim_get_current_win())
local sidebar = assert(vim.w[anchor].luanphan_window_bar)

local function choose_workspace(buf)
  vim.fn.maparg('<leader>ww', 'n', false, true).callback()
  local prompt = vim.api.nvim_get_current_buf()
  local picker = assert(action_state.get_current_picker(prompt), 'agent window picker did not open')
  assert(picker.layout_strategy == 'center' and vim.api.nvim_win_get_width(0) <= 96,
    'agent window picker did not use the compact centered layout')
  assert(vim.wait(3000, function() return picker.manager and picker.manager:num_results() == 2 end, 20),
    'agent window picker did not show one entry per workspace')
  actions.select_default(prompt)
  assert(vim.wait(3000, function() return vim.api.nvim_get_current_buf() == buf end, 20),
    'agent window picker did not return to the last session of the previous workspace')
  assert(#view.group_windows(anchor) == 3 and vim.w[anchor].luanphan_window_bar == sidebar,
    'agent window picker did not keep the tiles and sidebar together')
end

choose_workspace(home_peer)
assert(vim.fn.bufwinid(away) == -1 and vim.fn.bufwinid(away_peer) == -1,
  'agent window picker left tiles from the previous workspace')
choose_workspace(away_peer)
assert(vim.fn.bufwinid(home) == -1 and vim.fn.bufwinid(home_peer) == -1,
  'agent window picker left tiles on the return switch')
local window_bar = require('luanphan.agents.window_bar')
assert(window_bar.select_session({ kind = 'codex', bufnr = home, path = vim.b[home].luanphan_view_cwd }, { view_mode = true }),
  'sidebar could not select an individual agent session')

local reference = vim.fn.getcwd() .. '/example-reference.txt'
vim.fn.writefile({ 'first', 'second' }, reference)
local reference_buf = vim.fn.bufadd(reference)
local reference_peer = vim.fn.bufwinid(home_peer)
local peer_height = vim.api.nvim_win_get_height(reference_peer)
local height_during_read
vim.api.nvim_create_autocmd('BufReadPost', {
  buffer = reference_buf,
  once = true,
  callback = function() height_during_read = vim.api.nvim_win_get_height(reference_peer) end,
})
assert(require('luanphan.terminal_references').open(reference, 2, 1), 'first reference failed after switching workspaces')
assert(height_during_read == peer_height, 'the first file read ran while the panel was changing layout')
local editor = require('luanphan.view_container.editor').window(anchor)
assert(editor == vim.api.nvim_get_current_win() and vim.api.nvim_get_current_buf() == reference_buf,
  'the first reference did not open in the tiled agent panel')
assert(#view.group_windows(anchor) == 4 and vim.w[anchor].luanphan_window_bar == sidebar,
  'opening the first reference closed part of the panel')
choose_workspace(away_peer)
local editor_row
local sidebar_buf = vim.api.nvim_win_get_buf(sidebar)
for index, line in ipairs(vim.api.nvim_buf_get_lines(sidebar_buf, 0, -1, false)) do
  if vim.trim(line) == 'Editor · example-reference.txt' then editor_row = index end
end
assert(editor_row, 'switching workspaces hid the editor sidebar row')
vim.api.nvim_set_current_win(sidebar)
vim.api.nvim_win_set_cursor(sidebar, { editor_row, 0 })
vim.fn.maparg('<CR>', 'n', false, true).callback()
assert(vim.wait(1000, function()
  return require('luanphan.view_container.editor').window(anchor) == vim.api.nvim_get_current_win()
    and vim.api.nvim_buf_get_name(0) == reference
    and vim.api.nvim_win_get_cursor(0)[1] == 2
end, 20), 'selecting the editor row did not return to its workspace and tile')
vim.cmd.quit()
assert(vim.wait(1000, function() return #view.group_windows(anchor) == 3 end, 20),
  'closing the reference did not restore the panel')
assert(agents.focus('codex', home, { view_mode = true }))

vim.g.neovide = true
vim.api.nvim_exec_autocmds('UIEnter', {})
local bar = vim.iter(pairs(vim.luanphan_window_bars)):find(function(candidate) return candidate.win == sidebar end)
assert(bar, 'agent window bar is missing')
local systemlist = vim.fn.systemlist
local git_calls = 0
vim.fn.systemlist = function(args, ...)
  if type(args) == 'table' and args[1] == 'git' then git_calls = git_calls + 1 end
  return systemlist(args, ...)
end
bar:refresh()
assert(git_calls == 0, 'rendering the agent groups spawned Git')
local worktree_api = require('luanphan.plugins.worktree')
local groups, activate, rebuilds = bar.opts.groups, worktree_api.activate_agent, 0
bar.opts.groups = function()
  rebuilds = rebuilds + 1
  return groups()
end
worktree_api.activate_agent = function(...)
  assert(rebuilds == 0, 'numbered selection rebuilt the rendered groups')
  return activate(...)
end
vim.api.nvim_feedkeys(vim.keycode('<D-2>'), 'xt', false)
assert(vim.api.nvim_get_current_buf() == away_peer and #view.group_windows(anchor) == 3,
  'Cmd+2 did not switch to the second workspace in place')
vim.api.nvim_set_current_win(sidebar)
vim.api.nvim_feedkeys(vim.keycode('<D-1>'), 'xt', false)
assert(vim.api.nvim_get_current_buf() == home and vim.w[anchor].luanphan_window_bar == sidebar,
  'Cmd+1 did not restore the first workspace from the sidebar')
vim.fn.systemlist = systemlist
assert(git_calls == 0, 'switching between live checkouts spawned Git')
assert(rebuilds == 0, 'switching between live workspaces rebuilt the sidebar groups')
bar.opts.groups, worktree_api.activate_agent = groups, activate
vim.api.nvim_feedkeys(vim.keycode('<D-9>'), 'xt', false)
assert(vim.api.nvim_get_current_buf() == home, 'out-of-range window shortcut changed focus')

local home_path = vim.fn.getcwd()
require('luanphan.view_container.terminal').stop(away_peer)
assert(vim.wait(3000, function() return not vim.api.nvim_buf_is_valid(away_peer) end, 20),
  'could not reduce the destination to one tile')

-- Reproduce a leftover float for the same buffer in the current window group.
local peer_win = vim.fn.bufwinid(home_peer)
local extra = vim.api.nvim_open_win(home_peer, false, vim.api.nvim_win_get_config(peer_win))
vim.w[extra].luanphan_view_anchor = anchor
assert(window_bar.select_session({ kind = 'codex', bufnr = away, path = destination }, { view_mode = true }),
  'sidebar could not switch to the single-tile workspace')
assert(vim.api.nvim_get_current_win() == anchor and vim.api.nvim_win_get_buf(anchor) == away,
  'single tile did not reuse the panel anchor')
assert(#view.group_windows(anchor) == 2 and vim.w[anchor].luanphan_window_bar == sidebar,
  'single-tile workspace left a tile from the previous workspace on screen')
local single_width = vim.api.nvim_win_get_width(anchor)
assert(window_bar.select_session({ kind = 'codex', bufnr = home, path = home_path }, { view_mode = true }),
  'sidebar could not return to the multi-tile workspace')
assert(#view.group_windows(anchor) == 3 and vim.w[anchor].luanphan_window_bar == sidebar,
  'returning to the multi-tile workspace did not restore its panes in place')
local first = vim.api.nvim_win_get_config(vim.fn.bufwinid(home))
local second = vim.api.nvim_win_get_config(vim.fn.bufwinid(home_peer))
assert(first.col + first.width + 2 == second.col and first.width + second.width + 2 == single_width,
  'returning from the single tile left overlapping panes')

local backend = require('luanphan.agents.tmux')
local save, load_groups = bar.opts.save_order, bar.opts.groups
local saves, reads = 0, 0
bar.opts.save_order = function(order) saves = saves + 1 return save(order) end
bar.opts.groups = function() reads = reads + 1 return load_groups() end
vim.api.nvim_set_current_win(sidebar)
vim.api.nvim_win_set_cursor(sidebar, { 1, 0 })
local initial_order = vim.tbl_map(function(group) return group.id end, bar.rows[1].groups)
local function move(key) vim.api.nvim_feedkeys(vim.keycode(key), 'xt', false) end
move('<D-S-j>')
assert(bar.rows[1].group.id == initial_order[2], 'moving the workspace took focus or waited on tmux')
move('<D-S-k>')
vim.wait(350, function() return false end)
assert(saves == 0, 'moving back to the original order wrote to tmux')
move('<D-S-j>')
move('<D-S-k>')
move('<D-S-j>')
assert(saves == 0 and reads == 0, 'moving workspaces queried groups or saved before the debounce')
assert(vim.wait(1500, function() return saves == 1 end), 'final workspace order was not saved')
assert(vim.deep_equal(backend.load_window_order(), { initial_order[2], initial_order[1] }),
  'tmux did not store the final workspace order')

local windows = view.group_windows(anchor)
vim.api.nvim_create_autocmd('User', {
  pattern = 'SmokeHideAgentPanel',
  once = true,
  callback = function() require('luanphan.view_container').close_window(sidebar) end,
})
vim.api.nvim_exec_autocmds('User', { pattern = 'SmokeHideAgentPanel' })
for _, win in ipairs(windows) do
  assert(not vim.api.nvim_win_is_valid(win), 'closing the panel inside an autocmd left a window behind')
end
for _, buf in ipairs({ home, home_peer, away }) do
  assert(terminal.running(buf), 'hiding the panel stopped an agent job')
end

assert(agents.focus('codex', home, { view_mode = true }))
local reopened_anchor = view.group_anchor(vim.api.nvim_get_current_win())
local interrupted = vim.fn.getcwd() .. '/example-interrupted-reference.txt'
local main_buf = vim.api.nvim_win_get_buf(require('luanphan.editor_window').find(reopened_anchor))
vim.fn.writefile({ 'reference' }, interrupted)
vim.api.nvim_create_autocmd('BufReadPost', {
  buffer = vim.fn.bufadd(interrupted),
  once = true,
  callback = function() require('luanphan.view_container').close_window(reopened_anchor) end,
})
assert(require('luanphan.terminal_references').open(interrupted), 'a panel close during the first file read lost the reference')
local restored_anchor = view.group_anchor(vim.api.nvim_get_current_win())
assert(require('luanphan.view_container.editor').window(restored_anchor) == vim.api.nvim_get_current_win()
  and vim.uv.fs_realpath(vim.api.nvim_buf_get_name(0)) == vim.uv.fs_realpath(interrupted),
  'an interrupted reference did not open in an editor tile')
assert(#view.group_windows(reopened_anchor) == 0 and #view.group_windows(restored_anchor) == 4
  and view.group_anchor(vim.fn.bufwinid(home)) == restored_anchor and terminal.running(home),
  'an interrupted reference did not restore the original agent panel together')
assert(vim.api.nvim_win_get_buf(require('luanphan.editor_window').find(restored_anchor)) == main_buf,
  'an interrupted reference changed the main editor buffer')
]], "\n", { plain = true }))
  write(script, script_lines)
  local output = vim.fn.systemlist(child_nvim_luafile_command(repo, script))
  assert_true(vim.v.shell_error == 0, table.concat(output, "\n"))
  vim.list_extend(restart_setup, vim.split([[
vim.o.columns = 160
local agents = require('luanphan.agents.main')
agents.toggle()
local sidebar = assert(vim.w.luanphan_window_bar)
local function sidebar_rows()
  return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(sidebar), 0, -1, false)
end
assert(sidebar_rows()[1] == ' [1] ' .. vim.fs.basename(destination), 'restarting Neovim lost the reordered workspaces')
local function has_title()
  return table.concat(sidebar_rows(), '\n'):find('Example background thread', 1, true)
end
assert(has_title(), 'restored workspace showed a raw session ID before focus')
local bars = require('luanphan.view_container.window_bar')
assert(bars.focus_window(1) and bars.focus_window(2), 'could not switch between restored workspaces')
assert(has_title(), 'workspace switch brought a raw session ID back into the sidebar')
vim.api.nvim_set_current_win(sidebar)
vim.api.nvim_win_set_cursor(sidebar, { 1, 0 })
vim.api.nvim_feedkeys(vim.keycode('<D-S-j>'), 'xt', false)
]], "\n", { plain = true }))
  write(script, restart_setup)
  output = vim.fn.systemlist(child_nvim_luafile_command(repo, script))
  assert_true(vim.v.shell_error == 0, table.concat(output, "\n"))
  local saved = vim.system({ "tmux", "-S", agent_socket(script), "show-options", "-sv", "@luanphan-window-order" },
    { text = true }):wait()
  assert_true(saved.code == 0 and vim.deep_equal(vim.json.decode(vim.trim(saved.stdout)), { realpath(repo), realpath(worktree) }),
    "quitting before the debounce lost the pending workspace order")
end

local function test_floating_terminal_windows()
  local root = temp_root .. "/floating-terminal"
  local script = root .. "/check.lua"
  write(script, vim.split([=[
local api = vim.api
local root = vim.fn.getcwd()
vim.g.luanphan_recent_paths_file = root .. '/recent.json'
vim.g.luanphan_global_settings_path = root .. '/settings.toml'
vim.fn.writefile({ '[floating_terminal]', 'backend = "shell"', 'total_width_percent = 80',
  'sidebar_width_percent = 20' }, vim.g.luanphan_global_settings_path)
vim.o.shell = '/bin/sh'
vim.env.ENV = nil
vim.o.columns, vim.o.lines = 160, 48
require('lazy').load({ plugins = { 'luanphan-floating-terminal' } })
local function key(lhs) vim.fn.maparg(lhs, 'n', false, true).callback() end
local function floats()
  return vim.tbl_filter(function(win) return api.nvim_win_get_config(win).relative ~= '' end, api.nvim_list_wins())
end
local function window_bar()
  for _, win in ipairs(floats()) do
    if vim.w[win].luanphan_view_companion_anchor then
      return table.concat(api.nvim_buf_get_lines(api.nvim_win_get_buf(win), 0, -1, false), '\n'), win
    end
  end
  error('window bar missing')
end
local function config(buf) return api.nvim_win_get_config(vim.fn.bufwinid(buf)) end

key('<leader>t')
local left = api.nvim_get_current_buf()
assert(vim.b[left].luanphan_floating_terminal and #floats() == 2, 'floating shell did not open')
local labels, bar = window_bar()
assert(labels:find('Window 1', 1, true), 'initial window is missing')
local sidebar = api.nvim_win_get_config(bar)
local full = config(left)
assert(sidebar.col == 16 and sidebar.width + 2 == 25 and full.col == 48 and full.width + 2 == 96
  and full.height + 2 == vim.o.lines - vim.o.cmdheight,
  'floating shell did not center the configured widths and gap')
local layout = require('luanphan.global_settings').read().floating_terminal
assert(layout.backend == 'shell' and layout.total_width_percent == 80 and layout.sidebar_width_percent == 20
  and layout.terminal_width_percent == 75, 'adding missing width settings changed existing settings')
assert(vim.deep_equal(full.border[1], { '┏', 'DiagnosticOk' }), 'single shell tile lacks the view mode border')
key('<leader>nt')
local upper = api.nvim_get_current_buf()
assert(upper ~= left and #floats() == 3 and not window_bar():find('Window 2', 1, true),
  'new terminal tab did not stay in the current window')
key('<leader>fn')
local lower = api.nvim_get_current_buf()
assert(#floats() == 4 and config(left).width == config(upper).width and config(left).row == config(upper).row
  and config(upper).col == config(lower).col and config(upper).row < config(lower).row, 'three panes did not use the fixed split')
for _, move in ipairs({ { '<C-k>', upper }, { '<C-h>', left }, { '<C-h>', api.nvim_win_get_buf(bar) },
  { '<C-l>', left }, { '<C-l>', upper }, { '<C-j>', lower } }) do
  key(move[1])
  assert(api.nvim_get_current_buf() == move[2], move[1] .. ' focused the wrong pane')
end
local moved_win = api.nvim_get_current_win()
key('<C-S-h>')
assert(api.nvim_get_current_win() == moved_win and config(lower).col == full.col and config(left).row < config(upper).row,
  'moving left did not push the other panes after the focused pane')
key('<C-S-l>')
key('<C-S-j>')
assert(api.nvim_get_current_win() == moved_win and config(left).col == full.col and config(upper).row < config(lower).row,
  'moving right and down did not restore the original order')

key('<leader>nw')
local other_window = api.nvim_get_current_buf()
assert(#floats() == 2 and window_bar():find('Window 2', 1, true), 'new window did not show its own shell')
key('<S-Tab>')
assert(api.nvim_get_current_buf() == other_window, 'Shift-Tab left a one-pane window')
key('<C-o>')
assert(#floats() == 4 and api.nvim_get_current_buf() == lower and window_bar():find('Window 1', 1, true),
  'window switch did not restore its panes and focus')
key('<Tab>')
assert(#floats() == 4 and api.nvim_get_current_buf() == left, 'Tab did not wrap within the current window')
key('<S-Tab>')
assert(api.nvim_get_current_buf() == lower, 'Shift-Tab missed the previous pane')
key('<leader>e')
api.nvim_feedkeys(vim.keycode(vim.g.mapleader .. 'ww'), 'xt', false)
local prompt = api.nvim_get_current_buf()
local picker = assert(require('telescope.actions.state').get_current_picker(prompt), 'terminal window picker did not open')
assert(vim.wait(3000, function() return picker.manager and picker.manager:num_results() == 2 end, 20),
  'window picker did not show one entry per terminal window')
assert(picker:get_selection().ordinal == 'Window 2', 'window picker did not prioritize the most recent alternative')
local prompt_frame = api.nvim_win_get_config(0)
assert(picker.layout_strategy == 'center' and prompt_frame.width <= 96
  and math.abs(prompt_frame.col * 2 + prompt_frame.width - vim.o.columns) <= 4
  and api.nvim_win_get_height(picker.results_win) <= 16, 'window picker is not compact and centered')
require('telescope.actions').select_default(prompt)
assert(vim.wait(3000, function() return #floats() == 2 and api.nvim_get_current_buf() == other_window end, 20),
  'window picker did not select the second window')
key('<leader>nt')
local new_pane = api.nvim_get_current_buf()
assert(new_pane ~= other_window and #floats() == 3 and window_bar():find('Window 2', 1, true)
  and not window_bar():find('Window 3', 1, true), 'new terminal tab opened a window')
vim.cmd.quit()
assert(vim.wait(3000, function()
  return not api.nvim_buf_is_valid(new_pane) and api.nvim_get_current_buf() == other_window
end), 'direct quit did not close the shell and return to its neighbor')
key('<leader>t')
assert(#floats() == 0, 'toggle left part of the panel open')
for _, buf in ipairs({ left, upper, lower, other_window }) do
  assert(vim.fn.jobwait({ vim.b[buf].terminal_job_id }, 0)[1] == -1, 'toggle stopped a shell')
end
key('<leader>t')
assert(#floats() == 2 and api.nvim_get_current_buf() == other_window, 'toggle lost the active window')
local other_cwd = root .. '/other'
vim.fn.mkdir(other_cwd, 'p')
vim.cmd.cd(other_cwd)
assert(#floats() == 0, 'workspace switch left part of the panel open')
key('<leader>t')
assert(api.nvim_get_current_buf() == other_window and vim.b[other_window].luanphan_terminal_reference_cwd == root,
  'floating windows lost their original shell across workspaces')

api.nvim_feedkeys(vim.keycode(':q<CR>'), 'xt', false)
assert(vim.wait(3000, function() return not api.nvim_buf_is_valid(other_window) and #floats() == 4 end),
  'last pane exit did not remove its window')
assert(api.nvim_get_current_buf() == lower and not window_bar():find('Window 2', 1, true), 'window exit lost the previous pane')
vim.fn.chansend(vim.b[left].terminal_job_id, 'exit\n')
assert(vim.wait(3000, function() return not api.nvim_buf_is_valid(left) and #floats() == 3 end),
  'pane exit did not reflow its window')
local file = vim.fn.getcwd() .. '/example.txt'
vim.fn.writefile({ 'first', 'second' }, file)
assert(require('luanphan.terminal_references').open(file, 2, 3), 'shell could not open the editor tile')
assert(#floats() == 4 and api.nvim_buf_get_name(0) == file, 'shell opened the file outside its panel')
key('<leader>o')
assert(#floats() == 0 and api.nvim_buf_get_name(0) == file, 'shell editor tile did not open in the main editor')
]=], "\n", { plain = true }))
  local output = vim.fn.systemlist(child_nvim_luafile_command(root, script))
  assert_true(vim.v.shell_error == 0, table.concat(output, "\n"))
end

return {
  test_agent_view_container = test_agent_view_container,
  test_tiled_agent_workspace_picker = test_tiled_agent_workspace_picker,
  test_floating_terminal_windows = test_floating_terminal_windows,
}
