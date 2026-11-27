-- Search smoke tests, loaded by tests/nvim-smoke-test.lua with the shared helpers.
local H = ...
local temp_root = H.temp_root
local assert_true = H.assert_true
local assert_nonrecursive_map = H.assert_nonrecursive_map
local realpath = H.realpath
local run = H.run
local write = H.write
local child_nvim_luafile_command = H.child_nvim_luafile_command
local write_executable = H.write_executable
local wait_until = H.wait_until
local read_lines = H.read_lines
local make_project_scope_fixture = H.make_project_scope_fixture
local invoke_map = H.invoke_map
local worktree_test_api = H.worktree_test_api

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
    "for _, buf in ipairs({ first_tile, agent_buf }) do assert_true(require('luanphan.view_container.terminal').running(buf), 'folder switch stopped an agent session') end",
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
    "local agent_win = vim.api.nvim_get_current_win()",
    "vim.fn.maparg('<leader>p', 'n', false, true).callback()",
    "prompt_bufnr = vim.api.nvim_get_current_buf()",
    "picker = action_state.get_current_picker(prompt_bufnr)",
    "picker:set_prompt('open-from-agent')",
    "assert_true(vim.wait(3000, function() local selection = picker:get_selection(); return selection and tostring(selection.value):find('open-from-agent.txt', 1, true) end, 20), 'file picker did not find the fixture')",
    "actions.select_default(prompt_bufnr)",
    "assert_true(vim.wait(3000, function() return realpath(vim.api.nvim_buf_get_name(0)) == realpath(" .. string.format("%q", editor_file) .. ") end, 20), 'file picker did not open the selected file')",
    "assert_true(require('luanphan.view_container.editor').window(agent_win) == vim.api.nvim_get_current_win(), 'file picker from an agent did not open in its editor tile')",
    "assert_true(vim.api.nvim_win_is_valid(agent_win) and vim.api.nvim_win_get_buf(agent_win) == third, 'file picker replaced the agent terminal pane')",
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

return {
  test_dependency_tree_keeps_workspace_tree = test_dependency_tree_keeps_workspace_tree,
  test_file_tree_focuses_current_file = test_file_tree_focuses_current_file,
  test_searches_follow_tree_dotfiles = test_searches_follow_tree_dotfiles,
  test_search_rules = test_search_rules,
  test_search_rules_filter_disk_searches = test_search_rules_filter_disk_searches,
  test_search_priority_editor_closes_on_focus_loss = test_search_priority_editor_closes_on_focus_loss,
  test_live_grep_highlights_content_only = test_live_grep_highlights_content_only,
  test_live_grep_debounces_real_picker = test_live_grep_debounces_real_picker,
  test_live_grep_caches_only_completed_searches = test_live_grep_caches_only_completed_searches,
  test_flow_line_navigation = test_flow_line_navigation,
  test_adjacent_project_discovery = test_adjacent_project_discovery,
  test_recent_navigation_ordering = test_recent_navigation_ordering,
  test_workspace_and_master_project_discovery = test_workspace_and_master_project_discovery,
  test_workspace_folder_browser = test_workspace_folder_browser,
  test_workspace_project_discovery = test_workspace_project_discovery,
  test_add_repository_to_workspace = test_add_repository_to_workspace,
  test_remove_repository_from_workspace = test_remove_repository_from_workspace,
}
