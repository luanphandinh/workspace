local M = {}
local api = vim.api
local tmux = require("luanphan.view_container.tmux.client").new(function()
  local socket = vim.g.luanphan_floating_tmux_socket
  if not socket and vim.env.TMUX then
    local inherited = vim.env.TMUX:match("^(.*),%d+,%d+$")
    if inherited and vim.uv.fs_stat(inherited) then socket = inherited end
  end
  return { socket = socket, config = vim.g.luanphan_floating_tmux_config }
end)
local pty = require("luanphan.view_container.tmux.pane")
local model = require("luanphan.view_container.tmux.windows")
local views = require("luanphan.view_container")
local editor = require("luanphan.view_container.editor")
local bars = require("luanphan.view_container.window_bar")
local settings = require("luanphan.global_settings")

local client, session, previous_session
local windows, panes = {}, {}
local current, anchor, bar, tiles
local rendering, refresh_queued, refresh_pending, refresh_again
local creating, focus_on_render, selection
local layout_path, layout_stat, layout_options

local refresh, render, open, paint

local function valid(win)
  return win and api.nvim_win_is_valid(win)
end

local function geometry()
  local path = settings.config_path()
  local stat = vim.uv.fs_stat(path)
  if not layout_options or layout_path ~= path or not stat or not layout_stat
    or stat.ino ~= layout_stat.ino or stat.size ~= layout_stat.size
    or stat.mtime.sec ~= layout_stat.mtime.sec or stat.mtime.nsec ~= layout_stat.mtime.nsec then
    layout_options = settings.read(path).floating_terminal
    layout_path, layout_stat = path, vim.uv.fs_stat(path)
  end
  return views.layout(layout_options)
end

local function run(args, after, failed)
  if not client then return end
  local connection = client
  connection:request(args, function(ok, lines)
    if client ~= connection then return end
    if ok then
      if after then after(lines) end
    else
      if failed then failed() end
      vim.notify("tmux " .. args[1] .. ": " .. table.concat(lines, " "), vim.log.levels.ERROR)
    end
  end)
end

local function batch(commands, callback)
  if #commands == 0 then
    if callback then callback(true) end
    return
  end
  local connection = client
  connection:request_batch(commands, function(replies)
    if client ~= connection then return end
    local ok = true
    for index, reply in ipairs(replies) do
      if not reply.ok then
        ok = false
        vim.notify("tmux " .. commands[index][1] .. ": " .. table.concat(reply.lines, " "), vim.log.levels.ERROR)
      end
    end
    if callback then callback(ok) end
  end)
end

local function active_window()
  local buf = current and current.active and current.active.bufnr
  local win = buf and vim.fn.bufwinid(buf)
  return win and win ~= -1 and win or anchor
end

local function activate(pane, view_mode)
  if not client or not pane then return false end
  local target = { id = pane.id, focus = not view_mode or editor.window(anchor) == api.nvim_get_current_win() }
  selection = target
  local commands = {}
  if pane.group.active ~= pane then
    commands[#commands + 1] = model.write(pane.group.active, { active = false })
    commands[#commands + 1] = model.write(pane, { active = true })
  end
  commands[#commands + 1] = { "select-window", "-t", session.id .. ":" .. pane.window }
  batch(commands, function(ok)
    if selection ~= target then return end
    if ok then target.done = true else selection = nil end
    refresh()
  end)
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
  if not current or not current.active or creating then return end
  local group = current
  local active = group.active
  local function done()
    creating = false
    focus_new_pane()
  end
  creating = true
  run({ "new-window", "-P", "-F", "#{pane_id}", "-t", session.id .. ":", "-c", "#{pane_current_path}",
    "-n", group.title }, function(lines)
    local pane = { id = lines[1], data = active.data }
    local items = vim.list_slice(group.items)
    for index, item in ipairs(items) do
      if item == active then table.insert(items, index + 1, pane) break end
    end
    local commands = {}
    for index, item in ipairs(items) do
      commands[#commands + 1] = model.write(item, { pane_order = index, active = item == pane })
    end
    batch(commands, done)
  end, done)
end

local function pick_session()
  local sessions = tmux:sessions()
  views.select("Tmux Sessions", sessions, function(choice)
    if session and session.id == choice.id then return end
    M.hide()
    open(choice)
  end)
end

local function restore_view(pane)
  if not pane.pending_view or pane.view_pending then return end
  pane.view_pending = true
  vim.schedule(function()
    local view = pane.pending_view
    pane.pending_view, pane.view_pending = nil, false
    if panes[pane.id] ~= pane or not pane.visible or not view then return end
    local win = vim.fn.bufwinid(pane.bufnr)
    if win == -1 then return end
    pty.apply_view(pane, win, view)
  end)
end

paint = function(pane)
  if not pane.term or not pane.visible or pane.capturing or not client then return end
  local connection = client
  pane.capturing, pane.ready, pane.dirty = true, false, false
  pty.capture(pane, function(lines, flags, primary)
    if client ~= connection or panes[pane.id] ~= pane then return end
    pane.capturing = false
    if not lines or not pane.visible or pane.resizing then return end
    local frame, output = pty.frame(pane, lines, flags, primary)
    local in_input = api.nvim_get_current_buf() == pane.bufnr and api.nvim_get_mode().mode == "t"
    local follow = not pane.painted or (in_input and output ~= "")
    pane.frame, pane.ready, pane.painted = frame, true, true
    if follow then
      pane.pending_view = { row = frame.row, col = frame.col }
      -- Cursor-only frames can leave the terminal buffer text untouched.
      vim.defer_fn(function() restore_view(pane) end, 20)
    end
    if output ~= "" then pty.output(pane, output) end
    if pane.dirty then paint(pane) end
  end)
end

local function bind_shortcuts(buf)
  local opts = { buffer = buf, silent = true, nowait = true }
  editor.bind(buf)
  vim.keymap.set("n", "<leader>nw", new_window, vim.tbl_extend("force", opts, { desc = "New tmux window" }))
  for _, key in ipairs({ "<leader>nt", "<leader>fn" }) do
    vim.keymap.set("n", key, function() new_tab() end,
      vim.tbl_extend("force", opts, { desc = "New terminal pane" }))
  end
  vim.keymap.set("n", "<leader>ns", pick_session, vim.tbl_extend("force", opts, { desc = "Select tmux session" }))
end

local function select_neighbor(direction)
  local moved = views.focus_neighbor(api.nvim_get_current_win(), direction, function(neighbor)
    local id = vim.b[api.nvim_win_get_buf(neighbor)].luanphan_tmux_pane
    if id then activate(panes[id]) end
  end)
  if moved then return end
  if not tiles:navigate_tabs(direction, #current.items, true) then bar:focus_towards(direction) end
end

local function prepare_buffer(pane)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "hide"
  vim.b[buf].luanphan_persist_term = true
  vim.b[buf].luanphan_floating_terminal = true
  vim.b[buf].luanphan_tmux_pane = pane.id
  pane.bufnr = buf
  if pane.cwd then require("luanphan.terminal_references").attach(buf, pane.cwd) end
  bar:attach(buf)
  bar:map_jumps(buf, false)
  bind_shortcuts(buf)
  local opts = { buffer = buf, silent = true, nowait = true }
  vim.keymap.set("t", "<C-h>", "<C-h>", opts)
  vim.keymap.set("t", "<C-]>", function() pty.input(pane, "\27") end,
    vim.tbl_extend("force", opts, { desc = "Send Escape to tmux pane" }))
  tiles:bind(buf)
  for _, direction in ipairs({ "h", "j", "k", "l" }) do
    vim.keymap.set("n", "<C-" .. direction .. ">", function() select_neighbor(direction) end, opts)
  end
  tiles:bind_tile_moves(buf)
end

local function reorder_panes(items)
  local commands = {}
  for index, item in ipairs(items) do
    if item.data.pane_order ~= index then
      commands[#commands + 1] = model.write(item, { pane_order = index })
    end
  end
  if #commands == 0 then render() else batch(commands, refresh) end
end

tiles = views.create({
  context = function() return current end,
  tabs = function(group) return group.items end,
  editor = {
    key = function(group) return "tmux:" .. session.id .. ":" .. group.id end,
    active = function(group) return group.active.bufnr end,
    refresh = function() render() end,
    navigate = function(_, direction) select_neighbor(direction) end,
  },
  reorder = reorder_panes,
  activate = activate,
  new = new_tab,
  create_key = false,
  cycle_desc = "Next tmux pane",
})

bar = bars.create({
  title = "Tmux Windows",
  groups = function() return windows end,
  load_order = function() if session then return tmux:load_window_order(session.id) end end,
  save_order = function(order) return session and tmux:save_window_order(session.id, order) end,
  active_window = active_window,
  activate = activate,
  rename_window = function(group, name)
    local commands = {}
    for _, pane in ipairs(group.items) do
      commands[#commands + 1] = model.write(pane, { title = name })
      commands[#commands + 1] = model.rename(pane.window, name)
    end
    batch(commands, refresh)
  end,
  reorder = function(_, items) reorder_panes(items) end,
  bind = bind_shortcuts,
})

local function render_panel()
  if not current or not current.active then return end
  local layout = geometry()
  local focus = focus_on_render or not valid(anchor) or vim.api.nvim_get_current_win() == anchor
    or (vim.w[api.nvim_get_current_win()].luanphan_view_anchor == anchor
      and api.nvim_get_current_win() ~= editor.window(anchor))
  local selected = current.active
  for _, pane in ipairs(current.items) do
    if not pane.bufnr or not api.nvim_buf_is_valid(pane.bufnr) then
      pane.term, pane.frame, pane.painted = nil, nil, nil
      prepare_buffer(pane)
    end
  end
  if valid(anchor) then
    for _, win in ipairs(views.group_windows(anchor)) do
      local pane = panes[vim.b[api.nvim_win_get_buf(win)].luanphan_tmux_pane]
      if pane and pane.visible and not pane.pending_view then
        pane.last_view = api.nvim_win_call(win, vim.fn.winsaveview)
        pane.follow_live = pane.last_view.topline >= pty.live_topline(pane)
      end
    end
  end
  if not valid(anchor) then
    anchor = api.nvim_open_win(selected.bufnr, false, vim.tbl_extend("force", layout.body, { style = "minimal" }))
  end
  tiles.active_by_context = { [current] = { id = selected.id, bufnr = selected.bufnr } }
  local displayed = tiles:display(anchor, current, layout)
  if not displayed then
    api.nvim_win_set_buf(anchor, selected.bufnr)
    tiles:render(anchor, current)
    displayed = { { win = anchor, tab = selected } }
  end
  bar:layout(anchor, layout)
  local visible = {}
  for _, item in ipairs(displayed) do
    local pane, win = item.tab, item.win
    visible[pane.id] = true
    vim.wo[win].winhighlight = "NormalFloat:Normal,WinBar:Normal,WinBarNC:Comment,TabLineFill:Normal"
    vim.wo[win].scrolloff = 0
    local width = api.nvim_win_get_width(win)
    local height = math.max(1, api.nvim_win_get_height(win) - (vim.wo[win].winbar == "" and 0 or 1))
    local resize = pane.width ~= width or pane.height ~= height
    local follow = not pane.visible and pane.hidden_output and pane.follow_live
    if not pane.visible and pane.painted and not follow then
      if pane.last_view then pty.apply_view(pane, win, pane.last_view) end
    end
    pane.visible, pane.view_width, pane.view_height = true, width, height
    pane.hidden_output = nil
    if not pane.term then
      pane.client = client
      pane.restore_primary = true
      pty.open(pane)
      api.nvim_buf_attach(pane.bufnr, false, { on_lines = function() restore_view(pane) end })
    end
    if resize then
      local size = width .. "x" .. height
      if pane.resizing ~= size then
        pane.resizing = size
        pty.resize(pane, width, height, function(ok)
          if panes[pane.id] ~= pane or pane.resizing ~= size then return end
          pane.resizing = nil
          if ok then pane.width, pane.height = width, height end
          if not pane.ready then paint(pane) end
        end)
      end
    elseif not pane.ready and not pane.resizing then
      paint(pane)
    end
    if follow and pane.ready then
      pty.cursor(pane, function(view)
        if panes[pane.id] ~= pane or not pane.visible then return end
        pane.pending_view = view
        restore_view(pane)
      end)
    end
  end
  for id, pane in pairs(panes) do
    if not visible[id] then pane.visible = false end
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

local function apply_snapshot(records, completed_selection)
  local by_window, listed, next_windows, selected = {}, {}, {}, nil
  local selected_pane
  for _, record in ipairs(records) do
    local data = record.data
    local group = by_window[data.group]
    if not group then
      group = { id = data.group, title = data.title, index = data.window_order, items = {} }
      by_window[group.id] = group
      next_windows[#next_windows + 1] = group
    end
    local pane = panes[record.id] or { id = record.id }
    local old_cwd = pane.cwd
    for key, value in pairs(record) do pane[key] = value end
    pane.group = group
    if pane.bufnr and pane.cwd ~= old_cwd and pane.cwd ~= "" then
      require("luanphan.terminal_references").attach(pane.bufnr, pane.cwd)
    end
    group.items[#group.items + 1], listed[pane.id] = pane, pane
    if data.active then group.active = pane end
    if record.selected then selected, selected_pane = group, pane end
  end
  if selected then selected.active = selected_pane end
  table.sort(next_windows, function(a, b)
    if a.index ~= b.index then return a.index < b.index end
    return tonumber(a.id:sub(2)) < tonumber(b.id:sub(2))
  end)
  for _, group in ipairs(next_windows) do
    table.sort(group.items, function(a, b) return a.data.pane_order < b.data.pane_order end)
    group.active = group.active or group.items[1]
  end
  local old = panes
  windows, panes, current = next_windows, listed, selected or next_windows[1]
  if current then
    if selection then
      if current.active.id == selection.id then
        focus_on_render = selection.focus or focus_on_render
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
    if not listed[id] then
      pane.client = nil
      if pane.bufnr and api.nvim_buf_is_valid(pane.bufnr) then api.nvim_buf_delete(pane.bufnr, { force = true }) end
    end
  end
end

refresh = function()
  if not client or refresh_queued or creating then return end
  if refresh_pending then refresh_again = true return end
  local connection = client
  refresh_queued = true
  vim.schedule(function()
    if client ~= connection then return end
    if creating then refresh_queued = false return end
    refresh_queued, refresh_pending = false, true
    local completed_selection = selection and selection.done and selection
    client:request({ "list-panes", "-s", "-t", session.id, "-F", model.format }, function(ok, lines)
      if client ~= connection then return end
      refresh_pending = false
      if ok and not creating then
        local records = model.read(lines)
        local commands = model.migrate(records)
        if #commands > 0 then
          refresh_pending = true
          batch(commands, function(migrated)
            if client ~= connection then return end
            refresh_pending, refresh_again = false, false
            if migrated then refresh() else M.hide() end
          end)
          return
        end
        apply_snapshot(records, completed_selection)
      end
      if refresh_again then
        refresh_again = false
        refresh()
      end
    end)
  end)
end

function M.hide(closing)
  if not client and not valid(anchor) then return false end
  bar:reset_order()
  local connection, win, old = client, anchor, panes
  client, session, anchor, current = nil, nil, nil, nil
  windows, panes = {}, {}
  refresh_queued, refresh_pending, refresh_again = nil, nil, nil
  creating, focus_on_render, selection = nil, nil, nil
  bar.win, bar.anchor = nil, nil
  if connection then connection:detach() end
  if win then views.close_group(win, closing) end
  vim.schedule(function()
    for _, pane in pairs(old) do
      if pane.bufnr and api.nvim_buf_is_valid(pane.bufnr) then api.nvim_buf_delete(pane.bufnr, { force = true }) end
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
  editor.remember_source(api.nvim_get_current_win())
  session = target
  client = tmux:attach(target, {
    flags = "ignore-size,pause-after=5",
    ready = function()
      previous_session = target.id
      refresh()
    end,
    output = function(id, bytes)
      local pane = panes[id]
      if not pane then return end
      if pane.ready then
        if not pane.visible then pane.hidden_output = true end
        pane.frame = nil
        pty.output(pane, bytes)
      elseif pane.capturing then
        pane.dirty = true
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
  local body = geometry().body
  local target = tmux:ensure_session(previous_session, body.width, body.height - 1)
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
    if valid(win) and vim.w[win].luanphan_view_independent_tile then return end
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
