local uv = vim.uv or vim.loop

local tests = {}
local temp_root
local cleanup_fixture_id = 0
local project_scope_fixture_id = 0

local agent_cli_commands = {
  { command = "cursor-agent", lhs = "<leader>ac", plugin = "luanphan-cursor-agent", g_bufnr = "cursor_agent_bufnr" },
  { command = "claude", lhs = "<leader>xc", plugin = "luanphan-claude-agent", g_bufnr = "claude_agent_bufnr" },
  {
    command = "mcodex",
    lhs = "<leader>;",
    plugin = "luanphan-codex-agent",
    g_bufnr = "codex_agent_bufnr",
    optional_in_macos_ci = true,
  },
}

local function is_macos_ci_workspace()
  return vim.env.IS_CI_WORKSPACE == "1" and uv.os_uname().sysname == "Darwin"
end

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
  vim.g.luanphan_recent_paths_file = temp_root .. "/recent-paths.json"

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

local function make_project_scope_fixture()
  project_scope_fixture_id = project_scope_fixture_id + 1
  local suffix = tostring(project_scope_fixture_id)
  local station = temp_root .. "/example-station-" .. suffix
  local workspace_name = "example-workspace-" .. suffix
  local empty_workspace_name = "example-empty-" .. suffix
  local workspace_root = station .. "/local_workspaces/" .. workspace_name
  local sources = {}
  local workspaces = {}

  for _, project in ipairs({
    { name = "example-project-a", branch = "feature/a" },
    { name = "example-project-b-long", branch = "feature/b" },
  }) do
    local source = station .. "/" .. project.name
    local workspace = workspace_root .. "/" .. project.name
    vim.fn.mkdir(source, "p")
    run({ "git", "init", "-b", "main" }, source)
    run({ "git", "config", "user.name", "Example User" }, source)
    run({ "git", "config", "user.email", "example@example.invalid" }, source)
    write(source .. "/README.md", { project.name })
    run({ "git", "add", "." }, source)
    run({ "git", "commit", "-m", "initial fixture" }, source)
    run({ "git", "branch", project.branch }, source)
    vim.fn.mkdir(workspace_root, "p")
    run({ "git", "worktree", "add", workspace, project.branch }, source)
    sources[project.name] = source
    workspaces[project.name] = workspace
  end

  vim.fn.mkdir(station .. "/local_workspaces/" .. empty_workspace_name, "p")
  return sources, workspaces, station, workspace_name, empty_workspace_name
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

local function assert_lsp_keymap_navigation(buf)
  local usage = find_position(buf, "targetValue", "return targetValue()")
  local definition = find_position(buf, "targetValue", "func targetValue")

  local function invoke_lsp_map(lhs)
    local map = vim.fn.maparg(lhs, "n", false, true)
    assert_true(type(map) == "table" and type(map.callback) == "function", lhs .. " is not an LSP callback mapping")
    map.callback()
  end

  vim.api.nvim_win_set_cursor(0, { usage.line + 1, usage.character })
  invoke_lsp_map("gd")
  local jumped = vim.wait(5000, function()
    return vim.api.nvim_get_current_buf() == buf and vim.api.nvim_win_get_cursor(0)[1] == definition.line + 1
  end, 50, false)
  if not jumped then
    local clients = {}
    for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf })) do
      clients[#clients + 1] = string.format(
        "%s:%d initialized=%s stopped=%s",
        client.name,
        client.id,
        tostring(client.initialized),
        tostring(client:is_stopped())
      )
    end
    fail(string.format(
      "gd did not jump: current_buf=%d source_buf=%d cursor=%d direct_results=%d clients=[%s]",
      vim.api.nvim_get_current_buf(),
      buf,
      vim.api.nvim_win_get_cursor(0)[1],
      result_count(request(buf, "textDocument/definition", usage)),
      table.concat(clients, ", ")
    ))
  end

  invoke_lsp_map("gr")
  wait_until("gr reference jump", function()
    return vim.api.nvim_get_current_buf() == buf and vim.api.nvim_win_get_cursor(0)[1] == usage.line + 1
  end, 5000)
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
  assert_true(type(preview_map) == "table" and preview_map.desc == "Preview file", "<leader>fp should preview files")
  assert_true(vim.fn.maparg("<leader>fP", "n") == "", "<leader>fP should be removed")
  assert_true(vim.g.mkdp_auto_start == 0, "browser Markdown preview should not auto-start")
  assert_true(vim.g.mkdp_auto_close == 0, "browser Markdown preview should remain open when its buffer is hidden")
  assert_true(vim.g.mkdp_refresh_slow == 0, "browser Markdown preview should auto-refresh content")
  assert_true(vim.g.mkdp_open_to_the_world == 0, "browser Markdown preview should stay local")
  assert_true(vim.g.mkdp_theme == "light", "browser Markdown preview should use light theme")
  assert_true(
    type(vim.g.mkdp_preview_options) == "table" and vim.g.mkdp_preview_options.disable_sync_scroll == 1,
    "browser Markdown preview should not sync-scroll"
  )
  require("lazy").load({ plugins = { "markdown-preview.nvim" } })
  local refresh_events = {}
  for _, autocmd in ipairs(vim.api.nvim_get_autocmds({ group = "LuanphanMarkdownPreviewRefresh" })) do
    refresh_events[autocmd.event] = true
  end
  assert_true(refresh_events.TextChanged, "browser Markdown preview should refresh when markdown text changes")
  assert_true(refresh_events.TextChangedI, "browser Markdown preview should refresh while editing markdown")
  assert_true(refresh_events.BufWritePost, "browser Markdown preview should refresh after markdown writes")
end

local function test_markdown_preview_toggle_does_not_block()
  local file = temp_root .. "/preview-toggle.md"
  local old_browserfunc = vim.g.mkdp_browserfunc
  local old_clients_active = vim.g.mkdp_clients_active
  local channel = nil
  write(file, { "# Preview" })
  local other_file = temp_root .. "/preview-toggle-other.txt"
  write(other_file, { "Other file" })

  vim.cmd([[
    function! SmokeMarkdownPreviewBrowser(url) abort
      let g:smoke_markdown_preview_url = a:url
    endfunction
  ]])
  vim.g.mkdp_browserfunc = "SmokeMarkdownPreviewBrowser"
  vim.g.mkdp_clients_active = 0

  local function find_preview_channel()
    for _, candidate in ipairs(vim.api.nvim_list_chans()) do
      if candidate.mode == "rpc" and candidate.stream == "job" then
        for _, arg in ipairs(candidate.argv or {}) do
          if tostring(arg):find("markdown-preview.nvim", 1, true) then
            return candidate.id
          end
        end
      end
    end
  end

  local ok, err = xpcall(function()
    vim.cmd("edit " .. vim.fn.fnameescape(file))
    vim.bo.filetype = "markdown"
    local preview_buf = vim.api.nvim_get_current_buf()
    vim.b.MarkdownPreviewToggleBool = 0
    local preview_map = vim.fn.maparg("<leader>fp", "n", false, true)

    preview_map.callback()
    assert_true(vim.b.MarkdownPreviewToggleBool == 1, "markdown preview did not enter running state")
    wait_until("markdown preview RPC child", function()
      channel = find_preview_channel()
      return channel ~= nil and channel > 0
    end, 5000)

    vim.cmd("edit " .. vim.fn.fnameescape(other_file))
    assert_true(
      vim.b[preview_buf].MarkdownPreviewToggleBool == 1,
      "markdown preview stopped when its buffer was hidden"
    )
    local running = vim.fn.jobwait({ channel }, 0)
    assert_true(type(running) == "table" and running[1] == -1, "markdown preview RPC child exited on buffer switch")
    vim.api.nvim_set_current_buf(preview_buf)

    local started = uv.hrtime()
    preview_map.callback()
    local elapsed_ms = (uv.hrtime() - started) / 1000000
    assert_true(elapsed_ms < 500, "markdown preview stop blocked Neovim")
    assert_true(vim.b.MarkdownPreviewToggleBool == 0, "markdown preview did not leave running state")
    wait_until("markdown preview RPC child exit", function()
      local stopped, result = pcall(vim.fn.jobwait, { channel }, 0)
      return stopped and type(result) == "table" and result[1] ~= -1
    end, 5000)
  end, debug.traceback)

  if channel then
    pcall(vim.fn.jobstop, channel)
  end
  vim.g.mkdp_browserfunc = old_browserfunc
  vim.g.mkdp_clients_active = old_clients_active
  vim.g.smoke_markdown_preview_url = nil
  pcall(vim.cmd, "delfunction SmokeMarkdownPreviewBrowser")
  assert_true(ok, tostring(err))
end

local function test_csv_preview_keymap()
  local csv = temp_root .. "/preview.csv"
  local log = temp_root .. "/csvlens-preview.log"
  local fakebin = temp_root .. "/fakebin-csvlens"
  write(csv, { "name,value", "example,1" })
  vim.fn.mkdir(fakebin, "p")
  write_executable(fakebin .. "/csvlens", {
    "#!/bin/sh",
    "printf '%s\\n' \"$1\" > " .. vim.fn.shellescape(log),
    "sleep 3",
  })

  local old_path = vim.env.PATH
  vim.env.PATH = fakebin .. ":" .. old_path
  vim.cmd("edit " .. vim.fn.fnameescape(csv))
  vim.bo.filetype = "csv"
  local preview_map = vim.fn.maparg("<leader>fp", "n", false, true)
  assert_true(type(preview_map) == "table" and type(preview_map.callback) == "function", "<leader>fp should be a callback mapping")
  preview_map.callback()

  local function visible_csvlens_preview_count()
    local count = 0
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.b[buf].luanphan_csvlens_preview then
        count = count + 1
      end
    end
    return count
  end

  wait_until("csvlens preview", function()
    return visible_csvlens_preview_count() == 1 and vim.fn.filereadable(log) == 1
  end, 3000)
  assert_true(read_lines(log)[1] == csv, "csvlens should receive current CSV file")

  local preview_buf
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.b[buf].luanphan_csvlens_preview then
      preview_buf = buf
      break
    end
  end
  assert_true(type(preview_buf) == "number", "csvlens preview buffer should exist")
  local has_ctrl_h = false
  local has_ctrl_l = false
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(preview_buf, "t")) do
    has_ctrl_h = has_ctrl_h or map.lhs == "<C-H>"
    has_ctrl_l = has_ctrl_l or map.lhs == "<C-L>"
  end
  assert_true(has_ctrl_h, "csvlens preview should override terminal <C-h>")
  assert_true(has_ctrl_l, "csvlens preview should override terminal <C-l>")

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.b[buf].luanphan_csvlens_preview then
      local job = vim.b[buf].terminal_job_id
      if type(job) == "number" and job > 0 then
        pcall(vim.fn.jobstop, job)
      end
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  vim.env.PATH = old_path
end

local function test_no_italic_highlights()
  local italic_groups = {}
  for name, _ in pairs(vim.api.nvim_get_hl(0, {})) do
    local ok, highlight = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
    if ok and highlight.italic then
      table.insert(italic_groups, name)
    end
  end
  table.sort(italic_groups)
  assert_true(#italic_groups == 0, "italic highlight groups should be disabled: " .. table.concat(italic_groups, ", "))
end

local function test_git_conflict_decoration_guard()
  local guard = require("luanphan.git_conflict_guard")
  assert_true(
    guard.is_out_of_range_error("Invalid 'line': out of range"),
    "git conflict guard should recognize stale decoration line errors"
  )
  assert_true(
    guard.is_out_of_range_error("Invalid 'end_row': out of range"),
    "git conflict guard should recognize stale decoration end_row errors"
  )

  local wrapped = guard.wrap(function()
    error("Invalid 'line': out of range", 0)
  end)
  local ok, result = pcall(wrapped, nil, nil, vim.api.nvim_get_current_buf())
  assert_true(ok and result == false, "git conflict guard should swallow stale decoration line errors")

  local end_row_wrapped = guard.wrap(function()
    error("Invalid 'end_row': out of range", 0)
  end)
  local end_row_ok, end_row_result = pcall(end_row_wrapped, nil, nil, vim.api.nvim_get_current_buf())
  assert_true(
    end_row_ok and end_row_result == false,
    "git conflict guard should swallow stale decoration end_row errors"
  )

  local rethrow = guard.wrap(function()
    error("different error", 0)
  end)
  local rethrow_ok = pcall(rethrow)
  assert_true(not rethrow_ok, "git conflict guard should rethrow unrelated errors")
end

local function test_shell_treesitter_reads_workspace_scripts()
  local files = vim.fn.systemlist({ "git", "ls-files", "--", "*.sh" })
  assert_true(vim.v.shell_error == 0, table.concat(files, "\n"))
  assert_true(#files > 0, "workspace should have shell scripts to test")

  for _, file in ipairs(files) do
    vim.cmd("edit " .. vim.fn.fnameescape(file))
    local buf = vim.api.nvim_get_current_buf()
    assert_true(vim.bo[buf].filetype == "sh", file .. " should be detected as sh")
    wait_until(file .. " shell treesitter active", function()
      return vim.treesitter.highlighter.active[buf] ~= nil
    end, 3000)
  end
end

local function test_treesitter_uses_native_runtime()
  local plugin = require("lazy.core.config").plugins["nvim-treesitter"]
  assert_true(plugin == nil, "native treesitter runtime should not register nvim-treesitter")
  assert_true(package.loaded["nvim-treesitter"] == nil, "native runtime setup should not load nvim-treesitter")
  assert_true(package.loaded["nvim-treesitter.configs"] == nil, "native runtime setup should not load nvim-treesitter.configs")
end

local function runtimepath_contains(path)
  for entry in string.gmatch(vim.o.runtimepath, "([^,]+)") do
    if entry == path then
      return true
    end
  end
  return false
end

local function test_treesitter_uses_nix_parser_runtime()
  local profile = vim.env.NIX_PROFILE
  if profile == nil or profile == "" then
    profile = vim.env.HOME .. "/.nix-profile"
  end

  assert_true(vim.fn.isdirectory(profile .. "/parser") == 1, "Nix parser runtime should exist")
  assert_true(runtimepath_contains(profile), "runtimepath should include Nix parser runtime")

  for _, lang in ipairs({ "go", "json", "yaml", "bash" }) do
    assert_true(
      vim.fn.filereadable(profile .. "/parser/" .. lang .. ".so") == 1,
      lang .. " parser should be installed by Nix"
    )
  end
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

local function test_go_treesitter_configures_default_folds()
  local path = temp_root .. "/go-default-folds/main.go"
  write(path, {
    "package main",
    "",
    "func main() {",
    "\tif true {",
    "\t\tprintln(\"hello\")",
    "\t}",
    "}",
  })

  vim.cmd("edit " .. vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  wait_until("go treesitter active with fold setup", function()
    return vim.treesitter.highlighter.active[buf] ~= nil
  end, 3000)

  assert_true(vim.wo.foldmethod == "expr", "go buffers should use expression folds")
  assert_true(
    vim.wo.foldexpr == "v:lua.vim.treesitter.foldexpr()",
    "go buffers should use native treesitter foldexpr"
  )
  assert_true(vim.fn.foldlevel(3) > 0, "go function body should have a computed fold level")
  vim.cmd("normal! zM")
  assert_true(vim.fn.foldclosed(3) == 3, "zM should close the go function fold")
end

local function test_go_treesitter_preserves_fold_options_on_start()
  local path = temp_root .. "/go-folds/main.go"
  write(path, {
    "package main",
    "",
    "func main() {",
    "\tif true {",
    "\t\tprintln(\"hello\")",
    "\t}",
    "}",
  })

  vim.cmd("noautocmd edit " .. vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].filetype = "go"
  vim.opt_local.foldmethod = "marker"
  vim.opt_local.foldexpr = "0"
  vim.opt_local.foldlevel = 2
  vim.api.nvim_exec_autocmds("FileType", { buffer = buf, modeline = false })
  wait_until("go treesitter active without fold setup", function()
    return vim.treesitter.highlighter.active[buf] ~= nil
  end, 3000)

  assert_true(vim.wo.foldmethod == "marker", "treesitter should not change foldmethod")
  assert_true(vim.wo.foldexpr == "0", "treesitter should not change foldexpr")
  assert_true(vim.wo.foldlevel == 2, "treesitter should not change foldlevel")
end

local function test_treesitter_preserves_existing_fold_options_on_enter()
  local path = temp_root .. "/go-fold-preserve/main.go"
  write(path, {
    "package main",
    "",
    "func main() {",
    "\tif true {",
    "\t\tprintln(\"hello\")",
    "\t}",
    "}",
  })

  vim.cmd("edit " .. vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  wait_until("go treesitter active before fold preservation", function()
    return vim.treesitter.highlighter.active[buf] ~= nil
  end, 3000)

  vim.opt_local.foldmethod = "marker"
  vim.opt_local.foldexpr = "0"
  vim.opt_local.foldlevel = 3
  vim.cmd("enew")
  vim.cmd("buffer " .. buf)
  vim.api.nvim_exec_autocmds("BufEnter", { buffer = buf, modeline = false })
  vim.api.nvim_exec_autocmds("BufWinEnter", { buffer = buf, modeline = false })

  assert_true(vim.wo.foldmethod == "marker", "existing foldmethod should be preserved on enter")
  assert_true(vim.wo.foldexpr == "0", "existing foldexpr should be preserved on enter")
  assert_true(vim.wo.foldlevel == 3, "existing foldlevel should be preserved on enter")
end

local function test_diff_windows_keep_diff_folds_on_enter()
  local function fold_state(win)
    return vim.wo[win].foldmethod .. ":" .. vim.wo[win].foldlevel
  end

  local function go_lines(max)
    local result = {}
    for i = 1, max do
      result[#result + 1] = string.format("package main // %03d", i)
    end
    return result
  end

  vim.cmd("enew")
  local left_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_name(left_buf, "diffview://left")
  vim.bo[left_buf].filetype = "go"
  vim.bo[left_buf].buftype = "nowrite"
  vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, go_lines(200))
  local left_win = vim.api.nvim_get_current_win()

  vim.cmd("vsplit")
  local right_win = vim.api.nvim_get_current_win()
  local right_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(right_buf, temp_root .. "/diff-window-right.go")
  vim.api.nvim_buf_set_lines(right_buf, 0, -1, false, go_lines(200))
  vim.api.nvim_win_set_buf(right_win, right_buf)
  vim.bo[right_buf].filetype = "go"

  vim.api.nvim_win_call(left_win, function()
    vim.cmd("diffthis | setlocal foldmethod=diff foldlevel=0 foldenable")
  end)
  vim.api.nvim_win_call(right_win, function()
    vim.cmd("diffthis | setlocal foldmethod=diff foldlevel=0 foldenable")
  end)

  assert_true(fold_state(left_win) == "diff:0", "left diff fold state changed before enter")
  assert_true(fold_state(right_win) == "diff:0", "right diff fold state changed before enter")

  vim.api.nvim_set_current_win(left_win)
  vim.api.nvim_set_current_win(right_win)
  vim.api.nvim_exec_autocmds("BufEnter", { buffer = right_buf, modeline = false })
  vim.api.nvim_exec_autocmds("BufWinEnter", { buffer = right_buf, modeline = false })

  assert_true(fold_state(left_win) == "diff:0", "left diff fold state changed to " .. fold_state(left_win))
  assert_true(fold_state(right_win) == "diff:0", "right diff fold state changed to " .. fold_state(right_win))

  for _, win in ipairs({ left_win, right_win }) do
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_call(win, function()
        vim.cmd("diffoff")
      end)
    end
  end
  if vim.api.nvim_win_is_valid(right_win) then
    vim.api.nvim_win_close(right_win, true)
  end
  if vim.api.nvim_win_is_valid(left_win) then
    vim.api.nvim_set_current_win(left_win)
    vim.cmd("enew")
  end
  for _, buf in ipairs({ left_buf, right_buf }) do
    if vim.api.nvim_buf_is_valid(buf) and buf ~= vim.api.nvim_get_current_buf() then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
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
  wait_until("diffview repository " .. path, function()
    local ok, lib = pcall(require, "diffview.lib")
    local view = ok and lib.get_current_view() or nil
    local root = view and view.adapter and view.adapter.ctx and view.adapter.ctx.toplevel
    return root and realpath(root) == realpath(path)
  end, 10000)
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

local function test_ctrl_j_and_k_move_between_windows()
  local ok, err = xpcall(function()
    reset_window_layout()
    vim.cmd("enew")
    local upper = vim.api.nvim_get_current_win()
    vim.cmd("belowright new")
    local lower = vim.api.nvim_get_current_win()
    assert_true(lower ~= upper, "window navigation fixture did not create a lower window")

    feed_normal("<C-k>")
    assert_true(vim.api.nvim_get_current_win() == upper, "<C-k> did not move to the window above")
    feed_normal("<C-j>")
    assert_true(vim.api.nvim_get_current_win() == lower, "<C-j> did not move to the window below")
    assert_true(vim.fn.maparg("<C-j>", "t") == "", "<C-j> should remain unmapped in terminal mode")
  end, debug.traceback)

  reset_window_layout()
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
  local project_map = vim.fn.maparg("<leader>wp", "n", false, true)
  assert_true(
    type(project_map) == "table" and type(project_map.callback) == "function",
    "<leader>wp is not a lazy callback mapping"
  )
  local repository_map = vim.fn.maparg("<leader>wr", "n", false, true)
  assert_true(
    type(repository_map) == "table" and type(repository_map.callback) == "function",
    "<leader>wr is not a lazy callback mapping"
  )
  local workspace_map = vim.fn.maparg("<leader>ww", "n", false, true)
  assert_true(
    type(workspace_map) == "table" and type(workspace_map.callback) == "function",
    "<leader>ww is not a lazy callback mapping"
  )
  assert_true(vim.fn.maparg("<leader>gP", "n") == "", "<leader>gP should not have a duplicate project picker")
  local agent_map = vim.fn.maparg("<leader>w;", "n", false, true)
  assert_true(
    type(agent_map) == "table" and type(agent_map.callback) == "function",
    "<leader>w; is not a lazy callback mapping"
  )
  for _, old_lhs in ipairs({ "<leader>gp", "<leader>gr", "<leader>gw", "<leader>g;" }) do
    assert_true(vim.fn.maparg(old_lhs, "n") == "", old_lhs .. " workspace mapping should be removed")
  end
end

local function test_nvim_tree_hides_dotfiles()
  local config = require("nvim-tree.config").g_clone()
  assert_true(config and config.filters.dotfiles == true, "nvim-tree should hide dotfiles")
end

local function test_searches_follow_tree_dotfiles()
  local fixture = temp_root .. "/live-grep-hidden"
  write(fixture .. "/visible.txt", { "search target" })
  write(fixture .. "/.hidden/hidden.txt", { "search target" })

  local function search()
    local args = { "rg", "--files-with-matches" }
    vim.list_extend(args, require("luanphan.telescope_grep_opts").additional_args())
    vim.list_extend(args, { "search target", "." })
    local result = vim.system(args, { cwd = fixture, text = true }):wait()
    assert_true(result.code == 0, "live grep fixture failed: " .. (result.stderr or ""))
    return result.stdout
  end

  local function find_files()
    local args = require("luanphan.telescope_find_opts").find_command()
    local result = vim.system(args, { cwd = fixture, text = true }):wait()
    assert_true(result.code == 0, "find files fixture failed: " .. (result.stderr or ""))
    return result.stdout
  end

  local hidden = search()
  assert_true(hidden:find("visible.txt", 1, true) ~= nil, "live grep omitted a visible file")
  assert_true(hidden:find(".hidden", 1, true) == nil, "live grep included a hidden directory")
  assert_true(find_files():find(".hidden", 1, true) == nil, "find files included a hidden directory")

  local tree_api = require("nvim-tree.api")
  tree_api.tree.open({ path = fixture, focus = true })
  assert_true(vim.bo.filetype == "NvimTree", "nvim-tree did not open for the dotfile toggle fixture")
  invoke_map("H")
  assert_true(vim.g.luanphan_show_dotfiles == 1, "nvim-tree did not publish visible dotfile state")
  assert_true(search():find(".hidden", 1, true) ~= nil, "live grep did not follow visible dotfile state")
  assert_true(find_files():find(".hidden", 1, true) ~= nil, "find files did not follow visible dotfile state")
  invoke_map("H")
  assert_true(vim.g.luanphan_show_dotfiles == 0, "nvim-tree did not restore hidden dotfile state")
  tree_api.tree.close()
end

local function test_adjacent_project_discovery(repo, worktree)
  local api = worktree_test_api()
  local original_cwd = vim.fn.getcwd()
  local nested = repo .. "/nested"
  vim.fn.mkdir(nested, "p")
  vim.cmd("cd " .. vim.fn.fnameescape(nested))

  local projects, current_root = api.list_sibling_repos()
  local found = {}
  for _, project in ipairs(projects) do
    found[realpath(project.path)] = true
  end

  assert_true(realpath(current_root) == realpath(repo), "project discovery did not resolve the current git root")
  assert_true(found[realpath(repo)] == true, "project discovery omitted the current repository")
  assert_true(found[realpath(worktree)] == true, "project discovery omitted an adjacent git worktree")
  assert_true(vim.fn.exists(":ProjectSwitch") == 2, "ProjectSwitch command is missing")

  vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
end

local function test_recent_navigation_ordering(repo, worktree)
  local api = worktree_test_api()
  local recent_paths = require("luanphan.recent_paths")
  local original_cwd = vim.fn.getcwd()
  local state_file = vim.g.luanphan_recent_paths_file
  vim.fn.delete(state_file)

  local ok, err = xpcall(function()
    local items = {
      { name = "example-a", path = repo },
      { name = "example-b", path = worktree },
    }
    recent_paths.touch(worktree)
    recent_paths.sort(items, function(item) return item.path end)
    assert_true(items[1].name == "example-b", "shared recent-path ordering did not promote the latest path")
    recent_paths.touch(repo)
    recent_paths.sort(items, function(item) return item.path end)
    assert_true(items[1].name == "example-a", "revisiting a path did not move it back to the front")

    vim.cmd("cd " .. vim.fn.fnameescape(repo))
    recent_paths.touch(worktree)
    local trees = api.list_worktrees()
    assert_true(realpath(trees[1].path) == realpath(worktree), "worktree picker is not ordered by recent visits")

    local sources, workspaces, station, _, empty_workspace_name = make_project_scope_fixture()
    local workspace_a = workspaces["example-project-a"]
    local workspace_b = workspaces["example-project-b-long"]
    local source_b = sources["example-project-b-long"]
    vim.cmd("cd " .. vim.fn.fnameescape(workspace_a))

    recent_paths.touch(workspace_b)
    local projects = api.list_all_project_repos()
    assert_true(
      realpath(projects[1].path) == realpath(workspace_b),
      "repository picker did not promote the latest workspace repository"
    )

    recent_paths.touch(source_b)
    projects = api.list_all_project_repos()
    local first_root = nil
    for _, project in ipairs(projects) do
      if project.scope == "root" then
        first_root = project
        break
      end
    end
    assert_true(
      first_root and realpath(first_root.path) == realpath(source_b),
      "repository picker did not promote the latest root repository within its group"
    )

    local empty_workspace = station .. "/local_workspaces/" .. empty_workspace_name
    recent_paths.touch(empty_workspace)
    local workspace_entries = api.list_workspace_directories()
    assert_true(
      realpath(workspace_entries[1].path) == realpath(empty_workspace),
      "workspace picker did not promote the latest workspace"
    )
  end, debug.traceback)

  vim.fn.delete(state_file)
  if vim.fn.isdirectory(original_cwd) == 1 then
    vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
  end
  assert_true(ok, tostring(err))
end

local function test_workspace_and_master_project_discovery()
  local api = worktree_test_api()
  local original_cwd = vim.fn.getcwd()
  local sources, workspaces, station, workspace_name = make_project_scope_fixture()
  local nested = workspaces["example-project-a"] .. "/nested"
  vim.fn.mkdir(nested, "p")
  vim.cmd("cd " .. vim.fn.fnameescape(nested))

  local adjacent = api.list_sibling_repos()
  assert_true(#adjacent == 2, "adjacent project discovery escaped the current workspace")

  local projects, current_root = api.list_all_project_repos()
  local by_path = {}
  for _, project in ipairs(projects) do
    by_path[realpath(project.path)] = project
  end

  local expected = {
    [realpath(workspaces["example-project-a"])] = "feature/a",
    [realpath(workspaces["example-project-b-long"])] = "feature/b",
    [realpath(sources["example-project-a"])] = "main",
    [realpath(sources["example-project-b-long"])] = "main",
  }
  assert_true(#projects == 4, "combined project discovery returned an unexpected project count")
  assert_true(
    realpath(current_root) == realpath(workspaces["example-project-a"]),
    "combined project discovery did not resolve the current workspace project"
  )
  for project_path, branch in pairs(expected) do
    local project = by_path[project_path]
    assert_true(project ~= nil, "combined project discovery omitted " .. project_path)
    assert_true(project.branch == branch, "combined project discovery reported the wrong branch for " .. project_path)
  end
  local entries = api.group_project_entries(projects, current_root)
  assert_true(#entries == 7, "grouped project entries returned an unexpected row count")
  assert_true(entries[1].header and entries[1].display == "[workspace]", "workspace group header is missing")
  local workspace_root = station .. "/local_workspaces/" .. workspace_name
  assert_true(entries[2].workspace_root and entries[2].display == "  .", "workspace root option is missing")
  assert_true(realpath(entries[2].path) == realpath(workspace_root), "workspace root option has the wrong path")
  assert_true(entries[5].header and entries[5].display == "[root]", "root group header is missing")
  local branch_column = nil
  for _, entry in ipairs(entries) do
    if not entry.header and not entry.workspace_root then
      local column = entry.display:find("[", 1, true)
      assert_true(column ~= nil, "project entry branch label is missing")
      branch_column = branch_column or column
      assert_true(column == branch_column, "project entry branch labels are not aligned")
    end
  end

  local base_sorter = require("telescope.config").values.generic_sorter({})
  local sorter = api.make_project_sorter(base_sorter, require("telescope.sorters"))
  local function score(prompt, entry)
    return sorter:scoring_function(prompt, entry.ordinal, { value = entry })
  end
  assert_true(score("no-project-matches-this", entries[1]) >= 0, "workspace header was filtered by search")
  assert_true(score("no-project-matches-this", entries[5]) >= 0, "root header was filtered by search")
  assert_true(score("no-project-matches-this", entries[3]) < 0, "non-matching project survived search")
  assert_true(score("feature", entries[3]) < 0, "project search matched a branch name")
  assert_true(score("station", entries[3]) < 0, "project search matched a repository path")
  assert_true(score("project", entries[1]) < score("project", entries[3]), "workspace header is not first")
  assert_true(score("project", entries[4]) < score("project", entries[5]), "root header split the workspace group")
  assert_true(score("project", entries[5]) < score("project", entries[6]), "root header is not first in its group")

  local picker = {
    position = 1,
    rows = vim.tbl_map(function(entry) return { value = entry } end, entries),
  }
  picker.manager = { num_results = function() return #picker.rows end }
  function picker:move_selection(delta)
    self.position = ((self.position - 1 + delta) % #self.rows) + 1
  end
  function picker:get_selection()
    return self.rows[self.position]
  end
  api.move_project_selection(picker, 1)
  assert_true(picker.position == 2, "selection did not skip the workspace header")
  picker.position = 4
  api.move_project_selection(picker, 1)
  assert_true(picker.position == 6, "selection did not skip the root header")
  picker.position = 6
  api.move_project_selection(picker, -1)
  assert_true(picker.position == 4, "reverse selection did not skip the root header")
  assert_true(vim.fn.exists(":ProjectSwitch") == 2, "ProjectSwitch command is missing")

  local normalized_workspace_root = realpath(workspace_root)
  vim.cmd("cd " .. vim.fn.fnameescape(workspace_root))
  local from_workspace_root, resolved_root = api.list_all_project_repos()
  assert_true(#from_workspace_root == 4, "workspace root discovery returned an unexpected project count")
  assert_true(realpath(resolved_root) == normalized_workspace_root, "non-git workspace root was not resolved")
  local workspace_root_projects = {}
  for _, project in ipairs(from_workspace_root) do
    workspace_root_projects[realpath(project.path)] = project
  end
  for project_path in pairs(expected) do
    local project = workspace_root_projects[project_path]
    assert_true(project ~= nil, "workspace root discovery omitted " .. project_path)
    local expected_scope = vim.startswith(project_path, normalized_workspace_root .. "/") and "workspace" or "root"
    assert_true(project.scope == expected_scope, "workspace root discovery assigned the wrong scope")
  end

  vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
end

local function test_workspace_project_discovery()
  local api = worktree_test_api()
  local original_cwd = vim.fn.getcwd()
  local sources, workspaces, station, workspace_name, empty_workspace_name = make_project_scope_fixture()
  local nested = workspaces["example-project-a"] .. "/nested"
  vim.fn.mkdir(nested, "p")
  vim.cmd("cd " .. vim.fn.fnameescape(nested))

  local workspace_entries, root = api.list_workspace_directories()
  assert_true(realpath(root) == realpath(station), "workspace discovery did not resolve the workstation root")
  local by_name = {}
  for _, workspace in ipairs(workspace_entries) do
    by_name[workspace.name] = workspace
  end
  assert_true(#workspace_entries == 2, "workspace discovery returned an unexpected workspace count")
  assert_true(by_name[workspace_name] ~= nil, "workspace discovery omitted a workspace with repositories")
  assert_true(by_name[workspace_name].empty == false, "workspace with repositories was marked empty")
  assert_true(#by_name[workspace_name].repos == 2, "workspace repository count is incorrect")
  assert_true(by_name[empty_workspace_name] ~= nil, "workspace discovery omitted an empty workspace")
  assert_true(by_name[empty_workspace_name].empty == true, "empty workspace was not marked empty")

  local destinations, destination_root = api.list_workspace_destinations()
  assert_true(realpath(destination_root) == realpath(station), "workspace destinations resolved the wrong root")
  assert_true(#destinations == 3, "workspace destinations returned an unexpected count")
  assert_true(destinations[1].root == true, "workspace destinations did not put root first")
  assert_true(destinations[1].name == "root", "workspace root destination has the wrong name")
  assert_true(realpath(destinations[1].path) == realpath(station), "workspace root destination has the wrong path")

  api.activate_workspace(destinations[1])
  assert_true(
    realpath(vim.fn.getcwd()) == realpath(station),
    "root workspace selection did not switch to the workstation root"
  )

  api.activate_workspace(by_name[workspace_name])
  assert_true(
    realpath(vim.fn.getcwd()) == realpath(by_name[workspace_name].path),
    "workspace selection did not switch directly to the workspace root"
  )

  vim.cmd("cd " .. vim.fn.fnameescape(sources["example-project-a"]))
  local from_master, master_root = api.list_workspace_directories()
  assert_true(realpath(master_root) == realpath(station), "master repository did not resolve the workstation root")
  assert_true(#from_master == 2, "master repository discovered different workspaces")
  assert_true(vim.fn.exists(":ProjectSwitch") == 2, "ProjectSwitch command is missing")
  assert_true(vim.fn.exists(":RepositorySwitch") == 2, "RepositorySwitch command is missing")

  vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
end

local function test_active_agent_discovery(repo, worktree)
  local api = worktree_test_api()
  local agent_status = require("luanphan.agent_status")
  local original_buf = vim.api.nvim_get_current_buf()
  local original_cwd = vim.fn.getcwd()
  local original_status_dir = vim.g.luanphan_agent_status_dir
  local status_dir = vim.fn.tempname()
  vim.g.luanphan_agent_status_dir = status_dir
  local agent_keys = { "codex_agent_bufnr", "claude_agent_bufnr", "cursor_agent_bufnr" }
  local saved = {}
  for _, key in ipairs(agent_keys) do
    saved[#saved + 1] = { key = key, value = vim.g[key] }
  end

  local jobs = {}
  local buffers = {}
  local agents_module = nil
  local original_focus = nil
  local function start_terminal(cwd)
    vim.cmd("enew")
    local buf = vim.api.nvim_get_current_buf()
    local job = vim.fn.termopen({ "sh", "-c", "sleep 30" }, { cwd = cwd })
    assert_true(type(job) == "number" and job > 0, "failed to start active agent fixture")
    jobs[#jobs + 1] = job
    buffers[#buffers + 1] = buf
    return buf
  end

  local ok, err = xpcall(function()
    local codex_buf = start_terminal(repo)
    local cursor_buf = start_terminal(worktree)
    vim.g.codex_agent_bufnr = { [repo] = codex_buf }
    vim.g.cursor_agent_bufnr = { [worktree] = cursor_buf }
    vim.g.claude_agent_bufnr = { [repo] = 999999 }
    assert_true(agent_status.write("codex", repo, "running"), "failed to record first agent state")
    assert_true(agent_status.write("cursor", worktree, "idle"), "failed to record second agent state")

    local recent_paths = require("luanphan.recent_paths")
    recent_paths.touch(worktree)
    local instances = api.list_active_agents()
    assert_true(#instances == 2, "active agent discovery returned an unexpected instance count")
    assert_true(instances[1].agent == "cursor", "agent picker did not promote the latest project")
    recent_paths.touch(repo)
    instances = api.list_active_agents()
    assert_true(instances[1].agent == "codex", "agent picker did not move a revisited project to the front")
    local by_agent = {}
    for _, instance in ipairs(instances) do
      by_agent[instance.agent] = instance
    end
    assert_true(realpath(by_agent.codex.path) == realpath(repo), "Codex agent path was not discovered")
    assert_true(realpath(by_agent.cursor.path) == realpath(worktree), "Cursor agent path was not discovered")
    assert_true(by_agent.claude == nil, "stale agent terminal survived discovery")
    assert_true(by_agent.codex.status == "running", "running agent state was not discovered")
    assert_true(by_agent.cursor.status == "idle", "idle agent state was not discovered")
    assert_true(by_agent.codex.display:find("%[running%]") ~= nil, "agent display omitted running state")
    assert_true(by_agent.cursor.display:find("%[idle%s+%]") ~= nil, "agent display omitted idle state")
    assert_true(by_agent.codex.display:find("example%-repo") ~= nil, "agent display omitted repository context")
    assert_true(by_agent.cursor.display:find("%[feature%]") ~= nil, "agent display omitted branch context")
    assert_true(vim.fn.exists(":AgentSwitch") == 2, "AgentSwitch command is missing")

    agents_module = require("luanphan.plugins.agents")
    original_focus = agents_module.focus
    local focused = nil
    agents_module.focus = function(name)
      focused = name
      return true
    end
    api.activate_agent({ agent = "codex", path = original_cwd })
    assert_true(focused == "codex", "agent selection did not focus its terminal")
  end, debug.traceback)

  if agents_module and original_focus then
    agents_module.focus = original_focus
  end
  for _, job in ipairs(jobs) do
    pcall(vim.fn.jobstop, job)
  end
  for _, buf in ipairs(buffers) do
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  for _, item in ipairs(saved) do
    vim.g[item.key] = item.value
  end
  vim.g.luanphan_agent_status_dir = original_status_dir
  vim.fn.delete(status_dir, "rf")
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
  local original_codex = vim.g.codex_agent_bufnr
  local original_cursor = vim.g.cursor_agent_bufnr
  local agents = require("luanphan.plugins.agents")
  local original_focus = agents.focus
  local jobs = {}
  local buffers = {}

  local function start_terminal(cwd)
    local buf = vim.api.nvim_create_buf(false, true)
    local job
    vim.api.nvim_buf_call(buf, function()
      job = vim.fn.termopen({ "sh", "-c", "sleep 30" }, { cwd = cwd })
    end)
    assert_true(type(job) == "number" and job > 0, "failed to start agent switch fixture")
    vim.b[buf].luanphan_persist_term = true
    jobs[#jobs + 1] = job
    buffers[#buffers + 1] = buf
    return buf
  end

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
    local old_buf = start_terminal(repo)
    local target_buf = start_terminal(worktree)
    vim.g.codex_agent_bufnr = { [repo] = old_buf }
    vim.g.cursor_agent_bufnr = { [worktree] = target_buf }

    vim.api.nvim_open_win(old_buf, true, {
      relative = "editor",
      row = 1,
      col = 1,
      width = 40,
      height = 10,
      style = "minimal",
      border = "single",
    })
    assert_true(window_for_buffer(old_buf) ~= nil, "old repository agent fixture is not visible")

    agents.focus = function(name, bufnr)
      assert_true(name == "cursor", "agent switch focused the wrong agent type")
      assert_true(bufnr == target_buf, "agent switch did not focus the selected workspace terminal")
      if not window_for_buffer(target_buf) then
        vim.api.nvim_open_win(target_buf, true, {
          relative = "editor",
          row = 1,
          col = 1,
          width = 40,
          height = 10,
          style = "minimal",
          border = "single",
        })
      end
      return true
    end

    api.activate_agent({ agent = "cursor", path = worktree, bufnr = target_buf })
    assert_true(realpath(vim.fn.getcwd()) == realpath(worktree), "agent switch did not change repositories")
    assert_true(window_for_buffer(old_buf) == nil, "old repository agent window remained visible")
    assert_true(window_for_buffer(target_buf) ~= nil, "selected repository agent window was not focused")
    assert_true(visible_agent_float_count() == 1, "agent switch left multiple agent windows visible")
  end, debug.traceback)

  agents.focus = original_focus
  vim.g.codex_agent_bufnr = original_codex
  vim.g.cursor_agent_bufnr = original_cursor
  for _, job in ipairs(jobs) do
    pcall(vim.fn.jobstop, job)
  end
  for _, buf in ipairs(buffers) do
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  if vim.api.nvim_buf_is_valid(original_buf) then
    pcall(vim.api.nvim_set_current_buf, original_buf)
  end
  if vim.fn.isdirectory(original_cwd) == 1 then
    vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
  end
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
  write_executable(shim_dir .. "/mcodex", {
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
      return log_has_prefix(invoke_log, "mcodex|")
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

local function test_lsp_survives_duplicate_split_close(repo)
  vim.cmd("cd " .. vim.fn.fnameescape(repo))
  local buf = open_go_file(repo .. "/main.go")
  local client = active_lsp_client(buf, "gopls")
  assert_true(client ~= nil, "gopls was not attached before opening a split")
  local client_id = client.id
  local original_win = vim.api.nvim_get_current_win()

  vim.cmd("vsplit")
  local split_win = vim.api.nvim_get_current_win()
  assert_true(split_win ~= original_win, "vsplit did not create a second window")
  assert_true(vim.api.nvim_get_current_buf() == buf, "vsplit did not duplicate the Go buffer")
  vim.api.nvim_win_close(split_win, false)

  assert_true(vim.api.nvim_get_current_win() == original_win, "closing the split did not return to the original window")
  assert_true(vim.api.nvim_get_current_buf() == buf, "closing the split replaced the original Go buffer")
  client = active_lsp_client(buf, "gopls")
  assert_true(client ~= nil and client.id == client_id, "closing a duplicate split detached gopls")

  assert_lsp_keymap_navigation(buf)

  local usage = find_position(buf, "targetValue", "return targetValue()")
  assert_true(
    result_count(request(buf, "textDocument/definition", usage)) >= 1,
    "gopls definition failed after closing a duplicate split"
  )

  vim.cmd("vsplit")
  split_win = vim.api.nvim_get_current_win()
  client:stop(true)
  wait_until("stale gopls client to stop", function()
    return client:is_stopped()
  end, 5000)
  vim.api.nvim_win_close(split_win, false)
  assert_lsp_keymap_navigation(buf)
  wait_until("gopls recovery after split close", function()
    local recovered = active_lsp_client(buf, "gopls")
    return recovered ~= nil and recovered.id ~= client_id
  end, 5000)
  assert_true(
    result_count(request(buf, "textDocument/definition", usage)) >= 1,
    "recovered gopls definition failed after closing a duplicate split"
  )
end

local function test_workspace_root_uses_one_gopls_per_module()
  local api = worktree_test_api()
  local original_cwd = vim.fn.getcwd()
  local workspace = temp_root .. "/example-multi-module-workspace"
  local modules = {}

  for index, name in ipairs({ "example-module-a", "example-module-b" }) do
    local path = workspace .. "/" .. name
    vim.fn.mkdir(path, "p")
    run({ "git", "init", "-b", "main" }, path)
    write(path .. "/go.mod", {
      "module example.com/" .. name,
      "",
      "go 1.21",
    })
    write(path .. "/main.go", {
      "package " .. name:gsub("%-", ""),
      "",
      "func Value() string {",
      string.format('\treturn "module-%d"', index),
      "}",
    })
    modules[#modules + 1] = { path = path, file = path .. "/main.go" }
  end

  api.switch_to(workspace, "workspace root")
  local buffers = {}
  local clients = {}
  for index, module in ipairs(modules) do
    buffers[index] = open_go_file(module.file)
    clients[index] = active_lsp_client(buffers[index], "gopls")
    assert_true(clients[index] ~= nil, "workspace module has no gopls client")
    assert_true(
      realpath(clients[index].config.root_dir) == realpath(module.path),
      "gopls attached with the wrong module root"
    )
  end
  assert_true(clients[1].id ~= clients[2].id, "workspace modules unexpectedly reused one gopls client")

  local old_ids = { clients[1].id, clients[2].id }
  api.switch_to(modules[1].path, "workspace project")
  local module_a_buf = open_go_file(modules[1].file)
  local module_a_client = active_lsp_client(module_a_buf, "gopls")
  assert_true(module_a_client ~= nil, "gopls did not restart after switching to a workspace project")
  assert_true(
    realpath(module_a_client.config.root_dir) == realpath(modules[1].path),
    "switched project gopls has the wrong root"
  )
  assert_true(module_a_client.id ~= old_ids[1] and module_a_client.id ~= old_ids[2], "gopls was not restarted")
  wait_until("stale workspace gopls clients to stop", function()
    for _, id in ipairs(old_ids) do
      local client = vim.lsp.get_client_by_id(id)
      if client and not client:is_stopped() then
        return false
      end
    end
    return true
  end)

  local live_gopls = 0
  for _, client in ipairs(vim.lsp.get_clients({ name = "gopls" })) do
    if not client:is_stopped() then
      live_gopls = live_gopls + 1
    end
  end
  assert_true(live_gopls == 1, "project switch left stale gopls clients running")

  api.switch_to(original_cwd, "project")
end

local function test_lsp_recursive_incoming_call_graph(repo)
  vim.cmd("cd " .. vim.fn.fnameescape(repo))
  local shared_file = repo .. "/shared.go"
  write(shared_file, {
    "package main",
    "",
    "func secondaryRoot() string {",
    "\treturn useTarget()",
    "}",
    "",
    "func laterBranch() string {",
    "\treturn targetValue()",
    "}",
    "",
    "func earlierBranch() string {",
    "\treturn targetValue()",
    "}",
    "",
    "func orderedRoot() {",
    "\t_ = laterBranch()",
    "\t_ = earlierBranch()",
    "}",
  })
  local test_file = repo .. "/main_test.go"
  write(test_file, {
    "package main",
    "",
    'import "testing"',
    "",
    "func TestTargetValue(t *testing.T) {",
    "\t_ = targetValue()",
    "}",
  })
  open_go_file(shared_file)
  open_go_file(test_file)
  local buf = open_go_file(repo .. "/main.go")
  local target = find_position(buf, "targetValue", "func targetValue")
  vim.api.nvim_win_set_cursor(0, { target.line + 1, target.character })
  pcall(vim.treesitter.stop, buf)
  assert_true(vim.treesitter.highlighter.active[buf] == nil, "call graph fixture should start without highlighting")

  local graph_map = vim.fn.maparg("gR", "n", false, true)
  assert_true(
    type(graph_map) == "table" and graph_map.desc == "Incoming call graph",
    "gR should open the incoming call graph"
  )
  graph_map.callback()

  wait_until("recursive incoming call graph", function()
    local name = vim.api.nvim_buf_get_name(0)
    if not name:match("^incoming%-call%-graph://") then
      return false
    end
    local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    return text:find("targetValue", 1, true)
      and text:find("useTarget", 1, true)
      and text:find("main  ", 1, true)
      and text:find("orderedRoot", 1, true)
      and text:find("laterBranch", 1, true)
      and text:find("earlierBranch", 1, true)
      and not text:find("Loading incoming calls", 1, true)
  end, 10000)

  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local text = table.concat(lines, "\n")
  local function graph_highlight_groups(bufnr)
    local groups = {}
    for _, extmark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, -1, 0, -1, { details = true })) do
      local group = extmark[4].hl_group
      if group then
        groups[group] = true
      end
    end
    return groups
  end

  local function graph_line_highlight_groups(bufnr, line)
    local groups = {}
    for _, extmark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, -1, 0, -1, { details = true })) do
      local group = extmark[4].hl_group
      if extmark[2] == line - 1 and group then
        groups[group] = true
      end
    end
    return groups
  end

  local initial_highlights = graph_highlight_groups(0)
  assert_true(initial_highlights.IncomingCallGraphConnector, "call graph should highlight tree connectors")
  assert_true(initial_highlights.Function, "call graph should highlight function names")
  assert_true(initial_highlights.IncomingCallGraphPath, "call graph should highlight source paths")
  assert_true(initial_highlights.Number, "call graph should highlight source line numbers")
  assert_true(initial_highlights.Special, "call graph should highlight top-level callers")
  assert_true(not text:find("TestTargetValue", 1, true), "call graph should exclude Go test functions")
  assert_true(not text:find("main_test.go", 1, true), "call graph should exclude Go test files")
  assert_true(not text:find("`--", 1, true), "call graph should use Unicode tree connectors")
  local target_line
  local direct_caller_line
  local recursive_caller_line
  local secondary_root_line
  local ordered_root_line
  local later_branch_line
  local earlier_branch_line
  local target_count = 0
  for index, line in ipairs(lines) do
    target_line = target_line or (line:find("targetValue", 1, true) and index)
    direct_caller_line = direct_caller_line or (line:find("useTarget", 1, true) and index)
    recursive_caller_line = recursive_caller_line or (line:find("main  ", 1, true) and index)
    secondary_root_line = secondary_root_line or (line:find("secondaryRoot", 1, true) and index)
    ordered_root_line = ordered_root_line or (line:find("orderedRoot", 1, true) and index)
    later_branch_line = later_branch_line or (line:find("laterBranch", 1, true) and index)
    earlier_branch_line = earlier_branch_line or (line:find("earlierBranch", 1, true) and index)
    target_count = target_count + (line:find("targetValue", 1, true) and 1 or 0)
  end
  assert_true(recursive_caller_line == 1, "call graph should start at the top-level caller")
  assert_true(direct_caller_line == 2, "call graph should show each caller-to-callee step from top to bottom")
  assert_true(target_line == 3, "call graph should show the selected function below its callers")
  assert_true(lines[direct_caller_line]:match("^└ "), "call graph should use the sidebar branch connector")
  assert_true(
    #lines[target_line]:match("^%s*") > #lines[direct_caller_line]:match("^%s*"),
    "selected function should be indented below its caller"
  )
  assert_true(target_count == 4, "each call graph root should render its complete path to the selected function")
  assert_true(secondary_root_line ~= nil, "call graph should include the second top-level caller")
  assert_true(
    graph_line_highlight_groups(0, recursive_caller_line).Special,
    "first top-level caller should use the root highlight"
  )
  assert_true(
    graph_line_highlight_groups(0, secondary_root_line).Special,
    "second top-level caller should use the root highlight"
  )
  assert_true(
    graph_line_highlight_groups(0, direct_caller_line).Function,
    "nested callers should retain function highlighting"
  )
  assert_true(
    ordered_root_line < later_branch_line and later_branch_line < earlier_branch_line,
    "immediate child callers should follow their source call order"
  )
  assert_true(not text:find("[focused]", 1, true), "call graph should not render focused suffixes")
  assert_true(not text:find("[shared]", 1, true), "call graph should not truncate repeated paths")
  assert_true(vim.wo[0].foldmethod == "expr", "call graph should use hierarchy folds")
  vim.api.nvim_win_set_cursor(0, { recursive_caller_line, 0 })
  vim.cmd("normal! zM")
  assert_true(vim.fn.foldclosed(recursive_caller_line) == recursive_caller_line, "zM should close root folds")
  vim.cmd("normal! zo")
  assert_true(vim.fn.foldclosed(recursive_caller_line) == -1, "zo should open the current parent fold")
  assert_true(
    vim.fn.foldclosed(direct_caller_line) == direct_caller_line,
    "zo should leave the next parent level folded"
  )
  vim.cmd("normal! zM")
  vim.cmd("normal! zO")
  assert_true(vim.fn.foldclosed(direct_caller_line) == -1, "zO should open all descendant folds")
  vim.cmd("normal! zR")
  vim.cmd("normal! zm")
  assert_true(vim.fn.foldclosed(direct_caller_line) == direct_caller_line, "zm should close one fold level")
  vim.cmd("normal! zr")
  assert_true(vim.fn.foldclosed(direct_caller_line) == -1, "zr should open one fold level")
  vim.cmd("normal! zM")
  vim.cmd("normal! zR")
  assert_true(vim.fn.foldclosed(recursive_caller_line) == -1, "zR should open every call graph fold")

  local function graph_preview_window()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.w[win].luanphan_incoming_call_preview then
        return win
      end
    end
  end

  local preview_win = graph_preview_window()
  assert_true(preview_win ~= nil, "call graph should open a source preview")
  local graph_config = vim.api.nvim_win_get_config(0)
  local preview_config = vim.api.nvim_win_get_config(preview_win)
  assert_true(preview_config.col > graph_config.col, "call graph source preview should be positioned on the right")
  local editor_height = math.max(1, vim.o.lines - vim.o.cmdheight)
  local available_height = math.max(1, editor_height - 4)
  local expected_graph_height = math.min(math.max(3, #lines), available_height)
  local expected_preview_height = math.min(math.max(3, math.floor(editor_height * 0.8) - 2), available_height)
  assert_true(graph_config.height == expected_graph_height, "call graph height should fit its rendered content")
  assert_true(preview_config.height == expected_preview_height, "source preview should occupy 80 percent of the editor height")
  assert_true(vim.wo[0].cursorline, "call graph should highlight its focused row")
  assert_true(
    vim.wo[0].winhighlight:find("CursorLine:IncomingCallGraphFocus", 1, true) ~= nil,
    "call graph focused row should use the call graph highlight"
  )

  local function preview_highlight_line()
    return vim.api.nvim_win_call(preview_win, function()
      for _, match in ipairs(vim.fn.getmatches()) do
        if match.group == "IncomingCallGraphFocus" and match.pos1 then
          return match.pos1[1]
        end
      end
    end)
  end

  wait_until("recursive caller source file preview", function()
    return vim.api.nvim_win_is_valid(preview_win)
      and realpath(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(preview_win))) == realpath(repo .. "/main.go")
  end)
  local preview_buf = vim.api.nvim_win_get_buf(preview_win)
  assert_true(
    vim.treesitter.highlighter.active[preview_buf] ~= nil,
    "source preview should restore Treesitter highlighting"
  )
  local recursive_call_site = find_position(preview_buf, "useTarget", "_ = useTarget()")
  assert_true(
    vim.api.nvim_win_get_cursor(preview_win)[1] == recursive_call_site.line + 1,
    "top-level caller preview should focus the immediate child invocation"
  )
  assert_true(
    preview_highlight_line() == recursive_call_site.line + 1,
    "source preview should highlight the top-level caller invocation"
  )

  local graph_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_win_set_cursor(0, { direct_caller_line, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = graph_buf })
  local call_site = find_position(preview_buf, "targetValue", "return targetValue()")
  wait_until("direct caller source preview", function()
    return vim.api.nvim_win_is_valid(preview_win)
      and realpath(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(preview_win))) == realpath(repo .. "/main.go")
      and vim.api.nvim_win_get_cursor(preview_win)[1] == call_site.line + 1
  end)
  assert_true(
    preview_highlight_line() == call_site.line + 1,
    "source preview highlight should follow call graph navigation"
  )
  invoke_map("<CR>")
  assert_true(not vim.api.nvim_win_is_valid(preview_win), "call graph jump should close the source preview")
  assert_true(
    realpath(vim.api.nvim_buf_get_name(0)) == realpath(repo .. "/main.go"),
    "call graph jump should open the source file"
  )
  assert_true(
    vim.api.nvim_win_get_cursor(0)[1] == call_site.line + 1,
    "caller jump should focus where the immediate child is called"
  )

  local target_definition = find_position(0, "targetValue", "func targetValue")
  vim.api.nvim_win_set_cursor(0, { target_definition.line + 1, target_definition.character })
  invoke_map("gR")
  wait_until("second recursive incoming call graph", function()
    local name = vim.api.nvim_buf_get_name(0)
    if not name:match("^incoming%-call%-graph://") then
      return false
    end
    local graph_text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    return graph_text:find("orderedRoot", 1, true) and not graph_text:find("Loading incoming calls", 1, true)
  end, 10000)
  local second_highlights = graph_highlight_groups(0)
  assert_true(
    second_highlights.IncomingCallGraphConnector,
    "second call graph should retain tree-connector highlighting"
  )
  assert_true(second_highlights.Function, "second call graph should retain function highlighting")
  assert_true(second_highlights.IncomingCallGraphPath, "second call graph should retain path highlighting")
  assert_true(second_highlights.Number, "second call graph should retain line-number highlighting")
  assert_true(second_highlights.Special, "second call graph should retain top-level caller highlighting")
  invoke_map("q")

  local test_buf = open_go_file(test_file)
  local test_function = find_position(test_buf, "TestTargetValue", "func TestTargetValue")
  vim.api.nvim_win_set_cursor(0, { test_function.line + 1, test_function.character })
  invoke_map("gR")
  wait_until("excluded Go test call graph", function()
    local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    return vim.api.nvim_buf_get_name(0):match("^incoming%-call%-graph://")
      and text:find("Go test functions are excluded", 1, true)
  end, 10000)
  invoke_map("q")
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

local function test_worktree_switch_hides_foreign_file(repo, worktree)
  local api = worktree_test_api()
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

  api.switch_to(worktree, "worktree")
  assert_true(realpath(vim.fn.getcwd()) == realpath(worktree), "worktree switch did not change cwd")
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
  local agent_status = require("luanphan.agent_status")
  local original_status_dir = vim.g.luanphan_agent_status_dir
  local status_dir = vim.fn.tempname()
  vim.g.luanphan_agent_status_dir = status_dir

  local agent = require("luanphan.terminal_agent").create({
    status_name = "example-agent",
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
  assert_true(vim.fn.maparg("<C-j>", "t") == "", "agent terminal insert mode captured <C-j>")
  vim.cmd("stopinsert")
  local view_down_map = vim.fn.maparg("<C-j>", "n", false, true)
  assert_true(
    type(view_down_map) == "table" and type(view_down_map.callback) == "function",
    "agent terminal view mode is missing <C-j> navigation"
  )
  view_down_map.callback()
  assert_true(visible_agent_float_count() == 0, "agent terminal view-mode <C-j> did not return to the editor")
  agent.toggle()
  wait_until("agent terminal reopened after view navigation", function()
    return visible_agent_float_count() == 1
  end, 1000)
  assert_true(agent_status.read("example-agent", repo) == "idle", "new agent terminal did not start idle")
  local submit_map = vim.fn.maparg("<CR>", "t", false, true)
  assert_true(type(submit_map) == "table" and type(submit_map.callback) == "function", "agent submit tracking is missing")
  submit_map.callback()
  assert_true(agent_status.read("example-agent", repo) == "running", "agent submit did not record running state")

  invoke_lazy_map("<leader>tt", "toggleterm.nvim")
  wait_until("toggleterm open after agent terminal", function()
    return visible_toggleterm_window_count() > 0
  end, 3000)
  assert_true(visible_agent_float_count() == 0, "agent terminal remained visible after <leader>tt")
  close_agent_terminals()
  vim.g.luanphan_agent_status_dir = original_status_dir
  vim.fn.delete(status_dir, "rf")
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

  worktree_test_api().switch_to(worktree)
  wait_until("worktree agent terminal restored again", function()
    return visible_agent_float_count() == 1
  end, 1000)

  local buffers = vim.g.smoke_agent_bufnr
  local repo_buf = nil
  local worktree_buf = nil
  for path, bufnr in pairs(buffers) do
    if realpath(path) == realpath(repo) then
      repo_buf = bufnr
    elseif realpath(path) == realpath(worktree) then
      worktree_buf = bufnr
    end
  end
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
    assert_true(vim.wo[win].wrap == true, "agent terminal inherited wrapping")
    assert_true(not vim.wo[win].winhighlight:find("ErrorMsg", 1, true), "agent terminal inherited highlights")
    assert_true(vim.bo[buf].syntax == "", "agent terminal inherited syntax highlighting")
  end

  assert_true(agent.focus(repo_buf), "agent could not focus the selected repository terminal")
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
  assert_true(agent.focus(repo_buf), "agent could not repair a polluted terminal")
  assert_true(vim.bo[repo_buf].syntax == "", "agent focus did not clear inherited syntax highlighting")

  pcall(vim.api.nvim_win_close, repo_win, false)
  assert_true(agent.focus(worktree_buf), "agent could not restore the selected worktree terminal")
  assert_clean_terminal_window(window_for_buffer(worktree_buf))
  for name, value in pairs(saved_options) do
    vim.api.nvim_set_option_value(name, value, { win = source_win, scope = "local" })
  end
end

local function test_deleted_workspace_falls_back_to_master_worktree_from_lazy_key()
  local source, workspace = make_workspace_cleanup_fixture()
  vim.cmd("cd " .. vim.fn.fnameescape(workspace))

  run({ "git", "worktree", "remove", "--force", workspace }, source)
  feed_normal((vim.g.mapleader or "\\") .. "ww")

  local expected = realpath(source)
  wait_until("master worktree fallback", function()
    return realpath(vim.fn.getcwd()) == expected
  end, 10000)
  assert_true(worktree_plugin_loaded(), "worktree plugin did not lazy-load from <leader>ww")
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
    "vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes((vim.g.mapleader or '\\\\') .. 'ww', true, false, true), 'xt', false)",
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
  focus_file_window_inside_diffview_tab(worktree .. "/main.go")
  invoke_map("<leader>gd")
  wait_until("diffview closes from file window", function()
    return not has_visible_diffview()
  end, 5000)

  invoke_map("<leader>gD")
  wait_for_diffview()
  close_diffview()
end

local function test_git_diff_repository_bar_from_workspace_root()
  local original_cwd = vim.fn.getcwd()
  local _, workspaces, station, workspace_name = make_project_scope_fixture()
  local workspace_root = station .. "/local_workspaces/" .. workspace_name
  local first_repo = workspaces["example-project-a"]
  local second_repo = workspaces["example-project-b-long"]
  local clean_repo = workspace_root .. "/example-project-clean"
  vim.fn.delete(vim.g.luanphan_recent_paths_file)

  vim.fn.mkdir(clean_repo, "p")
  run({ "git", "init", "-b", "main" }, clean_repo)
  run({ "git", "config", "user.name", "Example User" }, clean_repo)
  run({ "git", "config", "user.email", "example@example.invalid" }, clean_repo)
  write(clean_repo .. "/README.md", { "clean repository" })
  run({ "git", "add", "." }, clean_repo)
  run({ "git", "commit", "-m", "clean fixture" }, clean_repo)
  require("luanphan.recent_paths").touch(clean_repo)

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
  vim.cmd("cd " .. vim.fn.fnameescape(workspace_root))

  invoke_map("<leader>gd")
  wait_for_diffview()
  wait_for_diffview_repository(first_repo)
  local tab, bar_win, bar_buf = find_workspace_diff_bar()
  assert_true(tab ~= nil and bar_win ~= nil and bar_buf ~= nil, "multi-repository diff did not create a repository bar")
  local initial_view = require("diffview.lib").get_current_view()
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
  local line = vim.api.nvim_buf_get_lines(bar_buf, 0, 1, false)[1] or ""
  assert_true(
    line:find("[example-project-a +5 -1]", 1, true) ~= nil,
    "initial diff repository omitted aggregate line changes"
  )
  assert_true(line:find("example-project-b-long", 1, true) ~= nil, "repository bar omitted a child repository")
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

  wait_until("next diff repository mapping", function()
    vim.api.nvim_set_current_win(bar_win)
    local map = vim.fn.maparg("l", "n", false, true)
    return type(map) == "table" and type(map.callback) == "function"
  end, 3000)
  invoke_map("l")
  wait_for_diffview_repository(second_repo)
  local second_view = require("diffview.lib").get_current_view()
  assert_true(second_view ~= initial_view, "repository browsing did not open the selected Diffview")
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
  invoke_map("<leader>gd")
  wait_until("workspace diff group closes", function()
    return not has_visible_diffview()
  end, 5000)

  write(second_repo .. "/branch-change.txt", { "committed branch change" })
  run({ "git", "add", "branch-change.txt" }, second_repo)
  run({ "git", "commit", "-m", "branch diff fixture" }, second_repo)
  require("luanphan.recent_paths").touch(clean_repo)
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
  vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
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
    "vim.env.GOWORK = 'off'",
    "vim.cmd('cd ' .. vim.fn.fnameescape(worktree))",
    "invoke_map('<leader>gd')",
    "wait_until('diffview', has_visible_diffview, 10000)",
    "wait_until('diffview files', function() return diffview_file_count() > 0 end, 10000)",
    "focus_diffview_jump_buffer()",
    "local needle = 'uncommitted fixture change'",
    "focus_diff_line(needle)",
    "local expected_line = line_number_for_content(file, needle)",
    "assert_true(expected_line ~= nil, 'fixture changed line missing from original file')",
    "invoke_map('<leader>gf')",
    "wait_until('original file buffer', function() return realpath(vim.api.nvim_buf_get_name(0)) == realpath(file) end, 5000)",
    "assert_true(has_visible_diffview(), 'diffview should remain open after original jump')",
    "assert_true(vim.api.nvim_win_get_cursor(0)[1] == expected_line, 'jumped cursor line should match focused diff line')",
    "local buf = vim.api.nvim_get_current_buf()",
    "assert_true(vim.bo[buf].filetype == 'go', 'jumped buffer filetype is ' .. vim.bo[buf].filetype)",
    "wait_until('go treesitter after diff jump', function() return vim.treesitter.highlighter.active[buf] ~= nil end, 5000)",
    "wait_for_lsp(buf)",
    "vim.api.nvim_set_current_tabpage(find_diffview_tab())",
    "vim.cmd('DiffviewClose')",
    "wait_until('working diffview closes', function() return not has_visible_diffview() end, 5000)",
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

  test("nvim-tree hides dotfiles", function()
    test_nvim_tree_hides_dotfiles()
  end)

  test("file searches follow nvim-tree dotfile visibility", function()
    test_searches_follow_tree_dotfiles()
  end)

  test("toggle icons reflect state", function()
    test_toggle_icons_reflect_state()
  end)

  test("word wrap keymap applies to all windows", function()
    test_word_wrap_keymap_applies_to_all_windows()
  end)

  test("Ctrl-J and Ctrl-K move between windows", function()
    test_ctrl_j_and_k_move_between_windows()
  end)

  test("markdown browser preview keymap", function()
    test_markdown_browser_preview_keymap()
  end)

  test("markdown preview toggle does not block", function()
    test_markdown_preview_toggle_does_not_block()
  end)

  test("csv preview keymap", function()
    test_csv_preview_keymap()
  end)

  test("no italic highlights", function()
    test_no_italic_highlights()
  end)

  test("git conflict decoration guard", function()
    test_git_conflict_decoration_guard()
  end)

  test("shell treesitter reads workspace scripts", function()
    test_shell_treesitter_reads_workspace_scripts()
  end)

  test("treesitter uses native runtime", function()
    test_treesitter_uses_native_runtime()
  end)

  test("treesitter uses nix parser runtime", function()
    test_treesitter_uses_nix_parser_runtime()
  end)

  test("treesitter required parsers available", function()
    test_treesitter_required_parsers_available()
  end)

  test("go treesitter configures default folds", function()
    test_go_treesitter_configures_default_folds()
  end)

  test("go treesitter preserves fold options on start", function()
    test_go_treesitter_preserves_fold_options_on_start()
  end)

  test("treesitter preserves existing fold options on enter", function()
    test_treesitter_preserves_existing_fold_options_on_enter()
  end)

  test("diff windows keep diff folds on enter", function()
    test_diff_windows_keep_diff_folds_on_enter()
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

  test("adjacent project picker discovers sibling git repositories", function()
    test_adjacent_project_discovery(repo, worktree)
  end)

  test("navigation pickers order destinations by most recent visit", function()
    test_recent_navigation_ordering(repo, worktree)
  end)

  test("project picker discovers grouped workspace and root repositories", function()
    test_workspace_and_master_project_discovery()
  end)

  test("workspace picker switches to root and workspace destinations", function()
    test_workspace_project_discovery()
  end)

  test("active agent picker discovers running project terminals", function()
    test_active_agent_discovery(repo, worktree)
  end)

  test("agent picker replaces the visible repository agent window", function()
    test_agent_switch_replaces_visible_repo_buffer(repo, worktree)
  end)

  test("filetype refresh uses each target buffer context", function()
    test_filetype_refire_uses_target_buffer()
  end)

  test("lsp definition and references", function()
    test_lsp_definition_and_references(repo)
  end)

  test("lsp survives duplicate split close", function()
    test_lsp_survives_duplicate_split_close(repo)
  end)

  test("workspace root starts one gopls client per Go module", function()
    test_workspace_root_uses_one_gopls_per_module()
  end)

  test("lsp recursive incoming call graph", function()
    test_lsp_recursive_incoming_call_graph(repo)
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

  test("worktree switch hides files from the previous repository", function()
    test_worktree_switch_hides_foreign_file(repo, worktree)
  end)

  test("worktree switch restores repository jump history", function()
    test_worktree_switch_restores_repository_jumplist(repo, worktree)
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

  test("git diff repository bar from workspace root", function()
    test_git_diff_repository_bar_from_workspace_root()
  end)

  test("git diff separates commit and push for its selected repository", function()
    test_git_diff_separate_commit_and_push_from_workspace_root()
  end)

  test("git diff original file jump starts go runtime", function()
    test_git_diff_original_file_jump_starts_go_runtime(worktree)
  end)

  test("worktree switch restores agent terminal", function()
    test_worktree_switch_restores_agent_terminal(repo, worktree)
  end)

  test("git diff refresh preserves directory folds", function()
    test_git_diff_refresh_preserves_directory_folds(worktree)
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
