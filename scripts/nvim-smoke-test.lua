local uv = vim.uv or vim.loop

local tests = {}
local temp_root
local cleanup_fixture_id = 0

local agent_cli_commands = {
  { command = "cursor-agent", lhs = "<leader>ac", plugin = "luanphan-cursor-agent", g_bufnr = "cursor_agent_bufnr" },
  { command = "claude", lhs = "<leader>xc", plugin = "luanphan-claude-agent", g_bufnr = "claude_agent_bufnr" },
  { command = "codex", lhs = "<leader>;", plugin = "luanphan-codex-agent", g_bufnr = "codex_agent_bufnr" },
}

vim.notify = function(message, level)
  if level and level >= vim.log.levels.WARN then
    io.stderr:write(tostring(message) .. "\n")
  end
end

local function fail(message)
  error(message, 0)
end

local function assert_true(value, message)
  if not value then
    fail(message)
  end
end

local function realpath(path)
  return uv.fs_realpath(path) or path
end

local function require_command(name, args)
  local out = vim.fn.systemlist(args)
  assert_true(vim.v.shell_error == 0, name .. " is required: " .. table.concat(out, "\n"))
end

local function ensure_gopls()
  if vim.fn.executable("gopls") == 1 then
    return
  end

  local ok_registry, registry = pcall(require, "mason-registry")
  assert_true(ok_registry, "gopls is required and mason-registry is not available")

  if not registry.has_package("gopls") then
    pcall(registry.refresh)
  end

  local ok_package, package = pcall(registry.get_package, "gopls")
  assert_true(ok_package, "gopls is required and Mason package gopls is not available")

  if not package:is_installed() and not package:is_installing() then
    local done = false
    local success = false
    local result = nil
    package:install({}, function(ok, install_result)
      success = ok
      result = install_result
      done = true
    end)
    wait_until("gopls install", function()
      return done
    end, 120000)
    assert_true(success, "failed to install gopls: " .. tostring(result))
  elseif package:is_installing() then
    wait_until("gopls install", function()
      return not package:is_installing()
    end, 120000)
  end

  assert_true(vim.fn.executable("gopls") == 1, "gopls is installed but not executable")
end

local function run(args, cwd)
  local cmd = args
  if cwd then
    cmd = vim.list_extend({ args[1], "-C", cwd }, vim.list_slice(args, 2))
  end
  local out = vim.fn.systemlist(cmd)
  if vim.v.shell_error ~= 0 then
    fail(table.concat(cmd, " ") .. "\n" .. table.concat(out, "\n"))
  end
  return out
end

local function write(path, lines)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile(lines, path)
end

local function child_nvim_luafile_command(cwd, script)
  local env = ""
  if vim.env.XDG_CONFIG_HOME and vim.env.XDG_CONFIG_HOME ~= "" then
    env = "XDG_CONFIG_HOME=" .. vim.fn.shellescape(vim.env.XDG_CONFIG_HOME) .. " "
  end

  local lua = table.concat({
    "local ok, err = xpcall(dofile, debug.traceback, " .. string.format("%q", script) .. ")",
    "if not ok then io.stderr:write(tostring(err) .. '\\n'); vim.cmd('cquit') end",
  }, "; ")

  return "cd " .. vim.fn.shellescape(cwd) .. " && " .. env .. "GOWORK=off nvim --headless " .. vim.fn.shellescape("+lua " .. lua) .. " +qa 2>&1"
end

local function write_executable(path, lines)
  write(path, lines)
  assert_true(vim.fn.setfperm(path, "rwxr-xr-x") == 1, "failed to chmod " .. path)
end

local function wait_until(label, predicate, timeout)
  local ok = vim.wait(timeout or 10000, predicate, 50, false)
  assert_true(ok, "timeout waiting for " .. label)
end

local function read_lines(path)
  return vim.fn.readfile(path)
end

local function read_log(path)
  if vim.fn.filereadable(path) ~= 1 then
    return {}
  end
  return read_lines(path)
end

local function log_has_prefix(path, prefix)
  for _, line in ipairs(read_log(path)) do
    if line:sub(1, #prefix) == prefix then
      return true
    end
  end
  return false
end

local function make_fixture()
  temp_root = vim.fn.tempname()
  vim.fn.delete(temp_root, "rf")
  vim.fn.mkdir(temp_root, "p")

  local repo = temp_root .. "/example-repo"
  local worktree = temp_root .. "/example-worktree"
  vim.fn.mkdir(repo, "p")

  run({ "git", "init", "-b", "main" }, repo)
  run({ "git", "config", "user.name", "Example User" }, repo)
  run({ "git", "config", "user.email", "example@example.invalid" }, repo)

  write(repo .. "/go.mod", {
    "module example.com/smoke",
    "",
    "go 1.21",
  })
  write(repo .. "/main.go", {
    "package main",
    "",
    "func targetValue() string {",
    '	return "base"',
    "}",
    "",
    "func useTarget() string {",
    "	return targetValue()",
    "}",
    "",
    "func main() {",
    "	_ = useTarget()",
    "}",
  })

  run({ "git", "add", "." }, repo)
  run({ "git", "commit", "-m", "initial fixture" }, repo)
  run({ "git", "branch", "feature" }, repo)
  run({ "git", "worktree", "add", worktree, "feature" }, repo)

  local branch_lines = read_lines(worktree .. "/main.go")
  table.insert(branch_lines, "")
  table.insert(branch_lines, "func branchValue() string {")
  table.insert(branch_lines, "	return targetValue()")
  table.insert(branch_lines, "}")
  write(worktree .. "/main.go", branch_lines)
  run({ "git", "add", "." }, worktree)
  run({ "git", "commit", "-m", "branch fixture" }, worktree)

  table.insert(branch_lines, "")
  table.insert(branch_lines, "// uncommitted fixture change")
  write(worktree .. "/main.go", branch_lines)

  return repo, worktree
end

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

local function find_position(buf, needle, line_match)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for i, line in ipairs(lines) do
    if not line_match or line:find(line_match, 1, true) then
      local start = line:find(needle, 1, true)
      if start then
        return { line = i - 1, character = start - 1 }
      end
    end
  end
  fail("could not find " .. needle)
end

local function wait_for_lsp(buf)
  wait_until("gopls", function()
    for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf })) do
      if client.name == "gopls" and not client:is_stopped() then
        return true
      end
    end
    return false
  end, 20000)
end

local function active_lsp_client(buf, name)
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf, name = name })) do
    if not client:is_stopped() then
      return client
    end
  end
  return nil
end

local function result_count(results)
  local count = 0
  for _, response in pairs(results or {}) do
    local result = response.result
    if type(result) == "table" then
      if result.uri or result.targetUri then
        count = count + 1
      else
        count = count + #result
      end
    end
  end
  return count
end

local function request(buf, method, position, timeout)
  local params = {
    textDocument = { uri = vim.uri_from_bufnr(buf) },
    position = position,
  }
  if method == "textDocument/references" then
    params.context = { includeDeclaration = true }
  end
  return vim.lsp.buf_request_sync(buf, method, params, timeout or 10000)
end

local function open_go_file(path)
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].filetype = "go"
  wait_for_lsp(buf)
  return buf
end

local function assert_lsp_navigation(path)
  local buf = open_go_file(path)
  local usage = find_position(buf, "targetValue", "return targetValue()")
  local definition = request(buf, "textDocument/definition", usage)
  assert_true(result_count(definition) >= 1, "definition request returned no locations")

  local def_pos = find_position(buf, "targetValue", "func targetValue")
  local refs = request(buf, "textDocument/references", def_pos)
  assert_true(result_count(refs) >= 2, "references request returned too few locations")
end

local function assert_lsp_code_action_keymaps()
  local change_definition = vim.fn.maparg("<leader>cd", "n", false, true)
  local code_action = vim.fn.maparg("<leader>ca", "n", false, true)

  assert_true(
    type(change_definition) == "table" and change_definition.desc == "Change Definition",
    "<leader>cd should be Change Definition"
  )
  assert_true(type(code_action) == "table" and code_action.desc == "Code Action", "<leader>ca should be Code Action")
  assert_true(vim.fn.maparg("<leader>rn", "n") == "", "<leader>rn should be removed")
end

local function test_json_format_keymap()
  local file = temp_root .. "/format-keymap.json"
  write(file, { '{"name":"example"}' })
  vim.cmd("edit " .. vim.fn.fnameescape(file))
  vim.bo.filetype = "json"

  wait_until("json format keymap", function()
    local map = vim.fn.maparg("<leader>kf", "n", false, true)
    return type(map) == "table" and map.desc == "Format"
  end, 3000)
end

local function test_markdown_browser_preview_keymap()
  local preview_map = vim.fn.maparg("<leader>fp", "n", false, true)
  local plugin = require("lazy.core.config").plugins["markdown-preview.nvim"]

  assert_true(type(plugin) == "table", "markdown-preview.nvim plugin should be registered")
  assert_true(type(preview_map) == "table" and preview_map.desc == "Preview Markdown in browser", "<leader>fp should toggle browser preview")
  assert_true(vim.fn.maparg("<leader>fP", "n") == "", "<leader>fP should be removed")
  assert_true(vim.g.mkdp_auto_start == 0, "browser Markdown preview should not auto-start")
  assert_true(vim.g.mkdp_auto_close == 1, "browser Markdown preview should auto-close")
  assert_true(vim.g.mkdp_refresh_slow == 0, "browser Markdown preview should auto-refresh content")
  assert_true(vim.g.mkdp_open_to_the_world == 0, "browser Markdown preview should stay local")
  assert_true(vim.g.mkdp_theme == "light", "browser Markdown preview should use light theme")
  assert_true(
    type(vim.g.mkdp_preview_options) == "table" and vim.g.mkdp_preview_options.disable_sync_scroll == 1,
    "browser Markdown preview should not sync-scroll"
  )
end

local function test_git_conflict_decoration_guard()
  local guard = require("luanphan.git_conflict_guard")
  assert_true(
    guard.is_out_of_range_error("Invalid 'line': out of range"),
    "git conflict guard should recognize stale decoration line errors"
  )

  local wrapped = guard.wrap(function()
    error("Invalid 'line': out of range", 0)
  end)
  local ok, result = pcall(wrapped, nil, nil, vim.api.nvim_get_current_buf())
  assert_true(ok and result == false, "git conflict guard should swallow stale decoration line errors")

  local rethrow = guard.wrap(function()
    error("different error", 0)
  end)
  local rethrow_ok = pcall(rethrow)
  assert_true(not rethrow_ok, "git conflict guard should rethrow unrelated errors")
end

local function test_shell_treesitter_guarded_injections()
  vim.cmd("edit scripts/mkws-smoke-test.sh")
  local buf = vim.api.nvim_get_current_buf()
  assert_true(vim.bo[buf].filetype == "sh", "mkws smoke script should be detected as sh")
  wait_until("shell treesitter active", function()
    return vim.treesitter.highlighter.active[buf] ~= nil
  end, 3000)
  assert_true(vim.g.luanphan_bash_injection_guard == 1, "bash injection guard should be installed")
  assert_true(vim.wo.foldmethod == "expr", "shell buffers should keep treesitter folds")
  assert_true(vim.wo.foldexpr == "v:lua.vim.treesitter.foldexpr()", "shell buffers should use treesitter foldexpr")
end

local function test_treesitter_uses_native_runtime()
  local plugin = require("lazy.core.config").plugins["nvim-treesitter"]
  assert_true(plugin == nil, "native treesitter runtime should not register nvim-treesitter")
  assert_true(package.loaded["nvim-treesitter"] == nil, "native runtime setup should not load nvim-treesitter")
  assert_true(package.loaded["nvim-treesitter.configs"] == nil, "native runtime setup should not load nvim-treesitter.configs")
end

local function test_treesitter_required_parsers_available()
  local expected = {
    go = "go",
    json = "json",
    yaml = "yaml",
    sh = "bash",
  }

  for ft, lang in pairs(expected) do
    assert_true(vim.treesitter.language.get_lang(ft) == lang, ft .. " should map to the " .. lang .. " parser")
    local ok = vim.treesitter.language.add(lang)
    assert_true(ok == true, lang .. " parser should be available")
  end
end

local function test_go_runtime_recovers_when_entering_loaded_buffer(worktree)
  local script = temp_root .. "/go-runtime-stale-buffer.lua"
  write(script, {
    "local function fail(message) error(message, 0) end",
    "local function assert_true(value, message) if not value then fail(message) end end",
    "local function wait_until(label, predicate, timeout)",
    "  local ok = vim.wait(timeout or 10000, predicate, 50, false)",
    "  assert_true(ok, 'timeout waiting for ' .. label)",
    "end",
    "local function wait_for_lsp(buf)",
    "  wait_until('gopls on recovered buffer', function()",
    "    for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf })) do",
    "      if client.name == 'gopls' and not client:is_stopped() then return true end",
    "    end",
    "    return false",
    "  end, 30000)",
    "end",
    "vim.env.GOWORK = 'off'",
    "vim.cmd('cd ' .. vim.fn.fnameescape(" .. string.format("%q", worktree) .. "))",
    "vim.cmd('noautocmd edit ' .. vim.fn.fnameescape(" .. string.format("%q", worktree .. "/main.go") .. "))",
    "local buf = vim.api.nvim_get_current_buf()",
    "vim.cmd('noautocmd setlocal filetype=go')",
    "assert_true(vim.treesitter.highlighter.active[buf] == nil, 'stale buffer should start without treesitter')",
    "vim.cmd('enew')",
    "vim.cmd('buffer ' .. buf)",
    "wait_until('go treesitter on recovered buffer', function() return vim.treesitter.highlighter.active[buf] ~= nil end, 5000)",
    "wait_for_lsp(buf)",
  })

  local cmd = child_nvim_luafile_command(worktree, script)
  local out = vim.fn.systemlist(cmd)
  assert_true(vim.v.shell_error == 0, table.concat(out, "\n"))
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

local function wait_for_diffview()
  wait_until("diffview", function()
    return has_visible_diffview()
  end, 10000)
end

local function close_diffview()
  pcall(vim.cmd, "DiffviewClose")
  wait_until("diffview close", function()
    return not has_visible_diffview()
  end, 5000)
end

local function find_diffview_tab()
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
      if name:match("^diffview://") then
        return tab
      end
    end
  end
  return nil
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

local function visible_toggleterm_window_count()
  local count = 0
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.b[buf].luanphan_toggleterm or vim.b[buf].toggle_number then
      count = count + 1
    end
  end
  return count
end

local function visible_agent_float_count()
  local count = 0
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local cfg = vim.api.nvim_win_get_config(win)
    local buf = vim.api.nvim_win_get_buf(win)
    if cfg.relative ~= "" and vim.bo[buf].buftype == "terminal" and vim.b[buf].luanphan_persist_term and not vim.b[buf].luanphan_toggleterm then
      count = count + 1
    end
  end
  return count
end

local function close_agent_terminals()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].buftype == "terminal" and vim.b[buf].luanphan_persist_term then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == "terminal" and vim.b[buf].luanphan_persist_term then
      local job = vim.b[buf].terminal_job_id
      if type(job) == "number" and job > 0 then
        pcall(vim.fn.jobstop, job)
      end
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end

  for _, item in ipairs(agent_cli_commands) do
    vim.g[item.g_bufnr] = nil
  end
end

local function invoke_map(lhs, mode)
  mode = mode or "n"
  local map = vim.fn.maparg(lhs, mode, false, true)
  assert_true(type(map) == "table" and type(map.callback) == "function", lhs .. " is not a callback mapping")
  map.callback()
end

local function agent_bufnr(global_name)
  local stored = vim.g[global_name]
  if type(stored) == "number" then
    return stored
  end
  if type(stored) ~= "table" then
    return nil
  end

  local cwd_bufnr = stored[vim.fn.getcwd()]
  if type(cwd_bufnr) == "number" then
    return cwd_bufnr
  end

  for _, bufnr in pairs(stored) do
    if type(bufnr) == "number" then
      return bufnr
    end
  end
  return nil
end

local function feed_normal(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "xt", false)
end

local function plugin_loaded(name)
  local plugin = require("lazy.core.config").plugins[name]
  return plugin and plugin._ and plugin._.loaded
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

local function worktree_plugin()
  return require("lazy.core.config").plugins["luanphan-worktree"]
end

local function worktree_plugin_loaded()
  return plugin_loaded("luanphan-worktree")
end

local function icon_char(value)
  assert_true(type(value) == "table" and type(value.icon) == "string", "toggle icon must return an icon table")
  return value.icon
end

local function assert_toggle_icon_changes(label, fn, off, on)
  off()
  local off_icon = icon_char(fn())
  on()
  local on_icon = icon_char(fn())
  assert_true(off_icon ~= on_icon, label .. " icon did not change")
  off()
end

local function assert_all_windows_wrap(expected)
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      assert_true(vim.wo[win].wrap == expected, "window " .. win .. " wrap should be " .. tostring(expected))
    end
  end
end

local function set_all_windows_wrap(value)
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      vim.wo[win].wrap = value
    end
  end
end

local function reset_window_layout()
  if #vim.api.nvim_list_tabpages() > 1 then
    pcall(vim.cmd, "tabonly!")
  end
  if #vim.api.nvim_tabpage_list_wins(0) > 1 then
    pcall(vim.cmd, "only!")
  end
end

local function test_word_wrap_keymap_applies_to_all_windows()
  local old_wrap = vim.wo.wrap

  local ok, err = xpcall(function()
    reset_window_layout()
    vim.cmd("enew")
    vim.cmd("vsplit")
    vim.cmd("split")
    vim.cmd("tabnew")
    vim.cmd("vsplit")

    set_all_windows_wrap(false)
    invoke_map("<leader>tW")
    assert_all_windows_wrap(true)

    vim.cmd("split")
    assert_true(vim.wo.wrap == true, "new split should inherit enabled wrap")

    invoke_map("<leader>tW")
    assert_all_windows_wrap(false)
  end, debug.traceback)

  reset_window_layout()
  vim.wo.wrap = old_wrap
  assert_true(ok, tostring(err))
end

local function test_toggle_icons_reflect_state()
  local icons = require("luanphan.toggle_icons")
  local old_case = vim.g.luanphan_live_grep_case_sensitive
  local old_regex = vim.g.luanphan_live_grep_regex
  local old_copilot = vim.g.copilot_enabled
  local had_copilot_cmd = vim.fn.exists(":Copilot") == 2
  local old_wrap = vim.wo.wrap

  if not had_copilot_cmd then
    vim.api.nvim_create_user_command("Copilot", function() end, { nargs = "*" })
  end

  local ok, err = xpcall(function()
    assert_toggle_icon_changes("live grep case sensitivity", icons.live_grep_case_sensitive, function()
      vim.g.luanphan_live_grep_case_sensitive = 0
    end, function()
      vim.g.luanphan_live_grep_case_sensitive = 1
    end)

    assert_toggle_icon_changes("live grep regex", icons.live_grep_regex, function()
      vim.g.luanphan_live_grep_regex = 0
    end, function()
      vim.g.luanphan_live_grep_regex = 1
    end)

    assert_toggle_icon_changes("copilot", icons.copilot, function()
      vim.g.copilot_enabled = 0
    end, function()
      vim.g.copilot_enabled = 1
    end)

    assert_toggle_icon_changes("file diff", icons.file_diff, function()
      pcall(vim.cmd, "windo diffoff")
    end, function()
      vim.cmd("diffthis")
    end)

    assert_toggle_icon_changes("terminal", icons.terminal, function()
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        local buf = vim.api.nvim_win_get_buf(win)
        vim.b[buf].luanphan_toggleterm = nil
        vim.b[buf].toggle_number = nil
      end
    end, function()
      vim.b[vim.api.nvim_get_current_buf()].luanphan_toggleterm = true
    end)

    assert_toggle_icon_changes("word wrap", icons.word_wrap, function()
      vim.wo.wrap = false
    end, function()
      vim.wo.wrap = true
    end)

    require("lazy").load({ plugins = { "gitsigns.nvim" } })
    local gitsigns = require("gitsigns")
    assert_toggle_icon_changes("line blame", icons.line_blame, function()
      gitsigns.toggle_current_line_blame(false)
    end, function()
      gitsigns.toggle_current_line_blame(true)
    end)
    assert_toggle_icon_changes("word diff", icons.word_diff, function()
      gitsigns.toggle_word_diff(false)
    end, function()
      gitsigns.toggle_word_diff(true)
    end)
  end, debug.traceback)

  vim.g.luanphan_live_grep_case_sensitive = old_case
  vim.g.luanphan_live_grep_regex = old_regex
  vim.g.copilot_enabled = old_copilot
  vim.wo.wrap = old_wrap
  pcall(vim.cmd, "windo diffoff")
  vim.b[vim.api.nvim_get_current_buf()].luanphan_toggleterm = nil
  if not had_copilot_cmd then
    pcall(vim.api.nvim_del_user_command, "Copilot")
  end
  local ok_gitsigns, gitsigns = pcall(require, "gitsigns")
  if ok_gitsigns then
    pcall(gitsigns.toggle_current_line_blame, false)
    pcall(gitsigns.toggle_word_diff, false)
  end

  assert_true(ok, tostring(err))
end

local function worktree_test_api()
  if not (_G._luanphan_wt_test and _G._luanphan_wt_test.switch_to) then
    require("lazy").load({ plugins = { "luanphan-worktree" } })
  end
  assert_true(_G._luanphan_wt_test and _G._luanphan_wt_test.switch_to, "worktree test hook is missing")
  return _G._luanphan_wt_test
end

local function test_worktree_plugin_starts_lazy()
  local plugin = worktree_plugin()
  assert_true(plugin and plugin.lazy == true, "worktree plugin is not lazy")
  assert_true(not worktree_plugin_loaded(), "worktree plugin loaded during startup")
end

local function test_agent_cli_commands_available()
  for _, item in ipairs(agent_cli_commands) do
    require_command(item.command, { item.command, "--version" })
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
  vim.env.PATH = shim_dir .. ":" .. old_path
  vim.env.NVIM_AGENT_SMOKE_LOG = log

  local ok, err = xpcall(function()
    for _, item in ipairs(agent_cli_commands) do
      invoke_lazy_map(item.lhs, item.plugin)
      wait_until(item.command .. " invocation", function()
        return log_has_prefix(log, item.command .. "|")
      end, 3000)
      assert_true(plugin_loaded(item.plugin), item.plugin .. " did not lazy-load")
      close_agent_terminals()
    end
  end, debug.traceback)

  vim.env.PATH = old_path
  vim.env.NVIM_AGENT_SMOKE_LOG = old_log
  close_agent_terminals()
  assert_true(ok, tostring(err))
end

local function test_codex_leader_semicolon_sends_visual_selection()
  local shim_dir = temp_root .. "/codex-send-shim"
  local invoke_log = temp_root .. "/codex-send-invocations.log"
  vim.fn.mkdir(shim_dir, "p")
  write(invoke_log, {})
  write_executable(shim_dir .. "/codex", {
    "#!/bin/sh",
    "printf '%s|%s|%s\\n' \"$(basename \"$0\")\" \"$PWD\" \"$*\" >> \"$NVIM_AGENT_SMOKE_LOG\"",
    "sleep 30",
  })

  local old_cwd = vim.fn.getcwd()
  local old_path = vim.env.PATH
  local old_log = vim.env.NVIM_AGENT_SMOKE_LOG
  vim.env.PATH = shim_dir .. ":" .. old_path
  vim.env.NVIM_AGENT_SMOKE_LOG = invoke_log

  local ok, err = xpcall(function()
    vim.cmd("cd " .. vim.fn.fnameescape(temp_root))
    local file = temp_root .. "/codex-send-buffer.txt"
    write(file, {
      "selected payload line",
      "unselected payload line",
    })
    vim.cmd("edit " .. vim.fn.fnameescape(file))

    local normal_map = vim.fn.maparg("<leader>;", "n", false, true)
    local visual_map = vim.fn.maparg("<leader>;", "x", false, true)
    local select_map = vim.fn.maparg("<leader>;", "s", false, true)
    assert_true(type(normal_map) == "table" and normal_map.desc == "Toggle Codex", "<leader>; normal should toggle Codex")
    assert_true(type(visual_map) == "table" and visual_map.desc == "Send to Codex", "<leader>; visual should send to Codex")
    assert_true(type(select_map) == "table" and select_map.desc == "Send to Codex", "<leader>; select should send to Codex")
    assert_true(vim.fn.maparg("<leader>cc", "n") == "", "<leader>cc should be removed")
    assert_true(vim.fn.maparg("<leader>cs", "x") == "", "<leader>cs should be removed")

    vim.cmd("normal! ggV")
    ensure_lazy_key_ready("<leader>;", "luanphan-codex-agent", "x")
    vim.cmd("normal! ggV")
    invoke_map("<leader>;", "x")
    wait_until("codex invocation", function()
      return log_has_prefix(invoke_log, "codex|")
    end, 3000)

    wait_until("codex selection marker", function()
      local bufnr = agent_bufnr("codex_agent_bufnr")
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
  pcall(vim.cmd, "cd " .. vim.fn.fnameescape(old_cwd))
  close_agent_terminals()
  assert_true(ok, tostring(err))
end

local function test_lsp_definition_and_references(repo)
  vim.cmd("cd " .. vim.fn.fnameescape(repo))
  assert_lsp_navigation(repo .. "/main.go")
  assert_lsp_code_action_keymaps()
end

local function test_lsp_restart_reattaches_all_buffers_for_current_server(repo)
  vim.cmd("cd " .. vim.fn.fnameescape(repo))
  write(repo .. "/extra.go", {
    "package main",
    "",
    "func extraValue() string {",
    "	return targetValue()",
    "}",
  })

  local main_buf = open_go_file(repo .. "/main.go")
  local extra_buf = open_go_file(repo .. "/extra.go")
  wait_for_lsp(main_buf)
  wait_for_lsp(extra_buf)

  local old_ids = {}
  for _, bufnr in ipairs({ main_buf, extra_buf }) do
    local client = active_lsp_client(bufnr, "gopls")
    assert_true(client ~= nil, "gopls was not attached before restart")
    old_ids[client.id] = true
  end

  local restart_map = vim.fn.maparg("<leader>rl", "n", false, true)
  assert_true(type(restart_map) == "table" and restart_map.desc == "LSP", "<leader>rl should be the combined LSP restart")
  assert_true(vim.fn.maparg("<leader>rb", "n") == "", "<leader>rb should be removed")
  assert_true(vim.fn.maparg("<leader>rg", "n") == "", "<leader>rg should be removed")
  invoke_map("<leader>rl")

  wait_until("gopls restart reattach", function()
    local main_client = active_lsp_client(main_buf, "gopls")
    local extra_client = active_lsp_client(extra_buf, "gopls")
    return main_client
      and extra_client
      and not old_ids[main_client.id]
      and not old_ids[extra_client.id]
  end, 20000)

  for old_id in pairs(old_ids) do
    local client = vim.lsp.get_client_by_id(old_id)
    assert_true(not client or client:is_stopped(), "old gopls client is still running after restart")
  end
end

local function test_worktree_switch_keeps_lsp(worktree)
  worktree_test_api().switch_to(worktree)
  local expected = realpath(worktree)
  wait_until("worktree cwd", function()
    return realpath(vim.fn.getcwd()) == expected
  end, 10000)
  assert_lsp_navigation(worktree .. "/main.go")
end

local function test_worktree_switch_hides_toggleterm(repo, worktree)
  vim.cmd("cd " .. vim.fn.fnameescape(repo))

  feed_normal((vim.g.mapleader or "\\") .. "tt")
  wait_until("toggleterm open", function()
    return visible_toggleterm_window_count() > 0
  end, 3000)

  worktree_test_api().switch_to(worktree)
  local expected = realpath(worktree)
  wait_until("worktree cwd", function()
    return realpath(vim.fn.getcwd()) == expected
  end, 10000)
  assert_true(visible_toggleterm_window_count() == 0, "toggleterm window remained visible after worktree switch")
end

local function test_toggleterm_hides_agent_terminal(repo)
  vim.cmd("cd " .. vim.fn.fnameescape(repo))

  local agent = require("luanphan.terminal_agent").create({
    g_bufnr = "toggleterm_hide_agent_bufnr",
    notify_prefix = "toggleterm_hide_agent",
    augroup_prefix = "ToggletermHideAgent",
    hint_open = "<smoke>",
    defaults = { cmd = "sh" },
  })
  agent.setup()
  agent.toggle()

  wait_until("agent terminal open before toggleterm", function()
    return visible_agent_float_count() == 1
  end, 1000)

  invoke_lazy_map("<leader>tt", "toggleterm.nvim")
  wait_until("toggleterm open after agent terminal", function()
    return visible_toggleterm_window_count() > 0
  end, 3000)
  assert_true(visible_agent_float_count() == 0, "agent terminal remained visible after <leader>tt")
  close_agent_terminals()
end

local function test_worktree_switch_restores_agent_terminal(repo, worktree)
  vim.cmd("cd " .. vim.fn.fnameescape(repo))

  local agent = require("luanphan.terminal_agent").create({
    g_bufnr = "smoke_agent_bufnr",
    notify_prefix = "smoke_agent",
    augroup_prefix = "SmokeAgent",
    hint_open = "<smoke>",
    defaults = { cmd = "sh" },
  })
  agent.setup()
  agent.toggle()

  wait_until("repo agent terminal open", function()
    return visible_agent_float_count() == 1
  end, 1000)

  worktree_test_api().switch_to(worktree)
  local expected_worktree = realpath(worktree)
  wait_until("worktree cwd", function()
    return realpath(vim.fn.getcwd()) == expected_worktree
  end, 10000)
  assert_true(visible_agent_float_count() == 0, "agent terminal unexpectedly visible in new worktree")

  agent.toggle()
  wait_until("worktree agent terminal open", function()
    return visible_agent_float_count() == 1
  end, 1000)

  worktree_test_api().switch_to(repo)
  local expected_repo = realpath(repo)
  wait_until("repo cwd", function()
    return realpath(vim.fn.getcwd()) == expected_repo
  end, 10000)
  wait_until("repo agent terminal restored", function()
    return visible_agent_float_count() == 1
  end, 1000)
end

local function test_deleted_workspace_falls_back_to_master_worktree_from_lazy_key()
  local source, workspace = make_workspace_cleanup_fixture()
  vim.cmd("cd " .. vim.fn.fnameescape(workspace))

  run({ "git", "worktree", "remove", "--force", workspace }, source)
  feed_normal((vim.g.mapleader or "\\") .. "gw")

  local expected = realpath(source)
  wait_until("master worktree fallback", function()
    return realpath(vim.fn.getcwd()) == expected
  end, 10000)
  assert_true(worktree_plugin_loaded(), "worktree plugin did not lazy-load from <leader>gw")
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
    "vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes((vim.g.mapleader or '\\\\') .. 'gw', true, false, true), 'xt', false)",
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
  focus_file_window_inside_diffview_tab(worktree .. "/main.go")
  invoke_map("<leader>gd")
  wait_until("diffview closes from file window", function()
    return not has_visible_diffview()
  end, 5000)

  invoke_map("<leader>gD")
  wait_for_diffview()
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
    "local function wait_for_lsp(buf)",
    "  wait_until('gopls after diff jump', function()",
    "    for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf })) do",
    "      if client.name == 'gopls' and not client:is_stopped() then return true end",
    "    end",
    "    return false",
    "  end, 30000)",
    "end",
    "vim.env.GOWORK = 'off'",
    "vim.cmd('cd ' .. vim.fn.fnameescape(worktree))",
    "invoke_map('<leader>gd')",
    "wait_until('diffview', has_visible_diffview, 10000)",
    "wait_until('diffview files', function() return diffview_file_count() > 0 end, 10000)",
    "focus_diffview_jump_buffer()",
    "invoke_map('<leader>gf')",
    "wait_until('diffview closes after original jump', function() return not has_visible_diffview() end, 5000)",
    "wait_until('original file buffer', function() return realpath(vim.api.nvim_buf_get_name(0)) == realpath(file) end, 5000)",
    "local buf = vim.api.nvim_get_current_buf()",
    "assert_true(vim.bo[buf].filetype == 'go', 'jumped buffer filetype is ' .. vim.bo[buf].filetype)",
    "wait_until('go treesitter after diff jump', function() return vim.treesitter.highlighter.active[buf] ~= nil end, 5000)",
    "wait_for_lsp(buf)",
  })

  local cmd = child_nvim_luafile_command(worktree, script)
  local out = vim.fn.systemlist(cmd)
  assert_true(vim.v.shell_error == 0, table.concat(out, "\n"))
end

local function test(name, fn)
  tests[#tests + 1] = { name = name, fn = fn }
end

local setup_ok, setup_err = xpcall(function()
  require_command("git", { "git", "--version" })
  require_command("go", { "go", "version" })
  ensure_gopls()

  local repo, worktree = make_fixture()
  vim.env.GOWORK = "off"

  test("worktree plugin starts lazy", function()
    test_worktree_plugin_starts_lazy()
  end)

  test("toggle icons reflect state", function()
    test_toggle_icons_reflect_state()
  end)

  test("word wrap keymap applies to all windows", function()
    test_word_wrap_keymap_applies_to_all_windows()
  end)

  test("markdown browser preview keymap", function()
    test_markdown_browser_preview_keymap()
  end)

  test("git conflict decoration guard", function()
    test_git_conflict_decoration_guard()
  end)

  test("shell treesitter guarded injections", function()
    test_shell_treesitter_guarded_injections()
  end)

  test("treesitter uses native runtime", function()
    test_treesitter_uses_native_runtime()
  end)

  test("treesitter required parsers available", function()
    test_treesitter_required_parsers_available()
  end)

  test("go runtime recovers when entering loaded buffer", function()
    test_go_runtime_recovers_when_entering_loaded_buffer(worktree)
  end)

  test("agent cli commands are executable", function()
    test_agent_cli_commands_available()
  end)

  test("agent keys invoke cli commands inside nvim", function()
    test_agent_keys_invoke_cli_commands()
  end)

  test("codex leader semicolon sends visual selection", function()
    test_codex_leader_semicolon_sends_visual_selection()
  end)

  test("deleted startup workspace falls back to master worktree", function()
    test_deleted_workspace_started_at_workspace_falls_back_to_master_worktree()
  end)

  test("deleted workspace lazy key falls back to master worktree", function()
    test_deleted_workspace_falls_back_to_master_worktree_from_lazy_key()
  end)

  test("lsp definition and references", function()
    test_lsp_definition_and_references(repo)
  end)

  test("json format keymap uses editor group", function()
    test_json_format_keymap()
  end)

  test("lsp restart reattaches all buffers for current server", function()
    test_lsp_restart_reattaches_all_buffers_for_current_server(repo)
  end)

  test("worktree switch keeps lsp", function()
    test_worktree_switch_keeps_lsp(worktree)
  end)

  test("worktree switch hides toggleterm", function()
    test_worktree_switch_hides_toggleterm(repo, worktree)
  end)

  test("toggleterm hides agent terminal", function()
    test_toggleterm_hides_agent_terminal(repo)
  end)

  test("git diff previews", function()
    test_git_diff_previews(worktree)
  end)

  test("git diff original file jump starts go runtime", function()
    test_git_diff_original_file_jump_starts_go_runtime(worktree)
  end)

  test("worktree switch restores agent terminal", function()
    test_worktree_switch_restores_agent_terminal(repo, worktree)
  end)

end, debug.traceback)

if not setup_ok then
  if temp_root and uv.fs_stat(temp_root) then
    vim.fn.delete(temp_root, "rf")
  end
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

if temp_root and uv.fs_stat(temp_root) then
  vim.fn.delete(temp_root, "rf")
end

if #failed > 0 then
  io.stderr:write(table.concat(failed, "\n\n") .. "\n")
  vim.cmd("cquit")
end

io.stdout:write("PASS nvim smoke tests\n")
