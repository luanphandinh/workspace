-- Headless Neovim smoke tests. Test bodies live in tests/nvim/<area>.lua.
-- Run one test or a group of tests with ONLY="<part of the test name>".
local dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/nvim/"
local H = dofile(dir .. "helpers.lua")
local uv = H.uv
local cleanup_agent_servers = H.cleanup_agent_servers
local temp_root = H.temp_root
local require_command = H.require_command
local make_fixture = H.make_fixture
local close_agent_terminals = H.close_agent_terminals
local T = {}
for _, area in ipairs({ "editor", "search", "agents", "view_container", "terminal", "lsp", "git" }) do
  for name, fn in pairs(assert(loadfile(dir .. area .. ".lua"))(H)) do T[name] = fn end
end

local tests = {}

local function test(name, fn)
  if vim.env.ONLY and vim.env.ONLY ~= "" and not name:find(vim.env.ONLY, 1, true) then return end
  tests[#tests + 1] = { name = name, fn = fn }
end

local search_and_navigation_tests = {
  flow = T.test_flow_line_navigation,
  lsp_search_priority = T.test_lsp_pickers_use_search_priority,
  live_grep_highlights = T.test_live_grep_highlights_content_only,
  live_grep_cache = T.test_live_grep_caches_only_completed_searches,
  live_grep_debounce = T.test_live_grep_debounces_real_picker,
  search_rules = T.test_search_rules,
  search_rules_disk = T.test_search_rules_filter_disk_searches,
  search_settings_editor = T.test_search_priority_editor_closes_on_focus_loss,
}

local agent_tests = {
  cli_commands = T.test_agent_cli_commands_available,
  sidebar_restore = T.test_agent_sidebar_restore,
  default_setting = T.test_default_agent_setting,
  keys = T.test_agent_keys_invoke_cli_commands,
  lifecycle = T.test_agent_terminal_lifecycle,
  panel_shells = T.test_panel_shell_sessions,
  reference_links = T.test_terminal_reference_links,
  reference_view = T.test_agent_terminal_reference_restores_view,
  send_selection = T.test_leader_a_sends_visual_selection_to_active_agent,
  terminal_shortcuts = T.test_terminal_normal_mode_shows_shortcuts,
  tiled_workspace_picker = T.test_tiled_agent_workspace_picker,
  view_container = T.test_agent_view_container,
  floating_terminal = T.test_floating_terminal_windows,
  tmux_terminal = T.test_tmux_floating_terminal,
  tmux_resize = T.test_tmux_resize_rebuilds_inline_output,
  tmux_split_sequence = T.test_tmux_paint_keeps_split_escape_sequence,
  tmux_split_window = T.test_tmux_split_window_keeps_cursor,
  tmux_steady_output = T.test_tmux_repaint_recovers_under_output,
  tmux_scroll_region = T.test_tmux_frame_restores_scroll_region,
  tmux_pending_wrap = T.test_tmux_frame_keeps_pending_wrap,
  record_dump = T.test_terminal_record_dump,
  record_limits = T.test_terminal_record_limits,
  claude_title_status = T.test_claude_title_reports_status,
}

local lsp_lifecycle_tests = {
  restart_current = T.test_lsp_restart_reattaches_current_client_only,
  switch_with_keymaps = T.test_workspace_keymaps_restart_lsp_for_selected_directory,
  typescript_compatibility = T.test_typescript_server_matches_project_version,
}

local safe_cleanup_tests = {
  buffer_only = T.test_buffer_only_keeps_current_and_special_buffers,
  tree_width = T.test_nvim_tree_keeps_width_with_terminal,
  ctrl_f_navigation = T.test_ctrl_f_uses_native_navigation,
  editor_defaults = T.test_editor_runtime_defaults,
  editor_text_helpers = T.test_editor_text_helpers,
  file_tree_focus = T.test_file_tree_focuses_current_file,
  filetype_options = T.test_filetype_editor_options,
  git_remote_links = T.test_git_remote_file_links,
  json_temporary_folds = T.test_temporary_json_buffer_folds,
  only_keep_tree = T.test_only_keep_tree_closes_other_windows,
  repository_remove = T.test_remove_repository_from_workspace,
  run_actions = T.test_run_actions,
  telescope_keymaps = T.test_telescope_keymaps_dispatch_to_modules,
  telescope_runtime_defaults = T.test_telescope_runtime_defaults,
  toggle_gitignore = T.test_gitignore_toggle_updates_telescope,
  worktree_keymaps = T.test_worktree_keymaps_dispatch_to_pickers,
  worktree_notification = T.test_worktree_switch_notification_is_compact,
}

local setup_ok, setup_err = xpcall(function()
  require_command("git", { "git", "--version" })
  require_command("go", { "go", "version" })
  require_command("gopls", { "gopls", "version" })
  require_command("cargo", { "cargo", "--version" })
  require_command("rustc", { "rustc", "--version" })
  require_command("rust-analyzer", { "rust-analyzer", "--version" })
  require_command("tsc", { "tsc", "--version" })
  require_command("typescript-language-server", { "typescript-language-server", "--version" })
  require_command("jq", { "jq", "--version" })

  local repo, worktree = make_fixture()
  vim.env.GOWORK = "off"

  test("worktree plugin starts lazy", function()
    T.test_worktree_plugin_starts_lazy()
  end)

  test("editor defaults and global mappings resolve at runtime", function()
    safe_cleanup_tests.editor_defaults()
  end)

  test("editor text helpers load and edit text", function()
    safe_cleanup_tests.editor_text_helpers()
  end)

  test("Ctrl-F uses native page-forward navigation", function()
    safe_cleanup_tests.ctrl_f_navigation()
  end)

  test("worktree keymaps dispatch to their pickers", function()
    safe_cleanup_tests.worktree_keymaps()
  end)

  test("telescope keymaps dispatch to their modules", function()
    safe_cleanup_tests.telescope_keymaps()
  end)

  test("run actions use configured command and current file", function()
    safe_cleanup_tests.run_actions(repo)
  end)

  test("telescope runtime defaults filter and rank files", function()
    safe_cleanup_tests.telescope_runtime_defaults()
  end)

  test("gitignore toggle updates Telescope searches", function()
    safe_cleanup_tests.toggle_gitignore()
  end)

  test("nvim-tree hides dotfiles", function()
    T.test_nvim_tree_hides_dotfiles()
  end)

  test("nvim-tree keeps fixed width beside terminals", function()
    safe_cleanup_tests.tree_width(repo)
  end)

  test("external files use a temporary dependency tree", function()
    T.test_dependency_tree_keeps_workspace_tree(repo)
  end)

  test("file tree focuses the current file", function()
    safe_cleanup_tests.file_tree_focus(repo)
  end)

  test("file searches follow nvim-tree dotfile visibility", function()
    T.test_searches_follow_tree_dotfiles()
  end)

  test("search settings migrate and apply priority rules", function()
    search_and_navigation_tests.search_rules()
  end)

  test("custom ignores filter content and file searches", function()
    search_and_navigation_tests.search_rules_disk()
  end)

  test("search settings editor saves and closes on focus loss", function()
    search_and_navigation_tests.search_settings_editor()
  end)

  test("live grep highlights content only", function()
    search_and_navigation_tests.live_grep_highlights()
  end)

  test("live grep debounces its real picker", function()
    search_and_navigation_tests.live_grep_debounce(repo)
  end)

  test("live grep caches only completed searches", function()
    search_and_navigation_tests.live_grep_cache(repo)
  end)

  test("Flow stores editable line marks per workspace", function()
    search_and_navigation_tests.flow()
  end)

  test("toggle icons reflect state", function()
    T.test_toggle_icons_reflect_state()
  end)

  test("word wrap keymaps respect window scope", function()
    T.test_word_wrap_keymaps_respect_window_scope()
  end)

  test("Ctrl-J and Ctrl-K move between windows", function()
    T.test_ctrl_j_and_k_move_between_windows()
  end)

  test("buffer-only keeps current and special buffers", function()
    safe_cleanup_tests.buffer_only()
  end)

  test("only-keep-tree closes ordinary sibling windows", function()
    safe_cleanup_tests.only_keep_tree()
  end)

  test("markdown browser preview keymap", function()
    T.test_markdown_browser_preview_keymap()
  end)

  test("markdown preview toggle does not block", function()
    T.test_markdown_preview_toggle_does_not_block()
  end)

  test("csv preview keymap", function()
    T.test_csv_preview_keymap()
  end)

  test("no italic highlights", function()
    T.test_no_italic_highlights()
  end)

  test("git conflict decoration guard", function()
    T.test_git_conflict_decoration_guard()
  end)

  test("git remote links use current branch, file, and line", function()
    safe_cleanup_tests.git_remote_links()
  end)

  test("shell treesitter reads workspace scripts", function()
    T.test_shell_treesitter_reads_workspace_scripts()
  end)

  test("treesitter uses native runtime", function()
    T.test_treesitter_uses_native_runtime()
  end)

  test("treesitter uses nix parser runtime", function()
    T.test_treesitter_uses_nix_parser_runtime()
  end)

  test("treesitter required parsers available", function()
    T.test_treesitter_required_parsers_available()
  end)

  test("go treesitter configures default folds", function()
    T.test_go_treesitter_configures_default_folds()
  end)

  test("go treesitter preserves fold options on start", function()
    T.test_go_treesitter_preserves_fold_options_on_start()
  end)

  test("treesitter preserves existing fold options on enter", function()
    T.test_treesitter_preserves_existing_fold_options_on_enter()
  end)

  test("diff windows keep diff folds on enter", function()
    T.test_diff_windows_keep_diff_folds_on_enter()
  end)

  test("go runtime recovers when entering loaded buffer", function()
    T.test_go_runtime_recovers_when_entering_loaded_buffer(worktree)
  end)

  test("Go test runs from nested module", function()
    T.test_go_test_runs_from_nested_module()
  end)

  test("agent cli commands are executable", function()
    agent_tests.cli_commands()
  end)

  test("Neovide Cmd+V pastes text without probing images", function()
    T.test_neovide_command_v_pastes_text_without_image_probe()
  end)

  test("remote clipboard references preserve paths", function()
    T.test_remote_clipboard_references()
  end)

  test("Neovide detach clears stale option callbacks", function()
    T.test_neovide_detach_clears_option_callbacks()
  end)

  test("Neovide detach restores tmux clipboard across reconnects", function()
    T.test_neovide_detach_restores_tmux_clipboard()
  end)

  test("agent terminal paths become editor reference links", function()
    agent_tests.reference_links()
  end)

  test("agent terminal reference restores scrollback view", function()
    agent_tests.reference_view(repo)
  end)

  test("terminal normal mode shows leader shortcuts", function()
    agent_tests.terminal_shortcuts()
  end)

  test("agent keys invoke cli commands inside nvim", function()
    agent_tests.keys()
  end)

  test("leader a sends visual selection to active agent", function()
    agent_tests.send_selection()
  end)

  test("default agent setting controls empty workspace launch", function()
    agent_tests.default_setting()
  end)

  test("agent terminals share a tabbed view container", function()
    agent_tests.view_container(repo)
  end)
  test("plain shells tile with agents and reopen after a restart", function()
    agent_tests.panel_shells(repo)
  end)
  test("floating terminal nests tabs inside global windows", agent_tests.floating_terminal)
  test("tmux terminal restores native panes across Neovim restarts", agent_tests.tmux_terminal)
  test("tmux terminal rebuilds inline output after resize", agent_tests.tmux_resize)
  test("tmux terminal keeps escape sequences split across a repaint", agent_tests.tmux_split_sequence)
  test("tmux terminal stays in sync after showing in split windows", agent_tests.tmux_split_window)
  test("tmux terminal recovers from steady output and failed captures", agent_tests.tmux_steady_output)
  test("tmux terminal repaint keeps the scroll region", agent_tests.tmux_scroll_region)
  test("tmux terminal repaint keeps a pending wrap", agent_tests.tmux_pending_wrap)
  test("terminal record dumps output and repaints", agent_tests.record_dump)
  test("terminal record keeps its size limit", agent_tests.record_limits)
  test("claude title reports working and done", agent_tests.claude_title_status)
  test("agent window picker keeps the tiled panel together", function()
    agent_tests.tiled_workspace_picker(repo, worktree)
  end)
  test("Codex sidebar restores exact threads across editor restarts", function()
    agent_tests.sidebar_restore(repo, "codex")
  end)
  test("Cursor sidebar restores exact threads across editor restarts", function()
    agent_tests.sidebar_restore(repo, "cursor")
  end)

  test("deleted startup workspace falls back to master worktree", function()
    T.test_deleted_workspace_started_at_workspace_falls_back_to_master_worktree()
  end)

  test("deleted workspace lazy key falls back to master worktree", function()
    T.test_deleted_workspace_falls_back_to_master_worktree_from_lazy_key()
  end)

  test("adjacent project picker discovers sibling git repositories", function()
    T.test_adjacent_project_discovery(repo, worktree)
  end)

  test("navigation pickers order destinations by most recent visit", function()
    T.test_recent_navigation_ordering(repo, worktree)
  end)

  test("project picker discovers grouped workspace and root repositories", function()
    T.test_workspace_and_master_project_discovery()
  end)

  test("workspace picker switches to root and workspace destinations", function()
    T.test_workspace_project_discovery()
  end)

  test("workspace folder picker browses and switches directories", function()
    T.test_workspace_folder_browser()
  end)

  test("repository picker adds a one-level nested project to the current workspace", function()
    T.test_add_repository_to_workspace()
  end)

  test("repository picker removes one clean project from the current workspace", function()
    safe_cleanup_tests.repository_remove()
  end)

  test("saved pane discovery observes external edits and deletions", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local store = require("luanphan.view_container.pane_state")
    local function list() return store.list(dir, function() return true end) end
    local path = dir .. "/pane.json"
    vim.fn.writefile({ '{"label":"first"}' }, path)
    list().pane.label = "local edit"
    assert(list().pane.label == "first")
    vim.fn.writefile({ '{"label":"other"}' }, path .. ".tmp")
    assert(vim.uv.fs_rename(path .. ".tmp", path))
    assert(list().pane.label == "other")
    vim.fn.delete(path)
    assert(next(list()) == nil)
    vim.fn.delete(dir, "d")
  end)
  test("agent sessions discover running project terminals", function()
    T.test_active_agent_discovery(repo, worktree)
  end)

  test("agent session selection replaces the visible repository agent window", function()
    T.test_agent_switch_replaces_visible_repo_buffer(repo, worktree)
  end)

  test("filetype refresh uses each target buffer context", function()
    T.test_filetype_refire_uses_target_buffer()
  end)

  test("lsp definition and references", function()
    T.test_lsp_definition_and_references(repo)
  end)

  test("TypeScript projects use a compatible language server", function()
    lsp_lifecycle_tests.typescript_compatibility()
  end)

  test("lsp references and implementations use search priority", function()
    search_and_navigation_tests.lsp_search_priority(repo)
  end)

  test("lsp survives duplicate split close", function()
    T.test_lsp_survives_duplicate_split_close(repo)
  end)

  test("workspace root starts one gopls client per Go module", function()
    T.test_workspace_root_uses_one_gopls_per_module()
  end)

  test("lsp recursive incoming call graph", function()
    T.test_lsp_recursive_incoming_call_graph(repo)
  end)

  test("json buffers format before write", function()
    T.test_json_format_keymap()
  end)

  test("temporary JSON buffers fold", function()
    safe_cleanup_tests.json_temporary_folds()
  end)

  test("filetype editor options", function()
    safe_cleanup_tests.filetype_options()
  end)

  test("lsp restart reattaches only the current client", function()
    lsp_lifecycle_tests.restart_current(repo, worktree)
  end)

  test("workspace keymaps restart lsp for the selected directory", function()
    lsp_lifecycle_tests.switch_with_keymaps(repo, worktree)
  end)

  test("repository switches keep language servers", function()
    T.test_worktree_switch_keeps_lsp(repo, worktree)
  end)

  test("worktree switch hides files from the previous repository", function()
    T.test_worktree_switch_hides_foreign_file(repo, worktree)
  end)

  test("worktree switch notification stays compact for long paths", function()
    safe_cleanup_tests.worktree_notification(repo)
  end)

  test("worktree switch restores repository jump history", function()
    T.test_worktree_switch_restores_repository_jumplist(repo, worktree)
  end)

  test("shell terminal tabs and worktree hiding", function()
    T.test_worktree_switch_hides_toggleterm(repo, worktree)
  end)

  test("agent terminal quits or hides without stale buffers", function()
    agent_tests.lifecycle(repo)
  end)

  test("git diff previews", function()
    T.test_git_diff_previews(worktree)
  end)

  test("git diff repository bar from workspace root", function()
    T.test_git_diff_repository_bar_from_workspace_root()
  end)

  test("git diff repository bar spans three-way conflicts", function()
    T.test_git_diff_repository_bar_spans_conflict_layout()
  end)

  test("git diff separates commit and push for its selected repository", function()
    T.test_git_diff_separate_commit_and_push_from_workspace_root()
  end)

  test("git diff original file jump starts go runtime", function()
    T.test_git_diff_original_file_jump_starts_go_runtime(worktree)
  end)

  test("worktree switch hides agent terminal", function()
    T.test_worktree_switch_hides_agent_terminal(repo, worktree)
  end)

  test("git diff refresh preserves directory folds", function()
    T.test_git_diff_refresh_preserves_directory_folds(worktree)
  end)

end, debug.traceback)

if not setup_ok then
  if temp_root and uv.fs_stat(temp_root) then
    vim.fn.delete(temp_root, "rf")
  end
  cleanup_agent_servers()
  io.stderr:write("FAIL setup\n" .. tostring(setup_err) .. "\n")
  vim.cmd("cquit")
end

local failed = {}
for _, item in ipairs(tests) do
  local ok, err = xpcall(item.fn, debug.traceback)
  if ok then
    io.stdout:write("PASS " .. item.name .. "\n")
  else
    failed[#failed + 1] = "FAIL " .. item.name .. "\n" .. tostring(err)
  end
end

vim.cmd("stopinsert")
close_agent_terminals()
for _, buf in ipairs(vim.api.nvim_list_bufs()) do
  if vim.api.nvim_buf_is_valid(buf) then
    if vim.bo[buf].buftype == "terminal" then
      local job = vim.b[buf].terminal_job_id
      if type(job) == "number" and job > 0 then
        pcall(vim.fn.jobstop, job)
        pcall(vim.fn.jobwait, { job }, 1000)
      end
    end
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
end

if temp_root and uv.fs_stat(temp_root) then
  vim.fn.delete(temp_root, "rf")
end

cleanup_agent_servers()

if #failed > 0 then
  io.stderr:write(table.concat(failed, "\n\n") .. "\n")
  vim.cmd("cquit")
end

io.stdout:write("PASS nvim smoke tests\n")
