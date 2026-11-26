-- Git smoke tests, loaded by tests/nvim-smoke-test.lua with the shared helpers.
local H = ...
local terminal_io = H.terminal_io
local temp_root = H.temp_root
local assert_true = H.assert_true
local assert_nonrecursive_map = H.assert_nonrecursive_map
local realpath = H.realpath
local run = H.run
local write = H.write
local child_nvim_luafile_command = H.child_nvim_luafile_command
local wait_until = H.wait_until
local read_lines = H.read_lines
local make_project_scope_fixture = H.make_project_scope_fixture
local active_lsp_client = H.active_lsp_client
local assert_lsp_navigation = H.assert_lsp_navigation
local visible_toggleterm_window_count = H.visible_toggleterm_window_count
local close_toggleterm_terminals = H.close_toggleterm_terminals
local visible_agent_window_count = H.visible_agent_window_count
local assert_agent_float = H.assert_agent_float
local close_agent_terminals = H.close_agent_terminals
local invoke_map = H.invoke_map
local registered_agent_bufnrs = H.registered_agent_bufnrs
local feed_normal = H.feed_normal
local worktree_plugin_loaded = H.worktree_plugin_loaded
local worktree_test_api = H.worktree_test_api
local open_agent_test_shell = H.open_agent_test_shell

local cleanup_fixture_id = 0

local function make_workspace_cleanup_fixture()
  cleanup_fixture_id = cleanup_fixture_id + 1
  local repo_name = "example-cleanup-repo-" .. cleanup_fixture_id
  local repo = temp_root .. "/" .. repo_name
  local workspace = temp_root .. "/local_workspaces/example-workspace-" .. cleanup_fixture_id .. "/" .. repo_name
  vim.fn.mkdir(repo, "p")
  vim.fn.mkdir(vim.fn.fnamemodify(workspace, ":h"), "p")

  run({ "git", "init", "-b", "main" }, repo)
  run({ "git", "config", "user.name", "Example User" }, repo)
  run({ "git", "config", "user.email", "example@example.invalid" }, repo)
  write(repo .. "/README.md", { "source worktree" })
  run({ "git", "add", "." }, repo)
  run({ "git", "commit", "-m", "initial cleanup fixture" }, repo)
  run({ "git", "branch", "feature-cleanup" }, repo)
  run({ "git", "worktree", "add", workspace, "feature-cleanup" }, repo)

  return repo, workspace
end

local function has_visible_diffview()
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
      if name:match("^diffview://") then
        return true
      end
    end
  end
  return false
end

local function wait_for_diffview(path)
  wait_until(path and ("diffview repository " .. path) or "diffview", function()
    local ok, lib = pcall(require, "diffview.lib")
    local view = ok and lib.get_current_view() or nil
    if not view or not has_visible_diffview() or not view.ready or not view.initialized then
      return false
    end
    if path then
      local root = view.adapter and view.adapter.ctx and view.adapter.ctx.toplevel
      if not root or realpath(root) ~= realpath(path) then
        return false
      end
    end
    if not view.cur_entry or not view.cur_entry.opened or not view.cur_layout then
      return false
    end
    for _, win in ipairs(view.cur_layout.windows or {}) do
      if not win:is_file_open() then
        return false
      end
    end
    return true
  end, 10000)
end

local function close_diffview()
  for _ = 1, 20 do
    if not has_visible_diffview() then
      break
    end
    for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
        local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
        if name:match("^diffview://") then
          vim.api.nvim_set_current_tabpage(tab)
          break
        end
      end
    end
    pcall(vim.cmd, "DiffviewClose")
    vim.wait(50)
  end
  wait_until("diffview close", function()
    return not has_visible_diffview()
  end, 5000)
end

local function find_diffview_tab()
  local current = vim.api.nvim_get_current_tabpage()
  local tabs = { current }
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    if tab ~= current then
      tabs[#tabs + 1] = tab
    end
  end
  for _, tab in ipairs(tabs) do
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
      if name:match("^diffview://") then
        return tab
      end
    end
  end
  return nil
end

local function find_workspace_diff_bar()
  local current = vim.api.nvim_get_current_tabpage()
  local tabs = { current }
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    if tab ~= current then
      tabs[#tabs + 1] = tab
    end
  end
  for _, tab in ipairs(tabs) do
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.b[buf].luanphan_workspace_diff_bar then
        return tab, win, buf
      end
    end
  end
  return nil, nil, nil
end

local function wait_for_diffview_repository(path)
  wait_for_diffview(path)
end

local function focus_file_window_inside_diffview_tab(path)
  local tab = find_diffview_tab()
  assert_true(tab ~= nil, "Diffview tab was not found")
  vim.api.nvim_set_current_tabpage(tab)

  local fallback = nil
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    local name = vim.api.nvim_buf_get_name(buf)
    if not name:match("^diffview://") and vim.bo[buf].buftype == "" then
      vim.api.nvim_set_current_win(win)
      return
    end
    if not name:match("^diffview://") then
      fallback = fallback or win
    end
  end

  vim.api.nvim_set_current_win(fallback or vim.api.nvim_get_current_win())
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  assert_true(not vim.api.nvim_buf_get_name(0):match("^diffview://"), "focused buffer should be a normal file")
  assert_true(has_visible_diffview(), "Diffview should remain visible beside the focused file")
end

local function test_worktree_switch_keeps_lsp(repo, worktree)
  worktree_test_api().switch_to(worktree)
  local expected = realpath(worktree)
  wait_until("worktree cwd", function()
    return realpath(vim.fn.getcwd()) == expected
  end, 10000)
  assert_lsp_navigation(worktree .. "/main.go")

  local rust_repo = temp_root .. "/example-rust-repo"
  vim.fn.mkdir(rust_repo .. "/src", "p")
  run({ "git", "init", "-b", "main" }, rust_repo)
  write(rust_repo .. "/Cargo.toml", {
    "[package]",
    'name = "example-rust-repo"',
    'version = "0.1.0"',
    'edition = "2024"',
  })
  write(rust_repo .. "/src/lib.rs", {
    "pub fn example_value() -> usize {",
    "    1",
    "}",
  })

  local api = worktree_test_api()
  api.switch_to(rust_repo, "repository")
  vim.cmd("edit " .. vim.fn.fnameescape(rust_repo .. "/src/lib.rs"))
  local buf = vim.api.nvim_get_current_buf()
  wait_until("rust_analyzer after repository switch", function()
    local client = active_lsp_client(buf, "rust_analyzer")
    return client and client.initialized
  end, 30000)

  local client = active_lsp_client(buf, "rust_analyzer")
  assert_true(realpath(client.config.root_dir) == realpath(rust_repo), "rust_analyzer used the wrong repository root")

  api.switch_to(repo, "repository")
end

local function test_worktree_switch_hides_foreign_file(repo, worktree)
  local api = worktree_test_api()
  local recent_paths = require("luanphan.recent_paths")
  local function listed_unnamed_buffers()
    local count = 0
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf)
        and vim.bo[buf].buflisted
        and vim.bo[buf].buftype == ""
        and vim.api.nvim_buf_get_name(buf) == ""
      then
        count = count + 1
      end
    end
    return count
  end

  vim.fn.delete(vim.g.luanphan_recent_paths_file)
  local clean_path = repo .. "/switch-clean.go"
  local modified_path = repo .. "/switch-modified.go"
  write(clean_path, { "package main", "", "var switchClean = true" })
  write(modified_path, { "package main", "", "var switchModified = true" })

  vim.cmd("cd " .. vim.fn.fnameescape(repo))
  vim.cmd("edit " .. vim.fn.fnameescape(modified_path))
  local modified_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(modified_buf, -1, -1, false, { "var pendingChange = true" })
  vim.cmd("hide edit " .. vim.fn.fnameescape(clean_path))
  local clean_buf = vim.api.nvim_get_current_buf()

  local store = vim.g[api.store_key] or {}
  store[worktree] = nil
  vim.g[api.store_key] = store

  local foreign_filetype_events = 0
  local group = vim.api.nvim_create_augroup("SmokeWorktreeForeignFile", { clear = true })
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    callback = function(args)
      if args.buf == modified_buf then
        foreign_filetype_events = foreign_filetype_events + 1
      end
    end,
  })

  local unnamed_before = listed_unnamed_buffers()
  api.switch_to(worktree, "worktree")
  assert_true(realpath(vim.fn.getcwd()) == realpath(worktree), "worktree switch did not change cwd")
  assert_true(
    listed_unnamed_buffers() == unnamed_before,
    "worktree switch leaked a listed unnamed placeholder buffer"
  )
  local targets = recent_paths.switch_targets({
    { path = repo },
    { path = worktree },
  }, function(item)
    return item.path
  end, worktree)
  assert_true(
    #targets == 2
      and realpath(targets[1].path) == realpath(repo)
      and realpath(targets[2].path) == realpath(worktree),
    "worktree switch did not preserve the previous destination"
  )
  vim.fn.delete(vim.g.luanphan_recent_paths_file)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local visible = vim.api.nvim_win_get_buf(win)
    assert_true(visible ~= clean_buf, "previous repository file remained visible after switch")
    assert_true(visible ~= modified_buf, "modified previous repository file remained visible after switch")
  end
  assert_true(not vim.api.nvim_buf_is_valid(clean_buf), "unmodified foreign buffer was not deleted")
  assert_true(vim.api.nvim_buf_is_valid(modified_buf), "modified foreign buffer was discarded")
  assert_true(vim.bo[modified_buf].modified, "modified foreign buffer lost its unsaved state")
  assert_true(foreign_filetype_events == 0, "foreign buffer restarted its filetype after switch")

  api.snapshot(worktree)
  local entry = (vim.g[api.store_key] or {})[worktree] or {}
  for _, path in ipairs(entry.files or {}) do
    assert_true(realpath(path) ~= realpath(modified_path), "foreign buffer leaked into repository snapshot")
  end

  vim.api.nvim_del_augroup_by_id(group)
  vim.bo[modified_buf].modified = false
  vim.api.nvim_buf_delete(modified_buf, { force = true })
end

local function test_worktree_switch_notification_is_compact(repo)
  local api = worktree_test_api()
  local target = temp_root
    .. "/a-very-long-parent-directory-used-to-exercise-workspace-switch-messages"
    .. "/example-workspace"
  local active = target
    .. "/a/deeply/nested/directory/with/a/long/path/to/the/previously-active-file.txt"
  vim.fn.mkdir(vim.fn.fnamemodify(active, ":h"), "p")
  write(active, { "example" })

  vim.cmd("cd " .. vim.fn.fnameescape(target))
  vim.cmd("edit " .. vim.fn.fnameescape(active))
  api.switch_to(repo, "folder")

  local original_notify = vim.notify
  local messages = {}
  vim.notify = function(message, level)
    messages[#messages + 1] = { message = message, level = level }
  end
  local ok, err = xpcall(function()
    api.switch_to(target, "folder")
  end, debug.traceback)
  vim.notify = original_notify
  assert_true(ok, tostring(err))

  local notification = messages[#messages]
  assert_true(notification ~= nil, "workspace switch did not notify")
  assert_true(
    notification.message == "Switched to folder: example-workspace (restored 1 buffer)",
    "workspace switch notification was not compact: " .. notification.message
  )
  assert_true(
    vim.fn.strdisplaywidth(notification.message) < vim.o.columns,
    "workspace switch notification exceeds the available command line"
  )
  assert_true(realpath(vim.api.nvim_buf_get_name(0)) == realpath(active), "workspace switch did not restore active file")

  api.switch_to(repo, "repository")
end

local function test_worktree_switch_restores_repository_jumplist(repo, worktree)
  local api = worktree_test_api()
  close_agent_terminals()

  local function make_jump_files(root, prefix)
    local paths = {}
    for index, suffix in ipairs({ "first", "second", "current" }) do
      local path = root .. "/" .. prefix .. "-" .. suffix .. ".go"
      local symbol = (prefix .. "_" .. suffix):gsub("[^%w_]", "_")
      write(path, {
        "package main",
        "",
        "// " .. suffix .. " jump target",
        "var " .. symbol .. " = 1",
      })
      paths[index] = path
    end
    return paths
  end

  local function build_jumplist(paths)
    vim.cmd("clearjumps")
    vim.cmd("edit " .. vim.fn.fnameescape(paths[1]))
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.cmd("edit " .. vim.fn.fnameescape(paths[2]))
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    vim.cmd("edit " .. vim.fn.fnameescape(paths[3]))
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
  end

  local function jump_back(expected_path, expected_line)
    vim.api.nvim_feedkeys(vim.keycode("<C-o>"), "nx", false)
    assert_true(realpath(vim.api.nvim_buf_get_name(0)) == realpath(expected_path), "jump history restored wrong file")
    assert_true(vim.api.nvim_win_get_cursor(0)[1] == expected_line, "jump history restored wrong line")
  end

  local repo_paths = make_jump_files(repo, "repo-jump")
  local worktree_paths = make_jump_files(worktree, "worktree-jump")

  vim.cmd("cd " .. vim.fn.fnameescape(repo))
  build_jumplist(repo_paths)
  api.switch_to(worktree, "worktree")
  build_jumplist(worktree_paths)

  local replay_filetypes = {}
  local group = vim.api.nvim_create_augroup("SmokeJumplistLspIsolation", { clear = true })
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "go",
    callback = function(args)
      replay_filetypes[realpath(vim.api.nvim_buf_get_name(args.buf))] = true
    end,
  })
  api.switch_to(repo, "repository")
  assert_true(
    realpath(vim.api.nvim_buf_get_name(0)) == realpath(repo_paths[3]),
    "repository active file was not restored: " .. vim.api.nvim_buf_get_name(0)
  )
  assert_true(replay_filetypes[realpath(repo_paths[3])] == true, "active Go buffer did not run normal FileType startup")
  assert_true(replay_filetypes[realpath(repo_paths[1])] == nil, "jumplist replay triggered FileType for a hidden Go buffer")
  assert_true(replay_filetypes[realpath(repo_paths[2])] == nil, "jumplist replay triggered FileType for a hidden Go buffer")
  assert_true(vim.api.nvim_win_get_cursor(0)[1] == 4, "repository active cursor was not restored")
  jump_back(repo_paths[2], 3)
  wait_until("jumped Go buffer FileType startup", function()
    return replay_filetypes[realpath(repo_paths[2])] == true
  end, 3000)
  vim.api.nvim_del_augroup_by_id(group)

  api.switch_to(worktree, "worktree")
  assert_true(realpath(vim.api.nvim_buf_get_name(0)) == realpath(worktree_paths[3]), "worktree active file was not restored")
  jump_back(worktree_paths[2], 3)

  api.switch_to(repo, "repository")
  assert_true(realpath(vim.api.nvim_buf_get_name(0)) == realpath(repo_paths[2]), "mid-list active file was not restored")
  jump_back(repo_paths[1], 2)
end

local function test_agent_terminal_lifecycle(repo)
  vim.cmd("cd " .. vim.fn.fnameescape(repo))
  local agents = require("luanphan.agents.main")
  open_agent_test_shell(agents)

  wait_until("agent terminal open before toggleterm", function()
    return visible_agent_window_count() == 1
  end, 1000)
  local first_buf = vim.api.nvim_get_current_buf()
  local first_used = tonumber(vim.b[first_buf].luanphan_view_last_used) or 0
  assert_true(first_used > 0, "new agent terminal did not record its use order")
  local quit_ok, quit_err = pcall(vim.cmd, "quit")
  assert_true(quit_ok, "agent terminal :q failed: " .. tostring(quit_err))
  wait_until("agent terminal client exit", function()
    return not vim.api.nvim_buf_is_valid(first_buf)
  end, 3000)

  open_agent_test_shell(agents)
  wait_until("fresh agent terminal after quit", function()
    return visible_agent_window_count() == 1 and vim.api.nvim_get_current_buf() ~= first_buf
  end, 1000)
  local second_buf = vim.api.nvim_get_current_buf()
  local second_used = tonumber(vim.b[second_buf].luanphan_view_last_used) or 0
  assert_true(second_used > first_used, "replacement agent terminal did not advance its use order")
  for _, lhs in ipairs({ "<C-h>", "<C-j>", "<C-k>", "<C-l>" }) do
    assert_nonrecursive_map(lhs, "n", second_buf)
  end
  local terminal_maps = vim.api.nvim_buf_get_keymap(second_buf, "t")
  for _, lhs in ipairs({ "<C-h>", "<C-j>", "<C-k>" }) do
    local expected = vim.api.nvim_replace_termcodes(lhs, true, false, true)
    for _, map in ipairs(terminal_maps) do
      local actual = vim.api.nvim_replace_termcodes(map.lhs, true, false, true)
      local passthrough = map.noremap == 1 and map.rhs and vim.keycode(map.rhs) == expected
      assert_true(actual ~= expected or passthrough, "agent terminal insert mode captured " .. lhs)
    end
  end
  vim.cmd("stopinsert")
  agents.toggle()
  assert_true(visible_agent_window_count() == 0, "Agents toggle did not return to the editor")
  agents.toggle()
  wait_until("agent terminal reopened after toggle", function()
    return visible_agent_window_count() == 1
  end, 1000)
  assert_true(
    (tonumber(vim.b[second_buf].luanphan_view_last_used) or 0) > second_used,
    "refocused agent terminal did not advance its use order"
  )

  invoke_map("<leader>-t")
  wait_until("toggleterm open after agent terminal", function()
    return visible_toggleterm_window_count() > 0
  end, 3000)
  assert_true(visible_agent_window_count() == 0, "agent terminal remained visible after <leader>-t")

  open_agent_test_shell(agents, second_buf)
  wait_until("agent terminal open before ctrl-d", function()
    return visible_agent_window_count() == 1
  end, 1000)
  local exit_buf = vim.api.nvim_get_current_buf()
  terminal_io.send(exit_buf, "\004")
  wait_until("agent terminal ctrl-d exit", function()
    return not vim.api.nvim_buf_is_valid(exit_buf) and visible_agent_window_count() == 0
  end, 3000)

  close_agent_terminals()
  close_toggleterm_terminals()
end

local function test_worktree_switch_hides_agent_terminal(repo, worktree)
  vim.cmd("cd " .. vim.fn.fnameescape(repo))

  local agents = require("luanphan.agents.main")
  open_agent_test_shell(agents)

  wait_until("repo agent terminal open", function()
    return visible_agent_window_count() == 1
  end, 1000)
  assert_agent_float(vim.api.nvim_get_current_win(), "repository agent container")

  worktree_test_api().switch_to(worktree)
  local expected_worktree = realpath(worktree)
  wait_until("worktree cwd", function()
    return realpath(vim.fn.getcwd()) == expected_worktree
  end, 10000)
  assert_true(visible_agent_window_count() == 0, "agent terminal unexpectedly visible in new worktree")

  open_agent_test_shell(agents)
  wait_until("worktree agent terminal open", function()
    return visible_agent_window_count() == 1
  end, 1000)
  assert_agent_float(vim.api.nvim_get_current_win(), "workspace agent container")

  worktree_test_api().switch_to(repo)
  local expected_repo = realpath(repo)
  wait_until("repo cwd", function()
    return realpath(vim.fn.getcwd()) == expected_repo
  end, 10000)
  assert_true(visible_agent_window_count() == 0, "workspace switch did not hide the worktree agent terminal")

  open_agent_test_shell(agents)
  wait_until("repo agent terminal manually reopened", function()
    return visible_agent_window_count() == 1
  end, 1000)

  worktree_test_api().switch_to(worktree)
  assert_true(visible_agent_window_count() == 0, "workspace switch did not hide the repository agent terminal")

  open_agent_test_shell(agents)
  wait_until("worktree agent terminal manually reopened", function()
    return visible_agent_window_count() == 1
  end, 1000)

  local repo_buf = registered_agent_bufnrs("terminal", repo)[1]
  local worktree_buf = registered_agent_bufnrs("terminal", worktree)[1]
  assert_true(repo_buf and worktree_buf, "agent terminal buffers were not persisted per workspace")
  local function window_for_buffer(bufnr)
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(win) == bufnr then
        return win
      end
    end
    return nil
  end

  local worktree_win = window_for_buffer(worktree_buf)
  assert_true(worktree_win ~= nil, "worktree agent terminal was not visible before explicit focus")
  pcall(vim.api.nvim_win_close, worktree_win, false)

  local source_win = vim.api.nvim_get_current_win()
  local polluted_options = {
    cursorbind = true,
    diff = true,
    foldenable = true,
    foldmethod = "diff",
    list = true,
    scrollbind = true,
    spell = true,
    winhighlight = "Normal:ErrorMsg",
    wrap = false,
  }
  local saved_options = {}
  for name, value in pairs(polluted_options) do
    saved_options[name] = vim.api.nvim_get_option_value(name, { win = source_win })
    vim.api.nvim_set_option_value(name, value, { win = source_win, scope = "local" })
  end
  local function assert_clean_terminal_window(win)
    local buf = vim.api.nvim_win_get_buf(win)
    assert_true(vim.wo[win].diff == false, "agent terminal inherited diff mode")
    assert_true(vim.wo[win].scrollbind == false, "agent terminal inherited scroll binding")
    assert_true(vim.wo[win].cursorbind == false, "agent terminal inherited cursor binding")
    assert_true(vim.wo[win].foldmethod == "manual", "agent terminal inherited fold formatting")
    assert_true(vim.wo[win].list == false, "agent terminal inherited list formatting")
    assert_true(vim.wo[win].spell == false, "agent terminal inherited spell checking")
    assert_true(vim.wo[win].wrap == false, "agent terminal inherited wrapping")
    assert_true(not vim.wo[win].winhighlight:find("ErrorMsg", 1, true), "agent terminal inherited highlights")
    assert_true(vim.bo[buf].syntax == "", "agent terminal inherited syntax highlighting")
  end

  assert_true(agents.focus("terminal", repo_buf), "agent could not focus the selected repository terminal")
  local repo_win = window_for_buffer(repo_buf)
  assert_true(repo_win ~= nil, "agent focused the cwd terminal instead of the selected terminal")
  assert_clean_terminal_window(repo_win)
  assert_true(window_for_buffer(worktree_buf) == nil, "cwd terminal reopened while focusing another terminal")

  local target_buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_call(target_buf, function()
    vim.bo.filetype = "go"
  end)
  local callback_buf = nil
  local group = vim.api.nvim_create_augroup("SmokeLspRecoveryBufferContext", { clear = true })
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    buffer = target_buf,
    callback = function()
      callback_buf = vim.api.nvim_get_current_buf()
    end,
  })
  vim.api.nvim_exec_autocmds("BufEnter", {
    group = "LuanphanLspRecoverEnteredBuffers",
    buffer = target_buf,
    modeline = false,
  })
  wait_until("LSP recovery FileType refresh", function()
    return callback_buf ~= nil
  end, 3000)
  assert_true(callback_buf == target_buf, "LSP recovery FileType ran in the agent terminal")
  assert_true(vim.bo[repo_buf].syntax == "", "LSP recovery applied source syntax to the agent terminal")
  pcall(vim.api.nvim_buf_delete, target_buf, { force = true })
  pcall(vim.api.nvim_del_augroup_by_id, group)

  vim.bo[repo_buf].syntax = "go"
  assert_true(agents.focus("terminal", repo_buf), "agent could not repair a polluted terminal")
  assert_true(vim.bo[repo_buf].syntax == "", "agent focus did not clear inherited syntax highlighting")

  pcall(vim.api.nvim_win_close, repo_win, false)
  assert_true(agents.focus("terminal", worktree_buf), "agent could not restore the selected worktree terminal")
  assert_clean_terminal_window(window_for_buffer(worktree_buf))
  for name, value in pairs(saved_options) do
    vim.api.nvim_set_option_value(name, value, { win = source_win, scope = "local" })
  end
end

local function test_deleted_workspace_falls_back_to_master_worktree_from_lazy_key()
  local source, workspace = make_workspace_cleanup_fixture()
  vim.cmd("cd " .. vim.fn.fnameescape(workspace))

  run({ "git", "worktree", "remove", "--force", workspace }, source)
  feed_normal((vim.g.mapleader or "\\") .. "wf")

  local expected = realpath(source)
  wait_until("master worktree fallback", function()
    return realpath(vim.fn.getcwd()) == expected
  end, 10000)
  assert_true(worktree_plugin_loaded(), "worktree plugin did not lazy-load from <leader>wf")
end

local function test_deleted_workspace_started_at_workspace_falls_back_to_master_worktree()
  local source, workspace = make_workspace_cleanup_fixture()
  local script = temp_root .. "/deleted-workspace-start.lua"
  write(script, {
    "local uv = vim.uv or vim.loop",
    "local source = " .. string.format("%q", source),
    "local workspace = " .. string.format("%q", workspace),
    "local expected = " .. string.format("%q", realpath(source)),
    "local function fail(message) error(message, 0) end",
    "local function assert_true(value, message) if not value then fail(message) end end",
    "local function realpath(path) return uv.fs_realpath(path) or path end",
    "local function cwd() local ok, value = pcall(vim.fn.getcwd); return ok and value or '' end",
    "local plugin = require('lazy.core.config').plugins['luanphan-worktree']",
    "assert_true(plugin and plugin.lazy == true, 'worktree plugin is not lazy')",
    "assert_true(not (plugin._ and plugin._.loaded), 'worktree plugin loaded before key')",
    "local out = vim.fn.systemlist({ 'git', '-C', source, 'worktree', 'remove', '--force', workspace })",
    "assert_true(vim.v.shell_error == 0, table.concat(out, '\\n'))",
    "vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes((vim.g.mapleader or '\\\\') .. 'wf', true, false, true), 'xt', false)",
    "local ok = vim.wait(10000, function() return realpath(cwd()) == expected end, 50, false)",
    "assert_true(ok, 'cwd did not fall back to master: ' .. cwd())",
    "assert_true(plugin._ and plugin._.loaded, 'worktree plugin did not load after key')",
  })

  local cmd = child_nvim_luafile_command(workspace, script)
  local out = vim.fn.systemlist(cmd)
  assert_true(vim.v.shell_error == 0, table.concat(out, "\n"))
end

local function test_git_diff_previews(worktree)
  vim.cmd("cd " .. vim.fn.fnameescape(worktree))
  local status = table.concat(run({ "git", "status", "--short" }, worktree), "\n")
  assert_true(status:find("main.go", 1, true), "fixture has no current git change")

  invoke_map("<leader>gd")
  wait_for_diffview()
  assert_true(find_workspace_diff_bar() == nil, "single-repository diff unexpectedly created a repository bar")

  local floating = require("luanphan.view_container.floating")
  local old_settings, old_shell, old_env = vim.g.luanphan_global_settings_path, vim.o.shell, vim.env.ENV
  local settings = temp_root .. "/diffview-terminal-settings.toml"
  vim.g.luanphan_global_settings_path = settings
  vim.o.shell, vim.env.ENV = "/bin/sh", nil
  local shell
  local ok, err = xpcall(function()
    for _, style in ipairs({ "vertical", "horizontal" }) do
      write(settings, { "[floating_terminal]", 'backend = "shell"', 'window_bar_style = "' .. style .. '"' })
      floating.toggle()
      local pane = vim.api.nvim_get_current_win()
      shell = vim.api.nvim_get_current_buf()
      local bar = vim.w[pane].luanphan_window_bar
      assert_true(bar and vim.b[shell].luanphan_floating_terminal, "floating terminal did not open over Diffview")
      vim.api.nvim_feedkeys(vim.g.mapleader .. "e", "xt", false)
      assert_true(vim.api.nvim_get_current_win() == bar, "Diffview stole <leader>e from the " .. style .. " terminal")
      vim.api.nvim_feedkeys(vim.g.mapleader .. "e", "xt", false)
      assert_true(vim.api.nvim_get_current_win() == pane, "Diffview stole <leader>e from the " .. style .. " bar")
      floating.hide()
    end
  end, debug.traceback)
  floating.hide()
  if shell and vim.api.nvim_buf_is_valid(shell) then vim.api.nvim_buf_delete(shell, { force = true }) end
  vim.g.luanphan_global_settings_path, vim.o.shell, vim.env.ENV = old_settings, old_shell, old_env
  assert_true(ok, tostring(err))

  focus_file_window_inside_diffview_tab(worktree .. "/main.go")
  invoke_map("<leader>gd")
  wait_until("diffview closes from file window", function()
    return not has_visible_diffview()
  end, 5000)

  invoke_map("<leader>gD")
  wait_for_diffview()
  local branch_view = require("diffview.lib").get_current_view()
  local branch_tab = branch_view.tabpage
  branch_view.panel:focus()
  invoke_map("L")
  wait_until("Diffview commit log", function()
    return branch_view.commit_log_panel:is_focused()
  end, 5000)
  invoke_map("q")
  wait_until("Diffview commit log closes", function()
    return not branch_view.commit_log_panel:is_open()
  end, 5000)
  assert_true(vim.api.nvim_tabpage_is_valid(branch_tab), "closing the commit log closed the Diffview tab")
  assert_true(require("diffview.lib").get_current_view() == branch_view, "closing the commit log replaced the branch Diffview")
  close_diffview()

  local original_cmd = vim.cmd
  local history_commands = {}
  local history_ok, history_err = xpcall(function()
    vim.cmd = function(command)
      if type(command) == "string" and command:match("^DiffviewFileHistory") then
        history_commands[#history_commands + 1] = command
        return
      end
      return original_cmd(command)
    end
    invoke_map("<leader>gH")
    invoke_map("<leader>gA")
    invoke_map("<leader>gC")
  end, debug.traceback)
  vim.cmd = original_cmd
  assert_true(history_ok, history_err)

  assert_true(vim.deep_equal(history_commands, {
    "DiffviewFileHistory %",
    "DiffviewFileHistory",
    "DiffviewFileHistory",
  }), "file history mappings dispatched unexpected commands")
end

local function test_git_diff_repository_bar_from_workspace_root()
  local original_cwd = vim.fn.getcwd()
  local _, workspaces, station, workspace_name = make_project_scope_fixture()
  local workspace_root = station .. "/local_workspaces/" .. workspace_name
  local first_repo = workspaces["example-project-a"]
  local second_repo = workspaces["example-project-b-long"]
  local grouped_repo = workspace_root .. "/front-end/example-project-c"
  local clean_repo = workspace_root .. "/example-project-clean"
  local recent_paths = require("luanphan.recent_paths")
  local settings_path = vim.g.luanphan_global_settings_path
  local original_settings = vim.fn.filereadable(settings_path) == 1 and read_lines(settings_path) or nil
  vim.fn.delete(vim.g.luanphan_recent_paths_file)

  vim.fn.mkdir(clean_repo, "p")
  run({ "git", "init", "-b", "main" }, clean_repo)
  run({ "git", "config", "user.name", "Example User" }, clean_repo)
  run({ "git", "config", "user.email", "example@example.invalid" }, clean_repo)
  write(clean_repo .. "/README.md", { "clean repository" })
  run({ "git", "add", "." }, clean_repo)
  run({ "git", "commit", "-m", "clean fixture" }, clean_repo)
  recent_paths.touch(clean_repo)

  local function assert_recent_paths_unchanged()
    local entries = recent_paths.entries()
    assert_true(
      #entries == 1 and realpath(entries[1]) == realpath(clean_repo),
      "git diff preview changed recent folders"
    )
  end

  write(first_repo .. "/first-change.txt", {
    "first repository change",
    "cursor state should persist",
    "last line",
  })
  write(first_repo .. "/README.md", {
    "replacement line one",
    "replacement line two",
  })
  write(second_repo .. "/second-change.txt", { "second repository change" })
  vim.fn.mkdir(grouped_repo, "p")
  run({ "git", "init", "-b", "main" }, grouped_repo)
  run({ "git", "config", "user.name", "Example User" }, grouped_repo)
  run({ "git", "config", "user.email", "example@example.invalid" }, grouped_repo)
  write(grouped_repo .. "/README.md", { "grouped repository" })
  run({ "git", "add", "." }, grouped_repo)
  run({ "git", "commit", "-m", "grouped fixture" }, grouped_repo)
  write(grouped_repo .. "/grouped-change.txt", { "grouped repository change" })

  vim.cmd("cd " .. vim.fn.fnameescape(first_repo))
  local source_tab = vim.api.nvim_get_current_tabpage()
  invoke_map("<leader>gd")
  wait_for_diffview()
  wait_for_diffview_repository(first_repo)
  assert_true(find_workspace_diff_bar() == nil, "single-repository setup unexpectedly created a repository bar")
  vim.api.nvim_set_current_tabpage(source_tab)
  vim.cmd("cd " .. vim.fn.fnameescape(workspace_root))

  invoke_map("<leader>gd")
  wait_for_diffview()
  wait_for_diffview_repository(first_repo)
  local tab, bar_win, bar_buf = find_workspace_diff_bar()
  assert_true(tab ~= nil and bar_win ~= nil and bar_buf ~= nil, "multi-repository diff did not create a repository bar")
  local initial_view = require("diffview.lib").get_current_view()
  vim.api.nvim_set_current_win(bar_win)
  invoke_map("<leader>e")
  assert_true(initial_view.panel:is_focused(), "<leader>e from the repository bar did not focus the Diffview file panel")
  wait_until("first repository files", function()
    return initial_view.files and initial_view.files:len() > 0
  end, 10000)
  initial_view:set_file_by_path("first-change.txt", true, true)
  wait_until("first repository file selection", function()
    return initial_view.cur_entry and initial_view.cur_entry.path == "first-change.txt"
  end, 5000)
  local initial_main_win = initial_view.cur_layout:get_main_win().id
  local saved_line = math.min(2, vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(initial_main_win)))
  vim.api.nvim_win_set_cursor(initial_main_win, { saved_line, 0 })
  vim.api.nvim_set_current_win(initial_main_win)
  invoke_map("<leader>gf")
  assert_true(
    realpath(vim.api.nvim_buf_get_name(0)) == realpath(first_repo .. "/first-change.txt"),
    "original file did not open"
  )
  assert_true(vim.api.nvim_get_current_tabpage() == source_tab, "original file did not open in the code tab")
  assert_true(not vim.wo.diff, "original file retained Diffview diff mode")
  assert_true(not vim.wo.scrollbind, "original file retained Diffview scroll binding")
  assert_true(not vim.wo.cursorbind, "original file retained Diffview cursor binding")
  assert_true(vim.wo.number, "original file did not restore line numbers")
  assert_true(vim.wo.relativenumber, "original file did not restore relative line numbers")
  assert_true(vim.wo.cursorline, "original file did not restore the cursor line")
  assert_true(vim.wo.signcolumn == "yes", "original file did not restore the sign column")
  assert_true(not vim.wo.winfixheight, "original file retained the repository bar fixed height")
  assert_true(vim.wo.winhighlight == "", "repository bar highlight leaked into the original file")
  local original_systemlist = vim.fn.systemlist
  vim.fn.systemlist = function()
    error("focusing an existing Diffview must not run synchronous repository discovery", 0)
  end
  local focus_ok, focus_error = pcall(invoke_map, "<leader>gd")
  vim.fn.systemlist = original_systemlist
  assert_true(focus_ok, tostring(focus_error))
  assert_true(vim.api.nvim_get_current_tabpage() == initial_view.tabpage, "existing Diffview was not focused")
  local line = vim.api.nvim_buf_get_lines(bar_buf, 0, 1, false)[1] or ""
  assert_true(
    line:find("[example-project-a +5 -1]", 1, true) ~= nil,
    "initial diff repository omitted aggregate line changes"
  )
  assert_true(line:find("example-project-b-long", 1, true) ~= nil, "repository bar omitted a child repository")
  assert_true(
    line:find("front-end/example-project-c +1 -0", 1, true) ~= nil,
    "repository bar omitted a grouped repository"
  )
  assert_true(
    line:find("example-project-b-long +1 -0", 1, true) ~= nil,
    "repository bar omitted untracked line changes"
  )
  assert_true(
    line:find("example-project-clean +", 1, true) == nil,
    "clean repository displayed line changes"
  )
  local namespace = vim.api.nvim_get_namespaces()["luanphan-diff-repositories"]
  local stat_highlights = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bar_buf, namespace, 0, -1, { details = true })) do
    local group = mark[4].hl_group
    if group == "DiffviewFilePanelInsertions" or group == "DiffviewFilePanelDeletions" then
      stat_highlights[group] = true
    end
  end
  assert_true(stat_highlights.DiffviewFilePanelInsertions, "repository additions were not highlighted")
  assert_true(stat_highlights.DiffviewFilePanelDeletions, "repository deletions were not highlighted")
  local changed_position = line:find("example-project-b-long", 1, true)
  local clean_position = line:find("example-project-clean", 1, true)
  assert_true(clean_position and clean_position > changed_position, "clean repository was not moved behind changed repositories")

  local bar_row = vim.fn.win_screenpos(bar_win)[1]
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    assert_true(bar_row <= vim.fn.win_screenpos(win)[1], "repository bar is not the top Diffview window")
  end

  vim.api.nvim_set_current_win(initial_main_win)
  local mouse_map = vim.fn.maparg("<LeftMouse>", "n", false, true)
  assert_true(
    type(mouse_map) == "table" and type(mouse_map.callback) == "function",
    "diff content does not handle repository bar clicks"
  )
  local original_getmousepos = vim.fn.getmousepos
  vim.fn.getmousepos = function()
    return { winid = bar_win, column = changed_position }
  end
  local click_ok, click_result = pcall(mouse_map.callback)
  vim.fn.getmousepos = original_getmousepos
  assert_true(click_ok, "repository bar click failed: " .. tostring(click_result))
  assert_true(click_result == "<Ignore>", "repository bar click was not consumed")
  wait_for_diffview_repository(second_repo)
  local clicked_view = require("diffview.lib").get_current_view()
  assert_true(clicked_view ~= initial_view, "repository bar click did not switch Diffview")
  invoke_map("h")
  wait_for_diffview_repository(first_repo)

  wait_until("next diff repository mapping", function()
    vim.api.nvim_set_current_win(bar_win)
    local map = vim.fn.maparg("l", "n", false, true)
    return type(map) == "table" and type(map.callback) == "function"
  end, 3000)
  invoke_map("l")
  wait_for_diffview_repository(second_repo)
  local second_view = require("diffview.lib").get_current_view()
  assert_true(second_view == clicked_view, "repository browsing rebuilt the clicked Diffview")
  _, bar_win, bar_buf = find_workspace_diff_bar()
  assert_true(vim.api.nvim_get_current_buf() == bar_buf, "repository browsing did not focus the selected repository bar")
  assert_true(vim.api.nvim_get_current_win() == bar_win, "repository browsing moved focus into the diff")
  line = vim.api.nvim_buf_get_lines(bar_buf, 0, 1, false)[1] or ""
  assert_true(
    line:find("[example-project-b-long +1 -0]", 1, true) ~= nil,
    "visible diff repository is not highlighted"
  )

  invoke_map("h")
  wait_for_diffview_repository(first_repo)
  assert_true(require("diffview.lib").get_current_view() == initial_view, "returning to a repository rebuilt Diffview")
  _, bar_win, bar_buf = find_workspace_diff_bar()
  assert_true(vim.api.nvim_get_current_win() == bar_win, "returning to a repository moved focus into the diff")

  invoke_map("l")
  wait_for_diffview_repository(second_repo)
  assert_true(require("diffview.lib").get_current_view() == second_view, "revisiting the second repository rebuilt Diffview")
  invoke_map("h")
  wait_for_diffview_repository(first_repo)

  invoke_map("o")
  wait_for_diffview_repository(first_repo)
  local active_view = require("diffview.lib").get_current_view()
  local main_win = active_view.cur_layout:get_main_win().id
  wait_until("repository bar file tree focus", function()
    return active_view.panel.winid and vim.api.nvim_get_current_win() == active_view.panel.winid
  end, 3000)
  _, bar_win = find_workspace_diff_bar()
  assert_true(vim.api.nvim_get_current_win() == active_view.panel.winid, "o did not focus the selected repository file tree")
  assert_true(active_view.cur_entry.path == "first-change.txt", "repository switch lost the selected diff file")
  assert_true(vim.api.nvim_win_get_cursor(main_win)[1] == saved_line, "repository switch lost the diff cursor line")
  assert_true(realpath(vim.fn.getcwd()) == realpath(workspace_root), "repository switching changed the workspace cwd")
  vim.api.nvim_set_current_win(bar_win)
  invoke_map("l")
  wait_for_diffview_repository(second_repo)
  original_systemlist = vim.fn.systemlist
  vim.fn.systemlist = function()
    error("closing Diffview must not run synchronous repository discovery", 0)
  end
  local close_ok, close_error = pcall(invoke_map, "<leader>gd")
  vim.fn.systemlist = original_systemlist
  assert_true(close_ok, tostring(close_error))
  wait_until("workspace diff group closes", function()
    return not has_visible_diffview()
  end, 5000)
  assert_recent_paths_unchanged()

  invoke_map("<leader>gd")
  wait_for_diffview_repository(second_repo)
  _, bar_win, bar_buf = find_workspace_diff_bar()
  line = vim.api.nvim_buf_get_lines(bar_buf, 0, 1, false)[1] or ""
  assert_true(
    line:find("[example-project-b-long +1 -0]", 1, true) ~= nil,
    "reopened diff did not focus the last visited repository"
  )
  invoke_map("<leader>gd")
  wait_until("reopened workspace diff group closes", function()
    return not has_visible_diffview()
  end, 5000)
  assert_recent_paths_unchanged()

  write(second_repo .. "/branch-change.txt", { "committed branch change" })
  run({ "git", "add", "branch-change.txt" }, second_repo)
  run({ "git", "commit", "-m", "branch diff fixture" }, second_repo)
  recent_paths.touch(clean_repo)
  invoke_map("<leader>gD")
  wait_for_diffview()
  _, _, bar_buf = find_workspace_diff_bar()
  assert_true(bar_buf ~= nil, "branch diff omitted the multi-repository bar")
  line = vim.api.nvim_buf_get_lines(bar_buf, 0, 1, false)[1] or ""
  assert_true(
    line:find("[example-project-b-long +1 -0]", 1, true) ~= nil,
    "branch diff omitted committed line changes"
  )
  close_diffview()

  write(settings_path, {
    "[recent_folder]",
    "max_cache_entry = 5",
    "",
    "[diff-repo-ignore]",
    'repositories = ["example-project-c"]',
  })
  local function invoke_without_ignored_repo_git(lhs)
    local original_system = vim.fn.system
    local original_systemlist = vim.fn.systemlist
    local function rejects_ignored_repo(command)
      return type(command) == "table"
        and command[1] == "git"
        and command[2] == "-C"
        and realpath(command[3]) == realpath(grouped_repo)
    end
    vim.fn.system = function(command, ...)
      assert_true(not rejects_ignored_repo(command), "ignored repository ran a Git command")
      return original_system(command, ...)
    end
    vim.fn.systemlist = function(command, ...)
      assert_true(not rejects_ignored_repo(command), "ignored repository ran a Git command")
      return original_systemlist(command, ...)
    end
    local ok, err = xpcall(function()
      invoke_map(lhs)
    end, debug.traceback)
    vim.fn.system = original_system
    vim.fn.systemlist = original_systemlist
    assert_true(ok, err)
  end

  for _, lhs in ipairs({ "<leader>gd", "<leader>gD" }) do
    invoke_without_ignored_repo_git(lhs)
    wait_for_diffview()
    _, _, bar_buf = find_workspace_diff_bar()
    assert_true(bar_buf ~= nil, lhs .. " did not create the filtered repository bar")
    line = vim.api.nvim_buf_get_lines(bar_buf, 0, 1, false)[1] or ""
    assert_true(
      line:find("front-end/example-project-c", 1, true) == nil,
      lhs .. " included an ignored repository"
    )
    close_diffview()
  end
  if original_settings then
    write(settings_path, original_settings)
  else
    vim.fn.delete(settings_path)
  end
  assert_recent_paths_unchanged()
  vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
end

local function test_git_diff_repository_bar_spans_conflict_layout()
  local original_cwd = vim.fn.getcwd()
  local _, workspaces, station, workspace_name = make_project_scope_fixture()
  local workspace_root = station .. "/local_workspaces/" .. workspace_name
  local conflicted_repo = workspaces["example-project-a"]
  local changed_repo = workspaces["example-project-b-long"]
  local conflict_path = "conflict.txt"
  vim.fn.delete(vim.g.luanphan_recent_paths_file)

  write(conflicted_repo .. "/" .. conflict_path, { "base" })
  run({ "git", "add", conflict_path }, conflicted_repo)
  run({ "git", "commit", "-m", "conflict base" }, conflicted_repo)
  run({ "git", "switch", "-c", "incoming" }, conflicted_repo)
  write(conflicted_repo .. "/" .. conflict_path, { "incoming" })
  run({ "git", "add", conflict_path }, conflicted_repo)
  run({ "git", "commit", "-m", "incoming change" }, conflicted_repo)
  run({ "git", "switch", "feature/a" }, conflicted_repo)
  write(conflicted_repo .. "/" .. conflict_path, { "local" })
  run({ "git", "add", conflict_path }, conflicted_repo)
  run({ "git", "commit", "-m", "local change" }, conflicted_repo)
  vim.fn.system({ "git", "-C", conflicted_repo, "merge", "incoming" })
  assert_true(vim.v.shell_error ~= 0, "merge conflict fixture did not conflict")
  write(changed_repo .. "/changed.txt", { "changed" })

  local ok, err = xpcall(function()
    vim.cmd("cd " .. vim.fn.fnameescape(workspace_root))
    invoke_map("<leader>gd")
    wait_for_diffview_repository(conflicted_repo)
    local tab, bar_win = find_workspace_diff_bar()
    assert_true(tab ~= nil and bar_win ~= nil, "conflict diff omitted the repository bar")
    wait_until("three-way conflict windows", function()
      return #vim.api.nvim_tabpage_list_wins(tab) >= 5
    end, 5000)
    wait_until("three-way conflict buffers", function()
      local count = 0
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
        if win ~= bar_win and vim.wo[win].diff then
          count = count + 1
        end
      end
      return count >= 3
    end, 5000)
    local bar_spans_layout = vim.wait(5000, function()
      local position = vim.fn.win_screenpos(bar_win)
      return position[2] == 1 and vim.api.nvim_win_get_width(bar_win) == vim.o.columns
    end, 50, false)
    local final_position = vim.fn.win_screenpos(bar_win)
    assert_true(bar_spans_layout, string.format(
      "repository bar geometry row=%d col=%d width=%d columns=%d layout=%s",
      final_position[1],
      final_position[2],
      vim.api.nvim_win_get_width(bar_win),
      vim.o.columns,
      vim.inspect(vim.fn.winlayout())
    ))

    local position = vim.fn.win_screenpos(bar_win)
    assert_true(position[2] == 1, "repository bar shifted into a three-way merge column")
    assert_true(vim.api.nvim_win_get_width(bar_win) == vim.o.columns, "repository bar did not span the conflict layout")
  end, debug.traceback)

  if has_visible_diffview() then
    close_diffview()
  end
  vim.fn.system({ "git", "-C", conflicted_repo, "merge", "--abort" })
  if vim.fn.isdirectory(original_cwd) == 1 then
    vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
  end
  assert_true(ok, tostring(err))
end

local function test_git_diff_separate_commit_and_push_from_workspace_root()
  local original_cwd = vim.fn.getcwd()
  local original_input = vim.ui.input
  local _, workspaces, station, workspace_name = make_project_scope_fixture()
  local workspace_root = station .. "/local_workspaces/" .. workspace_name
  local selected_repo = workspaces["example-project-b-long"]
  local remote = station .. "/example-remote.git"
  local message = "commit from diffview"
  local staged_file = selected_repo .. "/committed-from-diff.txt"
  local unstaged_file = selected_repo .. "/left-unstaged.txt"
  vim.fn.delete(vim.g.luanphan_recent_paths_file)

  run({ "git", "init", "--bare", remote })
  run({ "git", "remote", "add", "origin", remote }, selected_repo)
  write(workspaces["example-project-a"] .. "/unrelated-change.txt", { "keep first repository changed" })
  write(staged_file, { "staged change" })
  write(unstaged_file, { "unstaged change" })
  run({ "git", "add", "committed-from-diff.txt" }, selected_repo)

  local ok, err = xpcall(function()
    vim.cmd("cd " .. vim.fn.fnameescape(workspace_root))
    invoke_map("<leader>gd")
    wait_for_diffview()
    wait_for_diffview_repository(workspaces["example-project-a"])
    wait_until("next diff repository mapping", function()
      local map = vim.fn.maparg("]r", "n", false, true)
      return type(map) == "table"
        and type(map.callback) == "function"
        and map.desc == "Next diff repository"
    end, 10000)
    invoke_map("]r")
    wait_for_diffview_repository(selected_repo)
    focus_file_window_inside_diffview_tab(staged_file)

    wait_until("diff commit keymap", function()
      local map = vim.fn.maparg("<leader>gc", "n", false, true)
      return type(map) == "table"
        and type(map.callback) == "function"
        and map.desc == "Commit staged changes"
    end, 3000)

    vim.ui.input = function(_, callback)
      callback(message)
    end
    invoke_map("<leader>gc")

    local branch = run({ "git", "rev-parse", "--abbrev-ref", "HEAD" }, selected_repo)[1]
    wait_until("diff commit", function()
      local subject = vim.fn.systemlist({ "git", "-C", selected_repo, "log", "-1", "--format=%s" })
      return vim.v.shell_error == 0 and subject[1] == message
    end, 10000)
    vim.fn.system({
      "git", "--git-dir", remote, "rev-parse", "--verify", "refs/heads/" .. branch,
    })
    assert_true(vim.v.shell_error ~= 0, "diff commit unexpectedly pushed before <leader>gp")
    local commit_callback_settled = false
    vim.defer_fn(function()
      commit_callback_settled = true
    end, 100)
    wait_until("diff commit callback", function()
      return commit_callback_settled
    end, 1000)

    local push_map = vim.fn.maparg("<leader>gp", "n", false, true)
    assert_true(
      type(push_map) == "table" and type(push_map.callback) == "function" and push_map.desc == "Push origin HEAD",
      "Diffview <leader>gp push mapping is missing"
    )
    invoke_map("<leader>gp")
    wait_until("diff commit push", function()
      vim.fn.system({
        "git", "--git-dir", remote, "rev-parse", "--verify", "refs/heads/" .. branch,
      })
      return vim.v.shell_error == 0
    end, 10000)

    local subject = run({ "git", "log", "-1", "--format=%s" }, selected_repo)[1]
    assert_true(subject == message, "diff commit used the wrong message or repository")
    local local_head = run({ "git", "rev-parse", "HEAD" }, selected_repo)[1]
    local remote_head = run({ "git", "--git-dir", remote, "rev-parse", "refs/heads/" .. branch })[1]
    assert_true(local_head == remote_head, "diff commit did not push the selected repository branch")
    local status = table.concat(run({ "git", "status", "--short" }, selected_repo), "\n")
    assert_true(status:find("left%-unstaged%.txt") ~= nil, "diff commit unexpectedly staged unrelated changes")
    assert_true(realpath(vim.fn.getcwd()) == realpath(workspace_root), "diff commit changed the workspace cwd")
  end, debug.traceback)

  vim.ui.input = original_input
  if has_visible_diffview() then
    close_diffview()
  end
  if vim.fn.isdirectory(original_cwd) == 1 then
    vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
  end
  assert_true(ok, tostring(err))
end

local function test_git_diff_refresh_preserves_directory_folds(worktree)
  local first_path = "nested/first.txt"
  local later_path = "nested/later.txt"
  write(worktree .. "/" .. first_path, { "first" })
  run({ "git", "add", first_path }, worktree)
  vim.cmd("cd " .. vim.fn.fnameescape(worktree))

  invoke_map("<leader>gd")
  wait_for_diffview()

  local lib = require("diffview.lib")
  local view = lib.get_current_view()
  local function has_file(path)
    for _, entry in view.files:iter() do
      if entry.path == path then
        return true
      end
    end
    return false
  end
  local function nested_directory()
    for _, section in ipairs({ "conflicting", "working", "staged" }) do
      local files = view.panel.components[section].files
      local found = nil
      files.comp:deep_some(function(comp)
        if comp.name == "directory" and comp.context.path == "nested" then
          found = comp.context
          return true
        end
        return false
      end)
      if found then
        return found
      end
    end
    return nil
  end

  wait_until("initial nested diff directory", function()
    return has_file(first_path) and nested_directory() ~= nil
  end, 10000)
  nested_directory().collapsed = true
  view.panel:render()
  view.panel:redraw()

  local normal_tab = lib.get_prev_non_view_tabpage()
  assert_true(normal_tab ~= nil, "normal tab not found beside Diffview")
  vim.api.nvim_set_current_tabpage(normal_tab)
  write(worktree .. "/" .. later_path, { "later" })
  run({ "git", "add", later_path }, worktree)
  vim.api.nvim_set_current_tabpage(view.tabpage)

  wait_until("Diffview refresh with new file", function()
    return has_file(later_path)
  end, 10000)
  assert_true(nested_directory().collapsed, "Diffview directory fold was lost after refresh")
  close_diffview()
end

local function test_git_diff_original_file_jump_starts_go_runtime(worktree)
  local script = temp_root .. "/diffview-original-runtime.lua"
  write(script, {
    "local uv = vim.uv or vim.loop",
    "local worktree = " .. string.format("%q", worktree),
    "local file = worktree .. '/main.go'",
    "local function fail(message) error(message, 0) end",
    "local function assert_true(value, message) if not value then fail(message) end end",
    "local function realpath(path) return uv.fs_realpath(path) or path end",
    "local function wait_until(label, predicate, timeout)",
    "  local ok = vim.wait(timeout or 10000, predicate, 50, false)",
    "  assert_true(ok, 'timeout waiting for ' .. label)",
    "end",
    "local function invoke_map(lhs)",
    "  local map = vim.fn.maparg(lhs, 'n', false, true)",
    "  assert_true(type(map) == 'table' and type(map.callback) == 'function', lhs .. ' missing callback')",
    "  map.callback()",
    "end",
    "local function has_visible_diffview()",
    "  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do",
    "    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do",
    "      local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))",
    "      if name:match('^diffview://') then return true end",
    "    end",
    "  end",
    "  return false",
    "end",
    "local function find_diffview_tab()",
    "  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do",
    "    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do",
    "      local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))",
    "      if name:match('^diffview://') then return tab end",
    "    end",
    "  end",
    "  return nil",
    "end",
    "local function diffview_file_count()",
    "  local ok, lib = pcall(require, 'diffview.lib')",
    "  local view = ok and lib.get_current_view() or nil",
    "  if view and view.files and type(view.files.len) == 'function' then",
    "    local len_ok, len = pcall(function() return view.files:len() end)",
    "    if len_ok then return len end",
    "  end",
    "  return 0",
    "end",
    "local function focus_diffview_jump_buffer()",
    "  wait_until('diffview original jump mapping', function()",
    "    local tab = find_diffview_tab()",
    "    if not tab then return false end",
    "    vim.api.nvim_set_current_tabpage(tab)",
    "    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do",
    "      if pcall(vim.api.nvim_set_current_win, win) then",
    "        local map = vim.fn.maparg('<leader>gf', 'n', false, true)",
    "        if type(map) == 'table' and type(map.callback) == 'function' then return true end",
    "      end",
    "    end",
    "    return false",
    "  end, 5000)",
    "end",
    "local function focus_diff_line(needle)",
    "  wait_until('diffview changed line', function()",
    "    local tab = find_diffview_tab()",
    "    if not tab then return false end",
    "    vim.api.nvim_set_current_tabpage(tab)",
    "    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do",
    "      local buf = vim.api.nvim_win_get_buf(win)",
    "      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)",
    "      for i, line in ipairs(lines) do",
    "        if line:find(needle, 1, true) then",
    "          vim.api.nvim_set_current_win(win)",
    "          local map = vim.fn.maparg('<leader>gf', 'n', false, true)",
    "          if not (type(map) == 'table' and type(map.callback) == 'function') then return false end",
    "          vim.api.nvim_win_set_cursor(win, { i, 0 })",
    "          return true",
    "        end",
    "      end",
    "    end",
    "    return false",
    "  end, 5000)",
    "end",
    "local function line_number_for_content(path, needle)",
    "  local lines = vim.fn.readfile(path)",
    "  for i, line in ipairs(lines) do",
    "    if line:find(needle, 1, true) then return i end",
    "  end",
    "  return nil",
    "end",
    "local function wait_for_lsp(buf)",
    "  wait_until('gopls after diff jump', function()",
    "    for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf })) do",
    "      if client.name == 'gopls' and not client:is_stopped() then return true end",
    "    end",
    "    return false",
    "  end, 30000)",
    "end",
    "local function wait_for_normal_editor_options()",
    "  wait_until('normal editor window options', function()",
    "    return not vim.wo.diff and vim.wo.number and vim.wo.relativenumber",
    "      and vim.wo.foldenable and vim.wo.winhighlight == ''",
    "  end, 5000)",
    "end",
    "vim.env.GOWORK = 'off'",
    "vim.cmd('cd ' .. vim.fn.fnameescape(worktree))",
    "vim.cmd('edit ' .. vim.fn.fnameescape(worktree .. '/go.mod'))",
    "vim.wo.colorcolumn = '73'",
    "vim.wo.cursorline = true",
    "local code_win = vim.api.nvim_get_current_win()",
    "require('nvim-tree.api').tree.open({ focus = true })",
    "assert_true(vim.bo.filetype == 'NvimTree', 'nvim-tree did not receive focus before diff jump test')",
    "invoke_map('<leader>gd')",
    "wait_until('diffview', has_visible_diffview, 10000)",
    "wait_until('diffview files', function() return diffview_file_count() > 0 end, 10000)",
    "focus_diffview_jump_buffer()",
    "local needle = 'uncommitted fixture change'",
    "focus_diff_line(needle)",
    "local expected_line = line_number_for_content(file, needle)",
    "assert_true(expected_line ~= nil, 'fixture changed line missing from original file')",
    "vim.bo.filetype = ''",
    "local foldminlines_changes = 0",
    "local fold_group = vim.api.nvim_create_augroup('DiffJumpFoldOptions', { clear = true })",
    "vim.api.nvim_create_autocmd('OptionSet', {",
    "  group = fold_group,",
    "  pattern = 'foldminlines',",
    "  callback = function() foldminlines_changes = foldminlines_changes + 1 end,",
    "})",
    "invoke_map('<leader>gf')",
    "vim.api.nvim_del_augroup_by_id(fold_group)",
    "assert_true(foldminlines_changes == 0, 'diff jump rewrote foldminlines')",
    "wait_until('original file buffer', function() return realpath(vim.api.nvim_buf_get_name(0)) == realpath(file) end, 5000)",
    "assert_true(vim.api.nvim_get_current_win() == code_win, 'diff jump did not use the existing code window')",
    "assert_true(has_visible_diffview(), 'diffview should remain open after original jump')",
    "assert_true(vim.api.nvim_win_get_cursor(0)[1] == expected_line, 'jumped cursor line should match focused diff line')",
    "local buf = vim.api.nvim_get_current_buf()",
    "assert_true(vim.bo[buf].filetype == 'go', 'jumped buffer filetype is ' .. vim.bo[buf].filetype)",
    "wait_until('go treesitter after diff jump', function() return vim.treesitter.highlighter.active[buf] ~= nil end, 5000)",
    "wait_for_lsp(buf)",
    "wait_for_normal_editor_options()",
    "assert_true(vim.wo.colorcolumn == '73', 'diff jump did not preserve the code window colorcolumn')",
    "assert_true(vim.wo.cursorline, 'diff jump did not preserve the code window cursorline')",
    "local working_diff_tab = find_diffview_tab()",
    "vim.api.nvim_buf_delete(buf, { force = true })",
    "vim.api.nvim_set_current_tabpage(working_diff_tab)",
    "wait_until('Diffview working tree after code buffer delete', function()",
    "  local view = require('diffview.lib').get_current_view()",
    "  local main = view and view.cur_layout and view.cur_layout:get_main_win() or nil",
    "  return main and main.id and vim.api.nvim_win_is_valid(main.id)",
    "    and realpath(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(main.id))) == realpath(file)",
    "end, 5000)",
    "focus_diff_line(needle)",
    "assert_true(has_visible_diffview(), 'deleting the code buffer broke Diffview')",
    "vim.cmd('DiffviewClose')",
    "wait_until('working diffview closes', function() return not has_visible_diffview() end, 5000)",
    "local tree_win",
    "for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do",
    "  if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == 'NvimTree' then tree_win = win end",
    "end",
    "assert_true(tree_win ~= nil, 'nvim-tree disappeared before tree-only diff test')",
    "if vim.api.nvim_win_is_valid(code_win) then vim.api.nvim_win_close(code_win, true) end",
    "vim.api.nvim_set_current_win(tree_win)",
    "assert_true(#vim.api.nvim_tabpage_list_wins(0) == 1, 'tree-only diff test still has an editor window')",
    "invoke_map('<leader>gd')",
    "wait_until('tree-only diffview', has_visible_diffview, 10000)",
    "wait_until('tree-only diffview files', function() return diffview_file_count() > 0 end, 10000)",
    "focus_diffview_jump_buffer()",
    "focus_diff_line(needle)",
    "invoke_map('<leader>gf')",
    "wait_until('tree-only original file buffer', function() return realpath(vim.api.nvim_buf_get_name(0)) == realpath(file) end, 5000)",
    "assert_true(vim.api.nvim_get_current_win() ~= tree_win, 'tree-only diff jump replaced nvim-tree')",
    "assert_true(vim.api.nvim_win_is_valid(tree_win), 'tree-only diff jump closed nvim-tree')",
    "wait_for_normal_editor_options()",
    "vim.api.nvim_set_current_tabpage(find_diffview_tab())",
    "vim.cmd('DiffviewClose')",
    "wait_until('tree-only diffview closes', function() return not has_visible_diffview() end, 5000)",
    "invoke_map('<leader>gD')",
    "wait_until('committed diffview', has_visible_diffview, 10000)",
    "wait_until('committed diffview files', function() return diffview_file_count() > 0 end, 10000)",
    "focus_diffview_jump_buffer()",
    "needle = 'func branchValue() string {'",
    "focus_diff_line(needle)",
    "expected_line = line_number_for_content(file, needle)",
    "assert_true(expected_line ~= nil, 'committed changed line missing from original file')",
    "invoke_map('<leader>gf')",
    "wait_until('committed original file buffer', function() return realpath(vim.api.nvim_buf_get_name(0)) == realpath(file) end, 5000)",
    "assert_true(has_visible_diffview(), 'committed diffview should remain open after original jump')",
    "local actual_line = vim.api.nvim_win_get_cursor(0)[1]",
    "assert_true(actual_line == expected_line, 'committed jump cursor line ' .. actual_line .. ' should match focused diff line ' .. expected_line)",
    "wait_for_normal_editor_options()",
  })

  local cmd = child_nvim_luafile_command(worktree, script)
  local out = vim.fn.systemlist(cmd)
  assert_true(vim.v.shell_error == 0, table.concat(out, "\n"))
end

return {
  test_worktree_switch_keeps_lsp = test_worktree_switch_keeps_lsp,
  test_worktree_switch_hides_foreign_file = test_worktree_switch_hides_foreign_file,
  test_worktree_switch_notification_is_compact = test_worktree_switch_notification_is_compact,
  test_worktree_switch_restores_repository_jumplist = test_worktree_switch_restores_repository_jumplist,
  test_agent_terminal_lifecycle = test_agent_terminal_lifecycle,
  test_worktree_switch_hides_agent_terminal = test_worktree_switch_hides_agent_terminal,
  test_deleted_workspace_falls_back_to_master_worktree_from_lazy_key = test_deleted_workspace_falls_back_to_master_worktree_from_lazy_key,
  test_deleted_workspace_started_at_workspace_falls_back_to_master_worktree = test_deleted_workspace_started_at_workspace_falls_back_to_master_worktree,
  test_git_diff_previews = test_git_diff_previews,
  test_git_diff_repository_bar_from_workspace_root = test_git_diff_repository_bar_from_workspace_root,
  test_git_diff_repository_bar_spans_conflict_layout = test_git_diff_repository_bar_spans_conflict_layout,
  test_git_diff_separate_commit_and_push_from_workspace_root = test_git_diff_separate_commit_and_push_from_workspace_root,
  test_git_diff_refresh_preserves_directory_folds = test_git_diff_refresh_preserves_directory_folds,
  test_git_diff_original_file_jump_starts_go_runtime = test_git_diff_original_file_jump_starts_go_runtime,
}
