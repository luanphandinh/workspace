-- LSP smoke tests, loaded by tests/nvim-smoke-test.lua with the shared helpers.
local H = ...
local temp_root = H.temp_root
local fail = H.fail
local assert_true = H.assert_true
local assert_nonrecursive_map = H.assert_nonrecursive_map
local realpath = H.realpath
local run = H.run
local write = H.write
local wait_until = H.wait_until
local find_position = H.find_position
local wait_for_lsp = H.wait_for_lsp
local active_lsp_client = H.active_lsp_client
local result_count = H.result_count
local request = H.request
local open_go_file = H.open_go_file
local assert_lsp_navigation = H.assert_lsp_navigation
local invoke_map = H.invoke_map
local worktree_test_api = H.worktree_test_api

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

return {
  test_lsp_definition_and_references = test_lsp_definition_and_references,
  test_typescript_server_matches_project_version = test_typescript_server_matches_project_version,
  test_lsp_pickers_use_search_priority = test_lsp_pickers_use_search_priority,
  test_lsp_survives_duplicate_split_close = test_lsp_survives_duplicate_split_close,
  test_workspace_root_uses_one_gopls_per_module = test_workspace_root_uses_one_gopls_per_module,
  test_lsp_recursive_incoming_call_graph = test_lsp_recursive_incoming_call_graph,
  test_lsp_restart_reattaches_current_client_only = test_lsp_restart_reattaches_current_client_only,
  test_workspace_keymaps_restart_lsp_for_selected_directory = test_workspace_keymaps_restart_lsp_for_selected_directory,
}
