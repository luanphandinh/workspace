-- Editor smoke tests, loaded by tests/nvim-smoke-test.lua with the shared helpers.
local H = ...
local uv = H.uv
local temp_root = H.temp_root
local assert_true = H.assert_true
local assert_nonrecursive_map = H.assert_nonrecursive_map
local rendered_winbar = H.rendered_winbar
local realpath = H.realpath
local run = H.run
local write = H.write
local child_nvim_luafile_command = H.child_nvim_luafile_command
local write_executable = H.write_executable
local wait_until = H.wait_until
local read_lines = H.read_lines
local visible_toggleterm_window_count = H.visible_toggleterm_window_count
local close_toggleterm_terminals = H.close_toggleterm_terminals
local invoke_map = H.invoke_map
local feed_normal = H.feed_normal
local worktree_plugin_loaded = H.worktree_plugin_loaded
local worktree_test_api = H.worktree_test_api

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

local function worktree_plugin()
  return require("lazy.core.config").plugins["luanphan-worktree"]
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

return {
  test_json_format_keymap = test_json_format_keymap,
  test_temporary_json_buffer_folds = test_temporary_json_buffer_folds,
  test_filetype_editor_options = test_filetype_editor_options,
  test_markdown_browser_preview_keymap = test_markdown_browser_preview_keymap,
  test_markdown_preview_toggle_does_not_block = test_markdown_preview_toggle_does_not_block,
  test_csv_preview_keymap = test_csv_preview_keymap,
  test_no_italic_highlights = test_no_italic_highlights,
  test_git_conflict_decoration_guard = test_git_conflict_decoration_guard,
  test_git_remote_file_links = test_git_remote_file_links,
  test_shell_treesitter_reads_workspace_scripts = test_shell_treesitter_reads_workspace_scripts,
  test_treesitter_uses_native_runtime = test_treesitter_uses_native_runtime,
  test_treesitter_uses_nix_parser_runtime = test_treesitter_uses_nix_parser_runtime,
  test_treesitter_required_parsers_available = test_treesitter_required_parsers_available,
  test_go_treesitter_configures_default_folds = test_go_treesitter_configures_default_folds,
  test_go_treesitter_preserves_fold_options_on_start = test_go_treesitter_preserves_fold_options_on_start,
  test_treesitter_preserves_existing_fold_options_on_enter = test_treesitter_preserves_existing_fold_options_on_enter,
  test_diff_windows_keep_diff_folds_on_enter = test_diff_windows_keep_diff_folds_on_enter,
  test_go_runtime_recovers_when_entering_loaded_buffer = test_go_runtime_recovers_when_entering_loaded_buffer,
  test_go_test_runs_from_nested_module = test_go_test_runs_from_nested_module,
  test_buffer_only_keeps_current_and_special_buffers = test_buffer_only_keeps_current_and_special_buffers,
  test_only_keep_tree_closes_other_windows = test_only_keep_tree_closes_other_windows,
  test_word_wrap_keymaps_respect_window_scope = test_word_wrap_keymaps_respect_window_scope,
  test_ctrl_j_and_k_move_between_windows = test_ctrl_j_and_k_move_between_windows,
  test_terminal_normal_mode_shows_shortcuts = test_terminal_normal_mode_shows_shortcuts,
  test_toggle_icons_reflect_state = test_toggle_icons_reflect_state,
  test_worktree_plugin_starts_lazy = test_worktree_plugin_starts_lazy,
  test_worktree_keymaps_dispatch_to_pickers = test_worktree_keymaps_dispatch_to_pickers,
  test_telescope_keymaps_dispatch_to_modules = test_telescope_keymaps_dispatch_to_modules,
  test_run_actions = test_run_actions,
  test_editor_runtime_defaults = test_editor_runtime_defaults,
  test_editor_text_helpers = test_editor_text_helpers,
  test_ctrl_f_uses_native_navigation = test_ctrl_f_uses_native_navigation,
  test_telescope_runtime_defaults = test_telescope_runtime_defaults,
  test_gitignore_toggle_updates_telescope = test_gitignore_toggle_updates_telescope,
  test_nvim_tree_hides_dotfiles = test_nvim_tree_hides_dotfiles,
  test_nvim_tree_keeps_width_with_terminal = test_nvim_tree_keeps_width_with_terminal,
}
