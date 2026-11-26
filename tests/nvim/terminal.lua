-- Terminal smoke tests, loaded by tests/nvim-smoke-test.lua with the shared helpers.
local H = ...
local uv = H.uv
local agent_socket = H.agent_socket
local temp_root = H.temp_root
local assert_true = H.assert_true
local rendered_winbar = H.rendered_winbar
local realpath = H.realpath
local write = H.write
local child_nvim_luafile_command = H.child_nvim_luafile_command
local wait_until = H.wait_until
local visible_toggleterm_window_count = H.visible_toggleterm_window_count
local close_toggleterm_terminals = H.close_toggleterm_terminals
local invoke_map = H.invoke_map
local worktree_test_api = H.worktree_test_api

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
local panel = require("luanphan.view_container.floating")
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
local source_win = api.nvim_get_current_win()
vim.wo[source_win].list, vim.wo[source_win].spell, vim.wo[source_win].wrap = true, true, true
vim.wo[source_win].foldmethod, vim.wo[source_win].signcolumn, vim.wo[source_win].scrolloff = "marker", "yes", 8
key("<leader>t")
wait(function() return active() and vim.bo.buftype == "terminal" end, "create and attach")
local first = active()
local first_win = pane_window(first)
local terminal = require("luanphan.view_container.terminal")
assert(terminal.send(api.nvim_win_get_buf(first_win), "printf 'SHARED_%s\\n' INPUT\r"), "shared terminal input rejected a tmux pane")
wait(function() return tmux("capture-pane", "-p", "-t", first):find("SHARED_INPUT", 1, true) end, "shared input reached tmux")
assert(not vim.wo[first_win].list and not vim.wo[first_win].spell and not vim.wo[first_win].wrap
  and vim.wo[first_win].foldmethod == "manual" and vim.wo[first_win].signcolumn == "no"
  and vim.wo[first_win].scrolloff == 0, "floating terminal inherited editor window options")
assert(vim.bo[api.nvim_win_get_buf(first_win)].syntax == "" and vim.b.matchparen_timeout == 0,
  "floating terminal inherited syntax or matchparen")
assert(vim.wo[source_win].foldmethod == "marker" and vim.wo[source_win].scrolloff == 8,
  "terminal setup changed the source editor options")
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
assert(vim.b[api.nvim_win_get_buf(pane_window(first))].luanphan_terminal_reference_cwd == vim.uv.fs_realpath("/tmp"),
  "a terminal cwd change did not update relative references")
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
local pane = require("luanphan.view_container.tmux.pane").for_buffer(api.nvim_get_current_buf())
local client = pane.client
vim.wait(50, function() return false end)
wait(function() return not client.pending and #client.queue == 0 end, "finish opening both tiles")
local request, scans = client.request, 0
client.request = function(self, args, ...)
  if args[1] == "list-panes" then scans = scans + 1 end
  return request(self, args, ...)
end
key("<C-h>")
wait(function() return active() == first and tmux("display-message", "-p", "#{pane_id}") == first end,
  "focus and select the visible left tmux tile")
key("<C-l>")
wait(function() return active() == second and tmux("display-message", "-p", "#{pane_id}") == second end,
  "focus and select the visible right tmux tile")
vim.wait(50, function() return false end)
client.request = request
assert(scans == 0, "focus between visible tmux tiles requested a pane listing")
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
key(":q<CR>")
wait(function() return active() == second and not pane_window(bottom) end, "quit focuses the neighboring tile")
assert(not vim.tbl_contains(vim.split(tmux("list-panes", "-a", "-F", "#{pane_id}"), "\n"), bottom),
  ":q left the selected tmux process running")
assert(tmux("display-message", "-p", "-t", first, "#{pane_pid}") == shell_pid, ":q stopped another tile")
local tile = api.nvim_get_current_win()
assert(vim.w[tile].luanphan_view_anchor ~= tile, "the split did not open a separate tile")
api.nvim_win_close(tile, true)
assert(not vim.iter(api.nvim_list_wins()):any(function(win)
  return vim.b[api.nvim_win_get_buf(win)].luanphan_tmux_pane
end), "closing a tile left other panes visible")
panel.toggle()
wait(function() return active() == second end, "reattach after closing a tile")
key("<C-h>")
wait(function() return active() == first end, "select the first tile for insertion")
key("<leader>nt")
wait(function() return active() and active() ~= first and active() ~= second end, "create a tile for direct quit")
local disposable = active()
for order, id in ipairs({ first, disposable, second }) do
  local metadata = tmux("display-message", "-p", "-t", id, "#{@luanphan-view-window}")
  assert(vim.json.decode(metadata).pane_order == order, "new tile order was not saved after the focused tile")
end
vim.cmd.quit()
wait(function() return active() == first and pane_window(second) and not pane_window(disposable) end,
  "direct quit reopens the remaining panes")
assert(not vim.tbl_contains(vim.split(tmux("list-panes", "-a", "-F", "#{pane_id}"), "\n"), disposable),
  "direct quit left the selected tmux process running")
key("<C-l>")
wait(function() return active() == second end, "restore focus to the second tile")
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
local session_a = tmux("new-session", "-d", "-s", "example-a", "-P", "-F", "#{pane_id}")
local session_b = tmux("new-session", "-d", "-s", "example-b", "-P", "-F", "#{pane_id}")
local function session_sidebar(id)
  local win = pane_window(id)
  return win and vim.w[vim.w[win].luanphan_view_anchor or win].luanphan_window_bar == api.nvim_get_current_win()
end
key("<leader>e")
for _, switch in ipairs({ { "<C-S-l>", session_a }, { "<C-S-l>", session_b },
  { "<C-S-h>", session_a }, { "<C-S-h>", third } }) do
  key(switch[1])
  wait(function() return session_sidebar(switch[2]) end, "session switch kept focus in the sidebar")
end
assert(terminal.running(api.nvim_win_get_buf(assert(pane_window(third)))), "session switch lost the selected shell")
tmux("kill-session", "-t", "=example-a")
tmux("kill-session", "-t", "=example-b")
panel.hide()
assert(tmux("display-message", "-p", "-t", first, "#{pane_pid}") == shell_pid, "detach stopped the shell")
tmux("send-keys", "-l", "-t", first, "printf 'DETACHED_%s\\n' OUTPUT")
tmux("send-keys", "-t", first, "Enter")
wait(function()
  return tmux("capture-pane", "-p", "-t", first):find("DETACHED_OUTPUT", 1, true)
end, "tmux accepted output while the panel was hidden")
tmux("send-keys", "-l", "-t", first,
  [==[printf '資料 \033]8;;https://example.com/first\033\\%s\033]8;;\033\\ and \033]8;;https://example.com/second?q=1\033\\%s\033]8;;\033\\ end\n' 'Guide' 'Guide'; seq 1 60]==])
tmux("send-keys", "-t", first, "Enter")
wait(function()
  return tmux("capture-pane", "-p", "-t", first, "-S", "-80"):find("資料 Guide and Guide end", 1, true)
end, "hyperlink fixture appeared in tmux")
vim.fn.writefile({ first, shell_pid, third, second }, root .. "/panes")
]=])
    run_child([=[
local api = vim.api
local saved = vim.fn.readfile(root .. "/panes")
local panel = require("luanphan.view_container.floating")
panel.toggle()
assert(vim.wait(4000, function() return vim.b.luanphan_tmux_pane == saved[3] end), "reopen lost selected pane")
vim.fn.maparg("<leader>e", "n", false, true).callback()
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.fn.maparg("o", "n", false, true).callback()
assert(vim.wait(4000, function()
  if vim.b.luanphan_tmux_pane ~= saved[1] then return false end
  local output = table.concat(api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  return output:find("RESULT_PROBE_TEXT", 1, true) and output:find("DETACHED_OUTPUT", 1, true)
    and output:find("資料 Guide and Guide end", 1, true)
end), "reattach lost scrollback or output produced while hidden")
local peer = assert(vim.iter(api.nvim_list_wins()):find(function(win)
  return vim.b[api.nvim_win_get_buf(win)].luanphan_tmux_pane == saved[4]
end))
assert(api.nvim_win_get_config(peer).col < api.nvim_win_get_config(0).col,
  "reattach lost the reordered tmux pane position")
local references = require("luanphan.terminal_references")
local open_url, getmousepos = references.open_url, vim.fn.getmousepos
local clicked
references.open_url = function(url) clicked = url end
for lnum, line in ipairs(api.nvim_buf_get_lines(0, 0, -1, false)) do
  if vim.trim(line) == "資料 Guide and Guide end" then
    assert(lnum <= api.nvim_buf_line_count(0) - api.nvim_win_get_height(0), "fixture is outside scrollback")
    local column = assert(line:find("Guide end", 1, true))
    vim.fn.getmousepos = function()
      return { winid = api.nvim_get_current_win(), line = lnum, column = column }
    end
    assert(vim.fn.maparg("<D-LeftMouse>", "n", false, true).callback() == "<Ignore>")
    break
  end
end
assert(vim.wait(4000, function() return clicked ~= nil end), "Cmd+click missed a restored terminal hyperlink")
assert(clicked == "https://example.com/second?q=1", "Cmd+click opened the wrong terminal hyperlink")
references.open_url, vim.fn.getmousepos = open_url, getmousepos
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
api.nvim_set_current_win(terminal_win)
api.nvim_feedkeys(vim.keycode(vim.g.mapleader .. "e"), "xt", false)
local editor_sidebar = api.nvim_get_current_win()
local editor_row
for index, line in ipairs(api.nvim_buf_get_lines(0, 0, -1, false)) do
  if vim.trim(line) == "Editor · example.txt" then editor_row = index end
end
assert(editor_row, "tmux sidebar omitted the editor tile")
api.nvim_win_set_cursor(editor_sidebar, { editor_row, 0 })
api.nvim_feedkeys(vim.keycode("<CR>"), "xt", false)
assert(api.nvim_get_current_win() == editor_win, "tmux sidebar row did not focus the editor tile")
local editor_col = api.nvim_win_get_config(editor_win).col
api.nvim_feedkeys(vim.keycode("<C-S-h>"), "xt", false)
assert(vim.wait(4000, function() return api.nvim_win_get_config(editor_win).col < editor_col end)
  and api.nvim_get_current_win() == editor_win, "moving the tmux editor tile lost its position or focus")
api.nvim_set_current_win(terminal_win)
tmux("select-window", "-t", saved[3])
assert(vim.wait(4000, function() return vim.b.luanphan_tmux_pane == saved[3] end), "could not switch away from the editor tile")
editor_row = nil
for index, line in ipairs(api.nvim_buf_get_lines(api.nvim_win_get_buf(editor_sidebar), 0, -1, false)) do
  if vim.trim(line) == "Editor · example.txt" then editor_row = index end
end
assert(editor_row, "switching tmux windows hid the editor sidebar row")
api.nvim_set_current_win(editor_sidebar)
api.nvim_win_set_cursor(editor_sidebar, { editor_row, 0 })
api.nvim_feedkeys(vim.keycode("<CR>"), "xt", false)
assert(vim.wait(4000, function()
  return api.nvim_get_current_buf() == editor_buf and api.nvim_win_get_config(0).relative ~= ""
end), "selecting the inactive tmux editor row did not restore its tile")
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

local function test_tmux_resize_rebuilds_inline_output()
  if vim.fn.executable("tmux") == 0 or vim.fn.executable("python3") == 0 then return end
  local root = uv.fs_mkdtemp("/tmp/nvim-tmux-resize-XXXXXX")
  local script, socket = root .. "/test.lua", root .. "/socket"
  write(root .. "/tmux.conf", { "set -g default-shell /bin/sh", "set -g default-command 'exec /bin/sh'" })
  -- An inline TUI that repaints its bottom rows with relative cursor moves.
  write(root .. "/inline.py", {
    "import os, signal, sys, time",
    "def w(s): sys.stdout.write(s); sys.stdout.flush()",
    "def live():",
    "    cols = os.get_terminal_size(1).columns",
    [[    return "\r\x1b[J" + "-" * cols + "\r\n> prompt\r\n" + "status " * (cols // 8)]],
    "for i in range(40):",
    [[    w(f"history line {i:02d} " + "word " * 26 + "\r\n")]],
    "w(live())",
    [[signal.signal(signal.SIGWINCH, lambda *_: w("\x1b[2A" + live()))]],
    "while True:",
    "    time.sleep(0.2)",
    [[    w("\x1b[2A" + live())]],
  })
  write(script, vim.list_extend({
    "local root = " .. string.format("%q", root),
    "vim.g.luanphan_floating_tmux_socket = root .. '/socket'",
    "vim.g.luanphan_floating_tmux_config = root .. '/tmux.conf'",
    "vim.g.luanphan_global_settings_path = root .. '/settings.toml'",
    "vim.g.luanphan_recent_paths_file = root .. '/recent.json'",
    "vim.g.luanphan_terminal_sessions_dir = root .. '/sessions'",
    "vim.o.columns, vim.o.lines = 160, 48",
  }, vim.split([=[
local api = vim.api
local function trimmed(lines)
  lines = vim.tbl_map(function(line) return (line:gsub("%s+$", "")) end, lines)
  while lines[#lines] == "" do lines[#lines] = nil end
  return lines
end
local function check(label, socket, open)
  local function tmux(...)
    local result = vim.system(vim.list_extend({ "tmux", "-S", socket }, { ... }), { text = true }):wait(2000)
    assert(result.code == 0, result.stderr)
    return result.stdout
  end
  vim.o.columns, vim.o.lines = 160, 48
  open()
  assert(vim.wait(4000, function() return vim.b.luanphan_tmux_pane and vim.bo.buftype == "terminal" end), label .. " did not attach")
  local id, buf = vim.b.luanphan_tmux_pane, api.nvim_get_current_buf()
  tmux("send-keys", "-t", id, "exec python3 " .. root .. "/inline.py", "Enter")
  local function matches_tmux()
    local panel = trimmed(api.nvim_buf_get_lines(buf, 0, -1, false))
    return vim.deep_equal(panel, trimmed(vim.split(tmux("capture-pane", "-p", "-t", id, "-S", "-"), "\n")))
  end
  assert(vim.wait(4000, function() return tmux("capture-pane", "-p", "-t", id):find("status", 1, true) and matches_tmux() end, 100),
    label .. " inline output did not reach the panel")
  local function pane_width() return tmux("display-message", "-p", "-t", id, "#{pane_width}") end
  for _, columns in ipairs({ 110, 180, 90 }) do
    local previous = pane_width()
    vim.o.columns = columns
    assert(vim.wait(4000, function() return pane_width() ~= previous end, 50), label .. " did not follow " .. columns .. " columns")
    assert(vim.wait(4000, matches_tmux, 100), label .. " scrollback differs from tmux after resizing to " .. columns .. " columns")
  end
  -- A height change moves rows between screen and scrollback differently in Neovim and tmux.
  local pane = require("luanphan.view_container.tmux.pane").for_buffer(buf)
  local function screen_matches()
    local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
    local want = vim.split(tmux("capture-pane", "-p", "-t", id), "\n")
    for row = 1, pane.view_height do
      if (lines[#lines - pane.view_height + row] or ""):gsub("%s+$", "") ~= (want[row] or ""):gsub("%s+$", "") then return false end
    end
    return true
  end
  local function pane_height() return tmux("display-message", "-p", "-t", id, "#{pane_height}") end
  for _, rows in ipairs({ 36, 48, 26, 48 }) do
    local previous = pane_height()
    vim.o.lines = rows
    assert(vim.wait(4000, function() return pane_height() ~= previous end, 50), label .. " did not follow " .. rows .. " lines")
    assert(vim.wait(4000, screen_matches, 100), label .. " screen differs from tmux after resizing to " .. rows .. " lines")
  end
  vim.cmd("stopinsert")
  for _, win in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_is_valid(win) and api.nvim_win_get_config(win).relative ~= "" then api.nvim_win_close(win, true) end
  end
end
check("floating terminal", vim.g.luanphan_floating_tmux_socket, function()
  api.nvim_feedkeys(vim.keycode(vim.g.mapleader .. "t"), "xt", false)
end)
check("agent terminal", vim.env.LUANPHAN_AGENT_TMUX_SOCKET, function()
  require("luanphan.agents.main").new("terminal")
end)
]=], "\n", { plain = true })))
  local output = vim.fn.systemlist(child_nvim_luafile_command(root, script))
  vim.system({ "tmux", "-S", socket, "kill-server" }):wait()
  vim.system({ "tmux", "-S", agent_socket(script), "kill-server" }):wait()
  vim.fn.delete(root, "rf")
  assert_true(vim.v.shell_error == 0, table.concat(output, "\n"))
end

local function test_tmux_paint_keeps_split_escape_sequence()
  if vim.fn.executable("tmux") == 0 or vim.fn.executable("python3") == 0 then return end
  local root = uv.fs_mkdtemp("/tmp/nvim-tmux-split-XXXXXX")
  local script, socket = root .. "/test.lua", root .. "/socket"
  write(root .. "/tmux.conf", { "set -g default-shell /bin/sh", "set -g default-command 'exec /bin/sh'" })
  -- The pause lets a resize repaint run while tmux still waits for the end of the color sequence.
  write(root .. "/split.py", {
    "import os, time",
    [[os.write(1, b"\x1b[2J\x1b[HBEFORE\r\n\x1b[3")]],
    "time.sleep(1.5)",
    [[os.write(1, b"1mSPLIT_OK\x1b[0m\r\n")]],
    "time.sleep(60)",
  })
  write(script, vim.list_extend({
    "local root = " .. string.format("%q", root),
    "vim.g.luanphan_floating_tmux_socket = root .. '/socket'",
    "vim.g.luanphan_floating_tmux_config = root .. '/tmux.conf'",
    "vim.g.luanphan_global_settings_path = root .. '/settings.toml'",
    "vim.g.luanphan_recent_paths_file = root .. '/recent.json'",
    "vim.g.luanphan_terminal_sessions_dir = root .. '/sessions'",
  }, vim.split([=[
local api = vim.api
api.nvim_feedkeys(vim.keycode(vim.g.mapleader .. "t"), "xt", false)
assert(vim.wait(4000, function() return vim.b.luanphan_tmux_pane and vim.bo.buftype == "terminal" end), "tmux terminal did not attach")
local id, buf = vim.b.luanphan_tmux_pane, api.nvim_get_current_buf()
vim.system({ "tmux", "-S", root .. "/socket", "send-keys", "-t", id, "exec python3 " .. root .. "/split.py", "Enter" }):wait()
local function text() return table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n") end
assert(vim.wait(4000, function() return text():find("BEFORE", 1, true) end, 5), "output before the split did not arrive")
-- A width change rebuilds the panel from tmux while the sequence is still open.
vim.o.columns = vim.o.columns - 20
assert(vim.wait(5000, function() return text():find("SPLIT_OK", 1, true) end, 5), "split sequence output did not arrive")
assert(not text():find("1mSPLIT_OK", 1, true), "a repaint broke an escape sequence split across output chunks")
]=], "\n", { plain = true })))
  local output = vim.fn.systemlist(child_nvim_luafile_command(root, script))
  vim.system({ "tmux", "-S", socket, "kill-server" }):wait()
  vim.fn.delete(root, "rf")
  assert_true(vim.v.shell_error == 0, table.concat(output, "\n"))
end

local function test_tmux_split_window_keeps_cursor()
  if vim.fn.executable("tmux") == 0 or vim.fn.executable("python3") == 0 then return end
  local root = uv.fs_mkdtemp("/tmp/nvim-tmux-splitwin-XXXXXX")
  local script = root .. "/test.lua"
  -- An inline prompt that parks the cursor between two full-width rules and redraws relative to it.
  write(root .. "/prompt.py", {
    "import os, sys, time",
    "def w(s): sys.stdout.write(s); sys.stdout.flush()",
    "cols = os.get_terminal_size(1).columns",
    "def frame(tick):",
    [[    return "\x1b[J" + "-" * cols + "\r\n> \r\n" + "-" * cols + f"\r\nstatus {tick}\x1b[2A\r\x1b[2C"]],
    "for i in range(30):",
    [[    w(f"history line {i:02d}\r\n")]],
    "w(frame(0))",
    "tick = 0",
    "while True:",
    "    time.sleep(0.2)",
    "    tick += 1",
    [[    w("\r\x1b[1A" + frame(tick))]],
  })
  write(script, vim.list_extend({
    "local root = " .. string.format("%q", root),
    "vim.g.luanphan_global_settings_path = root .. '/settings.toml'",
    "vim.g.luanphan_recent_paths_file = root .. '/recent.json'",
    "vim.g.luanphan_terminal_sessions_dir = root .. '/sessions'",
    "vim.o.columns, vim.o.lines = 160, 48",
  }, vim.split([=[
local api = vim.api
local function tmux(...)
  local result = vim.system(vim.list_extend({ "tmux", "-S", vim.env.LUANPHAN_AGENT_TMUX_SOCKET }, { ... }), { text = true }):wait(2000)
  assert(result.code == 0, result.stderr)
  return result.stdout
end
local function trimmed(lines)
  lines = vim.tbl_map(function(line) return (line:gsub("%s+$", "")) end, lines)
  while lines[#lines] == "" do lines[#lines] = nil end
  return lines
end
require("luanphan.agents.main").new("terminal")
assert(vim.wait(4000, function() return vim.b.luanphan_tmux_pane and vim.bo.buftype == "terminal" end), "agent terminal did not attach")
local id, buf = vim.b.luanphan_tmux_pane, api.nvim_get_current_buf()
tmux("send-keys", "-t", id, "exec python3 " .. root .. "/prompt.py", "Enter")
local function matches_tmux()
  return vim.deep_equal(trimmed(api.nvim_buf_get_lines(buf, 0, -1, false)),
    trimmed(vim.split(tmux("capture-pane", "-p", "-t", id, "-S", "-"), "\n")))
end
assert(vim.wait(4000, function() return tmux("capture-pane", "-p", "-t", id):find("status", 1, true) and matches_tmux() end, 50),
  "prompt did not reach the panel")
vim.cmd("stopinsert")
-- Commands like Diffview split the current window, so the terminal briefly shows in narrow windows.
api.nvim_set_current_win(vim.fn.bufwinid(buf))
vim.cmd("tab split")
for _ = 1, 3 do vim.cmd("vsplit") end
vim.cmd("redraw")
vim.wait(300, function() return false end)
vim.cmd("tabclose")
local ok = vim.wait(3000, function() return matches_tmux() end, 50)
vim.wait(600, function() return false end)
assert(ok and matches_tmux(), "panel drifted from tmux after the terminal was shown in split windows")
]=], "\n", { plain = true })))
  local output = vim.fn.systemlist(child_nvim_luafile_command(root, script))
  vim.system({ "tmux", "-S", agent_socket(script), "kill-server" }):wait()
  vim.fn.delete(root, "rf")
  assert_true(vim.v.shell_error == 0, table.concat(output, "\n"))
end

local function test_tmux_repaint_recovers_under_output()
  if vim.fn.executable("tmux") == 0 or vim.fn.executable("python3") == 0 then return end
  local root = uv.fs_mkdtemp("/tmp/nvim-tmux-steady-XXXXXX")
  local script = root .. "/test.lua"
  write(root .. "/steady.py", {
    "import sys, time",
    "tick = 0",
    "while True:",
    "    tick += 1",
    [[    sys.stdout.write(f"tick {tick}\r\n"); sys.stdout.flush()]],
    "    time.sleep(0.005)",
  })
  write(script, vim.list_extend({
    "local root = " .. string.format("%q", root),
    "vim.g.luanphan_global_settings_path = root .. '/settings.toml'",
    "vim.g.luanphan_recent_paths_file = root .. '/recent.json'",
    "vim.g.luanphan_terminal_sessions_dir = root .. '/sessions'",
    "vim.o.columns, vim.o.lines = 160, 48",
  }, vim.split([=[
local api = vim.api
local pty = require("luanphan.view_container.tmux.pane")
local function tmux(...)
  local result = vim.system(vim.list_extend({ "tmux", "-S", vim.env.LUANPHAN_AGENT_TMUX_SOCKET }, { ... }), { text = true }):wait(2000)
  assert(result.code == 0, result.stderr)
  return result.stdout
end
require("luanphan.agents.main").new("terminal")
assert(vim.wait(4000, function() return vim.b.luanphan_tmux_pane and vim.bo.buftype == "terminal" end), "agent terminal did not attach")
local id, buf = vim.b.luanphan_tmux_pane, api.nvim_get_current_buf()
local pane = pty.for_buffer(buf)
tmux("send-keys", "-t", id, "exec python3 " .. root .. "/steady.py", "Enter")
assert(vim.wait(4000, function() return tmux("capture-pane", "-p", "-t", id):find("tick 50", 1, true) end, 50), "output did not start")
local function pane_width() return tmux("display-message", "-p", "-t", id, "#{pane_width}") end
local function resize(columns)
  local previous = pane_width()
  vim.o.columns = columns
  assert(vim.wait(4000, function() return pane_width() ~= previous end, 20), "tmux pane did not follow " .. columns .. " columns")
end
local function last_tick()
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  for index = #lines, 1, -1 do
    local tick = lines[index]:match("^tick (%d+)")
    if tick then return tonumber(tick) end
  end
  return 0
end

-- Output that keeps coming during a capture must not keep the pane capturing forever.
local paints, paint = 0, pty.paint
pty.paint = function(...) paints = paints + 1; return paint(...) end
resize(120)
vim.wait(1500, function() return false end)
pty.paint = paint
assert(paints <= 6, "steady output kept the pane repainting: " .. paints .. " paints in 1.5s")
local before = last_tick()
assert(vim.wait(2000, function() return pane.ready and last_tick() > before + 20 end, 20), "the pane did not go back to live output")

-- A failed capture must not freeze the pane.
local client = pane.client
local request_batch = client.request_batch
client.request_batch = function(self, commands, callback)
  if commands[1][1] == "capture-pane" then
    client.request_batch = request_batch
    local replies = {}
    for index = 1, #commands do replies[index] = { ok = false, lines = {} } end
    return vim.schedule(function() callback(replies) end)
  end
  return request_batch(self, commands, callback)
end
resize(140)
assert(vim.wait(3000, function() return client.request_batch == request_batch end, 20), "no capture ran after the resize")
before = last_tick()
assert(vim.wait(3000, function() return pane.ready and last_tick() > before + 20 end, 20), "a failed capture froze the pane")
]=], "\n", { plain = true })))
  local output = vim.fn.systemlist(child_nvim_luafile_command(root, script))
  vim.system({ "tmux", "-S", agent_socket(script), "kill-server" }):wait()
  vim.fn.delete(root, "rf")
  assert_true(vim.v.shell_error == 0, table.concat(output, "\n"))
end

local function test_tmux_frame_restores_scroll_region()
  -- tmux keeps an app's scroll region, but a fresh or repainted Neovim terminal starts without it.
  local screen = require("luanphan.view_container.tmux.screen")
  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, false, { relative = "editor", row = 0, col = 0, width = 20, height = 6, style = "minimal" })
  local ok, err = pcall(function()
    local term = vim.api.nvim_open_term(buf, {})
    local pane = { view_width = 20, view_height = 6, width = 20, height = 6, painted = true }
    local lines = { "TOP", "region 1", "region 2", "region 3", "BOTTOM 1", "BOTTOM 2" }
    -- cursor at the last region row, rows 1-3 (0-based) form the region
    local flags = { "0", "3", "0", "1", "0", "0", "0", "20", "6", "1", "0", "0", "0", "0", "1", "3" }
    local _, output = screen.frame(pane, lines, flags)
    vim.api.nvim_chan_send(term, output .. "\nNEW")
    local rows
    assert_true(vim.wait(2000, function()
      local lines_now = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      rows = vim.tbl_map(function(line) return vim.trim(line) end, vim.list_slice(lines_now, #lines_now - 5))
      return table.concat(rows, "\n"):find("NEW", 1, true) ~= nil
    end), "scroll region frame output did not render")
    assert_true(vim.deep_equal(rows, { "TOP", "region 2", "region 3", "NEW", "BOTTOM 1", "BOTTOM 2" }),
      "a repaint lost the scroll region: " .. vim.inspect(rows))
  end)
  pcall(vim.api.nvim_win_close, win, true)
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  assert_true(ok, tostring(err))
end

local function test_tmux_frame_keeps_pending_wrap()
  -- After a full row tmux reports the cursor one past the last column: the next character
  -- starts a new row. A repaint that parks the cursor on the last column would overwrite it.
  local screen = require("luanphan.view_container.tmux.screen")
  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, false, { relative = "editor", row = 0, col = 0, width = 10, height = 4, style = "minimal" })
  local ok, err = pcall(function()
    local term = vim.api.nvim_open_term(buf, {})
    for _, case in ipairs({ { "\27[44m0123456789\27[0m", "0123456789" }, { "wide 日本", "wide 日本" } }) do
      local pane = { view_width = 10, view_height = 4, width = 10, height = 4 }
      local flags = { "10", "1", "0", "1", "0", "0", "0", "10", "4", "1" }
      local _, output = screen.frame(pane, { "top", case[1], "", "" }, flags)
      vim.api.nvim_chan_send(term, output .. "X")
      local rows
      assert_true(vim.wait(2000, function()
        rows = vim.tbl_map(vim.trim, vim.api.nvim_buf_get_lines(buf, -5, -1, false))
        return rows[2] == case[2] and rows[3] ~= ""
      end), "the character after a full row did not start a new row: " .. vim.inspect(rows))
      assert_true(vim.deep_equal(rows, { "top", case[2], "X", "" }), "a repaint lost the pending wrap: " .. vim.inspect(rows))
    end
  end)
  pcall(vim.api.nvim_win_close, win, true)
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  assert_true(ok, tostring(err))
end

local function test_claude_title_reports_status()
  if vim.fn.executable("tmux") == 0 or vim.fn.executable("python3") == 0 then return end
  local root = uv.fs_mkdtemp("/tmp/nvim-claude-title-XXXXXX")
  local script = root .. "/test.lua"
  -- Claude prefixes its terminal title with a spinner while working and "✳" when it rests.
  write(root .. "/titles.py", {
    "import sys, time",
    "def title(text): sys.stdout.write(f'\x1b]0;{text}\x07'); sys.stdout.flush()",
    "title('✳ Claude Code'); time.sleep(1.2)",
    "for frame in ['◐', '◑', '◐']: title(f'{frame} Fix the parser'); time.sleep(0.4)",
    "title('✳ Fix the parser'); time.sleep(60)",
  })
  write(script, vim.list_extend({
    "local root = " .. string.format("%q", root),
    "vim.g.luanphan_global_settings_path = root .. '/settings.toml'",
    "vim.g.luanphan_recent_paths_file = root .. '/recent.json'",
    "vim.g.luanphan_claude_sessions_dir = root .. '/sessions'",
  }, vim.split([=[
require("luanphan.agents.plugins.claude.claude").defaults.cmd = { "python3", root .. "/titles.py" }
local buf = require("luanphan.agents.main").new("claude")
local view = require("luanphan.view_container")
local seen = {}
assert(vim.wait(8000, function()
  local status = vim.b[buf].luanphan_view_status
  if status ~= seen[#seen] then seen[#seen + 1] = status end
  return status == "done"
end, 20), "claude title never reported done: " .. table.concat(seen, ","))
assert(vim.tbl_contains(seen, "working"), "claude title never reported working: " .. table.concat(seen, ","))
assert(view.tab_label(buf) == "Fix the parser", "claude title kept its status prefix: " .. view.tab_label(buf))
]=], "\n", { plain = true })))
  local output = vim.fn.systemlist(child_nvim_luafile_command(root, script))
  vim.system({ "tmux", "-S", agent_socket(script), "kill-server" }):wait()
  vim.fn.delete(root, "rf")
  assert_true(vim.v.shell_error == 0, table.concat(output, "\n"))
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

return {
  test_tmux_floating_terminal = test_tmux_floating_terminal,
  test_tmux_resize_rebuilds_inline_output = test_tmux_resize_rebuilds_inline_output,
  test_tmux_paint_keeps_split_escape_sequence = test_tmux_paint_keeps_split_escape_sequence,
  test_tmux_split_window_keeps_cursor = test_tmux_split_window_keeps_cursor,
  test_tmux_repaint_recovers_under_output = test_tmux_repaint_recovers_under_output,
  test_tmux_frame_restores_scroll_region = test_tmux_frame_restores_scroll_region,
  test_tmux_frame_keeps_pending_wrap = test_tmux_frame_keeps_pending_wrap,
  test_claude_title_reports_status = test_claude_title_reports_status,
  test_terminal_view_container = test_terminal_view_container,
  test_worktree_switch_hides_toggleterm = test_worktree_switch_hides_toggleterm,
}
