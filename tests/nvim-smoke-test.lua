local uv = vim.uv or vim.loop

local tests = {}
local terminal_io = require("luanphan.terminal.window")
local agent_socket_dir = assert(uv.fs_mkdtemp("/tmp/nvim-agent-tmux-XXXXXX"))
vim.env.LUANPHAN_AGENT_TMUX_SOCKET = agent_socket_dir .. "/main"

local function agent_socket(script)
  return agent_socket_dir .. "/" .. vim.fn.sha256(script):sub(1, 12)
end

local function cleanup_agent_servers()
  for name in vim.fs.dir(agent_socket_dir) do
    vim.system({ "tmux", "-S", agent_socket_dir .. "/" .. name, "kill-server" }):wait()
  end
  vim.fn.delete(agent_socket_dir, "rf")
end
local temp_root
local cleanup_fixture_id = 0
local project_scope_fixture_id = 0

local agent_cli_commands = {
  { name = "cursor", command = "cursor-agent", g_bufnr = "cursor_agent_bufnr" },
  { name = "claude", command = "claude", g_bufnr = "claude_agent_bufnr" },
  {
    name = "codex",
    command = "mcodex",
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

local function assert_nonrecursive_map(lhs, mode, bufnr)
  local map
  local function read_map()
    map = vim.fn.maparg(lhs, mode, false, true)
  end
  if bufnr then
    vim.api.nvim_buf_call(bufnr, read_map)
  else
    read_map()
  end
  assert_true(type(map) == "table" and map.noremap == 1, lhs .. " should be nonrecursive in " .. mode .. " mode")
end

local function rendered_winbar(win)
  win = win or vim.api.nvim_get_current_win()
  local format = vim.api.nvim_get_option_value("winbar", { win = win })
  return vim.api.nvim_eval_statusline(format, { winid = win, use_winbar = true, maxwidth = 10000 }).str
end

local function realpath(path)
  return uv.fs_realpath(path) or path
end

local function require_command(name, args)
  local out = vim.fn.systemlist(args)
  assert_true(vim.v.shell_error == 0, name .. " is required: " .. table.concat(out, "\n"))
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
  local env = "LUANPHAN_AGENT_TMUX_SOCKET=" .. vim.fn.shellescape(agent_socket(script)) .. " "
  if vim.env.XDG_CONFIG_HOME and vim.env.XDG_CONFIG_HOME ~= "" then
    env = env .. "XDG_CONFIG_HOME=" .. vim.fn.shellescape(vim.env.XDG_CONFIG_HOME) .. " "
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
  vim.g.luanphan_global_settings_path = temp_root .. "/global-settings.toml"
  vim.g.luanphan_run_actions_path = temp_root .. "/run-actions.json"

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

local function make_typescript_fixture(name, version)
  local repo = temp_root .. "/" .. name
  vim.fn.mkdir(repo .. "/src", "p")
  run({ "git", "init", "-b", "main" }, repo)
  write(repo .. "/package.json", {
    "{",
    string.format('  "name": "%s",', name),
    '  "private": true,',
    '  "devDependencies": {',
    string.format('    "typescript": "%s"', version),
    "  }",
    "}",
  })
  write(repo .. "/package-lock.json", { '{ "lockfileVersion": 3 }' })
  write(repo .. "/tsconfig.json", {
    "{",
    '  "compilerOptions": {',
    '    "module": "esnext",',
    '    "moduleResolution": "bundler",',
    '    "strict": true,',
    '    "target": "es2022"',
    "  },",
    '  "include": ["src"]',
    "}",
  })
  write(repo .. "/src/value.ts", {
    'export function targetValue(): string {',
    '  return "example";',
    "}",
  })
  write(repo .. "/src/main.ts", {
    'import { targetValue } from "./value";',
    "",
    "export const result = targetValue();",
  })
  return repo
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
      if client.name == "gopls" and client.initialized and not client:is_stopped() then
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

  for _, lhs in ipairs({ "gd", "gi", "gr", "gR", "gh", "<leader>cd", "<leader>ca" }) do
    assert_nonrecursive_map(lhs, "n", buf)
  end

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
  write(file, { '{"name":"example","items":[1,2]}' })
  vim.cmd("edit " .. vim.fn.fnameescape(file))
  vim.bo.filetype = "json"

  wait_until("json format keymap", function()
    local map = vim.fn.maparg("<leader>kf", "n", false, true)
    return type(map) == "table" and map.desc == "Format"
  end, 3000)

  vim.cmd("write")
  local lines = read_lines(file)
  assert_true(#lines > 1 and lines[1] == "{", "json buffers should format before write")
end

local function test_temporary_json_buffer_folds()
  vim.cmd("enew")
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "{",
    '  "items": [',
    "    {",
    '      "name": "example"',
    "    }",
    "  ]",
    "}",
  })
  vim.bo[buf].filetype = "json"

  wait_until("temporary JSON folds", function()
    return vim.treesitter.highlighter.active[buf] ~= nil and vim.fn.foldlevel(2) > 0
  end, 3000)
  assert_true(vim.wo.foldmethod == "expr", "temporary JSON buffer should use expression folds")
  vim.cmd("normal! zM")
  assert_true(vim.fn.foldclosed(2) ~= -1, "zM should close temporary JSON folds")
end

local function test_filetype_editor_options()
  local cases = {
    {
      file = temp_root .. "/filetype-options/main.go",
      lines = { "package main" },
      shiftwidth = 4,
      tabstop = 4,
      softtabstop = 4,
      expandtab = false,
    },
    {
      file = temp_root .. "/filetype-options/init.lua",
      lines = { "return {}" },
      shiftwidth = 2,
      tabstop = 2,
      softtabstop = 2,
      expandtab = true,
    },
  }

  for _, case in ipairs(cases) do
    write(case.file, case.lines)
    vim.cmd("edit " .. vim.fn.fnameescape(case.file))
    assert_true(vim.bo.shiftwidth == case.shiftwidth, case.file .. " shiftwidth is incorrect")
    assert_true(vim.bo.tabstop == case.tabstop, case.file .. " tabstop is incorrect")
    assert_true(vim.bo.softtabstop == case.softtabstop, case.file .. " softtabstop is incorrect")
    assert_true(vim.bo.expandtab == case.expandtab, case.file .. " expandtab is incorrect")
  end
end

local function test_markdown_browser_preview_keymap()
  local preview_map = vim.fn.maparg("<leader>fp", "n", false, true)
  local plugin = require("lazy.core.config").plugins["markdown-preview.nvim"]

  assert_true(type(plugin) == "table", "markdown-preview.nvim plugin should be registered")
  assert_true(type(preview_map) == "table" and preview_map.desc == "Preview file", "<leader>fp should preview files")
  assert_true(vim.fn.maparg("<leader>fP", "n") == "", "<leader>fP should be removed")
  require("lazy").load({ plugins = { "markdown-preview.nvim" } })
  assert_true(vim.g.mkdp_auto_start == 0, "browser Markdown preview should not auto-start")
  assert_true(vim.g.mkdp_auto_close == 0, "browser Markdown preview should remain open when its buffer is hidden")
  assert_true(vim.g.mkdp_refresh_slow == 0, "browser Markdown preview should auto-refresh content")
  assert_true(vim.g.mkdp_open_to_the_world == 0, "browser Markdown preview should stay local")
  assert_true(vim.g.mkdp_theme == "light", "browser Markdown preview should use light theme")
  assert_true(
    type(vim.g.mkdp_preview_options) == "table" and vim.g.mkdp_preview_options.disable_sync_scroll == 1,
    "browser Markdown preview should not sync-scroll"
  )
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
  local preview_file = read_lines(log)[1]
  assert_true(
    preview_file and realpath(preview_file) == realpath(csv),
    "csvlens should receive current CSV file: " .. vim.inspect(preview_file)
  )

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

local function test_git_remote_file_links()
  local repo = temp_root .. "/git-remote-link"
  local file = repo .. "/src/example.lua"
  vim.fn.mkdir(repo, "p")
  run({ "git", "init", "-b", "feature/example" }, repo)
  run({ "git", "config", "user.name", "Example User" }, repo)
  run({ "git", "config", "user.email", "example@example.invalid" }, repo)
  write(file, { "local value = 1", "return value" })
  run({ "git", "add", "." }, repo)
  run({ "git", "commit", "-m", "initial fixture" }, repo)
  run({ "git", "remote", "add", "origin", "https://github.com/example/example-repo.git" }, repo)

  local git_remote = require("luanphan.git_remote")
  local url, err = git_remote.url_for_file(file, 2)
  assert_true(err == nil, tostring(err))
  assert_true(
    url == "https://github.com/example/example-repo/blob/feature/example/src/example.lua#L2",
    "GitHub file URL is incorrect: " .. tostring(url)
  )

  run({ "git", "remote", "set-url", "origin", "git@git.example.invalid:group/example-repo.git" }, repo)
  url, err = git_remote.url_for_file(file, 2)
  assert_true(err == nil, tostring(err))
  assert_true(
    url == "https://git.example.invalid/group/example-repo/blob/feature/example/src/example.lua#L2",
    "custom git host file URL is incorrect: " .. tostring(url)
  )

  run({ "git", "remote", "set-url", "origin", "git@gitlab.example.invalid:group/example-repo.git" }, repo)
  url, err = git_remote.url_for_file(file, 2)
  assert_true(err == nil, tostring(err))
  assert_true(
    url == "https://gitlab.example.invalid/group/example-repo/-/blob/feature/example/src/example.lua#L2",
    "GitLab file URL is incorrect: " .. tostring(url)
  )

  local mapping = vim.fn.maparg("<leader>gr", "n", false, true)
  assert_true(type(mapping) == "table" and type(mapping.callback) == "function", "<leader>gr mapping is missing")
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

local function test_go_test_runs_from_nested_module()
  local workspace = temp_root .. "/go-test-workspace"
  local module = workspace .. "/example-module"
  local fake_bin = workspace .. "/bin"
  local other_workspace = temp_root .. "/go-test-other-workspace"
  local marker = workspace .. "/test-cwd"
  local script = workspace .. "/go-test-cwd.lua"
  vim.fn.mkdir(other_workspace, "p")

  write(module .. "/go.mod", {
    "module example.com/example-module",
    "",
    "go 1.21",
  })
  write(module .. "/example_test.go", {
    "package example",
    "",
    "func TestNestedModule() {}",
  })
  write_executable(fake_bin .. "/go", {
    "#!/bin/sh",
    "if [ \"$1\" = \"list\" ]; then",
    "  printf '%s\\n' 'example.com/example-module'",
    "  exit 0",
    "fi",
    "if [ \"$1\" = \"test\" ]; then",
    "  pwd > \"$GO_TEST_CWD_FILE\"",
    "  printf 'Go test output\\n'",
    "  exit 0",
    "fi",
    "exit 1",
  })
  write(script, {
    "local function assert_true(value, message) if not value then error(message, 0) end end",
    "vim.env.PATH = " .. string.format("%q", fake_bin) .. " .. ':' .. vim.env.PATH",
    "vim.env.GO_TEST_CWD_FILE = " .. string.format("%q", marker),
    "vim.cmd('cd ' .. vim.fn.fnameescape(" .. string.format("%q", workspace) .. "))",
    "vim.cmd('noautocmd edit ' .. vim.fn.fnameescape(" .. string.format("%q", module .. "/example_test.go") .. "))",
    "vim.api.nvim_win_set_cursor(0, { 3, 0 })",
    "local editor_buf = vim.api.nvim_get_current_buf()",
    "local go = require('luanphan.plugins.go')",
    "local terminal = require('luanphan.terminal')",
    "local original_cursor = go.run_go_test_at_cursor",
    "local original_file = go.run_go_test_file",
    "local original_package = go.run_go_test_package",
    "local dispatched = {}",
    "go.run_go_test_at_cursor = function() dispatched[#dispatched + 1] = 'cursor' end",
    "go.run_go_test_file = function() dispatched[#dispatched + 1] = 'file' end",
    "go.run_go_test_package = function() dispatched[#dispatched + 1] = 'package' end",
    "vim.bo[editor_buf].filetype = 'go'",
    "vim.api.nvim_exec_autocmds('FileType', { buffer = editor_buf })",
    "for _, lhs in ipairs({ '<leader>gtc', '<leader>gtf', '<leader>gtp' }) do",
    "  local map = vim.fn.maparg(lhs, 'n', false, true)",
    "  assert_true(type(map) == 'table' and type(map.callback) == 'function', lhs .. ' mapping is missing')",
    "  map.callback()",
    "end",
    "assert_true(table.concat(dispatched, ',') == 'cursor,file,package', 'Go test mappings dispatched incorrectly')",
    "go.run_go_test_at_cursor = original_cursor",
    "go.run_go_test_file = original_file",
    "go.run_go_test_package = original_package",
    "local original_run_command = terminal.run_command",
    "local commands = {}",
    "terminal.run_command = function(command) commands[#commands + 1] = command end",
    "go.run_go_test_file()",
    "go.run_go_test_package()",
    "terminal.run_command = original_run_command",
    "assert_true(commands[1]:find('test -timeout 30s example.com/example-module -count=1 -v', 1, true), 'Go file test command is wrong')",
    "assert_true(commands[2]:find('test -timeout 60s example.com/example-module/... -count=1 -v', 1, true), 'Go package test command is wrong')",
    "require('lazy').load({ plugins = { 'toggleterm.nvim' } })",
    "vim.fn.maparg('<leader>-t', 'n', false, true).callback()",
    "local shell_buf = vim.api.nvim_get_current_buf()",
    "vim.api.nvim_set_current_win(vim.fn.bufwinid(editor_buf))",
    "go.run_go_test_at_cursor()",
    "local test_buf = vim.api.nvim_get_current_buf()",
    "assert_true(test_buf ~= shell_buf and vim.b[test_buf].luanphan_persist_term, 'Go test did not create a persistent tab')",
    "assert_true(vim.uv.fs_realpath(vim.b[test_buf].luanphan_toggleterm_cwd) == vim.uv.fs_realpath(" .. string.format("%q", workspace) .. "), 'Go test tab was scoped to its package instead of workspace')",
    "assert_true(vim.api.nvim_eval_statusline(vim.wo.winbar, { use_winbar = true }).str:find('Go test', 1, true), 'Go test tab label is missing')",
    "assert_true(vim.wait(5000, function() return vim.fn.filereadable(" .. string.format("%q", marker) .. ") == 1 end, 50), 'Go test did not run')",
    "local cwd = vim.fn.readfile(" .. string.format("%q", marker) .. ")[1]",
    "assert_true(vim.uv.fs_realpath(cwd) == vim.uv.fs_realpath(" .. string.format("%q", module) .. "), 'Go test ran from ' .. tostring(cwd))",
    "local job = vim.b[test_buf].terminal_job_id",
    "assert_true(vim.wait(5000, function() return vim.fn.jobwait({ job }, 0)[1] ~= -1 end, 50), 'Go test did not finish')",
    "vim.cmd('stopinsert')",
    "vim.fn.maparg('<Tab>', 'n', false, true).callback()",
    "assert_true(vim.api.nvim_get_current_buf() == shell_buf, 'Go test replaced the shell tab')",
    "vim.fn.maparg('<Tab>', 'n', false, true).callback()",
    "assert_true(vim.api.nvim_get_current_buf() == test_buf, 'completed Go test tab is inaccessible')",
    "vim.api.nvim_set_current_win(vim.fn.bufwinid(editor_buf))",
    "vim.keymap.set('n', '<leader>-t', function() error('stale terminal mapping') end)",
    "vim.fn.maparg('<leader>src', 'n', false, true).callback()",
    "local toggle = vim.fn.maparg('<leader>-t', 'n', false, true).callback",
    "go.run_go_test_at_cursor()",
    "local second_test = vim.api.nvim_get_current_buf()",
    "assert_true(second_test ~= test_buf and vim.b[second_test].luanphan_toggleterm, 'second Go test did not open its own tab')",
    "local second_job = vim.b[second_test].terminal_job_id",
    "assert_true(vim.wait(5000, function() return vim.fn.jobwait({ second_job }, 0)[1] ~= -1 end, 50), 'second Go test did not finish')",
    "vim.fn.maparg('<S-Tab>', 'n', false, true).callback()",
    "assert_true(vim.api.nvim_get_current_buf() == test_buf, 'config reload split the Go tests into separate panels')",
    "vim.fn.maparg('<Tab>', 'n', false, true).callback()",
    "toggle()",
    "assert_true(vim.fn.bufwinid(second_test) == -1 and vim.fn.bufwinid(test_buf) == -1, 'terminal toggle left a second dock visible')",
    "toggle()",
    "assert_true(vim.api.nvim_get_current_buf() == second_test, 'terminal toggle lost the most recent command tab')",
    "require('lazy').load({ plugins = { 'luanphan-worktree' } })",
    "_G._luanphan_wt_test.switch_to(" .. string.format("%q", other_workspace) .. ")",
    "assert_true(vim.fn.bufwinid(second_test) == -1 and vim.api.nvim_buf_is_valid(test_buf), 'workspace switch leaked the panel or deleted Go test output')",
    "toggle()",
    "local other_shell = vim.api.nvim_get_current_buf()",
    "assert_true(vim.b[other_shell].luanphan_toggleterm and other_shell ~= shell_buf and other_shell ~= second_test, 'second workspace used the first workspace terminal')",
    "_G._luanphan_wt_test.switch_to(" .. string.format("%q", workspace) .. ")",
    "assert_true(vim.wait(5000, function() return vim.fn.bufwinid(second_test) ~= -1 end, 50), 'last Go test tab did not reopen after returning')",
    "assert_true(vim.fn.bufwinid(other_shell) == -1, 'second workspace terminal leaked into the first')",
    "for _, buf in ipairs({ test_buf, second_test }) do",
    "  assert_true(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\\n'):find('Go test output', 1, true), 'Go test output was lost')",
    "end",
    "toggle()",
    "_G._luanphan_wt_test.switch_to(" .. string.format("%q", other_workspace) .. ")",
    "assert_true(vim.wait(5000, function() return vim.fn.bufwinid(other_shell) ~= -1 end, 50), 'second workspace lost its shell')",
    "_G._luanphan_wt_test.switch_to(" .. string.format("%q", workspace) .. ")",
    "assert_true(vim.fn.bufwinid(second_test) == -1, 'workspace reopened a manually hidden panel')",
    "toggle()",
    "assert_true(vim.api.nvim_get_current_buf() == second_test, 'manually hidden terminal lost its selected tab')",
  })

  local cmd = child_nvim_luafile_command(workspace, script)
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

local function close_toggleterm_terminals()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.b[buf].luanphan_toggleterm then
      for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        pcall(vim.api.nvim_win_close, win, true)
      end
      local job = vim.b[buf].terminal_job_id
      if type(job) == "number" and job > 0 then
        pcall(vim.fn.jobstop, job)
      end
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
end

local function visible_agent_window_count()
  local count = 0
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].buftype == "terminal" and vim.b[buf].luanphan_persist_term and not vim.b[buf].luanphan_toggleterm then
      count = count + 1
    end
  end
  return count
end

local function assert_agent_float(win, label)
  local config = vim.api.nvim_win_get_config(win)
  assert_true(config.relative == "editor", label .. " is not an editor-relative float")
end

local function terminal_grid_size(bufnr)
  local pane = vim.b[bufnr].luanphan_agent_tmux_pane
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

local function close_agent_terminals()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) then
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.bo[buf].buftype == "terminal" and vim.b[buf].luanphan_persist_term then
        pcall(vim.api.nvim_win_close, win, true)
      end
    end
  end

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == "terminal" and vim.b[buf].luanphan_persist_term then
      pcall(terminal_io.stop, buf)
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
  assert_true(type(map) == "table", lhs .. " mapping is missing")
  if type(map.callback) == "function" then
    map.callback()
    return
  end
  assert_true(type(map.rhs) == "string" and map.rhs ~= "", lhs .. " mapping has no executable target")
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(map.rhs, true, false, true), "xt", false)
end

local function registered_agent_bufnrs(global_name, cwd)
  local stored = vim.g[global_name]
  if type(stored) ~= "table" then return {} end
  cwd = cwd and realpath(cwd)
  local result = {}
  for path, bufnrs in pairs(stored) do
    if not cwd or realpath(path) == cwd then vim.list_extend(result, bufnrs) end
  end
  return result
end

local function agent_bufnr(global_name)
  local candidates = registered_agent_bufnrs(global_name, vim.fn.getcwd())
  if #candidates == 0 then
    candidates = registered_agent_bufnrs(global_name)
  end

  local selected = nil
  local selected_sequence = -1
  for _, bufnr in ipairs(candidates) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      local sequence = tonumber(vim.b[bufnr].luanphan_agent_last_used) or 0
      if sequence > selected_sequence then
        selected = bufnr
        selected_sequence = sequence
      end
    end
  end
  return selected
end

local function feed_normal(keys)
  -- Earlier terminal input can change mode when queued keys are processed.
  keys = "<C-\\><C-n>" .. keys
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

local function test_buffer_only_keeps_current_and_special_buffers()
  local terminal, job
  local special_buffers = {
    { filetype = "NvimTree", buftype = "nofile" },
    { filetype = "help", buftype = "help" },
    { filetype = "qf", buftype = "quickfix" },
  }
  local ok, err = xpcall(function()
    reset_window_layout()
    local first = temp_root .. "/buffer-only/first.txt"
    local second = temp_root .. "/buffer-only/second.txt"
    write(first, { "first" })
    write(second, { "second" })

    vim.cmd("edit " .. vim.fn.fnameescape(first))
    local current = vim.api.nvim_get_current_buf()
    vim.cmd("badd " .. vim.fn.fnameescape(second))
    local other = vim.fn.bufnr(second)
    vim.cmd("botright new")
    terminal = vim.api.nvim_get_current_buf()
    job = vim.fn.termopen({ "sh", "-c", "sleep 30" })
    vim.cmd("wincmd p")
    vim.wait(50)

    for _, special in ipairs(special_buffers) do
      special.buf = vim.api.nvim_create_buf(true, true)
      vim.bo[special.buf].buftype = special.buftype
      vim.bo[special.buf].filetype = special.filetype
    end

    invoke_map("<leader>kw")
    assert_true(vim.api.nvim_buf_is_valid(current), "buffer-only should keep the current file")
    assert_true(not vim.api.nvim_buf_is_valid(other), "buffer-only should close another listed file")
    assert_true(vim.api.nvim_buf_is_valid(terminal), "buffer-only should keep terminal buffers")
    for _, special in ipairs(special_buffers) do
      assert_true(
        vim.api.nvim_buf_is_valid(special.buf),
        "buffer-only should keep " .. special.filetype .. " buffers"
      )
    end
  end, debug.traceback)

  if job then pcall(vim.fn.jobstop, job) end
  if terminal and vim.api.nvim_buf_is_valid(terminal) then
    pcall(vim.api.nvim_buf_delete, terminal, { force = true })
  end
  for _, special in ipairs(special_buffers) do
    if special.buf and vim.api.nvim_buf_is_valid(special.buf) then
      pcall(vim.api.nvim_buf_delete, special.buf, { force = true })
    end
  end
  reset_window_layout()
  assert_true(ok, tostring(err))
end

local function test_only_keep_tree_closes_other_windows()
  local current
  local sibling
  local tree
  local tree_buf
  local ok, err = xpcall(function()
    reset_window_layout()
    vim.cmd("enew")
    current = vim.api.nvim_get_current_win()
    vim.cmd("vsplit")
    sibling = vim.api.nvim_get_current_win()
    vim.cmd("split")
    tree = vim.api.nvim_get_current_win()
    tree_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[tree_buf].filetype = "NvimTree"
    vim.api.nvim_win_set_buf(tree, tree_buf)
    vim.api.nvim_set_current_win(current)

    invoke_map("<C-w>o")

    assert_true(vim.api.nvim_win_is_valid(current), "only-keep-tree closed the current window")
    assert_true(vim.api.nvim_win_is_valid(tree), "only-keep-tree closed the tree window")
    assert_true(not vim.api.nvim_win_is_valid(sibling), "only-keep-tree preserved an ordinary sibling")
    assert_true(#vim.api.nvim_tabpage_list_wins(0) == 2, "only-keep-tree left unexpected windows")

    local alternate = vim.fn.maparg("<C-w><C-o>", "n", false, true)
    assert_true(
      type(alternate) == "table" and type(alternate.callback) == "function",
      "alternate only-keep-tree mapping is missing"
    )
  end, debug.traceback)

  if current and vim.api.nvim_win_is_valid(current) then
    vim.api.nvim_set_current_win(current)
  end
  reset_window_layout()
  if tree_buf and vim.api.nvim_buf_is_valid(tree_buf) then
    vim.api.nvim_buf_delete(tree_buf, { force = true })
  end
  assert_true(ok, tostring(err))
end

local function test_word_wrap_keymaps_respect_window_scope()
  local old_wrap = vim.wo.wrap

  local ok, err = xpcall(function()
    reset_window_layout()
    vim.cmd("enew")
    vim.cmd("vsplit")
    vim.cmd("split")
    vim.cmd("tabnew")
    vim.cmd("vsplit")

    set_all_windows_wrap(false)
    invoke_map("<leader>-W")
    assert_all_windows_wrap(true)

    vim.cmd("split")
    assert_true(vim.wo.wrap == true, "new split should inherit enabled wrap")

    invoke_map("<leader>-W")
    assert_all_windows_wrap(false)

    reset_window_layout()
    vim.cmd("edit " .. vim.fn.fnameescape(temp_root .. "/example-repo/main.go"))
    require("lazy").load({ plugins = { "gitsigns.nvim" } })
    wait_until("Gitsigns word diff mapping", function()
      local map = vim.fn.maparg("<leader>-D", "n", false, true)
      return type(map) == "table" and type(map.callback) == "function"
    end, 3000)

    local sibling = vim.api.nvim_get_current_win()
    vim.cmd("vsplit")
    local focused = vim.api.nvim_get_current_win()
    vim.wo[sibling].wrap = false
    vim.wo[focused].wrap = false

    invoke_map("<leader>-w")
    assert_true(vim.wo[focused].wrap, "focused window wrap should be enabled")
    assert_true(not vim.wo[sibling].wrap, "sibling window wrap should remain disabled")

    invoke_map("<leader>-w")
    assert_true(not vim.wo[focused].wrap, "focused window wrap should be disabled")
    assert_true(not vim.wo[sibling].wrap, "sibling window wrap should remain disabled")
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

local function test_terminal_normal_mode_shows_shortcuts()
  require("lazy").load({ plugins = { "which-key.nvim" }, wait = true })
  local config = require("which-key.config")
  if not config.loaded then
    vim.api.nvim_exec_autocmds("VimEnter", {})
  end
  assert_true(vim.wait(1000, function()
    return config.loaded == true
  end), "which-key did not finish loading")

  local original_buf = vim.api.nvim_get_current_buf()
  local terminal_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(terminal_buf)
  vim.fn.termopen({ "sh", "-c", "sleep 30" })
  vim.cmd("stopinsert")

  local normal_map
  local terminal_map
  assert_true(vim.wait(1000, function()
    vim.api.nvim_buf_call(terminal_buf, function()
      normal_map = vim.fn.maparg("<Space>", "n", false, true)
      terminal_map = vim.fn.maparg("<Space>", "t", false, true)
    end)
    return type(normal_map.callback) == "function"
  end), "which-key did not attach its terminal normal-mode trigger")
  assert_true(
    type(normal_map.desc) == "string" and normal_map.desc:find("which%-key%-trigger") ~= nil,
    "terminal normal mode should use a supported which-key trigger"
  )
  assert_true(vim.tbl_isempty(terminal_map), "terminal input mode should pass Space to the terminal")

  local state = require("which-key.state")
  local original_start = state.start
  local started = false
  state.start = function(opts)
    started = opts.keys == "<Space>"
    return true
  end
  normal_map.callback()
  state.start = original_start
  assert_true(started, "terminal normal mode Space did not start which-key")

  local job = vim.b[terminal_buf].terminal_job_id
  vim.api.nvim_set_current_buf(original_buf)
  if type(job) == "number" and job > 0 then
    pcall(vim.fn.jobstop, job)
    pcall(vim.fn.jobwait, { job }, 1000)
  end
  vim.api.nvim_buf_delete(terminal_buf, { force = true })
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
  for _, mapping in ipairs({
    { "<leader>wf", "n" },
    { "<leader>wd", "n" },
    { "<leader>wr", "n" },
    { "<leader>wp", "n" },
    { "<leader>wa", "n" },
  }) do
    local map = vim.fn.maparg(mapping[1], mapping[2], false, true)
    assert_true(type(map) == "table" and type(map.callback) == "function", mapping[1] .. " was lost after lazy load")
    assert_true(vim.fn.maparg(mapping[1], "t") == "", mapping[1] .. " intercepts terminal typing after lazy load")
  end
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
  assert_true(
    vim.fn.maparg("<leader>wr", "t") == "",
    "<leader>wr intercepts terminal typing before lazy load"
  )
  local window_map = vim.fn.maparg("<leader>ww", "n", false, true)
  assert_true(
    type(window_map) == "table" and type(window_map.callback) == "function" and window_map.desc == "Switch window",
    "<leader>ww did not register the window picker"
  )
  local folder_map = vim.fn.maparg("<leader>wf", "n", false, true)
  assert_true(
    type(folder_map) == "table" and type(folder_map.callback) == "function",
    "<leader>wf is not a lazy callback mapping"
  )
  local global_settings_map = vim.fn.maparg("<leader>sg", "n", false, true)
  assert_true(
    type(global_settings_map) == "table" and type(global_settings_map.callback) == "function",
    "<leader>sg is not a lazy callback mapping"
  )
  local add_repository_map = vim.fn.maparg("<leader>wa", "n", false, true)
  assert_true(
    type(add_repository_map) == "table" and type(add_repository_map.callback) == "function"
      and add_repository_map.desc == "Add repository",
    "<leader>wa did not register the Add Repository picker"
  )
  local remove_repository_map = vim.fn.maparg("<leader>wd", "n", false, true)
  assert_true(
    type(remove_repository_map) == "table" and type(remove_repository_map.callback) == "function",
    "<leader>wd is not a lazy callback mapping"
  )
  assert_true(vim.fn.maparg("<leader>gP", "n") == "", "<leader>gP should not have a duplicate project picker")
  assert_true(vim.fn.exists(":AgentSwitch") == 0, "the old agent picker command is still registered")
  for _, old_lhs in ipairs({ "<leader>gp", "<leader>gw", "<leader>g;", "<leader>w;", "<leader>wA" }) do
    assert_true(vim.fn.maparg(old_lhs, "n") == "", old_lhs .. " workspace mapping should be removed")
  end
end

local function test_worktree_keymaps_dispatch_to_pickers()
  local worktree = worktree_test_api()
  for _, mapping in ipairs({
    { "<leader>wf", "n", "pick_folder" },
    { "<leader>wa", "n", "pick_add_repository" },
    { "<leader>wd", "n", "pick_remove_repository" },
    { "<leader>wr", "n", "pick_project" },
    { "<leader>wp", "n", "pick_workspace_project" },
  }) do
    local method = mapping[3]
    local original = worktree[method]
    local called = false
    worktree[method] = function()
      called = true
    end
    local map = vim.fn.maparg(mapping[1], mapping[2], false, true)
    local ok, err = pcall(map.callback)
    worktree[method] = original
    assert_true(ok, mapping[1] .. " failed: " .. tostring(err))
    assert_true(called, mapping[1] .. " did not dispatch to " .. method)
  end
end

local function test_telescope_keymaps_dispatch_to_modules()
  require("lazy").load({ plugins = { "telescope.nvim" } })
  for _, mapping in ipairs({
    { "<leader>ff", require("luanphan.telescope_find_opts").find_files },
    { "<leader>p", require("luanphan.telescope_find_opts").find_files },
    { "g/", require("luanphan.telescope_grep_opts").live_grep },
    { "<leader>sg", require("luanphan.global_settings").open_editor },
    { "<leader>ss", require("luanphan.search_priority").open_editor },
  }) do
    local map = vim.fn.maparg(mapping[1], "n", false, true)
    assert_true(map.callback == mapping[2], mapping[1] .. " does not use its target function directly")
  end
  local buffers_map = vim.fn.maparg("<leader>fl", "n", false, true)
  assert_true(buffers_map.rhs == "<cmd>Telescope buffers<cr>", "<leader>fl does not run Telescope buffers")
end

local function test_run_actions(repo)
  require("lazy").load({ plugins = { "luanphan-actions", "telescope.nvim" } })
  local run_actions = require("luanphan.run_actions")
  local config_path = vim.g.luanphan_run_actions_path
  local original_cwd = vim.fn.getcwd()
  local original_buf = vim.api.nvim_get_current_buf()
  vim.fn.delete(config_path)

  local defaults = run_actions.read()
  assert_true(vim.fn.filereadable(config_path) == 1, "run action config was not created")
  assert_true(#defaults == 1 and defaults[1].cmd == "python3", "run action config has the wrong default")
  assert_true(
    vim.deep_equal(defaults[1].args, { "{{FILE_NAME}}" }),
    "run action config does not pass the current file"
  )

  local script = repo .. "/nested folder/example script.py"
  write(script, { "print('ok')" })
  vim.cmd("cd " .. vim.fn.fnameescape(repo))
  vim.cmd("edit " .. vim.fn.fnameescape(script))
  local current_file = vim.api.nvim_buf_get_name(0)

  local terminal = require("luanphan.terminal")
  local original_run_command = terminal.run_command
  local execution
  terminal.run_command = function(command, cwd, label)
    execution = { command = command, cwd = cwd, label = label }
  end
  run_actions.run({
    name = "Run current script",
    cmd = "python3",
    args = { "{{FILE_NAME}}", "--mode", "quick" },
  })
  terminal.run_command = original_run_command
  vim.api.nvim_set_current_buf(original_buf)
  vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))

  assert_true(execution ~= nil, "run action did not execute in a terminal")
  assert_true(realpath(execution.cwd) == realpath(repo), "run action used the wrong working directory")
  assert_true(execution.label == "Run current script", "run action used the wrong terminal label")
  assert_true(
    execution.command:find(vim.fn.shellescape(current_file), 1, true) ~= nil,
    "run action did not expand FILE_NAME to the nested current file"
  )

  close_toggleterm_terminals()
  vim.cmd("cd " .. vim.fn.fnameescape(repo))
  vim.cmd("edit " .. vim.fn.fnameescape(script))
  run_actions.run({
    name = "Run action output",
    cmd = "/bin/sh",
    args = { "-c", "printf 'run-action-output\\n'" },
  })
  local action_buf = vim.api.nvim_get_current_buf()
  assert_true(vim.b[action_buf].luanphan_toggleterm, "run action did not open in the terminal container")
  assert_true(rendered_winbar():find("Run action output", 1, true), "run action terminal tab label is missing")
  wait_until("run action terminal output", function()
    return table.concat(vim.api.nvim_buf_get_lines(action_buf, 0, -1, false), "\n")
      :find("run-action-output", 1, true) ~= nil
  end, 3000)
  close_toggleterm_terminals()
  vim.api.nvim_set_current_buf(original_buf)
  vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))

  vim.fn.writefile({ vim.json.encode({
    name = "Single action",
    cmd = "python3",
    args = { "{{FILE_NAME}}" },
  }) }, config_path)
  local configured = run_actions.read()
  assert_true(#configured == 1 and configured[1].name == "Single action", "single run action object was not accepted")

  local picker_test = temp_root .. "/run-action-picker.lua"
  write(picker_test, {
    "local function assert_true(value, message) if not value then error(message, 0) end end",
    "vim.g.luanphan_run_actions_path = " .. string.format("%q", config_path),
    "require('lazy').load({ plugins = { 'luanphan-actions', 'telescope.nvim' } })",
    "require('luanphan.run_actions').pick()",
    "local prompt_buf = vim.api.nvim_get_current_buf()",
    "assert_true(vim.bo[prompt_buf].filetype == 'TelescopePrompt', 'run action picker did not open')",
    "local prompt_win = vim.api.nvim_get_current_win()",
    "local results_win = -1",
    "for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do",
    "  if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].filetype == 'TelescopeResults' then",
    "    results_win = vim.fn.bufwinid(bufnr)",
    "    if results_win ~= -1 then break end",
    "  end",
    "end",
    "assert_true(vim.api.nvim_win_get_width(prompt_win) < vim.o.columns * 0.4, 'run action picker is too wide')",
    "assert_true(results_win ~= -1, 'run action picker results did not open')",
    "assert_true(vim.api.nvim_win_get_height(results_win) < vim.o.lines * 0.4, 'run action picker is too tall')",
    "require('telescope.actions').close(prompt_buf)",
  })
  local picker_output = vim.fn.systemlist(child_nvim_luafile_command(repo, picker_test))
  assert_true(vim.v.shell_error == 0, table.concat(picker_output, "\n"))

  local settings_editor = require("luanphan.settings_editor")
  local original_open = settings_editor.open
  local editor
  settings_editor.open = function(path, opts)
    editor = { path = path, opts = opts }
  end
  run_actions.open_editor()
  settings_editor.open = original_open
  assert_true(editor and editor.path == config_path, "run action editor opened the wrong file")
  assert_true(editor.opts.filetype == "json", "run action editor did not use JSON")

  local picked = false
  local configured_opened = false
  local original_pick = run_actions.pick
  local original_open_editor = run_actions.open_editor
  run_actions.pick = function()
    picked = true
  end
  run_actions.open_editor = function()
    configured_opened = true
  end
  local run_map = vim.fn.maparg("<leader>rr", "n", false, true)
  local config_map = vim.fn.maparg("<leader>rc", "n", false, true)
  run_map.callback()
  config_map.callback()
  run_actions.pick = original_pick
  run_actions.open_editor = original_open_editor
  assert_true(picked, "<leader>rr did not open the run action picker")
  assert_true(configured_opened, "<leader>rc did not open the run action config")

  local reload_map = vim.fn.maparg("<leader>src", "n", false, true)
  assert_true(type(reload_map) == "table" and reload_map.desc == "Config", "config restart did not move to <leader>src")
end

local function test_editor_runtime_defaults()
  require("lazy").load({ plugins = { "which-key.nvim" } })
  assert_true(vim.o.timeout, "mapped-sequence timeout should be enabled")
  assert_true(vim.o.timeoutlen == 300, "mapped-sequence timeout should be 300ms")
  assert_true(not vim.o.backup, "backup files should be disabled")
  assert_true(vim.o.hlsearch, "search matches should stay highlighted")
  assert_true(vim.o.incsearch, "searches should update incrementally")
  assert_true(vim.o.laststatus == 2, "the statusline should follow the multi-window default")

  for _, lhs in ipairs({ "n", "N", "<C-d>", "<C-u>", "J", "<C-h>", "<C-j>", "<C-k>", "<C-l>" }) do
    assert_nonrecursive_map(lhs, "n")
  end

  local original_buf = vim.api.nvim_get_current_buf()
  local source_buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(source_buf, temp_root .. "/new-buffer-source.txt")
  vim.api.nvim_set_current_buf(source_buf)
  invoke_map("<leader>fn")
  local new_buf = vim.api.nvim_get_current_buf()
  assert_true(new_buf ~= source_buf, "<leader>fn did not create a new buffer")
  assert_true(vim.api.nvim_buf_get_name(new_buf) == "", "<leader>fn created a named buffer")
  vim.api.nvim_set_current_buf(original_buf)
  vim.api.nvim_buf_delete(new_buf, { force = true })
  vim.api.nvim_buf_delete(source_buf, { force = true })

  local editor_win = vim.api.nvim_get_current_win()
  local editor_buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(editor_buf)
  vim.cmd("vsplit")
  local tree_win = vim.api.nvim_get_current_win()
  local tree_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(tree_win, tree_buf)
  vim.bo[tree_buf].filetype = "NvimTree"
  local window_count = #vim.api.nvim_tabpage_list_wins(0)

  invoke_map("<leader>fn")
  local tree_new_buf = vim.api.nvim_get_current_buf()
  assert_true(vim.api.nvim_get_current_win() == editor_win, "<leader>fn did not leave NvimTree for the editor window")
  assert_true(tree_new_buf ~= editor_buf, "<leader>fn did not create a buffer from NvimTree")
  assert_true(vim.api.nvim_buf_get_name(tree_new_buf) == "", "<leader>fn created a named buffer from NvimTree")
  assert_true(#vim.api.nvim_tabpage_list_wins(0) == window_count, "<leader>fn opened an extra editor window")
  assert_true(vim.api.nvim_win_get_buf(tree_win) == tree_buf, "<leader>fn replaced the NvimTree buffer")

  vim.api.nvim_set_current_buf(original_buf)
  vim.api.nvim_win_close(tree_win, true)
  vim.api.nvim_buf_delete(tree_new_buf, { force = true })
  vim.api.nvim_buf_delete(tree_buf, { force = true })
  vim.api.nvim_buf_delete(editor_buf, { force = true })

  vim.cmd("tabnew")
  local tree_only_tab = vim.api.nvim_get_current_tabpage()
  local tree_only_win = vim.api.nvim_get_current_win()
  local tree_only_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(tree_only_win, tree_only_buf)
  vim.bo[tree_only_buf].filetype = "NvimTree"

  invoke_map("<leader>fn")
  local only_tree_new_buf = vim.api.nvim_get_current_buf()
  assert_true(vim.api.nvim_get_current_tabpage() == tree_only_tab, "<leader>fn left the NvimTree tab")
  assert_true(vim.api.nvim_get_current_win() ~= tree_only_win, "<leader>fn reused the only NvimTree window")
  assert_true(vim.api.nvim_win_get_buf(tree_only_win) == tree_only_buf, "<leader>fn replaced the only NvimTree buffer")
  assert_true(#vim.api.nvim_tabpage_list_wins(tree_only_tab) == 2, "<leader>fn did not create an editor window")
  assert_true(vim.api.nvim_buf_get_name(only_tree_new_buf) == "", "<leader>fn created a named buffer beside NvimTree")

  vim.cmd("tabclose!")
  vim.api.nvim_buf_delete(only_tree_new_buf, { force = true })
  vim.api.nvim_buf_delete(tree_only_buf, { force = true })
end

local function test_editor_text_helpers()
  local original_buf = vim.api.nvim_get_current_buf()
  local buf = vim.api.nvim_create_buf(false, true)

  local ok, err = xpcall(function()
    vim.api.nvim_set_current_buf(buf)
    vim.bo[buf].filetype = "lua"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "local value = 1" })
    vim.api.nvim_feedkeys("gcc", "xt", false)
    assert_true(vim.api.nvim_get_current_line() == "-- local value = 1", "gcc did not comment the current line")

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.api.nvim_feedkeys("i(" .. vim.keycode("<Esc>"), "xt", false)
    assert_true(vim.api.nvim_get_current_line() == "()", "autopairs did not close the opening parenthesis")
  end, debug.traceback)

  if vim.api.nvim_buf_is_valid(original_buf) then
    vim.api.nvim_set_current_buf(original_buf)
  end
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  assert_true(ok, tostring(err))
end

local function test_ctrl_f_uses_native_navigation()
  local original_buf = vim.api.nvim_get_current_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  local lines = {}
  for line = 1, 200 do
    lines[line] = "line " .. line
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  local ok, err = xpcall(function()
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.api.nvim_feedkeys(vim.keycode("<C-f>"), "xt", false)
    assert_true(vim.api.nvim_win_get_cursor(0)[1] > 1, "Ctrl-F did not use native page-forward navigation")
  end, debug.traceback)

  if vim.api.nvim_buf_is_valid(original_buf) then
    vim.api.nvim_set_current_buf(original_buf)
  end
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  assert_true(ok, tostring(err))
end

local function test_telescope_runtime_defaults()
  require("lazy").load({ plugins = { "telescope.nvim" } })
  local config = require("telescope.config")
  local sorter = config.values.file_sorter({})
  local exact_score = sorter.scoring_function(sorter, "main.lua", "main.lua")
  local loose_score = sorter.scoring_function(sorter, "main.lua", "src/example_main.lua")
  local missing_score = sorter.scoring_function(sorter, "main.lua", "README.md")
  assert_true(exact_score < loose_score, "file sorter did not rank the exact match first")
  assert_true(missing_score < 0, "file sorter did not discard a missing match")

  local picker = require("telescope.pickers").new(vim.deepcopy(config.pickers.find_files), {
    finder = function() end,
    sorter = sorter,
  })
  local scored = {}
  picker._find_id = 1
  picker.sorter = {
    score = function(_, _, entry)
      scored[#scored + 1] = entry.value
    end,
  }
  local process = picker:get_result_processor(1, "", function() end)
  process({ value = ".git/config", filename = ".git/config", ordinal = ".git/config" })
  process({ value = "src/main.lua", filename = "src/main.lua", ordinal = "src/main.lua" })
  assert_true(#scored == 1 and scored[1] == "src/main.lua", "find-files picker did not inherit the global .git filter")
end

local function test_gitignore_toggle_updates_telescope()
  local script = temp_root .. "/gitignore-toggle-smoke.lua"
  write(script, {
    "local function assert_true(value, message)",
    "  if not value then error(message, 0) end",
    "end",
    "require('lazy').load({ plugins = { 'telescope.nvim', 'luanphan-actions' } })",
    "local tree_toggles = 0",
    "local tree_reloads = 0",
    "package.loaded['nvim-tree.api'] = {",
    "  tree = {",
    "    toggle_gitignore_filter = function() tree_toggles = tree_toggles + 1 end,",
    "    reload = function() tree_reloads = tree_reloads + 1 end,",
    "  },",
    "}",
    "local map = vim.fn.maparg('<leader>-g', 'n', false, true)",
    "assert_true(type(map) == 'table' and type(map.callback) == 'function', 'gitignore toggle mapping is missing')",
    "map.callback()",
    "local config = require('telescope.config')",
    "assert_true(vim.tbl_contains(config.values.vimgrep_arguments, '--no-ignore'), 'ignored grep results stayed hidden')",
    "assert_true(vim.tbl_contains(config.pickers.find_files.find_command, '--no-ignore'), 'ignored files stayed hidden')",
    "map.callback()",
    "assert_true(not vim.tbl_contains(config.values.vimgrep_arguments, '--no-ignore'), 'ignored grep filtering was not restored')",
    "assert_true(not vim.tbl_contains(config.pickers.find_files.find_command, '--no-ignore'), 'ignored file filtering was not restored')",
    "assert_true(tree_toggles == 2, 'nvim-tree filter was not toggled twice')",
    "assert_true(tree_reloads == 2, 'nvim-tree was not reloaded twice')",
  })

  local out = vim.fn.systemlist(child_nvim_luafile_command(vim.fn.getcwd(), script))
  assert_true(vim.v.shell_error == 0, table.concat(out, "\n"))
end

local function test_nvim_tree_hides_dotfiles()
  local config = require("nvim-tree.config").g_clone()
  assert_true(config and config.filters.dotfiles == true, "nvim-tree should hide dotfiles")
  assert_true(
    vim.deep_equal(config.actions.open_file.window_picker.exclude.buftype, { "nofile", "terminal", "help" }),
    "nvim-tree should keep non-file windows out of the file picker"
  )
  assert_nonrecursive_map("<leader>e", "n")
end

local function test_nvim_tree_keeps_width_with_terminal(repo)
  local tree_api = require("nvim-tree.api")
  local original_columns = vim.o.columns
  local original_cwd = vim.fn.getcwd()
  local original_tab = vim.api.nvim_get_current_tabpage()
  local test_tab

  local ok, err = xpcall(function()
    vim.o.columns = 120
    vim.cmd("tabnew")
    test_tab = vim.api.nvim_get_current_tabpage()
    vim.cmd("cd " .. vim.fn.fnameescape(repo))
    vim.cmd("edit " .. vim.fn.fnameescape(repo .. "/main.go"))
    local editor_win = vim.api.nvim_get_current_win()
    tree_api.tree.open({ path = repo, focus = false })
    tree_api.tree.change_root(repo)
    local tree_win = tree_api.tree.winid()
    assert_true(tree_win and vim.api.nvim_win_is_valid(tree_win), "workspace tree did not open")

    vim.api.nvim_win_close(editor_win, true)
    invoke_map("<leader>fn")
    wait_until("tree width after editor split", function()
      return vim.api.nvim_win_is_valid(tree_win) and vim.api.nvim_win_get_width(tree_win) == 40
    end, 3000)
    vim.wo.winfixwidth = true
    vim.wo.winfixheight = true

    require("lazy").load({ plugins = { "toggleterm.nvim" } })
    invoke_map("<leader>-t")
    wait_until("tree width beside narrow terminal", function()
      return visible_toggleterm_window_count() == 1
        and vim.api.nvim_win_is_valid(tree_win)
        and vim.api.nvim_win_get_width(tree_win) == 40
    end, 3000)
  end, debug.traceback)

  close_toggleterm_terminals()
  if test_tab and vim.api.nvim_tabpage_is_valid(test_tab) then
    vim.api.nvim_set_current_tabpage(test_tab)
    tree_api.tree.close()
    vim.cmd("tabclose!")
  end
  if vim.api.nvim_tabpage_is_valid(original_tab) then
    vim.api.nvim_set_current_tabpage(original_tab)
  end
  vim.o.columns = original_columns
  if vim.fn.isdirectory(original_cwd) == 1 then
    vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
  end
  assert_true(ok, tostring(err))
end

local function test_dependency_tree_keeps_workspace_tree(repo)
  local tree_api = require("nvim-tree.api")
  local original_cwd = vim.fn.getcwd()
  local external_file = temp_root .. "/external-module/package/dependency.go"
  local external_sibling = temp_root .. "/external-module/package/sibling.go"
  write(external_file, { "package dependency" })
  write(external_sibling, { "package dependency" })
  local dependency_buf
  local ok, err = xpcall(function()
    vim.cmd("cd " .. vim.fn.fnameescape(repo))
    tree_api.tree.open({ path = repo, focus = false })
    tree_api.tree.change_root(repo)
    local main_tree_win = tree_api.tree.winid()
    assert_true(main_tree_win and vim.api.nvim_win_is_valid(main_tree_win), "workspace tree did not open")

    vim.cmd("edit " .. vim.fn.fnameescape(external_file))
    local editor_win = vim.api.nvim_get_current_win()
    invoke_map("<leader>e")
    local dependency_win = vim.api.nvim_get_current_win()
    dependency_buf = vim.api.nvim_get_current_buf()
    assert_true(vim.bo.filetype == "netrw", "external file did not open the dependency tree")
    assert_true(vim.w.luanphan_dependency_tree == true, "dependency tree window was not marked")
    assert_true(
      realpath(vim.w.luanphan_dependency_root) == realpath(vim.fn.fnamemodify(external_file, ":h")),
      "dependency tree opened at the wrong directory"
    )
    assert_true(
      vim.fn.win_screenpos(dependency_win)[2] > vim.fn.win_screenpos(editor_win)[2],
      "dependency tree did not open on the right"
    )
    assert_true(
      realpath(require("nvim-tree.core").get_cwd()) == realpath(repo),
      "dependency tree changed workspace root"
    )

    local window_count = #vim.api.nvim_tabpage_list_wins(0)
    local sibling_line
    for line, text in ipairs(vim.api.nvim_buf_get_lines(dependency_buf, 0, -1, false)) do
      if text:find("sibling.go", 1, true) then
        sibling_line = line
        break
      end
    end
    assert_true(sibling_line ~= nil, "dependency tree did not list the sibling file")
    vim.api.nvim_win_set_cursor(dependency_win, { sibling_line, 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
    assert_true(vim.api.nvim_get_current_win() == editor_win, "dependency file did not open in the editor window")
    assert_true(
      realpath(vim.api.nvim_buf_get_name(0)) == realpath(external_sibling),
      "dependency file did not replace the editor buffer"
    )
    assert_true(#vim.api.nvim_tabpage_list_wins(0) == window_count, "dependency file opened another window")

    invoke_map("<leader>e")
    assert_true(vim.api.nvim_get_current_win() == dependency_win, "dependency tree did not regain focus")
    assert_true(
      vim.api.nvim_get_current_line():find("sibling.go", 1, true) ~= nil,
      "dependency tree did not focus the current sibling file"
    )

    local external_line
    for line, text in ipairs(vim.api.nvim_buf_get_lines(dependency_buf, 0, -1, false)) do
      if text:find("dependency.go", 1, true) then
        external_line = line
        break
      end
    end
    assert_true(external_line ~= nil, "dependency tree did not list the original file")
    vim.api.nvim_win_set_cursor(dependency_win, { external_line, 0 })
    vim.api.nvim_feedkeys("o", "x", false)
    assert_true(vim.api.nvim_get_current_win() == editor_win, "dependency tree o mapping did not focus the editor")
    assert_true(
      realpath(vim.api.nvim_buf_get_name(0)) == realpath(external_file),
      "dependency tree o mapping did not replace the editor buffer"
    )
    assert_true(#vim.api.nvim_tabpage_list_wins(0) == window_count, "dependency tree o mapping opened another window")

    invoke_map("<leader>e")
    assert_true(vim.api.nvim_get_current_win() == dependency_win, "dependency tree did not regain focus after o")
    assert_true(
      vim.api.nvim_get_current_line():find("dependency.go", 1, true) ~= nil,
      "dependency tree did not focus the current file after o"
    )
    invoke_map("<leader>e")
    assert_true(vim.api.nvim_get_current_win() == editor_win, "dependency tree did not return focus to the editor")
    vim.cmd("edit " .. vim.fn.fnameescape(repo .. "/main.go"))
    invoke_map("<leader>e")
    assert_true(vim.api.nvim_get_current_win() == main_tree_win, "workspace file did not focus the workspace tree")
    assert_true(realpath(require("nvim-tree.core").get_cwd()) == realpath(repo), "workspace tree root changed")

    vim.api.nvim_set_current_win(editor_win)
    vim.cmd("edit " .. vim.fn.fnameescape(external_file))
    invoke_map("<leader>e")
    assert_true(vim.api.nvim_get_current_win() == dependency_win, "external file did not refocus the dependency tree")
    invoke_map("<leader>e")
    invoke_map("<leader>b")
    assert_true(not vim.api.nvim_win_is_valid(dependency_win), "first tree toggle did not close the dependency tree")
    assert_true(vim.api.nvim_win_is_valid(main_tree_win), "closing the dependency tree closed the workspace tree")

    invoke_map("<leader>b")
    assert_true(not tree_api.tree.is_visible(), "tree toggle did not resume normal workspace-tree behavior")
    invoke_map("<leader>b")
    assert_true(tree_api.tree.is_visible(), "workspace tree did not reopen after dependency tree closed")
    assert_true(realpath(require("nvim-tree.core").get_cwd()) == realpath(repo), "workspace tree reopened at another root")

    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if not tree_api.tree.is_tree_buf(vim.api.nvim_win_get_buf(win)) then
        vim.api.nvim_set_current_win(win)
        break
      end
    end
    vim.cmd("edit " .. vim.fn.fnameescape(external_file))
    invoke_map("<leader>e")
    assert_true(vim.w.luanphan_dependency_tree == true, "explicit external-file focus did not reopen the dependency tree")
  end, debug.traceback)

  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.w[win].luanphan_dependency_tree then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  tree_api.tree.close()
  if dependency_buf and vim.api.nvim_buf_is_valid(dependency_buf) then
    pcall(vim.api.nvim_buf_delete, dependency_buf, { force = true })
  end
  vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
  assert_true(ok, err)
end

local function test_file_tree_focuses_current_file(repo)
  local tree_api = require("nvim-tree.api")
  local original_cwd = vim.fn.getcwd()
  local terminal_file = repo .. "/terminal-focus.txt"
  local hidden_file = repo .. "/.hidden-focus.txt"
  local ignored_file = repo .. "/generated/ignored-focus.txt"
  local stale_root = temp_root .. "/stale-tree-root"
  write(terminal_file, { "terminal focus" })
  write(hidden_file, { "hidden focus" })
  write(ignored_file, { "ignored focus" })
  write(repo .. "/.git/info/exclude", { "generated/" })
  vim.fn.mkdir(stale_root, "p")

  local function selected_tree_file()
    local node = tree_api.tree.get_node_under_cursor()
    return node and realpath(node.absolute_path) or nil
  end

  local terminal_win
  local ok, err = xpcall(function()
    vim.cmd("cd " .. vim.fn.fnameescape(repo))
    vim.cmd("edit " .. vim.fn.fnameescape(terminal_file))
    local editor_win = vim.api.nvim_get_current_win()
    tree_api.tree.open({ path = repo, focus = false })
    tree_api.tree.change_root(repo)
    local tree_win = tree_api.tree.winid()
    assert_true(tree_win and vim.api.nvim_win_is_valid(tree_win), "workspace tree did not open")

    vim.api.nvim_set_current_win(editor_win)
    local terminal_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_open_term(terminal_buf, {})
    terminal_win = vim.api.nvim_open_win(terminal_buf, true, {
      relative = "editor",
      row = 1,
      col = 1,
      width = 20,
      height = 5,
      style = "minimal",
    })
    invoke_map("<leader>e")
    assert_true(vim.bo.filetype == "NvimTree", "terminal focus did not open the workspace tree")
    assert_true(selected_tree_file() == realpath(terminal_file), "terminal focus did not select the visible editor file")
    vim.api.nvim_win_close(terminal_win, true)
    terminal_win = nil

    vim.api.nvim_set_current_win(editor_win)
    vim.cmd("edit " .. vim.fn.fnameescape(repo .. "/main.go"))
    tree_api.tree.change_root(stale_root)
    invoke_map("<leader>e")
    assert_true(realpath(require("nvim-tree.core").get_cwd()) == realpath(repo), "file focus did not repair the tree root")
    assert_true(selected_tree_file() == realpath(repo .. "/main.go"), "repaired tree did not select the current file")

    vim.api.nvim_set_current_win(editor_win)
    vim.cmd("edit " .. vim.fn.fnameescape(hidden_file))
    invoke_map("<leader>e")
    assert_true(selected_tree_file() == realpath(hidden_file), "workspace tree did not reveal the current dotfile")
    assert_true(vim.g.luanphan_show_dotfiles == 1, "dotfile visibility did not stay synchronized with file search")
    invoke_map("H")

    vim.api.nvim_set_current_win(editor_win)
    vim.cmd("edit " .. vim.fn.fnameescape(ignored_file))
    invoke_map("<leader>e")
    assert_true(selected_tree_file() == realpath(ignored_file), "workspace tree did not reveal the current ignored file")
  end, debug.traceback)

  if terminal_win and vim.api.nvim_win_is_valid(terminal_win) then
    vim.api.nvim_win_close(terminal_win, true)
  end
  if vim.g.luanphan_show_dotfiles == 1 then
    tree_api.filter.dotfiles.toggle()
    vim.g.luanphan_show_dotfiles = 0
  end
  require("luanphan.actions").set_gitignore_visible(false)
  tree_api.tree.close()
  vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
  assert_true(ok, err)
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
  assert_nonrecursive_map("H", "n", vim.api.nvim_get_current_buf())
  invoke_map("H")
  assert_true(vim.g.luanphan_show_dotfiles == 1, "nvim-tree did not publish visible dotfile state")
  assert_true(search():find(".hidden", 1, true) ~= nil, "live grep did not follow visible dotfile state")
  assert_true(find_files():find(".hidden", 1, true) ~= nil, "find files did not follow visible dotfile state")
  invoke_map("H")
  assert_true(vim.g.luanphan_show_dotfiles == 0, "nvim-tree did not restore hidden dotfile state")
  tree_api.tree.close()
end

local function test_search_rules()
  local priority = require("luanphan.search_priority")
  local path = temp_root .. "/search-rules/settings.conf"
  local defaults = priority.read_rules(path)
  assert_true(#defaults.deprioritize == 3, "search settings defaults have the wrong pattern count")
  assert_true(defaults.deprioritize[1].glob == "*.md", "markdown is not the first deprioritized group")
  assert_true(defaults.deprioritize[2].glob == "*_test.go", "Go tests are not the second deprioritized group")
  assert_true(defaults.deprioritize[3].glob == "*_gen.go", "generated Go is not the third deprioritized group")
  assert_true(#defaults.ignore == 0, "search settings should start without custom ignores")

  local legacy_path = temp_root .. "/search-rules/legacy"
  local migrated_path = temp_root .. "/search-rules/migrated.conf"
  write(legacy_path, { "*.txt", "", "# ignored comment", "*_test.go" })
  local migrated = priority.read_rules(migrated_path, legacy_path)
  assert_true(#migrated.deprioritize == 2, "legacy search priority patterns were not migrated")
  assert_true(migrated.deprioritize[1].glob == "*.txt", "migration changed the first priority pattern")
  assert_true(#migrated.ignore == 0, "migration should create an empty ignore section")

  write(path, {
    "[deprioritize]",
    "*.md",
    "*_test.go",
    "*_gen.go",
    "",
    "# ignored comment",
    "[ignore]",
    "**/vendor/**",
  })
  local rules = priority.read_rules(path)
  assert_true(#rules.deprioritize == 3, "search settings did not read deprioritized patterns")
  assert_true(#rules.ignore == 1, "search settings did not read ignore patterns")

  local base = require("telescope.sorters").empty()
  local sorter = priority.wrap_sorter(base, rules)
  local function score(filename)
    local entry = {
      filename = filename,
      ordinal = filename,
      display = function()
        return filename, { { { 0, 4 }, "ExistingHighlight" } }
      end,
    }
    return sorter.scoring_function(sorter, "target", filename, entry), entry
  end

  local code, code_entry = score("service/handler.go")
  local docs, docs_entry = score("docs/design.md")
  local tests = score("service/handler_test.go")
  local generated = score("service/schema_gen.go")
  local ignored = score("service/vendor/generated.go")
  assert_true(code < docs, "code did not rank above documentation")
  assert_true(docs < tests, "documentation did not rank above tests")
  assert_true(tests < generated, "configured pattern order was not preserved")
  assert_true(ignored < 0, "ignored search result was not discarded")

  local _, code_highlights = code_entry:display()
  assert_true(#code_highlights == 1, "normal search results were visually muted")

  local docs_display, docs_highlights = docs_entry:display()
  assert_true(docs_highlights[1][2] == "ExistingHighlight", "deprioritized styling replaced existing highlights")
  local muted = docs_highlights[#docs_highlights]
  assert_true(muted[2] == "LuanphanSearchDeprioritized", "deprioritized search result was not muted")
  assert_true(muted[1][1] == 0 and muted[1][2] == #docs_display, "muted highlight did not cover the result row")
end

local function test_search_rules_filter_disk_searches()
  local fixture = temp_root .. "/search-rules/disk-search"
  local path = temp_root .. "/search-rules/disk-search.conf"
  write(fixture .. "/included.txt", { "search target" })
  write(fixture .. "/archive/excluded.txt", { "search target" })
  write(path, {
    "[deprioritize]",
    "*.md",
    "",
    "[ignore]",
    "**/archive/**",
  })

  local original_path = vim.g.luanphan_search_rules_path
  vim.g.luanphan_search_rules_path = path
  local ok, err = xpcall(function()
    local grep_args = { "rg", "--files-with-matches" }
    vim.list_extend(grep_args, require("luanphan.telescope_grep_opts").additional_args())
    vim.list_extend(grep_args, { "search target", "." })
    local grep = vim.system(grep_args, { cwd = fixture, text = true }):wait()
    assert_true(grep.code == 0, "custom-ignore live grep failed: " .. (grep.stderr or ""))
    assert_true(grep.stdout:find("included.txt", 1, true) ~= nil, "custom ignore removed a normal grep result")
    assert_true(grep.stdout:find("archive", 1, true) == nil, "custom ignore leaked into live grep results")

    local find_args = require("luanphan.telescope_find_opts").find_command()
    local files = vim.system(find_args, { cwd = fixture, text = true }):wait()
    assert_true(files.code == 0, "custom-ignore file search failed: " .. (files.stderr or ""))
    assert_true(files.stdout:find("included.txt", 1, true) ~= nil, "custom ignore removed a normal file result")
    assert_true(files.stdout:find("archive", 1, true) == nil, "custom ignore leaked into file results")
  end, debug.traceback)

  vim.g.luanphan_search_rules_path = original_path
  assert_true(ok, tostring(err))
end

local function test_search_priority_editor_closes_on_focus_loss()
  local priority = require("luanphan.search_priority")
  local original_path = vim.g.luanphan_search_rules_path
  local path = temp_root .. "/search-rules/editor.conf"
  write(path, { "[deprioritize]", "*.md", "", "[ignore]" })
  vim.g.luanphan_search_rules_path = path

  local source_win = vim.api.nvim_get_current_win()
  local ok, err = xpcall(function()
    priority.open_editor()
    local popup_win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_get_current_buf()
    assert_true(popup_win ~= source_win, "search settings editor did not open a popup")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "[deprioritize]",
      "*_test.go",
      "",
      "[ignore]",
      "**/archive/**",
    })

    vim.api.nvim_set_current_win(source_win)
    wait_until("search settings editor closes after focus loss", function()
      return not vim.api.nvim_win_is_valid(popup_win)
    end, 3000)
    local rules = priority.read_rules(path)
    assert_true(rules.deprioritize[1].glob == "*_test.go", "search settings editor did not save priority rules")
    assert_true(rules.ignore[1].glob == "**/archive/**", "search settings editor did not save ignore rules")
  end, debug.traceback)

  vim.g.luanphan_search_rules_path = original_path
  assert_true(ok, tostring(err))
end

local function test_live_grep_highlights_content_only()
  local grep = require("luanphan.telescope_grep_opts")
  local display = "example/path_handler.go:12:8:func ExampleHandler()"
  local _, coordinates_end = display:find(":%d+:%d+:")
  local highlights = grep.content_highlights("ExampleHandler", display)

  assert_true(#highlights > 0, "live grep did not highlight matching content")
  for _, position in ipairs(highlights) do
    assert_true(position > coordinates_end, "live grep highlighted the filename")
  end
end

local function test_live_grep_debounces_real_picker(repo)
  local script = temp_root .. "/live-grep-debounce.lua"
  write(script, {
    "local function assert_true(value, message) if not value then error(message, 0) end end",
    "package.loaded['luanphan.telescope_grep_opts'] = nil",
    "require('luanphan.telescope_grep_opts').live_grep()",
    "local prompt_bufnr = vim.api.nvim_get_current_buf()",
    "local picker = require('telescope.actions.state').get_current_picker(prompt_bufnr)",
    "assert_true(picker ~= nil, 'live grep picker did not open')",
    "local function replace_prompt(text)",
    "  local current = vim.api.nvim_buf_get_lines(prompt_bufnr, 0, 1, false)[1]",
    "  vim.api.nvim_buf_set_text(prompt_bufnr, 0, 0, 0, #current, { text })",
    "end",
    "local function type_prompt(text)",
    "  for character in text:gmatch('.') do",
    "    local current = vim.api.nvim_buf_get_lines(prompt_bufnr, 0, 1, false)[1]",
    "    vim.api.nvim_buf_set_text(prompt_bufnr, 0, #current, 0, #current, { character })",
    "    vim.wait(30)",
    "  end",
    "end",
    "replace_prompt('targetValue')",
    "assert_true(vim.wait(5000, function() return picker.manager and picker.manager:num_results() > 0 end, 20), 'initial live grep produced no results')",
    "replace_prompt('missingValue')",
    "assert_true(vim.wait(1000, function() return vim.api.nvim_buf_get_lines(picker.results_bufnr, 0, 1, false)[1] == '' end, 20), 'live grep left stale rows visible')",
    "replace_prompt('')",
    "type_prompt('targetValue')",
    "local function final_results_visible()",
    "  if not picker.manager or picker.manager:num_results() == 0 then return false end",
    "  for entry in picker.manager:iter() do",
    "    if not tostring(entry.text or entry.value or entry.ordinal):find('targetValue', 1, true) then return false end",
    "  end",
    "  return true",
    "end",
    "assert_true(vim.wait(5000, final_results_visible, 20), 'live grep did not replace stale rows with final results')",
    "require('telescope.actions').close(prompt_bufnr)",
  })

  local cmd = child_nvim_luafile_command(repo, script)
  local out = vim.fn.systemlist(cmd)
  assert_true(vim.v.shell_error == 0, table.concat(out, "\n"))
end

local function test_live_grep_caches_only_completed_searches(repo)
  local script = temp_root .. "/live-grep-cache.lua"
  local fake_rg = temp_root .. "/live-grep-cache-rg"
  local invocation_log = temp_root .. "/live-grep-cache-invocations"
  write_executable(fake_rg, {
    "#!/bin/sh",
    "printf 'run\\n' >> " .. vim.fn.shellescape(invocation_log),
    "for argument in \"$@\"; do",
    "  if [ \"$argument\" = slowTarget ]; then sleep 2; fi",
    "done",
    "exec " .. vim.fn.shellescape(vim.fn.exepath("rg")) .. " \"$@\"",
  })
  write(script, {
    "local function assert_true(value, message) if not value then error(message, 0) end end",
    "local function invocation_count()",
    "  local path = " .. string.format("%q", invocation_log),
    "  return vim.fn.filereadable(path) == 1 and #vim.fn.readfile(path) or 0",
    "end",
    "local function results_title(picker)",
    "  return vim.api.nvim_buf_get_lines(picker.results_border.bufnr, 0, 1, false)[1] or ''",
    "end",
    "local function open_grep()",
    "  require('luanphan.telescope_grep_opts').live_grep()",
    "  local prompt = vim.api.nvim_get_current_buf()",
    "  local picker = require('telescope.actions.state').get_current_picker(prompt)",
    "  assert_true(picker ~= nil, 'live grep picker did not open')",
    "  return prompt, picker",
    "end",
    "local config = require('telescope.config')",
    "config.values.vimgrep_arguments[1] = " .. string.format("%q", fake_rg),
    "package.loaded['luanphan.telescope_grep_opts'] = nil",
    "local prompt, picker = open_grep()",
    "assert_true(vim.wait(1000, function() return results_title(picker):find('Ready', 1, true) ~= nil end, 20), 'empty live grep did not show ready status')",
    "picker:set_prompt('targetValue')",
    "assert_true(vim.wait(5000, function() return picker.manager and picker.manager:num_results() > 0 end, 20), 'completed search produced no results')",
    "assert_true(vim.wait(1000, function() return results_title(picker):find('Finished', 1, true) ~= nil end, 20), 'completed live grep did not show finished status')",
    "assert_true(invocation_count() == 1, 'completed search did not run exactly once')",
    "require('telescope.actions').close(prompt)",
    "prompt, picker = open_grep()",
    "assert_true(vim.wait(1000, function() return picker:_get_prompt() == 'targetValue' end, 20), 'completed search query was not restored')",
    "assert_true(vim.wait(1000, function() return picker.manager and picker.manager:num_results() > 0 end, 20), 'completed results were not restored')",
    "assert_true(results_title(picker):find('Finished', 1, true) ~= nil, 'cached live grep did not show finished status')",
    "assert_true(invocation_count() == 1, 'restoring completed results started rg again')",
    "picker:set_prompt('slowTarget')",
    "assert_true(vim.wait(1000, function() return invocation_count() == 2 end, 20), 'slow search did not start')",
    "assert_true(results_title(picker):find('Searching', 1, true) ~= nil, 'active live grep did not show searching status')",
    "require('telescope.actions').close(prompt)",
    "prompt, picker = open_grep()",
    "assert_true(vim.wait(1000, function() return picker:_get_prompt() == 'slowTarget' end, 20), 'interrupted search query was not restored')",
    "assert_true(vim.wait(1000, function() return invocation_count() == 3 end, 20), 'interrupted search did not restart rg')",
    "require('telescope.actions').close(prompt)",
  })

  local cmd = child_nvim_luafile_command(repo, script)
  local out = vim.fn.systemlist(cmd)
  assert_true(vim.v.shell_error == 0, table.concat(out, "\n"))
end

local function test_flow_line_navigation()
  local flow = require("luanphan.flow")
  local original_data_dir = vim.g.luanphan_flow_data_dir
  local original_cwd = vim.fn.getcwd()
  local workspace = temp_root .. "/flow-workspace"
  local other_workspace = temp_root .. "/other-flow-workspace"
  local first_file = workspace .. "/example-repo-a/main.go"
  local second_file = workspace .. "/example-repo-b/worker.go"
  vim.fn.mkdir(other_workspace, "p")
  write(first_file, { "package main", "", "func main() {}" })
  write(second_file, { "package worker", "", "func Run() {}", "", "var Value = true" })
  vim.g.luanphan_flow_data_dir = temp_root .. "/flow"

  local ok, err = xpcall(function()
    vim.cmd("cd " .. vim.fn.fnameescape(workspace))
    vim.cmd("edit " .. vim.fn.fnameescape(first_file))
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    flow.add()

    local storage = flow.storage_path()
    assert_true(vim.fn.filereadable(storage) == 1, "Flow did not create workspace storage")
    assert_true(read_lines(storage)[1] == "example-repo-a/main.go:3", "Flow did not append the current file and line")

    vim.cmd("edit " .. vim.fn.fnameescape(second_file))
    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    flow.add()
    assert_true(read_lines(storage)[2] == "example-repo-b/worker.go:5", "Flow did not include a second repository")
    assert_true(flow.storage_path(other_workspace) ~= storage, "Flow reused storage across workspaces")

    write(storage, {
      "// first operation",
      "example-repo-a/main.go:3 // first target",
      "missing.go:4 // ignored target",
      "example-repo-b/worker.go:5 // second target",
    })
    assert_true(flow.parse_entry("example-repo-b/worker.go:5 // second target").line == 5, "Flow rejected an entry suffix")
    assert_true(flow.parse_entry("// explanation only") == nil, "Flow parsed a comment as an entry")

    flow.toggle_menu()
    assert_true(vim.bo.filetype == "flow", "Flow did not open its editable menu")
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { "// updated operation" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    invoke_map("<CR>")
    assert_true(realpath(vim.api.nvim_buf_get_name(0)) == realpath(second_file), "comment selection did not close Flow")
    assert_true(read_lines(storage)[1] == "// updated operation", "Flow did not save menu edits")

    local editor_win = vim.api.nvim_get_current_win()
    flow.toggle_menu()
    local flow_win = vim.api.nvim_get_current_win()
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { "// saved after focus leaves" })
    vim.api.nvim_set_current_win(editor_win)
    wait_until("Flow menu closes after focus leaves", function()
      return not vim.api.nvim_win_is_valid(flow_win)
    end, 1000)
    assert_true(read_lines(storage)[1] == "// saved after focus leaves", "Flow lost edits when focus left the menu")

    flow.toggle_menu()
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    invoke_map("<CR>")
    assert_true(realpath(vim.api.nvim_buf_get_name(0)) == realpath(second_file), "Flow did not jump across repositories")
    assert_true(vim.api.nvim_win_get_cursor(0)[1] == 5, "Flow did not jump to the selected line")
    flow.previous()
    assert_true(realpath(vim.api.nvim_buf_get_name(0)) == realpath(first_file), "Flow previous did not change repositories")
    assert_true(vim.api.nvim_win_get_cursor(0)[1] == 3, "Flow previous did not skip non-navigable rows")
    flow.next()
    assert_true(vim.api.nvim_win_get_cursor(0)[1] == 5, "Flow next did not return to the next entry")
    flow.next()
    assert_true(vim.api.nvim_win_get_cursor(0)[1] == 3, "Flow next did not wrap")
  end, debug.traceback)

  vim.g.luanphan_flow_data_dir = original_data_dir
  if vim.fn.isdirectory(original_cwd) == 1 then
    vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
  end
  assert_true(ok, tostring(err))
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
  local original_env_state_file = vim.env.NVIM_RECENT_PATHS_FILE
  local env_state_file = temp_root .. "/env-recent-paths.json"
  vim.fn.delete(state_file)

  local ok, err = xpcall(function()
    vim.g.luanphan_recent_paths_file = nil
    vim.env.NVIM_RECENT_PATHS_FILE = env_state_file
    recent_paths.touch(repo)
    assert_true(vim.fn.filereadable(env_state_file) == 1, "recent folders ignored the environment override")
    local env_entries = recent_paths.entries()
    assert_true(
      #env_entries == 1 and realpath(env_entries[1]) == realpath(repo),
      "environment override stored the wrong recent folder"
    )
    vim.g.luanphan_recent_paths_file = state_file
    vim.env.NVIM_RECENT_PATHS_FILE = original_env_state_file

    local settings = require("luanphan.global_settings")
    local settings_path = vim.g.luanphan_global_settings_path
    assert_true(settings.max_recent_folders(settings_path) == 5, "global settings did not create recent-folder default")
    assert_true(#settings.diff_repo_ignores(settings_path) == 0, "global settings created a non-empty diff ignore list")
    assert_true(
      vim.tbl_contains(read_lines(settings_path), "[diff-repo-ignore]"),
      "global settings omitted the diff repository ignore section"
    )
    write(settings_path, {
      "[recent_folder]",
      "max_cache_entry = 5",
      "",
      "[diff-repo-ignore]",
      "repositories = [",
      '  "example-large",',
      '  "group/example-nested",',
      "]",
    })
    assert_true(
      vim.deep_equal(settings.diff_repo_ignores(settings_path), { "example-large", "group/example-nested" }),
      "global settings did not parse ignored diff repositories"
    )
    write(settings_path, { "[recent_folder]", "max_cache_entry = 2" })
    vim.fn.mkdir(temp_root .. "/first", "p")
    vim.fn.mkdir(temp_root .. "/second", "p")
    vim.fn.mkdir(temp_root .. "/third", "p")
    recent_paths.touch(temp_root .. "/first")
    recent_paths.touch(temp_root .. "/second")
    recent_paths.touch(temp_root .. "/third")
    local cached = recent_paths.entries()
    assert_true(#cached == 2, "recent folder cache did not enforce max_cache_entry")
    assert_true(cached[1]:match("/third$") ~= nil, "recent folder cache did not keep last visit first")
    assert_true(cached[2]:match("/second$") ~= nil, "recent folder cache did not retain second-last visit")
    assert_true(recent_paths.remove(temp_root .. "/third"), "recent folder removal failed")
    cached = recent_paths.entries()
    assert_true(#cached == 1 and cached[1]:match("/second$") ~= nil, "recent folder removal changed the wrong entry")
    assert_true(not recent_paths.remove(temp_root .. "/third"), "missing recent folder was reported as removed")
    recent_paths.touch(temp_root .. "/third")
    vim.fn.delete(temp_root .. "/third", "rf")
    cached = recent_paths.entries()
    assert_true(#cached == 1 and cached[1]:match("/second$") ~= nil, "recent folder cache retained a missing folder")
    write(settings_path, { "[recent_folder]", "max_cache_entry = 5" })
    vim.fn.delete(state_file)

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
    local targets = recent_paths.switch_targets(items, function(item) return item.path end, repo)
    assert_true(#targets == 2, "switch targets discarded an option")
    assert_true(targets[1].name == "example-b", "switch targets did not promote the previous path")
    assert_true(targets[2].name == "example-a", "switch targets did not retain the current path")

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

    recent_paths.touch(workspace_a)
    local current_root
    projects, current_root = api.list_all_project_repos()
    local grouped = api.group_project_entries(projects, current_root)
    assert_true(grouped[1].scope == "workspace", "root repository recency displaced the workspace group")
    local root_header = nil
    for index, entry in ipairs(grouped) do
      if entry.header and entry.scope == "root" then
        root_header = index
        break
      end
    end
    assert_true(
      root_header and grouped[root_header + 1] and realpath(grouped[root_header + 1].path) == realpath(source_b),
      "previous root repository was not first within the root group"
    )

    local empty_workspace = station .. "/local_workspaces/" .. empty_workspace_name
    recent_paths.touch(empty_workspace)
    local workspace_entries = api.list_workspace_directories()
    assert_true(
      realpath(workspace_entries[1].path) == realpath(empty_workspace),
      "workspace picker did not promote the latest workspace"
    )

    local workspace_root = vim.fn.fnamemodify(workspace_a, ":h")
    recent_paths.touch(workspace_root)
    recent_paths.touch(empty_workspace)
    local destinations = api.list_workspace_destinations()
    local workspace_targets = recent_paths.switch_targets(destinations, function(workspace)
      return workspace.path
    end, empty_workspace, function(a, b)
      return a.name < b.name
    end)
    assert_true(
      realpath(workspace_targets[1].path) == realpath(workspace_root),
      "workspace switch targets did not promote the previous workspace"
    )
    assert_true(#workspace_targets == #destinations, "workspace switch targets discarded an option")
    assert_true(
      realpath(workspace_targets[2].path) == realpath(empty_workspace),
      "workspace switch targets did not retain the current workspace"
    )
  end, debug.traceback)

  vim.g.luanphan_recent_paths_file = state_file
  vim.env.NVIM_RECENT_PATHS_FILE = original_env_state_file
  vim.fn.delete(env_state_file)
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

  vim.cmd("cd " .. vim.fn.fnameescape(station))
  local root_projects, root_current = api.list_all_project_repos()
  assert_true(#root_projects == 2, "bare workstation root did not discover its git repositories")
  assert_true(realpath(root_current) == realpath(station), "bare workstation root resolved the wrong current folder")
  local root_project_paths = {}
  for _, project in ipairs(root_projects) do
    root_project_paths[realpath(project.path)] = true
    assert_true(project.scope == "root", "bare workstation repository received the wrong scope")
  end
  for _, source in pairs(sources) do
    assert_true(root_project_paths[realpath(source)] == true, "bare workstation root omitted a git repository")
  end

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
  local current_entry = nil
  for _, entry in ipairs(entries) do
    if not entry.header and realpath(entry.path) == realpath(current_root) then
      current_entry = entry
    end
  end
  assert_true(current_entry ~= nil, "grouped project entries discarded the current repository")
  assert_true(vim.startswith(current_entry.display, "* "), "current repository marker is missing")
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

local function test_workspace_folder_browser()
  local api = worktree_test_api()
  local original_cwd = vim.fn.getcwd()
  local _, _, station = make_project_scope_fixture()
  local hidden = station .. "/.example-hidden"
  vim.fn.mkdir(hidden, "p")
  write(station .. "/example-file.txt", { "not a directory" })

  local recent_a = temp_root .. "/recent-folder-a"
  local recent_b = temp_root .. "/recent-folder-b"
  vim.fn.mkdir(recent_a, "p")
  vim.fn.mkdir(recent_b, "p")
  vim.fn.delete(vim.g.luanphan_recent_paths_file)
  local recent_paths = require("luanphan.recent_paths")
  recent_paths.touch(recent_a)
  recent_paths.touch(recent_b)
  recent_paths.touch(station)

  local picker_entries = api.folder_picker_entries(station, "")
  assert_true(picker_entries[1].header and picker_entries[1].display == "[recent folders]", "folder picker omitted recent section")
  assert_true(realpath(picker_entries[2].path) == realpath(recent_b), "folder picker did not put the previous folder first")
  assert_true(vim.startswith(picker_entries[2].display, "  "), "recent folder row is not indented")
  assert_true(realpath(picker_entries[3].path) == realpath(station), "folder picker did not put the current folder second")
  assert_true(realpath(picker_entries[4].path) == realpath(recent_a), "folder picker did not preserve remaining recent order")
  local first_separator = picker_entries[2].display:find("|", 1, true)
  local second_separator = picker_entries[4].display:find("|", 1, true)
  assert_true(first_separator ~= nil and first_separator == second_separator, "recent folder columns are not aligned")
  assert_true(
    picker_entries[2].display:find("recent-folder-b", 1, true) < first_separator,
    "recent folder name is not in the first column"
  )
  assert_true(
    picker_entries[2].display:find(recent_b, 1, true) > first_separator,
    "recent folder path is not in the second column"
  )
  assert_true(picker_entries[5].header and picker_entries[5].display:find("[folders]", 1, true), "folder picker omitted folder section")
  assert_true(vim.startswith(picker_entries[6].display, "  "), "folder row is not indented")

  local entries = api.list_folder_entries(station)
  local by_name = {}
  for _, entry in ipairs(entries) do
    by_name[entry.name] = entry
  end
  assert_true(entries[1].current == true, "folder browser did not put the current folder first")
  assert_true(realpath(entries[1].path) == realpath(station), "folder browser current entry has the wrong path")
  assert_true(by_name["../"] == nil, "folder browser included a parent shortcut")
  assert_true(by_name["../../"] == nil, "folder browser included an ancestor shortcut")
  assert_true(by_name["local_workspaces/"] and by_name["local_workspaces/"].child, "folder browser omitted a child")
  assert_true(by_name[".example-hidden/"] == nil, "folder browser included a hidden child")
  assert_true(by_name["example-file.txt"] == nil, "folder browser included a file")

  local parent = vim.fn.fnamemodify(station, ":h")
  local resolved, path_input = api.resolve_folder_input("../", station)
  assert_true(path_input and realpath(resolved) == realpath(parent), "folder input did not resolve ../")
  resolved, path_input = api.resolve_folder_input("../../", station)
  assert_true(
    path_input and realpath(resolved) == realpath(vim.fn.fnamemodify(parent, ":h")),
    "folder input did not resolve ../../"
  )
  resolved, path_input = api.resolve_folder_input(station .. "/local_workspaces", station)
  assert_true(path_input and realpath(resolved) == realpath(station .. "/local_workspaces"), "absolute folder input failed")
  resolved, path_input = api.resolve_folder_input("~", station)
  assert_true(path_input and realpath(resolved) == realpath(vim.uv.os_homedir()), "home-relative folder input failed")
  resolved, path_input = api.resolve_folder_input("local_workspaces", station)
  assert_true(resolved == nil and path_input == false, "fuzzy folder input was treated as a path")

  local partial = station .. "/local"
  local _, explicit, normalized, browse_path = api.folder_path_context(partial, station)
  assert_true(explicit and normalized == partial, "partial absolute folder input was not normalized")
  assert_true(realpath(browse_path) == realpath(station), "partial folder input did not use its existing parent")
  local partial_entries = api.folder_picker_entries(station, partial)
  local partial_child = nil
  for _, entry in ipairs(partial_entries) do
    if entry.path and realpath(entry.path) == realpath(station .. "/local_workspaces") then
      partial_child = entry
      break
    end
  end
  assert_true(partial_child ~= nil, "partial folder input did not list a matching child")
  assert_true(partial_child.search_prompt == partial, "partial folder input did not expand its search prompt")

  local original_home = vim.env.HOME
  local test_home = temp_root .. "/folder-picker-home"
  local home_child = test_home .. "/example-folder"
  vim.fn.mkdir(home_child, "p")
  vim.env.HOME = test_home
  local tilde_entries = api.folder_picker_entries(station, "~/example")
  vim.env.HOME = original_home
  local tilde_child = nil
  for _, entry in ipairs(tilde_entries) do
    if entry.path and realpath(entry.path) == realpath(home_child) then
      tilde_child = entry
      break
    end
  end
  assert_true(tilde_child ~= nil, "partial home-relative folder input did not list its matching child")
  assert_true(
    tilde_child.search_prompt:sub(1, 1) == "/" and not tilde_child.search_prompt:find("~", 1, true),
    "home-relative search prompt was not expanded"
  )

  local shim_dir = temp_root .. "/folder-picker-shims"
  write_executable(shim_dir .. "/mcodex", { "#!/bin/sh", "exec cat" })
  local editor_file = station .. "/local_workspaces/open-from-agent.txt"
  write(editor_file, { "File picker destination" })
  local script = temp_root .. "/workspace-folder-picker.lua"
  write(script, {
    "local function assert_true(value, message) if not value then error(message, 0) end end",
    "local function realpath(path) return (vim.uv or vim.loop).fs_realpath(path) or path end",
    "vim.g.luanphan_recent_paths_file = " .. string.format("%q", temp_root .. "/child-recent-paths.json"),
    "vim.g.luanphan_global_settings_path = " .. string.format("%q", vim.g.luanphan_global_settings_path),
    "require('lazy').load({ plugins = { 'luanphan-worktree' } })",
    "local recent = require('luanphan.recent_paths')",
    "recent.touch(" .. string.format("%q", recent_a) .. ")",
    "recent.touch(" .. string.format("%q", recent_b) .. ")",
    "recent.touch(" .. string.format("%q", station) .. ")",
    "vim.env.PATH = " .. string.format("%q", shim_dir .. ":") .. " .. vim.env.PATH",
    "vim.g.luanphan_agent_status_dir = " .. string.format("%q", temp_root .. "/folder-picker-agent-status"),
    "local agents = require('luanphan.agents.main')",
    "local global_settings = vim.g.luanphan_global_settings_path",
    "vim.g.luanphan_global_settings_path = " .. string.format("%q", temp_root .. "/folder-picker-agent-settings.toml"),
    "vim.fn.writefile({'[agent_float]', 'display_style = \"tile\"'}, vim.g.luanphan_global_settings_path)",
    "local first_tile = agents.new('codex')",
    "local agent_buf = agents.new('codex')",
    "local main = vim.api.nvim_get_current_win()",
    "local other_tile = vim.fn.bufwinid(first_tile)",
    "assert_true(other_tile ~= -1 and other_tile ~= main, 'folder switch fixture did not open two tiles')",
    "vim.fn.maparg('<leader>e', 'n', false, true).callback()",
    "local sidebar = vim.api.nvim_get_current_win()",
    "assert_true(vim.bo.filetype == 'agent-window-bar', 'folder switch fixture could not open the agent sidebar')",
    "vim.fn.maparg('<C-l>', 'n', false, true).callback()",
    "vim.fn.maparg('<leader>wf', 'n', false, true).callback()",
    "local prompt_bufnr = vim.api.nvim_get_current_buf()",
    "local action_state = require('telescope.actions.state')",
    "local actions = require('telescope.actions')",
    "local picker = action_state.get_current_picker(prompt_bufnr)",
    "assert_true(picker ~= nil, 'folder picker did not open')",
    "assert_true(vim.wait(3000, function() local selection = picker:get_selection(); return selection and selection.value and selection.value.recent and realpath(selection.value.path) == realpath(" .. string.format("%q", recent_b) .. ") end, 20), 'previous folder was not selected first')",
    "picker:set_prompt('recent-folder-a')",
    "assert_true(vim.wait(3000, function() local selection = picker:get_selection(); return selection and selection.value and selection.value.recent and realpath(selection.value.path) == realpath(" .. string.format("%q", recent_a) .. ") end, 20), 'recent folder did not match fuzzy search')",
    "picker:set_prompt('')",
    "assert_true(vim.wait(3000, function() local selection = picker:get_selection(); return selection and selection.value and selection.value.recent and realpath(selection.value.path) == realpath(" .. string.format("%q", recent_b) .. ") end, 20), 'clearing search did not restore recent order')",
    "local remove_map = vim.fn.maparg('x', 'n', false, true)",
    "assert_true(type(remove_map) == 'table' and type(remove_map.callback) == 'function', 'recent folder remove mapping is missing')",
    "remove_map.callback()",
    "assert_true(vim.wait(3000, function() for _, path in ipairs(recent.entries()) do if realpath(path) == realpath(" .. string.format("%q", recent_b) .. ") then return false end end return true end, 20), 'recent folder remove mapping did not persist removal')",
    "assert_true(vim.wait(3000, function() local selection = picker:get_selection(); return selection and selection.value and selection.value.recent and realpath(selection.value.path) == realpath(" .. string.format("%q", recent_a) .. ") end, 20), 'recent folder picker did not refresh after removal')",
    "assert_true(action_state.get_current_line() == '', 'recent folder removal reset the search prompt')",
    "local original_home = vim.env.HOME",
    "vim.env.HOME = " .. string.format("%q", test_home),
    "picker:set_prompt('~/example')",
    "assert_true(vim.wait(3000, function() local selection = picker:get_selection(); return selection and selection.value and realpath(selection.value.path) == realpath(" .. string.format("%q", home_child) .. ") end, 20), 'partial home-relative path did not select its matching child')",
    "vim.env.HOME = original_home",
    "local target = " .. string.format("%q", station .. "/local_workspaces"),
    "local partial = " .. string.format("%q", station .. "/local"),
    "picker:set_prompt(partial)",
    "assert_true(vim.wait(3000, function() local selection = picker:get_selection(); return selection and selection.value and not selection.value.exact and realpath(selection.value.path) == realpath(target) end, 20), 'partial folder path did not select its matching child')",
    "picker:set_prompt(target)",
    "assert_true(vim.wait(3000, function() return action_state.get_current_line() == target end, 20), 'absolute folder input did not reach the prompt')",
    "assert_true(vim.wait(3000, function() local selection = picker:get_selection(); return selection and selection.value and selection.value.exact and realpath(selection.value.path) == realpath(target) end, 20), 'absolute folder match was not selected first')",
    "assert_true(picker:get_selection().display == target, 'resolved folder was not displayed first')",
    "local recent_before = vim.json.encode(recent.entries())",
    "remove_map.callback()",
    "assert_true(vim.json.encode(recent.entries()) == recent_before, 'recent folder remove mapping changed state for a folder row')",
    "actions.move_selection_next(prompt_bufnr)",
    "local child = picker:get_selection().value.path",
    "assert_true(realpath(child) ~= realpath(target), 'resolved folder child was not selectable')",
    "actions.select_default(prompt_bufnr)",
    "assert_true(vim.wait(3000, function() local selection = picker:get_selection(); return action_state.get_current_line() == child and selection and selection.value and selection.value.exact and realpath(selection.value.path) == realpath(child) end, 20), 'resolved folder child did not open in the picker')",
    "picker:set_prompt(target)",
    "assert_true(vim.wait(3000, function() local selection = picker:get_selection(); return action_state.get_current_line() == target and selection and selection.value and selection.value.current and realpath(selection.value.path) == realpath(target) end, 20), 'resolved folder did not repopulate after child navigation')",
    "actions.select_default(prompt_bufnr)",
    "assert_true(vim.wait(3000, function() return realpath(vim.fn.getcwd()) == realpath(target) end, 20), 'absolute folder input did not switch workspaces')",
    "assert_true(not vim.api.nvim_win_is_valid(main) and not vim.api.nvim_win_is_valid(sidebar) and not vim.api.nvim_win_is_valid(other_tile), 'folder switch left an agent pane open')",
    "for _, buf in ipairs({ first_tile, agent_buf }) do assert_true(require('luanphan.terminal.window').running(buf), 'folder switch stopped an agent session') end",
    "vim.g.luanphan_global_settings_path = global_settings",
    "vim.api.nvim_buf_delete(first_tile, { force = true })",
    "assert_true(vim.fn.exists(':FolderSwitch') == 2, 'FolderSwitch command is missing')",
    "local middle_agent = agents.new('codex')",
    "local newest_agent = agents.new('codex')",
    "main = vim.api.nvim_get_current_win()",
    "sidebar = vim.w[main].luanphan_window_bar",
    "vim.fn.maparg('<C-o>', 'n', false, true).callback()",
    "assert_true(vim.api.nvim_get_current_buf() == middle_agent, 'older agent jump missed the previous session')",
    "vim.fn.maparg('<C-o>', 'n', false, true).callback()",
    "assert_true(vim.api.nvim_get_current_buf() == agent_buf and realpath(vim.fn.getcwd()) == realpath(" .. string.format("%q", station) .. "), 'older agent jump did not switch workspaces')",
    "vim.api.nvim_buf_delete(middle_agent, { force = true })",
    "vim.fn.maparg('<C-i>', 'n', false, true).callback()",
    "assert_true(vim.api.nvim_get_current_buf() == newest_agent and realpath(vim.fn.getcwd()) == realpath(target), 'newer agent jump did not skip the closed session')",
    "assert_true(vim.api.nvim_get_current_win() == main and vim.api.nvim_win_is_valid(sidebar), 'agent jumps replaced the float')",
    "vim.api.nvim_buf_delete(agent_buf, { force = true })",
    "local first = newest_agent",
    "local second = agents.new('codex')",
    "assert_true(agents.open('codex', first, { view_mode = true }), 'could not focus the previous agent again')",
    "local third = agents.new('codex')",
    "local function expect_jump(key, expected) vim.fn.maparg(key, 'n', false, true).callback(); assert_true(vim.api.nvim_get_current_buf() == expected, 'agent jump revisited a session or broke history order') end",
    "expect_jump('<C-o>', first)",
    "expect_jump('<C-o>', second)",
    "expect_jump('<C-o>', second)",
    "expect_jump('<C-i>', first)",
    "expect_jump('<C-i>', third)",
    "vim.b[third].luanphan_agent_name = nil",
    "vim.fn.maparg('<leader>p', 'n', false, true).callback()",
    "prompt_bufnr = vim.api.nvim_get_current_buf()",
    "picker = action_state.get_current_picker(prompt_bufnr)",
    "picker:set_prompt('open-from-agent')",
    "assert_true(vim.wait(3000, function() local selection = picker:get_selection(); return selection and tostring(selection.value):find('open-from-agent.txt', 1, true) end, 20), 'file picker did not find the fixture')",
    "actions.select_default(prompt_bufnr)",
    "assert_true(realpath(vim.api.nvim_buf_get_name(0)) == realpath(" .. string.format("%q", editor_file) .. "), 'file picker did not open the selected file')",
    "assert_true(vim.api.nvim_win_get_config(0).relative == '' and vim.bo[third].buftype == 'terminal', 'file picker replaced the agent terminal pane')",
  })
  local output = vim.fn.systemlist(child_nvim_luafile_command(station, script))
  assert_true(vim.v.shell_error == 0, table.concat(output, "\n"))

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

local function test_add_repository_to_workspace()
  local api = worktree_test_api()
  local original_cwd = vim.fn.getcwd()
  local original_path = vim.env.PATH
  local original_log = vim.env.MKWS_TEST_LOG
  local original_fail = vim.env.MKWS_TEST_FAIL
  local original_notify = vim.notify
  local sources, workspaces, station, workspace_name = make_project_scope_fixture()
  local source = station .. "/front-end/example-project-c"
  local workspace = station .. "/local_workspaces/" .. workspace_name
  local fake_bin = temp_root .. "/fake-mkws-bin"
  local log = temp_root .. "/fake-mkws.log"

  vim.fn.mkdir(source, "p")
  run({ "git", "init", "-b", "main" }, source)
  local hidden_source = station .. "/.hidden/example-hidden"
  local deep_source = station .. "/clients/mobile/example-deep"
  vim.fn.mkdir(hidden_source, "p")
  vim.fn.mkdir(deep_source, "p")
  run({ "git", "init", "-b", "main" }, hidden_source)
  run({ "git", "init", "-b", "main" }, deep_source)
  local function write_fake_mkws(create_target)
    local lines = {
      "#!/bin/sh",
      'printf "%s\\n" "$PWD" "$@" > "$MKWS_TEST_LOG"',
      'if [ "${MKWS_TEST_FAIL:-}" = "1" ]; then',
      '  printf "%s\\n" "fixture add failure" >&2',
      "  exit 7",
      "fi",
    }
    if create_target then
      vim.list_extend(lines, {
        'target="$PWD/front-end/$(basename "$2")"',
        'mkdir -p "$target"',
        ': > "$target/.git"',
      })
    end
    write_executable(fake_bin .. "/mkws", lines)
  end
  write_fake_mkws(true)

  local ok, err = xpcall(function()
    vim.cmd("cd " .. vim.fn.fnameescape(workspaces["example-project-a"]))
    local candidates, resolved_workspace = api.list_addable_repositories()
    assert_true(
      #candidates == 1,
      "repository add candidates were: " .. table.concat(vim.tbl_map(function(item) return item.name end, candidates), ", ")
    )
    assert_true(candidates[1].name == "front-end/example-project-c", "repository add candidate has the wrong name")
    assert_true(realpath(candidates[1].path) == realpath(source), "repository add candidate has the wrong path")
    assert_true(realpath(resolved_workspace) == realpath(workspace), "repository add resolved the wrong workspace")

    vim.env.PATH = fake_bin .. ":" .. original_path
    vim.env.MKWS_TEST_LOG = log
    local result = nil
    api.add_repository(candidates[1], resolved_workspace, function(value)
      result = value
    end)
    wait_until("repository add command", function() return result ~= nil end, 5000)
    assert_true(result.code == 0, "repository add command failed")
    local invocation = vim.fn.readfile(log)
    assert_true(realpath(invocation[1]) == realpath(workspace), "mkws did not run from the workspace root")
    assert_true(invocation[2] == "--add", "mkws omitted --add")
    assert_true(realpath(invocation[3]) == realpath(source), "mkws received the wrong source repository")

    local projects = api.list_all_project_repos()
    local nested_scopes = {}
    for _, project in ipairs(projects) do
      if project.name == "front-end/example-project-c" then
        nested_scopes[project.scope] = realpath(project.path)
      end
      assert_true(project.name ~= ".hidden/example-hidden", "repository discovery included a hidden group")
      assert_true(project.name ~= "clients/mobile/example-deep", "repository discovery descended two levels")
    end
    assert_true(nested_scopes.root == realpath(source), "repository picker omitted the nested source repository")
    assert_true(
      nested_scopes.workspace == realpath(workspace .. "/front-end/example-project-c"),
      "repository picker omitted the nested workspace repository"
    )

    vim.fn.delete(workspace .. "/front-end/example-project-c", "rf")
    write_fake_mkws(false)
    result = nil
    local missing_target_error = nil
    vim.notify = function(message, level)
      if level == vim.log.levels.ERROR then
        missing_target_error = tostring(message)
      end
    end
    api.add_repository(candidates[1], resolved_workspace, function(value)
      result = value
    end)
    wait_until("repository add missing target", function() return result ~= nil end, 5000)
    assert_true(result.code ~= 0, "repository add accepted a missing worktree")
    assert_true(
      missing_target_error and missing_target_error:find("completed without creating", 1, true),
      "repository add did not report the missing worktree"
    )

    write_fake_mkws(true)

    local reported_error = nil
    vim.notify = function(message, level)
      if level == vim.log.levels.ERROR then
        reported_error = tostring(message)
      end
    end
    vim.env.MKWS_TEST_FAIL = "1"
    result = nil
    api.add_repository(candidates[1], resolved_workspace, function(value)
      result = value
    end)
    wait_until("repository add failure", function() return result ~= nil end, 5000)
    assert_true(result.code == 7, "repository add did not preserve the mkws exit code")
    assert_true(
      reported_error and reported_error:find("fixture add failure", 1, true),
      "repository add did not report mkws failure output"
    )
    assert_true(vim.fn.exists(":RepositoryAdd") == 2, "RepositoryAdd command is missing")
  end, debug.traceback)

  vim.notify = original_notify
  vim.env.PATH = original_path
  vim.env.MKWS_TEST_LOG = original_log
  vim.env.MKWS_TEST_FAIL = original_fail
  if vim.fn.isdirectory(original_cwd) == 1 then
    vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
  end
  assert_true(ok, tostring(err))
end

local function test_remove_repository_from_workspace()
  local api = worktree_test_api()
  local original_cwd = vim.fn.getcwd()
  local original_buf = vim.api.nvim_get_current_buf()
  local original_path = vim.env.PATH
  local original_log = vim.env.MKWS_TEST_LOG
  local original_fail = vim.env.MKWS_TEST_FAIL
  local original_notify = vim.notify
  local _, workspaces, station, workspace_name = make_project_scope_fixture()
  local workspace = station .. "/local_workspaces/" .. workspace_name
  local fake_bin = temp_root .. "/fake-remove-mkws-bin"
  local log = temp_root .. "/fake-remove-mkws.log"

  write_executable(fake_bin .. "/mkws", {
    "#!/bin/sh",
    'printf "%s\\n" "$PWD" "$@" > "$MKWS_TEST_LOG"',
    'if [ "${MKWS_TEST_FAIL:-}" = "1" ]; then',
    '  printf "%s\\n" "fixture remove failure" >&2',
    "  exit 7",
    "fi",
    'rm -rf "$PWD/$2"',
  })

  local ok, err = xpcall(function()
    vim.cmd("cd " .. vim.fn.fnameescape(workspaces["example-project-a"]))
    local candidates, resolved_workspace = api.list_removable_repositories()
    assert_true(#candidates == 2, "repository remove candidates have the wrong count")
    assert_true(realpath(resolved_workspace) == realpath(workspace), "repository remove resolved the wrong workspace")
    local by_name = {}
    for _, repo in ipairs(candidates) do
      by_name[repo.name] = repo
    end

    vim.env.PATH = fake_bin .. ":" .. original_path
    vim.env.MKWS_TEST_LOG = log
    local dirty_path = by_name["example-project-a"].path .. "/dirty.ts"
    write(dirty_path, { "const value = 1" })
    vim.cmd("edit " .. vim.fn.fnameescape(dirty_path))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "const value = 2" })
    local dirty_buf = vim.api.nvim_get_current_buf()
    local result = nil
    api.remove_repository(by_name["example-project-a"], resolved_workspace, function(value)
      result = value
    end)
    assert_true(result and result.code ~= 0, "repository remove accepted an unsaved buffer")
    assert_true(vim.fn.isdirectory(by_name["example-project-a"].path) == 1, "repository remove deleted a dirty project")
    assert_true(vim.fn.filereadable(log) == 0, "repository remove invoked mkws for an unsaved buffer")

    vim.bo[dirty_buf].modified = false
    vim.api.nvim_set_current_buf(original_buf)
    vim.api.nvim_buf_delete(dirty_buf, { force = true })
    local stale_buf = vim.fn.bufadd(dirty_path)
    vim.fn.bufload(stale_buf)
    result = nil
    api.remove_repository(by_name["example-project-a"], resolved_workspace, function(value)
      result = value
    end)
    wait_until("repository remove command", function() return result ~= nil end, 5000)
    assert_true(result.code == 0, "repository remove command failed")
    assert_true(realpath(vim.fn.getcwd()) == realpath(workspace), "repository remove left cwd inside the deleted project")
    assert_true(not vim.api.nvim_buf_is_valid(stale_buf), "repository remove kept a deleted project buffer")
    assert_true(vim.fn.isdirectory(by_name["example-project-a"].path) == 0, "repository remove kept its worktree")
    assert_true(vim.fn.isdirectory(by_name["example-project-b-long"].path) == 1, "repository remove deleted a sibling")
    local invocation = vim.fn.readfile(log)
    assert_true(realpath(invocation[1]) == realpath(workspace), "mkws remove did not run from the workspace root")
    assert_true(invocation[2] == "remove", "mkws omitted remove")
    assert_true(invocation[3] == "example-project-a", "mkws remove received the wrong repository")

    local reported_error = nil
    vim.notify = function(message, level)
      if level == vim.log.levels.ERROR then
        reported_error = tostring(message)
      end
    end
    vim.env.MKWS_TEST_FAIL = "1"
    vim.cmd("cd " .. vim.fn.fnameescape(by_name["example-project-b-long"].path))
    result = nil
    api.remove_repository(by_name["example-project-b-long"], resolved_workspace, function(value)
      result = value
    end)
    wait_until("repository remove failure", function() return result ~= nil end, 5000)
    assert_true(result.code == 7, "repository remove did not preserve the mkws exit code")
    assert_true(
      realpath(vim.fn.getcwd()) == realpath(by_name["example-project-b-long"].path),
      "failed repository remove did not restore its cwd"
    )
    assert_true(vim.fn.isdirectory(by_name["example-project-b-long"].path) == 1, "failed remove deleted its worktree")
    assert_true(
      reported_error and reported_error:find("fixture remove failure", 1, true),
      "repository remove did not report mkws failure output"
    )
    assert_true(vim.fn.exists(":RepositoryRemove") == 2, "RepositoryRemove command is missing")
  end, debug.traceback)

  vim.notify = original_notify
  vim.env.PATH = original_path
  vim.env.MKWS_TEST_LOG = original_log
  vim.env.MKWS_TEST_FAIL = original_fail
  if vim.api.nvim_buf_is_valid(original_buf) then
    vim.api.nvim_set_current_buf(original_buf)
  end
  if vim.fn.isdirectory(original_cwd) == 1 then
    vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
  end
  assert_true(ok, tostring(err))
end

local function test_active_agent_discovery(repo, worktree)
  local api = worktree_test_api()
  local original_buf = vim.api.nvim_get_current_buf()
  local original_cwd = vim.fn.getcwd()
  local agent_keys = { "codex_agent_bufnr", "claude_agent_bufnr", "cursor_agent_bufnr" }
  local saved = {}
  for _, key in ipairs(agent_keys) do
    saved[#saved + 1] = { key = key, value = vim.g[key] }
  end

  local jobs = {}
  local buffers = {}
  local agents_module = nil
  local original_focus = nil
  local function start_terminal(cwd, title)
    vim.cmd("enew")
    local buf = vim.api.nvim_get_current_buf()
    local command = "sleep 30"
    if title then
      command = "printf '\\033]2;%s\\007' " .. vim.fn.shellescape(title) .. "; " .. command
    end
    local job = vim.fn.termopen({ "sh", "-c", command }, { cwd = cwd })
    assert_true(type(job) == "number" and job > 0, "failed to start active agent fixture")
    jobs[#jobs + 1] = job
    buffers[#buffers + 1] = buf
    return buf
  end

  local ok, err = xpcall(function()
    local repo_codex_buf = start_terminal(repo, "Review example parser")
    local worktree_codex_buf = start_terminal(worktree, "Fix test failures")
    local worktree_cursor_buf = start_terminal(worktree)
    vim.b[repo_codex_buf].luanphan_agent_last_used = 3
    vim.b[worktree_codex_buf].luanphan_agent_last_used = 2
    vim.b[worktree_cursor_buf].luanphan_agent_last_used = 1
    vim.g.codex_agent_bufnr = { [repo] = { repo_codex_buf }, [worktree] = { worktree_codex_buf } }
    vim.g.cursor_agent_bufnr = { [worktree] = { worktree_cursor_buf } }
    vim.g.claude_agent_bufnr = { [repo] = { 999999 } }
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
    assert_true(codex.agent_label == "Review example parser", "agent sessions ignored the terminal title")
    assert_true(cursor and cursor.agent_label == "cursor", "untitled agent did not retain its fallback label")
    vim.b[repo_codex_buf].term_title = "Renamed parser review"
    assert_true(live_agents()[repo_codex_buf].agent_label == "Renamed parser review", "agent session kept a stale title")

    agents_module = require("luanphan.agents.main")
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
  local agents = require("luanphan.agents.main")
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
    vim.g.codex_agent_bufnr = { [repo] = { old_buf } }
    vim.g.cursor_agent_bufnr = { [worktree] = { target_buf } }
    vim.b[old_buf].luanphan_agent_name = "codex"
    vim.b[old_buf].luanphan_agent_cwd = repo
    vim.b[old_buf].luanphan_agent_last_used = 1
    vim.b[target_buf].luanphan_agent_name = "cursor"
    vim.b[target_buf].luanphan_agent_cwd = worktree
    vim.b[target_buf].luanphan_agent_last_used = 2

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
    assert_true(visible_agent_window_count() == 1, "agent switch left multiple agent windows visible")

    api.switch_to(repo, "worktree")
    assert_true(realpath(vim.fn.getcwd()) == realpath(repo), "workspace switch did not return to the repository")
    assert_true(window_for_buffer(target_buf) == nil, "previous workspace agent remained visible")
    assert_true(visible_agent_window_count() == 0, "workspace switch kept an agent from another cwd visible")
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

  local agent = require("luanphan.agents.terminal-chat").create({
    g_bufnr = "terminal_reference_view_agent_bufnr",
    notify_prefix = "terminal_reference_view_agent",
    augroup_prefix = "TerminalReferenceViewAgent",
    hint_open = "<smoke>",
    defaults = { cmd = "sh" },
  })
  agent.setup()
  agent.toggle()
  wait_until("agent terminal for reference view", function()
    return visible_agent_window_count() == 1
  end, 1000)

  local function assert_resize_restores_float(win, label)
    local width = vim.api.nvim_win_get_width(win)
    vim.api.nvim_win_set_config(win, { width = width - 1 })
    vim.api.nvim_exec_autocmds("VimResized", {})
    assert_true(vim.api.nvim_win_get_width(win) == width, label .. " did not restore its saved width")
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
  vim.wait(30)
  vim.cmd("stopinsert")
  vim.api.nvim_win_set_cursor(terminal_win, { 10, 0 })
  vim.api.nvim_win_call(terminal_win, function()
    vim.cmd("normal! zt")
  end)
  local saved_view = vim.api.nvim_win_call(terminal_win, vim.fn.winsaveview)

  local references = require("luanphan.terminal_references")
  assert_true(references.open(target_path, 1, 1), "agent terminal reference did not open")
  assert_true(not vim.api.nvim_win_is_valid(terminal_win), "agent terminal reference left its float open")

  agent.toggle()
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
  close_agent_terminals()
  local target_buf = vim.fn.bufnr(target_path)
  if target_buf >= 0 and vim.api.nvim_buf_is_valid(target_buf) then
    pcall(vim.api.nvim_buf_delete, target_buf, { force = true })
  end
  vim.g.terminal_reference_view_agent_bufnr = nil
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
    "vim.g.luanphan_agent_status_dir = root .. '/status'",
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
    "local sessions = require('luanphan.agents.sessions')",
    "for _, id in ipairs({ first, second }) do",
    "  vim.env.TEST_AGENT_THREAD = id",
    "  local buf = assert(agents.new(agent))",
    "  assert(vim.wait(3000, function() return vim.b[buf].luanphan_agent_thread_id == id end), 'missing exact thread ID')",
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
    "assert(vim.b.luanphan_agent_thread_id == second, 'reattach did not select the most recent running thread')",
    "assert(#require('luanphan.agents.sessions').instances(false) == 2, 'reattach lost a running pane')",
    "assert(#vim.fn.readfile(root .. '/invocations') == 2, 'reattach relaunched an existing thread')",
  })
  assert_true(vim.system({ "tmux", "-S", agent_socket(script), "kill-server" }):wait().code == 0,
    "could not stop the isolated agent server")
  run({
    "agents.toggle()",
    "local main = vim.api.nvim_get_current_win()",
    "local sidebar = assert(vim.w[main].luanphan_window_bar)",
    "local second_buf = vim.api.nvim_get_current_buf()",
    "assert(vim.b.luanphan_agent_thread_id == second, 'did not resume the most recent thread')",
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
    "assert(vim.api.nvim_get_current_win() == main and vim.b.luanphan_agent_thread_id == first, 'wrong sidebar thread resumed')",
    "assert(vim.wait(3000, function()",
    "  return (vim.b.term_title or ''):find('Example', 1, true)",
    "end), 'missing agent title')",
    "assert(require('luanphan.view_container').tab_label(vim.api.nvim_get_current_buf()) == 'Example 000000000001', 'unexpected agent tab label')",
    "if agent == 'cursor' then",
    "  local send = require('luanphan.terminal.window').send",
    "  local buf = vim.api.nvim_get_current_buf()",
    "  assert(vim.wait(3000, function() return vim.b.luanphan_agent_program_status == 'idle' end), 'Cursor has no startup status')",
    "  send(buf, 'submit\\n')",
    "  assert(vim.wait(3000, function() return vim.b.luanphan_agent_program_status == 'working' end), 'Cursor has no working status')",
    "  assert(vim.b[second_buf].luanphan_agent_program_status == 'idle', 'another Cursor terminal was marked working')",
    "  send(buf, 'stop\\n')",
    "  assert(vim.wait(3000, function() return vim.b.luanphan_agent_program_status == 'done' end), 'Cursor kept its working status')",
    "end",
    "local cwd = vim.uv.fs_realpath(vim.fn.getcwd())",
    "assert(vim.wait(3000, function()",
    "  local lines = vim.fn.readfile(root .. '/invocations')",
    "  return vim.tbl_contains(lines, resume .. '|' .. cwd .. '|' .. first)",
    "    and vim.tbl_contains(lines, resume .. '|' .. cwd .. '|' .. second)",
    "end), 'agent did not receive the exact IDs and original directory')",
    "vim.cmd('quit')",
    "local sessions = require('luanphan.agents.sessions')",
    "assert(vim.wait(3000, function()",
    "  local saved = sessions.list()",
    "  return #saved == 1 and saved[1].thread_id == second",
    "end), 'closing one agent should remove only its saved record')",
  })
  run({
    "local saved = require('luanphan.agents.sessions').list()",
    "assert(#saved == 1 and saved[1].thread_id == second, 'editor exit should preserve the remaining agent')",
  })
  if agent == "cursor" then
    write(script, setup)
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
        return vim.rpcrequest(rpc, "nvim_eval", "get(b:, 'luanphan_agent_thread_id', '')") == second
      end, 4000)
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
    "local sessions = require('luanphan.agents.sessions')",
    "local terminal = require('luanphan.agents.terminal-chat')",
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
press('<leader>ne')
local editor = api.nvim_get_current_win()
assert(editor ~= main_win and api.nvim_get_current_buf() == main_buf, 'editor tile did not share the main buffer')
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
local linked = vim.fn.getcwd() .. '/editor-linked.txt'
local function command_click(path, line, col)
  assert(agents.focus('codex', agent, { view_mode = true }))
  local term_win = api.nvim_get_current_win()
  local reference = ('./%s:%d:%d'):format(vim.fs.basename(path), line, col)
  require('luanphan.terminal.window').send(agent, '\n' .. reference .. '\n')
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
assert(vim.b[first].luanphan_agent_name == 'terminal', 'new terminal did not create a shell')
press('<leader>e')
assert(vim.bo.filetype == 'agent-window-bar', 'could not focus the sidebar from the shell')
press('<leader>nt')
local second = vim.api.nvim_get_current_buf()
assert(first ~= second and vim.b[second].luanphan_agent_name == 'terminal', 'sidebar reused the first shell')
for _, buf in ipairs({ agent, first, second }) do
  local win = vim.fn.bufwinid(buf)
  assert(win ~= -1 and vim.w[win].luanphan_view_anchor, 'shell and agent do not share the tiled panel')
  press('<Tab>')
  assert(vim.api.nvim_get_current_buf() == buf, 'Tab did not follow shell and agent order')
end
assert(agents.send_selection('terminal') == false, 'shell was accepted as an agent prompt destination')
local marker = 'PANEL_SHELL_OUTPUT'
local send = require('luanphan.terminal.window').send
send(first,
  "printf '\\n%s\\n' " .. marker .. "; seq 1 150 | sed 's/^/history-line-/'\n")
assert(vim.wait(3000, function()
  return vim.tbl_contains(vim.api.nvim_buf_get_lines(first, 0, -1, false), 'history-line-150')
end, 20), 'plain shell could not execute a command')
send(second, [[seq 1 60 | sed 's/^/primary-line-/'; printf '\033[?1049h\033[2J\033[H%s\n' alternate-view]] .. '\n')
assert(vim.wait(3000, function()
  return vim.tbl_contains(vim.api.nvim_buf_get_lines(second, 0, -1, false), 'alternate-view')
end, 20), 'shell did not switch to its alternate screen')
local ids = { vim.b[first].luanphan_agent_thread_id, vim.b[second].luanphan_agent_thread_id }
assert(#sessions.list('terminal') == 2 and ids[1] ~= ids[2], 'shell slots were not saved independently')
vim.fn.writefile(ids, root .. '/ids')
assert(agents.open('codex', agent, { view_mode = true }))
os.exit(0)
]=])
  run([=[
agents.toggle()
assert(vim.b.luanphan_agent_thread_id == agent_id, 'restored shells took focus from the agent')
local shells = {}
for _, item in ipairs(sessions.instances(false)) do
  if item.agent == 'terminal' then shells[vim.b[item.bufnr].luanphan_agent_thread_id] = item end
end
local ids = vim.fn.readfile(root .. '/ids')
assert(vim.tbl_count(shells) == 2, 'panel did not recreate both shell slots')
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
    require('luanphan.terminal.window').send(item.bufnr, [[printf '\033[?1049l']] .. '\n')
    assert(vim.wait(4000, function() return has_line('primary-line-1') and has_line('primary-line-60') end),
      'reattaching while in the alternate screen lost primary scrollback')
  end
end
require('luanphan.terminal.window').send(shells[ids[1]].bufnr, 'exit\n')
assert(vim.wait(3000, function() return #sessions.list('terminal') == 1 end, 20),
  'exiting a shell did not remove its saved slot')

vim.g.luanphan_floating_tmux_socket = terminal_socket
vim.g.luanphan_floating_tmux_config = '/dev/null'
local floating = require('luanphan.terminal.floating')
floating.toggle()
assert(vim.wait(3000, function() return vim.b.luanphan_tmux_pane ~= nil end), 'floating terminal did not attach')
local function tmux(socket, ...)
  local result = vim.system(vim.list_extend({ 'tmux', '-S', socket }, { ... }), { text = true }):wait()
  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout)
end
local terminal_pid = tmux(terminal_socket, 'list-panes', '-a', '-F', '#{pane_pid}')
assert(terminal_pid:match('^%d+$'), 'agent processes appeared in the floating terminal server')
agents.toggle()
assert(vim.b.luanphan_agent_thread_id == agent_id, 'could not reopen the agent panel')
tmux(vim.env.LUANPHAN_AGENT_TMUX_SOCKET, 'kill-server')
assert(vim.wait(3000, function() return #sessions.instances(false) == 0 end), 'server loss left stale agent panes')
assert(#sessions.list('codex') == 1 and #sessions.list('terminal') == 1, 'server loss removed active session records')
assert(tmux(terminal_socket, 'list-panes', '-a', '-F', '#{pane_pid}') == terminal_pid, 'server loss affected the floating terminal')
agents.toggle()
assert(vim.wait(3000, function()
  return #sessions.instances(false) == 2 and vim.b.luanphan_agent_thread_id == agent_id
end), 'same editor could not recover the original agent and shell slots')
]=])
end

local function test_agent_view_container(repo)
  local shim_dir = temp_root .. "/agent-view-shims"
  local status_dir = temp_root .. "/agent-view-status"
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
  local old_status_dir = vim.g.luanphan_agent_status_dir
  local old_global_settings = vim.g.luanphan_global_settings_path
  local old_codex_sessions = vim.g.luanphan_codex_sessions_dir
  local old_cursor_sessions = vim.g.luanphan_cursor_sessions_dir
  local old_terminal_sessions = vim.g.luanphan_terminal_sessions_dir
  local settings_path = temp_root .. "/agent-view-settings.toml"
  local agents = require("luanphan.agents.main")
  vim.env.PATH = shim_dir .. ":" .. old_path
  vim.env.NVIM_AGENT_SMOKE_LOG = invoke_log
  vim.env.NVIM_AGENT_SMOKE_INPUT = input_log
  vim.g.luanphan_agent_status_dir = status_dir
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
        and agent_bufnr("codex_agent_bufnr") ~= nil
    end, 3000)
    local codex_buf = agent_bufnr("codex_agent_bufnr")
    local agent_win = vim.api.nvim_get_current_win()
    assert_agent_float(agent_win, "first agent container")
    local agent_height = vim.api.nvim_win_get_height(agent_win)
    local winbar = rendered_winbar(agent_win)
    assert_true(
      winbar:find("[codex]", 1, true) ~= nil,
      "single agent did not reserve its tab bar: " .. vim.inspect(winbar)
    )
    assert_terminal_grid_matches(codex_buf, agent_win, "first agent")
    invoke_map("<S-Tab>")
    assert_true(vim.api.nvim_get_current_buf() == codex_buf, "backward cycling changed a single agent tab")

    assert_true(agents.open("cursor"), "could not open the second terminal agent")
    wait_until("second agent tab", function()
      return visible_agent_window_count() == 1
        and agent_bufnr("cursor_agent_bufnr") ~= nil
        and vim.api.nvim_get_current_buf() == agent_bufnr("cursor_agent_bufnr")
    end, 3000)
    local cursor_buf = agent_bufnr("cursor_agent_bufnr")
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
        and #registered_agent_bufnrs("codex_agent_bufnr", repo) == 2
        and vim.api.nvim_get_current_buf() == agent_bufnr("codex_agent_bufnr")
    end, 3000)
    local second_codex_buf = agent_bufnr("codex_agent_bufnr")
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
      return vim.b[codex_buf].luanphan_agent_program_status == "done"
        and vim.b[second_codex_buf].luanphan_agent_program_status == "working"
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
      return #registered_agent_bufnrs("cursor_agent_bufnr", repo) == 2
        and vim.api.nvim_get_current_buf() == agent_bufnr("cursor_agent_bufnr")
    end, 3000)
    local second_cursor_buf = agent_bufnr("cursor_agent_bufnr")
    assert_true(second_cursor_buf ~= cursor_buf, "new Cursor tab reused the existing terminal")
    cursor_buf = second_cursor_buf

    assert_true(agents.new("claude"), "could not create the first Claude terminal")
    assert_true(agents.new("claude"), "could not create the second Claude terminal")
    wait_until("duplicate agent tabs", function()
      return #registered_agent_bufnrs("claude_agent_bufnr", repo) == 2
        and vim.api.nvim_get_current_buf() == agent_bufnr("claude_agent_bufnr")
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

    assert_true(agents.open("cursor"), "could not reactivate the selected terminal agent")
    wait_until("active agent before send", function()
      return vim.api.nvim_get_current_buf() == cursor_buf
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
      local last_claude = registered_agent_bufnrs("claude_agent_bufnr", repo)[2]
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
    terminal_io.send(first_cursor_buf, "\27]7501;state=done\27\\")
    wait_until("sidebar accepts terminal status from Cursor", function()
      return status_icon(main, first_cursor_buf) == "✓"
    end, 3000)
    terminal_io.send(first_cursor_buf, "\27]7501;state=clear\27\\")
    wait_until("sidebar clears the terminal status icon", function()
      return status_icon(main, first_cursor_buf) == nil
    end, 3000)
    local agent_status = require("luanphan.agents.status")
    assert_true(agent_status.write("codex", other_path, "done"), "could not record the hook's completion state")
    wait_until("sidebar receives hook completion without switching focus", function()
      local icon, col = status_icon(main, other_buf)
      return icon == "✓" and col == sidebar_config.width - 4
    end, 3000)
    terminal_io.send(other_buf, "\27]7501;state=working:app=codex\27\\")
    local frame
    wait_until("sidebar uses terminal status ahead of the hook status", function()
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
    require("luanphan.agents.window_bar").refresh(true)
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
  vim.g.luanphan_agent_status_dir = old_status_dir
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
  write_executable(fixture .. "/bin/mcodex", { "#!/bin/sh", "exec cat" })
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
local terminal = require('luanphan.agents.terminal-chat')
local view = require('luanphan.view_container')
local actions = require('telescope.actions')
local action_state = require('telescope.actions.state')
local function new_agent()
  return agents.new('codex', { view_mode = true })
end
local home, home_peer = new_agent(), new_agent()
agents.hide()
vim.cmd.cd({ args = { destination } })
local away, away_peer = new_agent(), new_agent()
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
assert(window_bar.select_session({ agent = 'codex', bufnr = home, path = vim.b[home].luanphan_agent_cwd }, { view_mode = true }),
  'sidebar could not select an individual agent session')

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
vim.fn.systemlist = systemlist
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
bar.opts.groups, worktree_api.activate_agent = groups, activate
assert(vim.api.nvim_get_current_buf() == away_peer and #view.group_windows(anchor) == 3,
  'Cmd+2 did not switch to the second workspace in place')
vim.api.nvim_set_current_win(sidebar)
vim.api.nvim_feedkeys(vim.keycode('<D-1>'), 'xt', false)
assert(vim.api.nvim_get_current_buf() == home and vim.w[anchor].luanphan_window_bar == sidebar,
  'Cmd+1 did not restore the first workspace from the sidebar')
vim.api.nvim_feedkeys(vim.keycode('<D-9>'), 'xt', false)
assert(vim.api.nvim_get_current_buf() == home, 'out-of-range window shortcut changed focus')

local home_path = vim.fn.getcwd()
require('luanphan.terminal.window').stop(away_peer)
assert(vim.wait(3000, function() return not vim.api.nvim_buf_is_valid(away_peer) end, 20),
  'could not reduce the destination to one tile')

-- Reproduce a leftover float for the same buffer in the current window group.
local peer_win = vim.fn.bufwinid(home_peer)
local extra = vim.api.nvim_open_win(home_peer, false, vim.api.nvim_win_get_config(peer_win))
vim.w[extra].luanphan_view_anchor = anchor
assert(window_bar.select_session({ agent = 'codex', bufnr = away, path = destination }, { view_mode = true }),
  'sidebar could not switch to the single-tile workspace')
assert(vim.api.nvim_get_current_win() == anchor and vim.api.nvim_win_get_buf(anchor) == away,
  'single tile did not reuse the panel anchor')
assert(#view.group_windows(anchor) == 2 and vim.w[anchor].luanphan_window_bar == sidebar,
  'single-tile workspace left a tile from the previous workspace on screen')
local single_width = vim.api.nvim_win_get_width(anchor)
assert(window_bar.select_session({ agent = 'codex', bufnr = home, path = home_path }, { view_mode = true }),
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
  callback = function() terminal.close_window(sidebar) end,
})
vim.api.nvim_exec_autocmds('User', { pattern = 'SmokeHideAgentPanel' })
for _, win in ipairs(windows) do
  assert(not vim.api.nvim_win_is_valid(win), 'closing the panel inside an autocmd left a window behind')
end
for _, buf in ipairs({ home, home_peer, away }) do
  assert(terminal.running(buf), 'hiding the panel stopped an agent job')
end
]], "\n", { plain = true }))
  write(script, script_lines)
  local output = vim.fn.systemlist(child_nvim_luafile_command(repo, script))
  assert_true(vim.v.shell_error == 0, table.concat(output, "\n"))
  vim.list_extend(restart_setup, vim.split([[
vim.o.columns = 160
local agents = require('luanphan.agents.main')
agents.toggle()
local sidebar = assert(vim.w.luanphan_window_bar)
local first = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(sidebar), 0, 1, false)[1]
assert(first == ' [1] ' .. vim.fs.basename(destination), 'restarting Neovim lost the reordered workspaces')
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
vim.fn.chansend(vim.b[new_pane].terminal_job_id, 'exit\n')
assert(vim.wait(3000, function() return api.nvim_get_current_buf() == other_window end), 'new terminal tab did not return to its neighbor')
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

vim.fn.chansend(vim.b[other_window].terminal_job_id, 'exit\n')
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

local function test_tmux_floating_terminal()
  if vim.fn.executable("tmux") == 0 then return end
  local root = uv.fs_mkdtemp("/tmp/nvim-tmux-XXXXXX")
  local script, socket = root .. "/test.lua", root .. "/socket"
  write(root .. "/tmux.conf", {
    "set -g default-shell /bin/sh", "set -g default-command 'exec /bin/sh'",
    "set -g focus-events on", "set -g window-size latest", "set -g renumber-windows on",
  })
  write(root .. "/redraw.py", {
    "import os, tty",
    "tty.setraw(0)",
    "width = os.get_terminal_size(0).columns",
    [[os.write(1, b"\033[38;2;255;80;20mBEFORE_CLEAR\033[0m plain\r\n" + b"OLD_OUTPUT\r\n" * 10)]],
    [[if os.read(0, 1) == b"\x0c":]],
    [[    os.write(1, b"\033[H\033[2J\033[38;2;255;80;20mAFTER_CLEAR\033[0m plain")]],
    [[    os.write(1, f"\033[7;{width - 14}HCURSOR_TEST_ROW\033[H".encode())]],
    [[if os.read(0, 1) == b"x":]],
    [[    os.write(1, f"\033[7;{width}H".encode())]],
    "os.read(0, 1)",
  })
  write(root .. "/prompt.py", {
    "import os, tty",
    "tty.setraw(0)",
    [[os.write(1, b"HISTORY_PROMPT\r\n> \r\n" * 90 + b"\033[H\033[2JLIVE_PROMPT\r\n> ")]],
    "os.read(0, 1)",
  })
  write(root .. "/focus.py", {
    "import os, tty",
    "tty.setraw(0)",
    [[os.write(1, b"HISTORY_FOCUS\r\n" * 90 + b"\033[H\033[2JFOCUS_PROMPT\r\n> ")]],
    [[if os.read(0, 1) == b"e":]],
    [[    os.write(1, b"\033[?1004hFOCUS_ENABLED")]],
    [[while True:]],
    [[    key = os.read(0, 1)]],
    [[    if key == b"\033" and os.read(0, 1) == b"[":]],
    [[        report = os.read(0, 1)]],
    [[        if report in (b"I", b"O"):]],
    [[            os.write(1, b"\033[999;1H\r\nUNEXPECTED_FOCUS")]],
    [[    elif key == b"x":]],
    [[        os.write(1, b"USER_INPUT")]],
  })
  local setup = {
    "local root = " .. string.format("%q", root),
    "vim.g.luanphan_floating_tmux_socket = root .. '/socket'",
    "vim.g.luanphan_floating_tmux_config = root .. '/tmux.conf'",
    "vim.g.luanphan_global_settings_path = root .. '/settings.toml'",
    "vim.g.luanphan_recent_paths_file = root .. '/recent.json'",
    "vim.o.columns, vim.o.lines = 160, 48",
  }
  local function run_child(body)
    write(script, vim.list_extend(vim.list_slice(setup), vim.split(body, "\n", { plain = true })))
    local output = vim.fn.systemlist(child_nvim_luafile_command(root, script))
    assert_true(vim.v.shell_error == 0, table.concat(output, "\n"))
  end
  local ok, err = xpcall(function()
    run_child([=[
local api = vim.api
local panel = require("luanphan.terminal.floating")
local function tmux(...)
  local argv = vim.list_extend({ "tmux", "-S", vim.g.luanphan_floating_tmux_socket }, { ... })
  local result = vim.system(argv, { text = true }):wait(2000)
  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout)
end
local function active() return vim.b.luanphan_tmux_pane end
local function pane_window(id)
  return vim.iter(api.nvim_list_wins()):find(function(win)
    return vim.b[api.nvim_win_get_buf(win)].luanphan_tmux_pane == id
  end)
end
local function config(id) return api.nvim_win_get_config(assert(pane_window(id))) end
local function same_grid(id)
  local cfg = config(id)
  return tmux("display-message", "-p", "-t", id, "#{pane_width}x#{pane_height}")
    == ("%dx%d"):format(cfg.width, cfg.height - 1)
end
local function wait(predicate, label)
  assert(vim.wait(4000, predicate), "timeout " .. label)
end
local function key(keys)
  api.nvim_feedkeys(vim.keycode(keys:gsub("<leader>", vim.g.mapleader)), "xt", false)
end
key("<leader>t")
wait(function() return active() and vim.bo.buftype == "terminal" end, "create and attach")
local first = active()
require("luanphan.global_settings").open_editor()
local settings_buf = api.nvim_get_current_buf()
local settings_lines = api.nvim_buf_get_lines(settings_buf, 0, -1, false)
local floating_section = vim.fn.index(settings_lines, "[floating_terminal]") + 1
for index = floating_section + 1, #settings_lines do
  if settings_lines[index]:match("^%[") then break end
  settings_lines[index] = settings_lines[index]:gsub("^total_width_percent = 100$", "total_width_percent = 80")
end
api.nvim_buf_set_lines(settings_buf, 0, -1, false, settings_lines)
key("q")
wait(function()
  local cfg = config(first)
  return cfg.col == 48 and cfg.width + 2 == 96
    and tmux("display-message", "-p", "-t", first, "#{pane_width}x#{pane_height}") ==
      ("%dx%d"):format(cfg.width, cfg.height - 1)
end, "saving floating terminal width resized the tmux grid")
local full = config(first)
assert(vim.deep_equal(full.border[1], { "┏", "DiagnosticOk" }), "single pane lacks the view mode border")
local bar_win = vim.w[pane_window(first)].luanphan_window_bar
local sidebar = api.nvim_win_get_config(bar_win)
assert(sidebar.col == 16 and sidebar.width + 2 == 32, "tmux sidebar did not resize and center with the terminal")
local shell_pid = tmux("display-message", "-p", "-t", first, "#{pane_pid}")
local first_buf = api.nvim_get_current_buf()
local single_input_border
vim.defer_fn(function()
  if api.nvim_get_mode().mode == "t" then single_input_border = config(first).border[1] end
  api.nvim_input("printf 'RESULT_%s\\n' PROBE_TEXT<CR><Esc>")
end, 20)
api.nvim_feedkeys("i", "xt!", false)
assert(vim.deep_equal(single_input_border, { "┏", "LuanphanTileInputBorder" }), "single pane lacks the input mode border")
assert(vim.deep_equal(config(first), full), "single pane did not return to the view mode border")
wait(function()
  return table.concat(api.nvim_buf_get_lines(first_buf, 0, -1, false), "\n"):find("RESULT_PROBE_TEXT", 1, true)
end, "terminal input and output")
tmux("send-keys", "-l", "-t", first, "cd /tmp")
tmux("send-keys", "-t", first, "Enter")
wait(function()
  return tmux("display-message", "-p", "-t", first, "#{pane_current_path}") == vim.uv.fs_realpath("/tmp")
end, "update the first shell working directory")
key("<leader>nt")
wait(function() return active() and active() ~= first end, "new terminal tile")
local second = active()
assert(tmux("display-message", "-p", "-t", second, "#{pane_current_path}") == vim.uv.fs_realpath("/tmp"),
  "new tile did not inherit the source shell's working directory")
assert(tmux("display-message", "-p", "-t", first, "#{window_id}")
  ~= tmux("display-message", "-p", "-t", second, "#{window_id}"), "tiles share a tmux window")
wait(function() return same_grid(first) and same_grid(second) end, "exact PTY sizes for two tiles")
local left, right = config(first), config(second)
assert(type(left.border) == "table" and type(right.border) == "table", "split panes lack their Neovim borders")
assert(left.col == full.col and left.col + left.width + 2 == right.col
  and right.col + right.width == full.col + full.width and left.height == full.height,
  "split panes did not fill the Neovim tile area")
assert(vim.deep_equal(right.border[1], { "┏", "DiagnosticOk" }) and left.border[1] == "┌",
  "view mode should show a heavy green border only on the focused tile")
key("<leader>e")
assert(api.nvim_get_current_win() == bar_win, "could not focus the tmux sidebar")
api.nvim_win_set_cursor(bar_win, { 1, 0 })
key("<leader>e")
assert(active() == second and api.nvim_win_get_cursor(bar_win)[1] == 3,
  "leaving the tmux sidebar did not restore the row for the focused pane")
local editing_border
vim.defer_fn(function()
  if api.nvim_get_mode().mode == "t" then editing_border = config(second).border end
  api.nvim_input("<Esc>")
end, 20)
api.nvim_feedkeys("i", "xt!", false)
assert(editing_border and vim.deep_equal(editing_border[1], { "┏", "LuanphanTileInputBorder" }),
  "focused tile did not switch to orange in terminal input mode")
assert(vim.deep_equal(config(second), right), "leaving terminal input did not restore the view mode border and layout")

local function screen_position(label, offset)
  vim.cmd.redraw({ bang = true })
  local cfg = config(second)
  local x = cfg.col + 2 + (offset or 0)
  for y = cfg.row + 3, cfg.row + cfg.height + 1 do
    local text = {}
    for col = x, x + #label - 1 do text[#text + 1] = vim.fn.screenstring(y, col) end
    if table.concat(text) == label then return y, x end
  end
end
tmux("send-keys", "-l", "-t", second, "python3 " .. vim.fn.shellescape(root .. "/redraw.py"))
tmux("send-keys", "-t", second, "Enter")
wait(function() return screen_position("BEFORE_CLEAR") end, "colored text on the tile")
vim.defer_fn(function() api.nvim_input("<C-l><Esc>") end, 20)
api.nvim_feedkeys("i", "xt!", false)
wait(function() return screen_position("AFTER_CLEAR") and not screen_position("OLD_OUTPUT") end,
  "Ctrl+l should show the cleared screen without a second input")
local row, col = screen_position("AFTER_CLEAR")
assert(vim.fn.screenattr(row, col) ~= vim.fn.screenattr(row, col + #"AFTER_CLEAR "),
  "the streamed tmux redraw lost terminal RGB colors")

local cursor_matches, observed
local started = vim.uv.now()
local timer = assert(vim.uv.new_timer())
vim.defer_fn(function() api.nvim_input("x") end, 20)
timer:start(50, 20, vim.schedule_wrap(function()
  if vim.uv.now() - started < 3000 and api.nvim_get_mode().mode ~= "t" then return end
  local pos = api.nvim_win_get_cursor(0)
  observed = { pos[1] - vim.fn.line("w0"), pos[2] }
  cursor_matches = observed[1] == 6 and observed[2] == right.width - 1
    and screen_position("CURSOR_TEST_ROW", right.width - #"CURSOR_TEST_ROW") ~= nil
  if cursor_matches or vim.uv.now() - started >= 3000 then
    timer:stop()
    api.nvim_input("<Esc>")
  end
end))
api.nvim_feedkeys("i", "xt!", false)
timer:close()
assert(cursor_matches, "the caret did not follow a cursor-only tmux redraw: " .. vim.inspect(observed))

key("<leader>nt")
wait(function() return active() and active() ~= first and active() ~= second end, "third terminal tile")
local bottom = active()
wait(function() return same_grid(bottom) end, "exact PTY size for the small tile")
local bottom_buf = api.nvim_get_current_buf()
local function bottom_lines()
  return api.nvim_buf_get_lines(bottom_buf, 0, -1, false)
end
for first_row = 1, 81, 80 do
  local last_row = first_row + 79
  local command = ("i=%d; while [ $i -le %d ]; do printf 'SCROLL_%%03d\\n' $i; i=$((i+1)); done")
    :format(first_row, last_row)
  tmux("send-keys", "-l", "-t", bottom, command)
  tmux("send-keys", "-t", bottom, "Enter")
  local marker = ("SCROLL_%03d"):format(last_row)
  wait(function()
    return vim.iter(bottom_lines()):any(function(line) return vim.trim(line) == marker end)
  end, "scrollback burst reached the small tile")
end
local next_row = 1
for _, line in ipairs(bottom_lines()) do
  local row = tonumber(line:match("^SCROLL_(%d+)%s*$"))
  if row then
    assert(row == next_row, ("small tile scrollback skipped row %d and resumed at row %d"):format(next_row, row))
    next_row = next_row + 1
  end
end
assert(next_row == 161, "small tile scrollback lost output")
tmux("resize-window", "-t", second, "-x", "100", "-y", "30")
wait(function() return same_grid(second) end, "restore the tile grid after a native resize")
local main, upper, lower = config(first), config(second), config(bottom)
assert(main.row == upper.row and main.col < upper.col and upper.col == lower.col
  and upper.row + upper.height + 2 == lower.row and lower.row + lower.height + 2 == main.row + main.height + 2,
  "Neovim lost its left/top-right/bottom-right tile layout after an external tmux layout change")
tmux("send-keys", "-l", "-t", first, "printf 'LIVE_%s\\n' MATCHING_TILE")
tmux("send-keys", "-t", first, "Enter")
wait(function()
  local win = pane_window(first)
  return win and table.concat(api.nvim_buf_get_lines(api.nvim_win_get_buf(win), 0, -1, false), "\n")
    :find("LIVE_MATCHING_TILE", 1, true)
end, "the matching tmux grid still streams into the Neovim tile")
local lower_win = pane_window(bottom)
for _, move in ipairs({ { "<C-S-k>", upper.row }, { "<C-S-j>", lower.row } }) do
  key(move[1])
  wait(function() return config(bottom).row == move[2] end, "move the tmux pane vertically")
  assert(active() == bottom and api.nvim_get_current_win() == lower_win
    and tmux("display-message", "-p", "-t", bottom, "#{pane_active}") == "1",
    "moving vertically left focus in the original tile slot")
end
tmux("kill-pane", "-t", bottom)
tmux("select-window", "-t", second)
wait(function() return active() == second and not pane_window(bottom) end, "remove third tile")
local tile = api.nvim_get_current_win()
assert(vim.w[tile].luanphan_view_anchor ~= tile, "the split did not open a separate tile")
api.nvim_win_close(tile, true)
assert(not vim.iter(api.nvim_list_wins()):any(function(win)
  return vim.b[api.nvim_win_get_buf(win)].luanphan_tmux_pane
end), "closing a tile left other panes visible")
panel.toggle()
wait(function() return active() == second end, "reattach after closing a tile")
local moved_win = api.nvim_get_current_win()
local right_edge = api.nvim_win_get_config(0).col
key("<C-S-h>")
wait(function()
  return active() == second and api.nvim_win_get_config(0).col < right_edge
    and vim.json.decode(tmux("display-message", "-p", "-t", second, "#{@luanphan-view-window}")).pane_order == 1
end, "tmux pane move")
key("<C-S-l>")
wait(function() return config(second).col == right_edge end, "move the tmux pane right")
assert(active() == second and api.nvim_get_current_win() == moved_win
  and tmux("display-message", "-p", "-t", second, "#{pane_active}") == "1",
  "moving right left focus in the original tile slot")
key("<C-S-h>")
wait(function() return active() == second and config(second).col < right_edge end, "move the tmux pane left again")
key("<C-l>")
wait(function() return active() == first end, "tile navigation")
key("<leader>nw")
wait(function() return active() and active() ~= first and active() ~= second end, "native window")
local third = active()
for _, jump in ipairs({ { "<C-o>", first }, { "<C-o>", second }, { "<C-i>", first }, { "<C-i>", third } }) do
  vim.fn.maparg(jump[1], "n", false, true).callback()
  wait(function() return active() == jump[2] end, "tmux pane jump history")
end
for _, key_name in ipairs({ "<Tab>", "<S-Tab>" }) do
  key(key_name)
  assert(active() == third, "cycling left a one-pane tmux window")
end
vim.fn.maparg("<C-o>", "n", false, true).callback()
wait(function() return active() == first end, "previous window from history")
key("<Tab>")
wait(function() return active() == second end, "Tab wrapped within the tmux window")
key("<S-Tab>")
wait(function() return active() == first end, "Shift-Tab selected the previous tmux pane")
key("<leader>e")
vim.cmd.redraw({ bang = true })
local sidebar_win = api.nvim_get_current_win()
local last_pane_row = vim.fn.screenpos(sidebar_win, 3, 2).row
local next_window_row = vim.fn.screenpos(sidebar_win, 4, 2).row
assert(last_pane_row > 0 and next_window_row == last_pane_row + 2,
  "vertical window bar did not leave one blank screen line between windows")
local prompt, rename
local input = vim.ui.input
vim.ui.input = function(opts, callback) prompt, rename = opts, callback end
api.nvim_win_set_cursor(0, { 2, 0 })
key("e")
assert(not prompt, "pane row opened the window rename prompt")
api.nvim_win_set_cursor(0, { 4, 0 })
key("e")
vim.ui.input = input
assert(prompt and prompt.default == tmux("display-message", "-p", "-t", third, "#{window_name}"),
  "rename prompt did not use the selected tmux window name")
local new_name = "-Example 100% #{window_id}"
local window_bar_buf = api.nvim_get_current_buf()
rename(new_name)
local displayed_name = " [2] " .. new_name
local display_width = api.nvim_win_get_width(sidebar_win) - 1
if #displayed_name > display_width then displayed_name = displayed_name:sub(1, display_width - 1) .. "…" end
wait(function()
  return vim.tbl_contains(api.nvim_buf_get_lines(window_bar_buf, 0, -1, false), displayed_name)
end, "renamed window in the tmux bar")
assert(tmux("display-message", "-p", "-t", third, "#{window_name}") == new_name, "tmux did not store the literal name")
assert(api.nvim_get_current_buf() == window_bar_buf and api.nvim_win_get_cursor(0)[1] == 4,
  "rename moved focus away from the window row")
key("o")
wait(function() return active() == third end, "window bar selected the second tmux window")
panel.hide()
assert(tmux("display-message", "-p", "-t", first, "#{pane_pid}") == shell_pid, "detach stopped the shell")
tmux("send-keys", "-l", "-t", first, "printf 'DETACHED_%s\\n' OUTPUT")
tmux("send-keys", "-t", first, "Enter")
wait(function()
  return tmux("capture-pane", "-p", "-t", first):find("DETACHED_OUTPUT", 1, true)
end, "tmux accepted output while the panel was hidden")
vim.fn.writefile({ first, shell_pid, third }, root .. "/panes")
]=])
    run_child([=[
local api = vim.api
local saved = vim.fn.readfile(root .. "/panes")
local panel = require("luanphan.terminal.floating")
panel.toggle()
assert(vim.wait(4000, function() return vim.b.luanphan_tmux_pane == saved[3] end), "reopen lost selected pane")
vim.fn.maparg("<leader>e", "n", false, true).callback()
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.fn.maparg("o", "n", false, true).callback()
assert(vim.wait(4000, function()
  if vim.b.luanphan_tmux_pane ~= saved[1] then return false end
  local output = table.concat(api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  return output:find("RESULT_PROBE_TEXT", 1, true) and output:find("DETACHED_OUTPUT", 1, true)
end), "reattach lost scrollback or output produced while hidden")
local result = vim.system({ "tmux", "-S", vim.g.luanphan_floating_tmux_socket,
  "display-message", "-p", "-t", saved[1], "#{pane_pid}" }, { text = true }):wait()
assert(result.code == 0 and vim.trim(result.stdout) == saved[2], "reattach replaced the shell")

local function tmux(...)
  local args = vim.list_extend({ "tmux", "-S", vim.g.luanphan_floating_tmux_socket }, { ... })
  local reply = vim.system(args, { text = true }):wait()
  assert(reply.code == 0, reply.stderr)
  return vim.trim(reply.stdout)
end
local prompt_pane = tmux("new-window", "-d", "-P", "-F", "#{pane_id}", "python3 " .. vim.fn.shellescape(root .. "/prompt.py"))
assert(vim.wait(4000, function()
  return tmux("capture-pane", "-p", "-t", prompt_pane):find("LIVE_PROMPT", 1, true)
end), "prompt fixture did not produce scrollback")
local bars = require("luanphan.view_container.window_bar")
local function select_window(index, id)
  assert(vim.wait(4000, function() return bars.focus_window(index) end), "could not switch tmux window")
  assert(vim.wait(4000, function() return vim.b.luanphan_tmux_pane == id and vim.bo.buftype == "terminal" end),
    "switch did not focus the requested tmux pane")
end
local function live_view()
  local view = vim.fn.winsaveview()
  local line = api.nvim_buf_get_lines(0, view.topline - 1, view.topline, false)[1] or ""
  return vim.trim(line) == "LIVE_PROMPT"
end
select_window(2, saved[3])
tmux("send-keys", "-l", "-t", saved[1], "seq 1 70; printf 'HIDDEN_%s\\n' OUTPUT")
tmux("send-keys", "-t", saved[1], "Enter")
assert(vim.wait(4000, function()
  return tmux("capture-pane", "-p", "-t", saved[1]):find("HIDDEN_OUTPUT", 1, true)
end), "hidden shell did not produce output")
select_window(1, saved[1])
assert(vim.wait(4000, function()
  local view = vim.fn.winsaveview()
  local visible = api.nvim_buf_get_lines(0, view.topline - 1, vim.fn.line("w$"), false)
  return vim.tbl_contains(visible, "HIDDEN_OUTPUT")
end), "returning to a live shell did not follow hidden output")
select_window(3, prompt_pane)
assert(vim.wait(4000, live_view), "initial prompt did not show the live screen")
vim.defer_fn(function() api.nvim_input("<Esc>") end, 20)
api.nvim_feedkeys("i", "xt!", false)
select_window(2, saved[3])
select_window(3, prompt_pane)
assert(vim.wait(4000, live_view), "returning to the prompt exposed its scrollback as the live screen")

api.nvim_win_set_cursor(0, { 5, 0 })
vim.cmd("normal! zt")
local scrolled = vim.fn.winsaveview()
select_window(2, saved[3])
select_window(3, prompt_pane)
assert(vim.wait(4000, function()
  local restored = vim.fn.winsaveview()
  return restored.topline == scrolled.topline and restored.lnum == scrolled.lnum
end), "returning to a pane lost the user's scrollback view")

local prompt_command = "python3 " .. vim.fn.shellescape(root .. "/prompt.py")
local left = tmux("new-window", "-d", "-P", "-F", "#{pane_id}", prompt_command)
local right = tmux("split-window", "-h", "-P", "-F", "#{pane_id}", "-t", left, prompt_command)
local pid_left = tmux("display-message", "-p", "-t", left, "#{pane_pid}")
local pid_right = tmux("display-message", "-p", "-t", right, "#{pane_pid}")
local function pane_view(id)
  for _, win in ipairs(api.nvim_list_wins()) do
    local buf = api.nvim_win_get_buf(win)
    if vim.b[buf].luanphan_tmux_pane == id then
      local view = api.nvim_win_call(win, vim.fn.winsaveview)
      return { view.topline, view.lnum, view.col, lines = api.nvim_buf_get_lines(buf, 0, -1, false) }
    end
  end
end
for _, id in ipairs({ left, right }) do
  assert(vim.wait(4000, function() return tmux("capture-pane", "-p", "-t", id):find("LIVE_PROMPT", 1, true) end))
end
tmux("select-window", "-t", right)
assert(vim.wait(4000, function()
  for _, id in ipairs({ left, right }) do
    local pane = pane_view(id)
    if not pane or pane[1] <= 1 or vim.trim(pane.lines[pane[1]]) ~= "LIVE_PROMPT" then return false end
  end
  return vim.b.luanphan_tmux_pane == right
end), "split panes did not show their live screen")
assert(tmux("display-message", "-p", "-t", left, "#{window_id}")
  ~= tmux("display-message", "-p", "-t", right, "#{window_id}"), "native split was not migrated")
assert(tmux("display-message", "-p", "-t", left, "#{pane_pid}") == pid_left
  and tmux("display-message", "-p", "-t", right, "#{pane_pid}") == pid_right, "migration replaced a native process")
local before = { pane_view(left), pane_view(right) }
for _, view in ipairs(before) do
  assert(vim.iter(view.lines):any(function(line) return vim.trim(line) == "HISTORY_PROMPT" end),
    "migration lost native pane scrollback")
end
for _ = 1, 3 do
  select_window(2, saved[3])
  select_window(4, right)
  vim.cmd.redraw()
  assert(vim.deep_equal(before, { pane_view(left), pane_view(right) }),
    "switching back exposed the wrong first frame")
  vim.wait(80, function() return false end)
  assert(vim.deep_equal(before, { pane_view(left), pane_view(right) }),
    "switching back shifted a pane's screen or scrollback")
end

local focus_pane = tmux("new-window", "-d", "-P", "-F", "#{pane_id}",
  "python3 " .. vim.fn.shellescape(root .. "/focus.py"))
assert(vim.wait(4000, function()
  return tmux("capture-pane", "-p", "-t", focus_pane):find("FOCUS_PROMPT", 1, true)
end))
tmux("select-window", "-t", focus_pane)
local function visible_output(marker)
  return vim.b.luanphan_tmux_pane == focus_pane
    and table.concat(api.nvim_buf_get_lines(0, 0, -1, false), "\n"):find(marker, 1, true)
end
assert(vim.wait(4000, function()
  return visible_output("FOCUS_PROMPT") and vim.fn.winsaveview().topline > 1
end), "focus reporting fixture did not show its live prompt")
tmux("send-keys", "-t", focus_pane, "e")
assert(vim.wait(4000, function() return visible_output("FOCUS_ENABLED") end), "focus reporting was not enabled")
local top = vim.fn.winsaveview().topline
local input_top
vim.defer_fn(function()
  input_top = vim.fn.winsaveview().topline
  api.nvim_input("x<Esc>")
end, 150)
api.nvim_feedkeys("i", "xt!", false)
assert(vim.wait(4000, function() return visible_output("USER_INPUT") end), "terminal mode lost typed input")
assert(input_top == top and not visible_output("UNEXPECTED_FOCUS"),
  "entering or leaving terminal mode sent a focus report to tmux")
vim.fn.maparg("<leader>e", "n", false, true).callback()
local bar = vim.iter(pairs(vim.luanphan_window_bars)):find(function(item) return item.win == api.nvim_get_current_win() end)
local initial = vim.tbl_map(function(group) return group.id end, bar.rows[1].groups)
local session_id = tmux("display-message", "-p", "-t", focus_pane, "#{session_id}")
api.nvim_win_set_cursor(bar.win, { 1, 0 })
api.nvim_feedkeys(vim.keycode("<D-S-j>"), "xt", false)
assert(bar.rows[1].group.id == initial[2], "native terminal window did not move immediately")
assert(not pcall(tmux, "show-options", "-v", "-t", session_id, "@luanphan-window-order"),
  "moving a terminal window saved before the debounce")
panel.hide()
initial[1], initial[2] = initial[2], initial[1]
assert(vim.deep_equal(vim.json.decode(tmux("show-options", "-v", "-t", session_id, "@luanphan-window-order")), initial),
  "detaching the terminal lost the pending window order")
panel.toggle()
assert(vim.wait(4000, function() return vim.b.luanphan_tmux_pane == focus_pane end))
local ref = vim.uv.fs_realpath(root) .. "/example.txt"
vim.fn.writefile({ "first", "second" }, ref)
local terminal_win = api.nvim_get_current_win()
assert(require("luanphan.terminal_references").open(ref, 2, 3), "tmux could not open the editor tile")
local editor_win, editor_buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
assert(editor_win ~= terminal_win and api.nvim_win_is_valid(terminal_win) and api.nvim_buf_get_name(editor_buf) == ref,
  "tmux opened its reference outside the panel")
assert(vim.deep_equal(api.nvim_win_get_cursor(editor_win), { 2, 2 }), "tmux editor tile lost the reference position")
api.nvim_feedkeys(vim.keycode("<C-h>"), "xt", false)
assert(vim.wait(4000, function() return api.nvim_get_current_win() == terminal_win end), "editor could not navigate to tmux")
api.nvim_feedkeys(vim.keycode("<C-l>"), "xt", false)
assert(vim.wait(4000, function() return api.nvim_get_current_win() == editor_win end), "tmux could not navigate to the editor")
local editor_col = api.nvim_win_get_config(editor_win).col
api.nvim_feedkeys(vim.keycode("<C-S-h>"), "xt", false)
assert(vim.wait(4000, function() return api.nvim_win_get_config(editor_win).col < editor_col end)
  and api.nvim_get_current_win() == editor_win, "moving the tmux editor tile lost its position or focus")
api.nvim_feedkeys(vim.keycode(vim.g.mapleader .. "o"), "xt", false)
assert(api.nvim_win_get_config(0).relative == "" and api.nvim_get_current_buf() == editor_buf
  and not api.nvim_win_is_valid(terminal_win), "tmux editor tile did not open the same buffer in the main editor")
panel.toggle()
assert(vim.wait(4000, function()
  local anchor = require("luanphan.view_container").group_anchor(api.nvim_get_current_win())
  local win = require("luanphan.view_container.editor").window(anchor)
  return win and api.nvim_win_get_buf(win) == editor_buf
end), "tmux did not restore the editor tile after reopening")
]=])
  end, debug.traceback)
  vim.system({ "tmux", "-S", socket, "kill-server" }):wait()
  vim.fn.delete(root, "rf")
  assert_true(ok, tostring(err))
end

local function test_terminal_view_container(repo)
  local old_cwd = vim.fn.getcwd()
  close_toggleterm_terminals()
  require("lazy").load({ plugins = { "toggleterm.nvim" } })
  local terminal_config = require("toggleterm.config").get()
  local original_shell = terminal_config.shell
  local original_env = vim.env.ENV
  local original_settings = vim.g.luanphan_global_settings_path
  local original_sessions = vim.g.luanphan_terminal_sessions_dir
  local panel_settings = temp_root .. "/terminal-panel-settings.toml"
  vim.g.luanphan_global_settings_path = panel_settings
  vim.g.luanphan_terminal_sessions_dir = temp_root .. "/terminal-panel-agent-sessions"
  write(panel_settings, { "[terminal_split]", 'window_bar_style = "horizontal"', 'display_style = "tabs"' })
  terminal_config.shell = "/bin/sh"
  vim.env.ENV = nil
  local agent_buf

  local function window_bar()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "window-bar" then return win end
    end
    error("integrated window bar is missing")
  end

  local function window_labels()
    return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(window_bar()), 0, 1, false)[1]
  end

  local ok, err = xpcall(function()
    vim.cmd("cd " .. vim.fn.fnameescape(repo))
    invoke_map("<leader>-t")
    wait_until("first terminal tab", function()
      return visible_toggleterm_window_count() == 1
        and vim.b[vim.api.nvim_get_current_buf()].luanphan_toggleterm
        and vim.api.nvim_get_mode().mode:sub(1, 1) ~= "t"
    end, 3000)

    local first_buf = vim.api.nvim_get_current_buf()
    invoke_map("<C-h>")
    assert_true(vim.api.nvim_get_current_buf() ~= first_buf and visible_toggleterm_window_count() == 1,
      "leaving the integrated terminal hid it or failed to focus the editor")
    vim.api.nvim_feedkeys(vim.keycode("<C-l>"), "xt", false)
    wait_until("editor can return to the docked terminal", function()
      return vim.api.nvim_get_current_buf() == first_buf
    end, 3000)
    local first_job = vim.b[first_buf].terminal_job_id
    local first_win = vim.api.nvim_get_current_win()
    local body_frame = vim.api.nvim_win_get_config(first_win)
    local bar_frame = vim.api.nvim_win_get_config(window_bar())
    assert_true(window_labels():find("[Window 1]", 1, true), "first integrated window is missing")
    assert_true(bar_frame.height == 1 and body_frame.row == bar_frame.row + 1,
      "integrated window bar leaves an empty row above its tabs")

    local agents = require("luanphan.agents.main")
    assert_true(agents.new("terminal", { view_mode = true }), "could not open a shell in the agent panel")
    agent_buf = vim.api.nvim_get_current_buf()
    assert_true(agents.hide(), "could not hide the agent panel before testing its toggle")
    vim.api.nvim_set_current_win(first_win)
    invoke_map("<leader>a")
    local agent_win = vim.api.nvim_get_current_win()
    local agent_bar = vim.w[agent_win].luanphan_window_bar
    local terminal_layer = math.max(body_frame.zindex, bar_frame.zindex)
    assert_true(vim.api.nvim_get_current_buf() == agent_buf, "agent toggle did not restore its shell")
    assert_true(vim.api.nvim_win_get_config(agent_win).zindex > terminal_layer
        and agent_bar and vim.api.nvim_win_get_config(agent_bar).zindex > terminal_layer,
      "integrated terminal can draw over the agent panel")
    assert_true(agents.hide(), "could not close the agent overlay")
    vim.api.nvim_buf_delete(agent_buf, { force = true })
    assert_true(vim.api.nvim_win_is_valid(first_win) and vim.fn.jobwait({ first_job }, 0)[1] == -1,
      "toggling agents stopped the integrated terminal")
    vim.api.nvim_set_current_win(first_win)

    invoke_map("<S-Tab>")
    assert_true(vim.api.nvim_get_current_buf() == first_buf, "backward cycling changed a single terminal tab")
    assert_true(
      realpath(vim.b[first_buf].luanphan_terminal_reference_cwd) == realpath(repo),
      "toggle terminal did not attach terminal references"
    )
    vim.fn.chansend(first_job, "i=1; while [ \"$i\" -le 100 ]; do printf 'first-%03d\\n' \"$i\"; i=$((i+1)); done\n")
    wait_until("first terminal scrollback", function()
      return vim.api.nvim_buf_line_count(first_buf) >= 80
    end, 3000)
    vim.cmd("stopinsert")
    vim.api.nvim_win_set_cursor(first_win, { 10, 0 })
    vim.api.nvim_win_call(first_win, function()
      vim.cmd("normal! zt")
    end)
    local first_view = vim.api.nvim_win_call(first_win, vim.fn.winsaveview)

    local new_map = vim.fn.maparg("<leader>fn", "n", false, true)
    assert_true(type(new_map) == "table" and type(new_map.callback) == "function", "terminal view mode is missing new-tab creation")
    new_map.callback()
    wait_until("second terminal tab", function()
      return visible_toggleterm_window_count() == 1
        and vim.b[vim.api.nvim_get_current_buf()].luanphan_toggleterm
        and vim.api.nvim_get_current_buf() ~= first_buf
        and vim.api.nvim_get_mode().mode:sub(1, 1) ~= "t"
    end, 3000)

    local second_buf = vim.api.nvim_get_current_buf()
    local second_job = vim.b[second_buf].terminal_job_id
    local winbar = rendered_winbar()
    assert_true(winbar:find("terminal 1", 1, true) ~= nil, "terminal tab bar omitted the first terminal")
    assert_true(winbar:find("[terminal 2]", 1, true) ~= nil, "terminal tab bar did not select the new terminal")

    vim.fn.chansend(first_job, "printf '\\033]2;Background shell\\007'\n")
    wait_until("background shell title", function()
      return vim.b[first_buf].term_title == "Background shell"
    end, 3000)
    assert_true(rendered_winbar():find("Background shell", 1, true), "hidden shell title was not updated")
    for _, title in ipairs({ "Shell 100% %{1+1}", "Renamed shell" }) do
      vim.fn.chansend(second_job, "printf '\\033]2;%s\\007' " .. vim.fn.shellescape(title) .. "\n")
      wait_until("shell terminal title", function()
        return vim.b[second_buf].term_title == title
      end, 3000)
      assert_true(rendered_winbar():find("[" .. title .. "]", 1, true), "shell tab did not render its title literally")
    end

    vim.fn.chansend(second_job, "i=1; while [ \"$i\" -le 100 ]; do printf 'second-%03d\\n' \"$i\"; i=$((i+1)); done\n")
    wait_until("second terminal scrollback", function()
      return vim.api.nvim_buf_line_count(second_buf) >= 80
    end, 3000)
    vim.cmd("stopinsert")
    local second_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_cursor(second_win, { 20, 0 })
    vim.api.nvim_win_call(second_win, function()
      vim.cmd("normal! zt")
    end)
    local second_view = vim.api.nvim_win_call(second_win, vim.fn.winsaveview)

    invoke_map("<leader>-t")
    assert_true(visible_toggleterm_window_count() == 0, "terminal toggle did not hide the container")
    assert_true(vim.fn.jobwait({ first_job, second_job }, 0)[1] == -1, "hiding the terminal container stopped the first shell")
    assert_true(vim.fn.jobwait({ first_job, second_job }, 0)[2] == -1, "hiding the terminal container stopped the second shell")

    invoke_map("<leader>-t")
    wait_until("last terminal tab restored", function()
      if vim.api.nvim_get_current_buf() ~= second_buf then
        return false
      end
      local view = vim.api.nvim_win_call(vim.api.nvim_get_current_win(), vim.fn.winsaveview)
      return view.lnum == second_view.lnum
        and view.topline == second_view.topline
        and vim.api.nvim_get_mode().mode:sub(1, 1) ~= "t"
    end, 3000)

    vim.cmd("stopinsert")
    local next_map = vim.fn.maparg("<Tab>", "n", false, true)
    assert_true(rendered_winbar():find("[Renamed shell]", 1, true), "reopening lost the terminal title")
    assert_true(type(next_map) == "table" and type(next_map.callback) == "function", "terminal view mode is missing tab cycling")
    next_map.callback()
    wait_until("first terminal view restored", function()
      if vim.api.nvim_get_current_buf() ~= first_buf then
        return false
      end
      local view = vim.api.nvim_win_call(vim.api.nvim_get_current_win(), vim.fn.winsaveview)
      return view.lnum == first_view.lnum
        and view.topline == first_view.topline
        and vim.api.nvim_get_mode().mode:sub(1, 1) ~= "t"
    end, 3000)
    for _, expected in ipairs({ { second_buf, second_view }, { first_buf, first_view } }) do
      invoke_map("<S-Tab>")
      wait_until("backward terminal view restored", function()
        if vim.api.nvim_get_current_buf() ~= expected[1] then
          return false
        end
        local view = vim.api.nvim_win_call(vim.api.nvim_get_current_win(), vim.fn.winsaveview)
        return view.lnum == expected[2].lnum
          and view.topline == expected[2].topline
          and vim.api.nvim_get_mode().mode:sub(1, 1) ~= "t"
      end, 3000)
    end
    invoke_map("<leader>nw")
    local third_buf = vim.api.nvim_get_current_buf()
    assert_true(window_labels():find("[Window 2]", 1, true), "second integrated window is missing")
    invoke_map("<leader>nt")
    local fourth_buf = vim.api.nvim_get_current_buf()
    assert_true(fourth_buf ~= third_buf and not window_labels():find("Window 3", 1, true),
      "new tab created another integrated window")
    local input, prompt, rename = vim.ui.input
    invoke_map("<leader>e")
    invoke_map("h")
    vim.ui.input = function(opts, callback) prompt, rename = opts, callback end
    invoke_map("e")
    vim.ui.input = input
    assert_true(prompt and prompt.default == "Window 1", "rename prompt did not use the selected horizontal window")
    rename("Example window")
    assert_true(window_labels():find("Example window", 1, true), "integrated window did not show its new name")
    invoke_map("<leader>e")
    assert_true(vim.api.nvim_get_current_buf() == fourth_buf, "rename switched the active terminal window")
    invoke_map("<S-Tab>")
    assert_true(vim.api.nvim_get_current_buf() == first_buf, "outer window lost its selected terminal tab")
    invoke_map("<C-l>")
    assert_true(vim.api.nvim_get_current_buf() == second_buf, "inner tab navigation switched windows")
    invoke_map("<Tab>")
    assert_true(vim.api.nvim_get_current_buf() == fourth_buf, "outer window switch lost the active tab")
    invoke_map("<leader>-t")
    write(panel_settings, { "[terminal_split]", 'window_bar_style = "vertical"', 'display_style = "tabs"' })
    invoke_map("<leader>-t")
    local bar = window_bar()
    assert_true(vim.api.nvim_win_get_config(bar).border ~= nil, "vertical window bar lacks its border")
    invoke_map("<leader>e")
    assert_true(vim.api.nvim_get_current_win() == bar, "could not focus integrated window bar")
    invoke_map("<C-o>")
    assert_true(vim.api.nvim_get_current_win() == bar and vim.fn.bufwinid(second_buf) ~= -1,
      "backward window bar jump did not restore the previous tab and keep focus")
    invoke_map("<C-i>")
    assert_true(vim.api.nvim_get_current_win() == bar and vim.fn.bufwinid(fourth_buf) ~= -1,
      "forward window bar jump did not restore the next tab and keep focus")
    local function has_folded_window()
      return vim.iter(vim.api.nvim_buf_get_lines(0, 0, -1, false)):any(function(line)
        return line:match("^▸ %[%d+%]") ~= nil
      end)
    end
    invoke_map("h")
    assert_true(has_folded_window(), "window bar did not fold")
    invoke_map("l")
    assert_true(not has_folded_window(), "window bar did not unfold")
    invoke_map("<leader>e")
    assert_true(vim.api.nvim_get_current_buf() == fourth_buf, "window bar did not return focus to its active tab")
    invoke_map("<leader>-t")
    assert_true(not vim.api.nvim_win_is_valid(bar) and visible_toggleterm_window_count() == 0,
      "closing integrated terminal left part of its panel behind")
  end, debug.traceback)

  if agent_buf and vim.api.nvim_buf_is_valid(agent_buf) then
    vim.api.nvim_buf_delete(agent_buf, { force = true })
  end
  close_toggleterm_terminals()
  vim.g.luanphan_global_settings_path = original_settings
  vim.g.luanphan_terminal_sessions_dir = original_sessions
  terminal_config.shell = original_shell
  vim.env.ENV = original_env
  if vim.fn.isdirectory(old_cwd) == 1 then
    pcall(vim.cmd, "cd " .. vim.fn.fnameescape(old_cwd))
  end
  assert_true(ok, tostring(err))
end

local function test_lsp_definition_and_references(repo)
  vim.cmd("cd " .. vim.fn.fnameescape(repo))
  assert_lsp_navigation(repo .. "/main.go")
  assert_lsp_code_action_keymaps()
end

local function test_typescript_server_matches_project_version()
  local api = worktree_test_api()
  local original_cwd = vim.fn.getcwd()
  local legacy_repo = make_typescript_fixture("example-typescript-legacy", "5.3.3")
  local native_repo = make_typescript_fixture("example-typescript-native", "7.0.2")

  local function open_and_check(repo, expected, unexpected)
    api.switch_to(repo, "repository")
    vim.cmd("edit " .. vim.fn.fnameescape(repo .. "/src/main.ts"))
    local buf = vim.api.nvim_get_current_buf()
    wait_until(expected .. " on TypeScript " .. repo, function()
      local client = active_lsp_client(buf, expected)
      return client and client.initialized
    end, 30000)

    local client = active_lsp_client(buf, expected)
    assert_true(active_lsp_client(buf, unexpected) == nil, unexpected .. " also attached to " .. repo)
    assert_true(realpath(client.config.root_dir) == realpath(repo), expected .. " used the wrong project root")
    local usage = find_position(buf, "targetValue", "export const result")
    assert_true(
      result_count(request(buf, "textDocument/definition", usage, 20000)) >= 1,
      expected .. " definition request returned no locations"
    )
    return client
  end

  local legacy_client = open_and_check(legacy_repo, "ts_ls", "tsc")
  local native_client = open_and_check(native_repo, "tsc", "ts_ls")
  wait_until("legacy TypeScript server to stop", function()
    return legacy_client:is_stopped()
  end, 10000)

  local recovered_legacy_client = open_and_check(legacy_repo, "ts_ls", "tsc")
  assert_true(recovered_legacy_client.id ~= legacy_client.id, "legacy TypeScript server was not restarted")
  wait_until("native TypeScript server to stop", function()
    return native_client:is_stopped()
  end, 10000)

  api.switch_to(original_cwd, "repository")
end

local function test_lsp_pickers_use_search_priority(repo)
  vim.cmd("cd " .. vim.fn.fnameescape(repo))
  local buf = open_go_file(repo .. "/main.go")
  local builtin = require("telescope.builtin")
  local original_references = builtin.lsp_references
  local original_implementations = builtin.lsp_implementations
  local original_path = vim.g.luanphan_search_rules_path
  local captured = {}
  local path = temp_root .. "/lsp-search-priority/settings.conf"
  write(path, {
    "[deprioritize]",
    "*_test.go",
    "",
    "[ignore]",
    "**/generated/**",
  })
  vim.g.luanphan_search_rules_path = path

  local ok, err = xpcall(function()
    builtin.lsp_references = function(opts)
      captured.references = opts
    end
    builtin.lsp_implementations = function(opts)
      captured.implementations = opts
    end

    local function invoke(lhs)
      local map = vim.fn.maparg(lhs, "n", false, true)
      assert_true(type(map) == "table" and type(map.callback) == "function", lhs .. " is not an LSP callback mapping")
      map.callback()
    end

    invoke("gr")
    invoke("gi")
    wait_until("prioritized LSP picker options", function()
      return captured.references ~= nil and captured.implementations ~= nil
    end, 3000)

    for name, opts in pairs(captured) do
      assert_true(type(opts.sorter) == "table", name .. " picker has no search-priority sorter")
      local code = { filename = "service/handler.go", ordinal = "target" }
      local test = { filename = "service/handler_test.go", ordinal = "target" }
      local ignored = { filename = "service/generated/handler.go", ordinal = "target" }
      local code_score = opts.sorter.scoring_function(opts.sorter, "", "target", code)
      local test_score = opts.sorter.scoring_function(opts.sorter, "", "target", test)
      local ignored_score = opts.sorter.scoring_function(opts.sorter, "", "target", ignored)
      assert_true(code_score < test_score, name .. " picker did not rank code above Go tests")
      assert_true(ignored_score < 0, name .. " picker did not discard an ignored path")
    end
  end, debug.traceback)

  builtin.lsp_references = original_references
  builtin.lsp_implementations = original_implementations
  vim.g.luanphan_search_rules_path = original_path
  assert_true(ok, tostring(err))
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

local function test_lsp_restart_reattaches_current_client_only(repo, worktree)
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
  local worktree_buf = open_go_file(worktree .. "/main.go")
  wait_for_lsp(main_buf)
  wait_for_lsp(extra_buf)
  wait_for_lsp(worktree_buf)

  local old_client = active_lsp_client(main_buf, "gopls")
  local extra_client = active_lsp_client(extra_buf, "gopls")
  local worktree_client = active_lsp_client(worktree_buf, "gopls")
  assert_true(old_client ~= nil and extra_client ~= nil, "repository gopls was not attached before restart")
  assert_true(old_client.id == extra_client.id, "repository buffers did not share one gopls client")
  assert_true(worktree_client ~= nil, "worktree gopls was not attached before restart")
  assert_true(worktree_client.id ~= old_client.id, "separate repositories unexpectedly shared one gopls client")

  require("lazy").load({ plugins = { "nvim-cmp" } })
  local cmp_nvim_lsp = require("cmp_nvim_lsp")
  vim.api.nvim_buf_call(extra_buf, function()
    vim.api.nvim_exec_autocmds("InsertEnter", { buffer = extra_buf })
  end)
  wait_until("initial gopls completion source", function()
    return cmp_nvim_lsp.client_source_map[old_client.id] ~= nil
  end, 5000)

  local restart_map = vim.fn.maparg("<leader>srl", "n", false, true)
  assert_true(type(restart_map) == "table" and restart_map.desc == "LSP", "<leader>srl should be the combined LSP restart")
  assert_true(vim.fn.maparg("<leader>rl", "n") == "", "<leader>rl should be removed")
  assert_true(vim.fn.maparg("<leader>rb", "n") == "", "<leader>rb should be removed")
  assert_true(vim.fn.maparg("<leader>rg", "n") == "", "<leader>rg should be removed")
  vim.api.nvim_set_current_buf(extra_buf)
  invoke_map("<leader>srl")

  wait_until("gopls restart reattach", function()
    local main_client = active_lsp_client(main_buf, "gopls")
    local reattached_extra_client = active_lsp_client(extra_buf, "gopls")
    return main_client
      and reattached_extra_client
      and main_client.id == reattached_extra_client.id
      and main_client.id ~= old_client.id
  end, 20000)

  assert_true(old_client:is_stopped(), "old gopls client is still running after restart")
  local restarted_client = active_lsp_client(extra_buf, "gopls")
  vim.api.nvim_buf_call(extra_buf, function()
    vim.api.nvim_exec_autocmds("InsertEnter", { buffer = extra_buf })
  end)
  wait_until("restarted gopls completion source", function()
    return cmp_nvim_lsp.client_source_map[old_client.id] == nil
      and restarted_client
      and cmp_nvim_lsp.client_source_map[restarted_client.id] ~= nil
  end, 5000)

  local untouched_client = active_lsp_client(worktree_buf, "gopls")
  assert_true(
    untouched_client ~= nil and untouched_client.id == worktree_client.id,
    "restart replaced the unrelated repository's gopls client"
  )
end

local function test_workspace_keymaps_restart_lsp_for_selected_directory(repo, worktree)
  local api = worktree_test_api()
  local cases = {
    { lhs = "<leader>wp", method = "pick_workspace_project" },
    { lhs = "<leader>wr", method = "pick_project" },
    { lhs = "<leader>wf", method = "pick_folder" },
  }

  for _, case in ipairs(cases) do
    api.switch_to(repo, "repository")
    local old_buf = open_go_file(repo .. "/main.go")
    wait_for_lsp(old_buf)
    local old_client = active_lsp_client(old_buf, "gopls")
    assert_true(old_client ~= nil, case.lhs .. " fixture has no source gopls client")

    local original = api[case.method]
    api[case.method] = function()
      api.switch_to(worktree, "repository")
    end
    local ok, err = pcall(invoke_map, case.lhs)
    api[case.method] = original
    assert_true(ok, case.lhs .. " failed to switch directories: " .. tostring(err))
    assert_true(realpath(vim.fn.getcwd()) == realpath(worktree), case.lhs .. " did not select the target directory")

    wait_until(case.lhs .. " old gopls stop", function()
      return old_client:is_stopped()
    end, 10000)

    local new_buf = open_go_file(worktree .. "/main.go")
    wait_for_lsp(new_buf)
    local new_client = active_lsp_client(new_buf, "gopls")
    assert_true(new_client ~= nil and new_client.id ~= old_client.id, case.lhs .. " did not start a new gopls client")
    assert_true(
      realpath(new_client.config.root_dir) == realpath(worktree),
      case.lhs .. " attached gopls with the wrong root"
    )
  end

  api.switch_to(repo, "repository")
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

local function test_worktree_switch_hides_toggleterm(repo, worktree)
  test_terminal_view_container(repo)
  vim.cmd("cd " .. vim.fn.fnameescape(repo))

  invoke_map("<leader>-t")
  wait_until("toggleterm open", function()
    return visible_toggleterm_window_count() > 0
  end, 3000)

  worktree_test_api().switch_to(worktree)
  local expected = realpath(worktree)
  wait_until("worktree cwd", function()
    return realpath(vim.fn.getcwd()) == expected
  end, 10000)
  assert_true(visible_toggleterm_window_count() == 0, "toggleterm window remained visible after worktree switch")
  close_toggleterm_terminals()
end

local function test_agent_terminal_lifecycle(repo)
  vim.cmd("cd " .. vim.fn.fnameescape(repo))
  local agent_status = require("luanphan.agents.status")
  local original_status_dir = vim.g.luanphan_agent_status_dir
  local status_dir = vim.fn.tempname()
  vim.g.luanphan_agent_status_dir = status_dir

  local agent = require("luanphan.agents.terminal-chat").create({
    status_name = "example-agent",
    g_bufnr = "toggleterm_hide_agent_bufnr",
    notify_prefix = "toggleterm_hide_agent",
    augroup_prefix = "ToggletermHideAgent",
    hint_open = "<smoke>",
    defaults = { cmd = "sh", detach_on_quit = true },
  })
  agent.setup()
  agent.toggle()

  wait_until("agent terminal open before toggleterm", function()
    return visible_agent_window_count() == 1
  end, 1000)
  local first_buf = vim.api.nvim_get_current_buf()
  local first_used = tonumber(vim.b[first_buf].luanphan_agent_last_used) or 0
  assert_true(first_used > 0, "new agent terminal did not record its use order")
  local quit_ok, quit_err = pcall(vim.cmd, "quit")
  assert_true(quit_ok, "agent terminal :q failed: " .. tostring(quit_err))
  wait_until("agent terminal client exit", function()
    return not vim.api.nvim_buf_is_valid(first_buf)
  end, 3000)

  agent.toggle()
  wait_until("fresh agent terminal after quit", function()
    return visible_agent_window_count() == 1 and vim.api.nvim_get_current_buf() ~= first_buf
  end, 1000)
  local second_buf = vim.api.nvim_get_current_buf()
  local second_used = tonumber(vim.b[second_buf].luanphan_agent_last_used) or 0
  assert_true(second_used > first_used, "replacement agent terminal did not advance its use order")
  for _, lhs in ipairs({ "<C-h>", "<C-j>", "<C-k>", "<C-l>" }) do
    assert_nonrecursive_map(lhs, "n", second_buf)
  end
  local terminal_maps = vim.api.nvim_buf_get_keymap(second_buf, "t")
  for _, lhs in ipairs({ "<C-h>", "<C-j>", "<C-k>" }) do
    local expected = vim.api.nvim_replace_termcodes(lhs, true, false, true)
    for _, map in ipairs(terminal_maps) do
      local actual = vim.api.nvim_replace_termcodes(map.lhs, true, false, true)
      assert_true(actual ~= expected, "agent terminal insert mode captured " .. lhs)
    end
  end
  vim.cmd("stopinsert")
  local view_down_map = vim.fn.maparg("<C-j>", "n", false, true)
  assert_true(
    type(view_down_map) == "table" and type(view_down_map.callback) == "function",
    "agent terminal view mode is missing <C-j> navigation"
  )
  view_down_map.callback()
  assert_true(visible_agent_window_count() == 0, "agent terminal view-mode <C-j> did not return to the editor")
  agent.toggle()
  wait_until("agent terminal reopened after view navigation", function()
    return visible_agent_window_count() == 1
  end, 1000)
  assert_true(
    (tonumber(vim.b[second_buf].luanphan_agent_last_used) or 0) > second_used,
    "refocused agent terminal did not advance its use order"
  )
  assert_true(agent_status.read("example-agent", repo) == "idle", "new agent terminal did not start idle")
  local submit_map = vim.fn.maparg("<CR>", "t", false, true)
  assert_true(type(submit_map) == "table" and type(submit_map.callback) == "function", "agent submit tracking is missing")
  submit_map.callback()
  assert_true(agent_status.read("example-agent", repo) == "running", "agent submit did not record running state")

  invoke_map("<leader>-t")
  wait_until("toggleterm open after agent terminal", function()
    return visible_toggleterm_window_count() > 0
  end, 3000)
  assert_true(visible_agent_window_count() == 0, "agent terminal remained visible after <leader>-t")

  agent.toggle()
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
  vim.g.luanphan_agent_status_dir = original_status_dir
  vim.fn.delete(status_dir, "rf")
end

local function test_worktree_switch_hides_agent_terminal(repo, worktree)
  vim.cmd("cd " .. vim.fn.fnameescape(repo))

  local agent = require("luanphan.agents.terminal-chat").create({
    g_bufnr = "smoke_agent_bufnr",
    notify_prefix = "smoke_agent",
    augroup_prefix = "SmokeAgent",
    hint_open = "<smoke>",
    defaults = { cmd = "sh" },
  })
  agent.setup()
  agent.toggle()

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

  agent.toggle()
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

  agent.toggle()
  wait_until("repo agent terminal manually reopened", function()
    return visible_agent_window_count() == 1
  end, 1000)

  worktree_test_api().switch_to(worktree)
  assert_true(visible_agent_window_count() == 0, "workspace switch did not hide the repository agent terminal")

  agent.toggle()
  wait_until("worktree agent terminal manually reopened", function()
    return visible_agent_window_count() == 1
  end, 1000)

  local buffers = vim.g.smoke_agent_bufnr
  local repo_buf = nil
  local worktree_buf = nil
  for path, value in pairs(buffers) do
    local bufnr = type(value) == "table" and value[1] or value
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
    assert_true(vim.wo[win].wrap == false, "agent terminal inherited wrapping")
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

  local floating = require("luanphan.terminal.floating")
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

local function test(name, fn)
  tests[#tests + 1] = { name = name, fn = fn }
end

local search_and_navigation_tests = {
  flow = test_flow_line_navigation,
  lsp_search_priority = test_lsp_pickers_use_search_priority,
  live_grep_highlights = test_live_grep_highlights_content_only,
  live_grep_cache = test_live_grep_caches_only_completed_searches,
  live_grep_debounce = test_live_grep_debounces_real_picker,
  search_rules = test_search_rules,
  search_rules_disk = test_search_rules_filter_disk_searches,
  search_settings_editor = test_search_priority_editor_closes_on_focus_loss,
}

local agent_tests = {
  cli_commands = test_agent_cli_commands_available,
  sidebar_restore = test_agent_sidebar_restore,
  default_setting = test_default_agent_setting,
  keys = test_agent_keys_invoke_cli_commands,
  lifecycle = test_agent_terminal_lifecycle,
  panel_shells = test_panel_shell_sessions,
  reference_links = test_terminal_reference_links,
  reference_view = test_agent_terminal_reference_restores_view,
  send_selection = test_leader_a_sends_visual_selection_to_active_agent,
  terminal_shortcuts = test_terminal_normal_mode_shows_shortcuts,
  tiled_workspace_picker = test_tiled_agent_workspace_picker,
  view_container = test_agent_view_container,
  floating_terminal = test_floating_terminal_windows,
  tmux_terminal = test_tmux_floating_terminal,
}

local lsp_lifecycle_tests = {
  restart_current = test_lsp_restart_reattaches_current_client_only,
  switch_with_keymaps = test_workspace_keymaps_restart_lsp_for_selected_directory,
  typescript_compatibility = test_typescript_server_matches_project_version,
}

local safe_cleanup_tests = {
  buffer_only = test_buffer_only_keeps_current_and_special_buffers,
  tree_width = test_nvim_tree_keeps_width_with_terminal,
  ctrl_f_navigation = test_ctrl_f_uses_native_navigation,
  editor_defaults = test_editor_runtime_defaults,
  editor_text_helpers = test_editor_text_helpers,
  file_tree_focus = test_file_tree_focuses_current_file,
  filetype_options = test_filetype_editor_options,
  git_remote_links = test_git_remote_file_links,
  json_temporary_folds = test_temporary_json_buffer_folds,
  only_keep_tree = test_only_keep_tree_closes_other_windows,
  repository_remove = test_remove_repository_from_workspace,
  run_actions = test_run_actions,
  telescope_keymaps = test_telescope_keymaps_dispatch_to_modules,
  telescope_runtime_defaults = test_telescope_runtime_defaults,
  toggle_gitignore = test_gitignore_toggle_updates_telescope,
  worktree_keymaps = test_worktree_keymaps_dispatch_to_pickers,
  worktree_notification = test_worktree_switch_notification_is_compact,
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
    test_worktree_plugin_starts_lazy()
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
    test_nvim_tree_hides_dotfiles()
  end)

  test("nvim-tree keeps fixed width beside terminals", function()
    safe_cleanup_tests.tree_width(repo)
  end)

  test("external files use a temporary dependency tree", function()
    test_dependency_tree_keeps_workspace_tree(repo)
  end)

  test("file tree focuses the current file", function()
    safe_cleanup_tests.file_tree_focus(repo)
  end)

  test("file searches follow nvim-tree dotfile visibility", function()
    test_searches_follow_tree_dotfiles()
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
    test_toggle_icons_reflect_state()
  end)

  test("word wrap keymaps respect window scope", function()
    test_word_wrap_keymaps_respect_window_scope()
  end)

  test("Ctrl-J and Ctrl-K move between windows", function()
    test_ctrl_j_and_k_move_between_windows()
  end)

  test("buffer-only keeps current and special buffers", function()
    safe_cleanup_tests.buffer_only()
  end)

  test("only-keep-tree closes ordinary sibling windows", function()
    safe_cleanup_tests.only_keep_tree()
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

  test("git remote links use current branch, file, and line", function()
    safe_cleanup_tests.git_remote_links()
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

  test("Go test runs from nested module", function()
    test_go_test_runs_from_nested_module()
  end)

  test("agent cli commands are executable", function()
    agent_tests.cli_commands()
  end)

  test("Neovide Cmd+V pastes text without probing images", function()
    test_neovide_command_v_pastes_text_without_image_probe()
  end)

  test("remote clipboard references preserve paths", function()
    test_remote_clipboard_references()
  end)

  test("Neovide detach clears stale option callbacks", function()
    test_neovide_detach_clears_option_callbacks()
  end)

  test("Neovide detach restores tmux clipboard across reconnects", function()
    test_neovide_detach_restores_tmux_clipboard()
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

  test("workspace folder picker browses and switches directories", function()
    test_workspace_folder_browser()
  end)

  test("repository picker adds a one-level nested project to the current workspace", function()
    test_add_repository_to_workspace()
  end)

  test("repository picker removes one clean project from the current workspace", function()
    safe_cleanup_tests.repository_remove()
  end)

  test("agent sessions discover running project terminals", function()
    test_active_agent_discovery(repo, worktree)
  end)

  test("agent session selection replaces the visible repository agent window", function()
    test_agent_switch_replaces_visible_repo_buffer(repo, worktree)
  end)

  test("filetype refresh uses each target buffer context", function()
    test_filetype_refire_uses_target_buffer()
  end)

  test("lsp definition and references", function()
    test_lsp_definition_and_references(repo)
  end)

  test("TypeScript projects use a compatible language server", function()
    lsp_lifecycle_tests.typescript_compatibility()
  end)

  test("lsp references and implementations use search priority", function()
    search_and_navigation_tests.lsp_search_priority(repo)
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

  test("json buffers format before write", function()
    test_json_format_keymap()
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
    test_worktree_switch_keeps_lsp(repo, worktree)
  end)

  test("worktree switch hides files from the previous repository", function()
    test_worktree_switch_hides_foreign_file(repo, worktree)
  end)

  test("worktree switch notification stays compact for long paths", function()
    safe_cleanup_tests.worktree_notification(repo)
  end)

  test("worktree switch restores repository jump history", function()
    test_worktree_switch_restores_repository_jumplist(repo, worktree)
  end)

  test("shell terminal tabs and worktree hiding", function()
    test_worktree_switch_hides_toggleterm(repo, worktree)
  end)

  test("agent terminal quits or hides without stale buffers", function()
    agent_tests.lifecycle(repo)
  end)

  test("git diff previews", function()
    test_git_diff_previews(worktree)
  end)

  test("git diff repository bar from workspace root", function()
    test_git_diff_repository_bar_from_workspace_root()
  end)

  test("git diff repository bar spans three-way conflicts", function()
    test_git_diff_repository_bar_spans_conflict_layout()
  end)

  test("git diff separates commit and push for its selected repository", function()
    test_git_diff_separate_commit_and_push_from_workspace_root()
  end)

  test("git diff original file jump starts go runtime", function()
    test_git_diff_original_file_jump_starts_go_runtime(worktree)
  end)

  test("worktree switch hides agent terminal", function()
    test_worktree_switch_hides_agent_terminal(repo, worktree)
  end)

  test("git diff refresh preserves directory folds", function()
    test_git_diff_refresh_preserves_directory_folds(worktree)
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
