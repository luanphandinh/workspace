local uv = vim.uv or vim.loop

local tests = {}
local temp_root
local cleanup_fixture_id = 0

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

local function wait_until(label, predicate, timeout)
  local ok = vim.wait(timeout or 10000, predicate, 50, false)
  assert_true(ok, "timeout waiting for " .. label)
end

local function read_lines(path)
  return vim.fn.readfile(path)
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

local function invoke_map(lhs)
  local map = vim.fn.maparg(lhs, "n", false, true)
  assert_true(type(map) == "table" and type(map.callback) == "function", lhs .. " is not a callback mapping")
  map.callback()
end

local function feed_normal(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "xt", false)
end

local function worktree_plugin()
  return require("lazy.core.config").plugins["luanphan-worktree"]
end

local function worktree_plugin_loaded()
  local plugin = worktree_plugin()
  return plugin and plugin._ and plugin._.loaded
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

local function test_lsp_definition_and_references(repo)
  vim.cmd("cd " .. vim.fn.fnameescape(repo))
  assert_lsp_navigation(repo .. "/main.go")
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

  local env = ""
  if vim.env.XDG_CONFIG_HOME and vim.env.XDG_CONFIG_HOME ~= "" then
    env = "XDG_CONFIG_HOME=" .. vim.fn.shellescape(vim.env.XDG_CONFIG_HOME) .. " "
  end
  local cmd = "cd " .. vim.fn.shellescape(workspace) .. " && " .. env .. "GOWORK=off nvim --headless '+luafile " .. vim.fn.shellescape(script) .. "' +qa"
  local out = vim.fn.systemlist(cmd)
  assert_true(vim.v.shell_error == 0, table.concat(out, "\n"))
end

local function test_git_diff_previews(worktree)
  vim.cmd("cd " .. vim.fn.fnameescape(worktree))
  local status = table.concat(run({ "git", "status", "--short" }, worktree), "\n")
  assert_true(status:find("main.go", 1, true), "fixture has no current git change")

  invoke_map("<leader>gd")
  wait_for_diffview()
  close_diffview()

  invoke_map("<leader>gD")
  wait_for_diffview()
  close_diffview()
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

  test("deleted startup workspace falls back to master worktree", function()
    test_deleted_workspace_started_at_workspace_falls_back_to_master_worktree()
  end)

  test("deleted workspace lazy key falls back to master worktree", function()
    test_deleted_workspace_falls_back_to_master_worktree_from_lazy_key()
  end)

  test("lsp definition and references", function()
    test_lsp_definition_and_references(repo)
  end)

  test("worktree switch keeps lsp", function()
    test_worktree_switch_keeps_lsp(worktree)
  end)

  test("worktree switch hides toggleterm", function()
    test_worktree_switch_hides_toggleterm(repo, worktree)
  end)

  test("git diff previews", function()
    test_git_diff_previews(worktree)
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
