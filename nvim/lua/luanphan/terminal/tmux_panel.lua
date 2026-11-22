local M = {}
local api = vim.api
local tmux = require("luanphan.terminal.tmux_client")
local screen = require("luanphan.terminal.tmux_screen")
local views = require("luanphan.view_container")
local bars = require("luanphan.view_container.window_bar")
local settings = require("luanphan.global_settings")

local client, session, previous_session
local windows, panes = {}, {}
local current, anchor, bar, tiles
local rendering, refresh_pending, refresh_again
local client_size, focus_on_render, selection

local pane_fields = {
  "window_id", "window_index", "window_active", "pane_id", "pane_active",
  "pane_index", "pane_width", "pane_height", "@pin_sidebar",
  "pane_current_command", "window_name", "pane_current_path",
}
local pane_format = "#{" .. table.concat(pane_fields, "}\t#{") .. "}"
local history_position = "#{?#{!=:#{history_added},},#{history_added},#{history_size}}"
local cursor_format = "#{cursor_x}\t#{cursor_y}\t#{alternate_on}\t#{cursor_flag}"
  .. "\t#{keypad_cursor_flag}\t#{bracket_paste_flag}\t" .. history_position
  .. "\t#{pane_width}\t#{pane_height}\t#{history_generation}"

local refresh, render, open, paint

local function valid(win)
  return win and api.nvim_win_is_valid(win)
end

local function geometry()
  local options = settings.read().floating_terminal
  local border_size = options.display_style == "tile" and 2 or 0
  local frame = {
    relative = "editor", row = 0, col = 0, width = vim.o.columns - border_size,
    height = math.max(4, vim.o.lines - vim.o.cmdheight) - border_size,
    border = border_size == 0 and "none" or "single", zindex = 40,
  }
  local body, header = bars.float_geometry(frame, options)
  return body, header, options
end

local function resize(body)
  if not client or session.attached > 0 then return end
  local size = ("%dx%d"):format(body.width, body.height - 1)
  if size == client_size then return end
  client_size = size
  client:request({ "list-clients", "-t", session.id, "-F", "#{client_control_mode}" }, function(ok, lines)
    if ok and #lines <= 1 and client_size == size then
      client:request({ "refresh-client", "-C", size })
    end
  end)
end

local function run(args, after, failed)
  if not client then return end
  client:request(args, function(ok, lines)
    if ok then
      if after then after(lines) end
    else
      if failed then failed() end
      vim.notify("tmux " .. args[1] .. ": " .. table.concat(lines, " "), vim.log.levels.ERROR)
    end
  end)
end

local function active_window()
  local win = current and current.active and vim.fn.bufwinid(current.active.bufnr)
  return win and win ~= -1 and win or anchor
end

local function activate(pane, view_mode)
  if not client or not pane then return false end
  local target = { id = pane.id, enter = not view_mode }
  selection = target
  local function complete()
    target.done = true
    refresh()
  end
  local function failed()
    if selection == target then selection = nil end
    refresh()
  end
  run({ "select-pane", "-t", pane.id }, function()
    if selection ~= target then return end
    if current and current.id == pane.group.id then
      complete()
    else
      run({ "select-window", "-t", session.id .. ":" .. pane.group.id }, complete, failed)
    end
  end, failed)
  return true
end

local function focus_new_pane()
  focus_on_render = true
  refresh()
end

local function new_window()
  if session then run({ "new-window", "-t", session.id .. ":", "-c", vim.fn.getcwd() }, focus_new_pane) end
end

local function new_tab()
  if not current or not current.active then return end
  local pane = current.active
  local axis = #current.items % 2 == 1 and "-h" or "-v"
  run({ "split-window", axis, "-t", pane.id, "-c", "#{pane_current_path}" }, focus_new_pane)
end

local function pick_session()
  local sessions = tmux.sessions()
  views.select("Tmux Sessions", sessions, function(choice)
    if session and session.id == choice.id then return end
    M.hide()
    open(choice)
  end)
end

local function enter_input(pane, data)
  -- The tmux server handles terminal replies. Forward only input from the user.
  if pane.receiving or not client then return end
  if data:find("\12", 1, true) then pane.follow_clear = true end
  pane.input = (pane.input or "") .. data
  if pane.input_pending then return end
  pane.input_pending = true
  local connection = client
  vim.schedule(function()
    local bytes = pane.input
    pane.input, pane.input_pending = nil, nil
    if client ~= connection or panes[pane.id] ~= pane then return end
    for start = 1, #bytes, 512 do
      local args = { "send-keys", "-H", "-t", pane.id }
      for index = start, math.min(start + 511, #bytes) do
        args[#args + 1] = ("%02x"):format(bytes:byte(index))
      end
      client:request(args)
    end
  end)
end

local function send_output(pane, bytes)
  if not pane.term or not api.nvim_buf_is_valid(pane.bufnr) then return end
  pane.receiving = true
  api.nvim_chan_send(pane.term, bytes)
  pane.receiving = false
end

local function update_live_view(pane)
  if not pane.live_cursor or pane.view_pending then return end
  pane.view_pending = true
  vim.schedule(function()
    local cursor = pane.live_cursor
    pane.live_cursor, pane.view_pending = nil, false
    if panes[pane.id] ~= pane or not pane.visible or not cursor then return end
    local win = vim.fn.bufwinid(pane.bufnr)
    if win == -1 then return end
    local count = api.nvim_buf_line_count(pane.bufnr)
    local top = math.max(1, count - pane.view_height + 1)
    local line = math.min(count, top + cursor[1])
    api.nvim_win_call(win, function()
      local col = math.max(0, vim.fn.virtcol2col(win, line, cursor[2] + 1) - 1)
      vim.fn.winrestview({ topline = top, lnum = line, col = col, leftcol = 0 })
    end)
  end)
end

local function queue_paint(pane)
  if pane.capturing then pane.dirty = true return end
  if pane.paint_pending then return end
  pane.paint_pending = true
  vim.defer_fn(function()
    pane.paint_pending = false
    if panes[pane.id] == pane then paint(pane) end
  end, 20)
end

local function capture_start(pane)
  if not pane.painted then return "-1000" end
  local frame = pane.frame
  if not frame or frame.alternate then return "0" end
  -- Include the rows that passed the tile's top since the last snapshot.
  local offset = ("#{e|-:%d,%s}"):format(frame.history + frame.top, history_position)
  return ("#{?#{m:-*,%s},%s,0}"):format(offset, offset)
end

paint = function(pane)
  if not pane.term or not pane.visible or pane.capturing or not client then return end
  local connection = client
  pane.capturing, pane.ready, pane.dirty = true, false, false
  local capture = { "capture-pane", "-epN", "-t", pane.id, "-S", capture_start(pane) }
  client:request_batch({ capture, { "display-message", "-p", "-t", pane.id, cursor_format } }, function(replies)
    if client ~= connection or panes[pane.id] ~= pane then return end
    pane.capturing = false
    local content, cursor = unpack(replies)
    if not content.ok or not cursor.ok or not pane.visible then return end
    local flags = vim.split(cursor.lines[1] or "", "\t", { plain = true })
    local frame, output = screen.frame(pane, content.lines, flags)
    local in_input = api.nvim_get_current_buf() == pane.bufnr and api.nvim_get_mode().mode == "t"
    local follow = pane.follow_clear or not pane.painted or (in_input and output ~= "")
    pane.frame, pane.ready, pane.painted, pane.follow_clear = frame, true, true, false
    if follow then
      pane.live_cursor = { frame.row, frame.col }
      -- Cursor-only frames can leave the terminal buffer text untouched.
      vim.defer_fn(function() update_live_view(pane) end, 20)
    end
    if output ~= "" then send_output(pane, output) end
    if pane.dirty then queue_paint(pane) end
  end)
end

local function bind_shortcuts(buf)
  local opts = { buffer = buf, silent = true, nowait = true }
  vim.keymap.set("n", "<leader>nw", new_window, vim.tbl_extend("force", opts, { desc = "New tmux window" }))
  for _, key in ipairs({ "<leader>nt", "<leader>fn" }) do
    vim.keymap.set("n", key, function() new_tab() end,
      vim.tbl_extend("force", opts, { desc = "Split tmux pane" }))
  end
  vim.keymap.set("n", "<leader>ns", pick_session, vim.tbl_extend("force", opts, { desc = "Select tmux session" }))
end

local function select_neighbor(direction)
  local neighbor = views.tile_neighbor(api.nvim_get_current_win(), direction)
  if not neighbor then
    if not tiles.tile_anchor and #current.items > 1 and (direction == "h" or direction == "l") then
      tiles:cycle(current, direction == "h" and -1 or 1)
    elseif direction == (bar.style == "horizontal" and "k" or "h") then
      bar:focus()
    end
    return
  end
  local id = vim.b[api.nvim_win_get_buf(neighbor)].luanphan_tmux_pane
  if id then activate(panes[id]) end
end

local function prepare_buffer(pane)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "hide"
  vim.b[buf].luanphan_persist_term = true
  vim.b[buf].luanphan_floating_terminal = true
  vim.b[buf].luanphan_tmux_pane = pane.id
  pane.bufnr = buf
  bar:attach(buf)
  bar:map_jumps(buf, false)
  bind_shortcuts(buf)
  local opts = { buffer = buf, silent = true, nowait = true }
  vim.keymap.set("t", "<C-h>", "<C-h>", opts)
  vim.keymap.set("t", "<C-]>", function() enter_input(pane, "\27") end,
    vim.tbl_extend("force", opts, { desc = "Send Escape to tmux pane" }))
  tiles:bind(buf)
  for _, direction in ipairs({ "h", "j", "k", "l" }) do
    vim.keymap.set("n", "<C-" .. direction .. ">", function() select_neighbor(direction) end, opts)
  end
  tiles:bind_tile_moves(buf)
end

local function reorder_panes(group, items)
  local previous = vim.list_slice(group.items)
  table.sort(previous, function(a, b) return a.index < b.index end)
  for index, item in ipairs(items) do
    local other = previous[index]
    if item.id ~= other.id then
      run({ "swap-pane", "-d", "-s", item.id, "-t", other.id }, refresh)
      local source = vim.iter(previous):enumerate():find(function(_, candidate) return candidate.id == item.id end)
      previous[source], previous[index] = other, item
    end
  end
end

tiles = views.create({
  context = function() return current end,
  tabs = function(group) return group.items end,
  reorder = function(items, group) reorder_panes(group, items) end,
  activate = activate,
  new = new_tab,
  create_key = false,
  cycle_desc = "Next tmux pane",
})

bar = bars.create({
  title = "Tmux Windows",
  groups = function() return windows end,
  active_window = active_window,
  activate = activate,
  rename_window = function(group, name)
    -- tmux expands formats in window names.
    run({ "rename-window", "-t", group.id, "--", (name:gsub("#", "##")) }, refresh)
  end,
  reorder = reorder_panes,
  reorder_groups = function(group, other)
    local prefix = session.id .. ":"
    run({ "swap-window", "-d", "-s", prefix .. group.id, "-t", prefix .. other.id }, refresh)
  end,
  bind = bind_shortcuts,
})

local function render_panel()
  if not current or not current.active then return end
  local body, header, options = geometry()
  resize(body)
  local focus = focus_on_render or not valid(anchor) or vim.api.nvim_get_current_win() == anchor
    or vim.w[api.nvim_get_current_win()].luanphan_view_anchor == anchor
  local selected = current.active
  if not valid(anchor) then
    anchor = api.nvim_open_win(selected.bufnr, false, vim.tbl_extend("force", body, { style = "minimal" }))
  end
  tiles.active_by_context = { [current] = { id = selected.id, bufnr = selected.bufnr } }
  local displayed = tiles:display(anchor, current, body, options.display_style)
  if not displayed then
    api.nvim_win_set_buf(anchor, selected.bufnr)
    tiles:render(anchor, current)
    displayed = { { win = anchor, tab = selected } }
  end
  bar:layout(anchor, header, options.window_bar_style)
  local visible = {}
  for _, item in ipairs(displayed) do
    local pane, win = item.tab, item.win
    bar:attach(pane.bufnr)
    visible[pane.id] = true
    vim.wo[win].winhighlight = "NormalFloat:Normal,WinBar:Normal,WinBarNC:Comment,TabLineFill:Normal"
    vim.wo[win].scrolloff = 0
    local width = api.nvim_win_get_width(win)
    local height = math.max(1, api.nvim_win_get_height(win) - (vim.wo[win].winbar == "" and 0 or 1))
    local repaint = not pane.visible or pane.view_width ~= width or pane.view_height ~= height or pane.changed_size
    pane.visible, pane.view_width, pane.view_height, pane.changed_size = true, width, height, nil
    pane.snapshot = pane.width ~= width or pane.height ~= height
    if not pane.term then
      pane.term = api.nvim_open_term(pane.bufnr, {
        force_crlf = false,
        on_input = function(_, _, _, data) enter_input(pane, data) end,
      })
      api.nvim_buf_attach(pane.bufnr, false, { on_lines = function() update_live_view(pane) end })
    end
    if repaint then paint(pane) end
  end
  for id, pane in pairs(panes) do
    if not visible[id] then pane.visible, pane.ready = false, false end
  end
  if focus and valid(active_window()) then
    focus_on_render = false
    api.nvim_set_current_win(active_window())
  end
  if not selection then bar.history.record(selected.bufnr) end
  bar:refresh(api.nvim_get_current_win() == bar.win)
  tiles:refresh_tile_highlights()
end

render = function()
  if rendering then return end
  rendering = true
  local ok, err = pcall(render_panel)
  rendering = false
  if not ok then
    M.hide()
    vim.notify("Could not render tmux panes: " .. tostring(err), vim.log.levels.ERROR)
  end
end

local function apply_snapshot(lines, completed_selection)
  local by_window, listed, next_windows, selected = {}, {}, {}, nil
  for _, line in ipairs(lines) do
    local field = vim.split(line, "\t", { plain = true })
    local window_id, pane_id = field[1], field[4]
    if pane_id and pane_id:match("^%%%d+$") and field[9] ~= "1" then
      local group = by_window[window_id]
      if not group then
        group = { id = window_id, title = field[11] or window_id, index = tonumber(field[2]), items = {} }
        by_window[window_id] = group
        next_windows[#next_windows + 1] = group
      end
      local pane = panes[pane_id]
      if not pane or not api.nvim_buf_is_valid(pane.bufnr) then
        pane = { id = pane_id }
        prepare_buffer(pane)
      end
      local width, height = tonumber(field[7]), tonumber(field[8])
      pane.changed_size = pane.width ~= width or pane.height ~= height
      pane.group, pane.label = group, field[10] ~= "" and field[10] or "shell"
      local cwd = field[12]
      if cwd and cwd ~= "" and cwd ~= pane.cwd then
        pane.cwd = cwd
        require("luanphan.terminal_references").attach(pane.bufnr, cwd)
      end
      pane.index, pane.width, pane.height = tonumber(field[6]), width, height
      group.items[#group.items + 1], listed[pane_id] = pane, pane
      if field[5] == "1" then group.active = pane end
      if field[3] == "1" then selected = group end
    end
  end
  table.sort(next_windows, function(a, b) return a.index < b.index end)
  for _, group in ipairs(next_windows) do
    table.sort(group.items, function(a, b) return a.index < b.index end)
    group.active = group.active or group.items[1]
  end
  local old = panes
  windows, panes, current = next_windows, listed, selected or next_windows[1]
  if current then
    if selection then
      if current.active.id == selection.id then
        focus_on_render = selection.enter or focus_on_render
        if selection.done then selection = nil end
      elseif selection == completed_selection then
        selection = nil
      end
    end
    render()
  elseif valid(anchor) then
    M.hide()
  end
  for id, pane in pairs(old) do
    if not listed[id] and api.nvim_buf_is_valid(pane.bufnr) then api.nvim_buf_delete(pane.bufnr, { force = true }) end
  end
end

refresh = function()
  if not client then return end
  if refresh_pending then refresh_again = true return end
  refresh_pending = true
  local completed_selection = selection and selection.done and selection
  client:request({ "list-panes", "-s", "-t", session.id, "-F", pane_format }, function(ok, lines)
    refresh_pending = false
    if ok then apply_snapshot(lines, completed_selection) end
    if refresh_again then
      refresh_again = false
      refresh()
    end
  end)
end

function M.hide(closing)
  if not client and not valid(anchor) then return false end
  local connection, win, old = client, anchor, panes
  client, session, anchor, current = nil, nil, nil, nil
  windows, panes = {}, {}
  refresh_pending, refresh_again, client_size, focus_on_render, selection = nil, nil, nil, nil, nil
  bar.win, bar.anchor = nil, nil
  if connection then connection:detach() end
  if win then views.close_group(win, closing) end
  vim.schedule(function()
    for _, pane in pairs(old) do
      if api.nvim_buf_is_valid(pane.bufnr) then api.nvim_buf_delete(pane.bufnr, { force = true }) end
    end
  end)
  return true
end

local topology_events = {
  ["layout-change"] = true, ["window-add"] = true, ["window-close"] = true, ["window-renamed"] = true,
  ["window-pane-changed"] = true, ["session-window-changed"] = true,
}

open = function(target)
  require("luanphan.agents.main").hide()
  session = target
  client = tmux.attach(target, {
    ready = function()
      previous_session = target.id
      resize(geometry())
      refresh()
    end,
    output = function(id, bytes)
      local pane = panes[id]
      if not pane or not pane.visible then return end
      if pane.snapshot or pane.follow_clear or pane.capturing then
        queue_paint(pane)
      elseif pane.ready then
        pane.frame = nil
        send_output(pane, bytes)
      end
    end,
    event = function(event, payload)
      if topology_events[event] then
        refresh()
      elseif event == "pause" then
        local pane = panes[payload]
        if pane then pane.ready = false end
        client:request({ "refresh-client", "-A", payload .. ":continue" }, function(ok)
          if ok and pane then paint(pane) end
        end)
      end
    end,
    exit = function(code, message)
      M.hide()
      if code ~= 0 then vim.notify(message or "tmux client disconnected", vim.log.levels.WARN) end
    end,
  })
end

function M.toggle()
  if M.hide() then return end
  local body = geometry()
  local target = tmux.ensure_session(previous_session, body.width, body.height - 1)
  if target then open(target) end
end

local events = api.nvim_create_augroup("LuanphanTmuxTerminal", { clear = true })
api.nvim_create_autocmd("WinEnter", {
  group = events,
  callback = function()
    if rendering or not valid(anchor) then return end
    local win = api.nvim_get_current_win()
    local pane = panes[vim.b.luanphan_tmux_pane]
    if pane and vim.fn.bufwinid(pane.bufnr) == win then
      if current and current.active ~= pane then activate(pane, true) end
    elseif views.group_anchor(win) ~= anchor
      and (api.nvim_win_get_config(win).relative == "" or vim.bo.buftype == "terminal") then
      local previous = anchor
      vim.schedule(function()
        if anchor == previous and views.group_anchor(api.nvim_get_current_win()) ~= anchor then M.hide() end
      end)
    end
  end,
})
api.nvim_create_autocmd("WinClosed", {
  group = events,
  callback = function(args)
    local win = tonumber(args.match)
    if win == anchor or win == bar.win or vim.tbl_contains(tiles.tile_windows or {}, win) then
      M.hide(win)
    end
  end,
})
api.nvim_create_autocmd("VimResized", {
  group = events,
  callback = function() if valid(anchor) then render() end end,
})
api.nvim_create_autocmd("BufWritePost", {
  group = events,
  callback = function(args)
    if valid(anchor) and vim.uv.fs_realpath(args.file) == vim.uv.fs_realpath(settings.config_path()) then render() end
  end,
})
api.nvim_create_autocmd("DirChangedPre", { group = events, callback = function() M.hide() end })
api.nvim_create_autocmd("User", {
  group = events, pattern = "LuanphanWorktreeSwitchPre", callback = function() M.hide() end,
})
api.nvim_create_autocmd("VimLeavePre", { group = events, callback = function() if client then client:detach() end end })

return M
