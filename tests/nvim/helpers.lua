-- Shared helpers for the headless Neovim smoke tests (tests/nvim-smoke-test.lua).
local uv = vim.uv or vim.loop

local terminal_io = require("luanphan.view_container.terminal")

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

local temp_root = vim.fn.tempname()

local project_scope_fixture_id = 0

local agent_cli_commands = {
  { name = "cursor", command = "cursor-agent" },
  { name = "claude", command = "mclaude" },
  {
    name = "codex",
    command = "mcodex",
    optional_in_macos_ci = true,
  },
}

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

local function make_fixture()
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

local function registered_agent_bufnrs(name, cwd)
  cwd = cwd and realpath(cwd)
  local result = {}
  for _, pane in ipairs(require("luanphan.agents.tmux").panes(name)) do
    if not cwd or realpath(pane.data.cwd) == cwd then result[#result + 1] = pane.bufnr end
  end
  return result
end

local function agent_bufnr(name)
  local candidates = registered_agent_bufnrs(name, vim.fn.getcwd())
  if #candidates == 0 then
    candidates = registered_agent_bufnrs(name)
  end

  local selected = nil
  local selected_sequence = -1
  for _, bufnr in ipairs(candidates) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      local sequence = tonumber(vim.b[bufnr].luanphan_view_last_used) or 0
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

local function worktree_plugin_loaded()
  return plugin_loaded("luanphan-worktree")
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

local function open_agent_test_shell(agents, bufnr)
  local shell = vim.o.shell
  vim.o.shell = "/bin/sh"
  local ok, result = pcall(agents.open, "terminal", bufnr, { view_mode = true })
  vim.o.shell = shell
  assert_true(ok and result, "could not open the Agents shell: " .. tostring(result))
end

return {
  uv = uv,
  terminal_io = terminal_io,
  agent_socket_dir = agent_socket_dir,
  agent_socket = agent_socket,
  cleanup_agent_servers = cleanup_agent_servers,
  temp_root = temp_root,
  project_scope_fixture_id = project_scope_fixture_id,
  agent_cli_commands = agent_cli_commands,
  fail = fail,
  assert_true = assert_true,
  assert_nonrecursive_map = assert_nonrecursive_map,
  rendered_winbar = rendered_winbar,
  realpath = realpath,
  require_command = require_command,
  run = run,
  write = write,
  child_nvim_luafile_command = child_nvim_luafile_command,
  write_executable = write_executable,
  wait_until = wait_until,
  read_lines = read_lines,
  read_log = read_log,
  make_fixture = make_fixture,
  make_project_scope_fixture = make_project_scope_fixture,
  find_position = find_position,
  wait_for_lsp = wait_for_lsp,
  active_lsp_client = active_lsp_client,
  result_count = result_count,
  request = request,
  open_go_file = open_go_file,
  assert_lsp_navigation = assert_lsp_navigation,
  visible_toggleterm_window_count = visible_toggleterm_window_count,
  close_toggleterm_terminals = close_toggleterm_terminals,
  visible_agent_window_count = visible_agent_window_count,
  assert_agent_float = assert_agent_float,
  close_agent_terminals = close_agent_terminals,
  invoke_map = invoke_map,
  registered_agent_bufnrs = registered_agent_bufnrs,
  agent_bufnr = agent_bufnr,
  feed_normal = feed_normal,
  plugin_loaded = plugin_loaded,
  worktree_plugin_loaded = worktree_plugin_loaded,
  worktree_test_api = worktree_test_api,
  open_agent_test_shell = open_agent_test_shell,
}
