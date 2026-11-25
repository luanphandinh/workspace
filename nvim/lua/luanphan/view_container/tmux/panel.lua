local M = {}
local api = vim.api
local tmux_client = require("luanphan.view_container.tmux.client")
local pty = require("luanphan.view_container.tmux.pane")
local terminal_pane = require("luanphan.view_container.terminal")
local model = require("luanphan.view_container.tmux.windows")
local views = require("luanphan.view_container")
local editor = require("luanphan.view_container.editor")
local bars = require("luanphan.view_container.window_bar")
local settings = require("luanphan.global_settings")

function M.create(opts)
  local panel = {}
  local tmux = tmux_client.new(opts.server)
  local client, session, previous_session
  local windows, panes = {}, {}
  local current, bar, tiles
  local rendering, refresh_queued, refresh_pending, refresh_again
  local creating, focus_on_render, selection, closing_pane
  local focus_sidebar
  local layout_path, layout_stat, layout_options

  local refresh, render, open
  local events = api.nvim_create_augroup("LuanphanTmuxTerminal", { clear = true })

  local function valid(win)
    return win and api.nvim_win_is_valid(win)
  end

  local function geometry()
    local path = settings.config_path()
    local stat = vim.uv.fs_stat(path)
    if not layout_options or layout_path ~= path or not stat or not layout_stat
      or stat.ino ~= layout_stat.ino or stat.size ~= layout_stat.size
      or stat.mtime.sec ~= layout_stat.mtime.sec or stat.mtime.nsec ~= layout_stat.mtime.nsec then
      layout_options = settings.read(path)[opts.settings]
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
    return win and win ~= -1 and win or tiles:anchor()
  end

  local function should_focus(force)
    local win = api.nvim_get_current_win()
    local anchor = tiles:anchor()
    return force or not anchor or win == anchor
      or (views.group_anchor(win) == anchor and win ~= editor.window(anchor) and win ~= bar.win)
  end

  local function focus_visible(pane, force)
    if pane.group ~= current or not tiles:visible_window(current, pane.bufnr) then return false end
    current.active.data.active = false
    current.active, pane.data.active = pane, true
    return tiles:focus_tile(current, pane, should_focus(force))
  end

  local function activate(pane, view_mode)
    if not client or not pane then return false end
    local focus = not view_mode or editor.window(tiles:anchor()) == api.nvim_get_current_win()
    local visible = pane.group == current and tiles:visible_window(current, pane.bufnr)
    if visible and not selection and current.active == pane then return focus_visible(pane, focus) end
    local target = { id = pane.id, focus = focus, visible = visible, window = pane.window }
    selection = target
    local commands = {}
    if pane.group.active ~= pane then
      commands[#commands + 1] = model.write(pane.group.active, { active = false })
      commands[#commands + 1] = model.write(pane, { active = true })
    end
    commands[#commands + 1] = { "select-window", "-t", session.id .. ":" .. pane.window }
    batch(commands, function(ok)
      if selection ~= target then return end
      if ok and target.visible and focus_visible(pane, target.focus) then
        selection = nil
        return
      end
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
    local group, active = current, current.active
    return tiles:open_tile(group, function(place)
      local function done()
        creating = false
        focus_new_pane()
      end
      creating = true
      run({ "new-window", "-P", "-F", "#{pane_id}", "-t", session.id .. ":", "-c", "#{pane_current_path}",
        "-n", group.title }, function(lines)
        local pane = { id = lines[1], data = active.data }
        local commands = {}
        for index, item in ipairs(place(pane)) do
          commands[#commands + 1] = model.write(item, { pane_order = index, active = item == pane })
        end
        batch(commands, done)
      end, done)
    end)
  end

  local function switch_session(target, keep_sidebar)
    if session and session.id == target.id then return end
    panel.hide()
    focus_sidebar = keep_sidebar
    open(target)
  end

  local function pick_session()
    views.select("Tmux Sessions", tmux:sessions(), switch_session)
  end

  local function cycle_session(step)
    if not session then return end
    local sessions = tmux:sessions()
    if #sessions < 2 then return end
    table.sort(sessions, function(a, b) return tonumber(a.id:sub(2)) < tonumber(b.id:sub(2)) end)
    local index = vim.iter(sessions):enumerate():find(function(_, item) return item.id == session.id end)
    if index then switch_session(sessions[(index - 1 + step) % #sessions + 1], true) end
  end

  local function can_paint(pane)
    return client ~= nil and pane.client == client and panes[pane.id] == pane and pty.is_visible(pane) and not pane.resizing
  end

  local function repaint(pane)
    if not pane.ready then pty.paint(pane, can_paint) end
  end

  local function bind_shortcuts(buf)
    local opts = { buffer = buf, silent = true, nowait = true }
    vim.keymap.set("n", "<leader>nw", new_window, vim.tbl_extend("force", opts, { desc = "New tmux window" }))
    for _, key in ipairs({ "<leader>nt", "<leader>fn" }) do
      vim.keymap.set("n", key, function() new_tab() end,
        vim.tbl_extend("force", opts, { desc = "New terminal pane" }))
    end
    vim.keymap.set("n", "<leader>ns", pick_session, vim.tbl_extend("force", opts, { desc = "Select tmux session" }))
  end

  local function navigate(win, direction)
    views.navigate(win, direction, function(neighbor)
      local id = vim.b[api.nvim_win_get_buf(neighbor)].luanphan_tmux_pane
      if id then activate(panes[id]) end
    end, bar, function(step)
      return current and tiles:navigate_tabs(step, #current.items, true)
    end)
  end

  local function prepare_quit(pane)
    if not client or not pane or panes[pane.id] ~= pane then return end
    if closing_pane == pane then return function() end end
    closing_pane = pane
    return function()
      if closing_pane ~= pane then return end
      local next_pane = tiles:replacement(pane.group, pane.bufnr)
      local commands = { { "kill-pane", "-t", pane.id } }
      if next_pane then
        commands[#commands + 1] = model.write(next_pane, { active = true })
        commands[#commands + 1] = { "select-window", "-t", session.id .. ":" .. next_pane.window }
      end
      if selection and selection.id == pane.id then selection = nil end
      batch(commands, function(ok)
        if closing_pane == pane then closing_pane = nil end
        if ok then focus_on_render = true end
        refresh()
      end)
    end
  end

  local process = {
    stop = function(buf)
      local close = prepare_quit(pty.for_buffer(buf))
      if not close then return false end
      close()
      return true
    end,
  }

  local function prepare_buffer(pane)
    local buf = api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "hide"
    vim.b[buf].luanphan_persist_term = true
    vim.b[buf].luanphan_floating_terminal = true
    vim.b[buf].luanphan_tmux_pane = pane.id
    pane.bufnr, pane.repaint, pane.process = buf, repaint, process
    terminal_pane.set_reference_cwd(buf, pane.cwd)
    tiles:bind_terminal(buf)
    bind_shortcuts(buf)
    terminal_pane.bind_quit(buf, events, function() return prepare_quit(pane) end)
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

  local function prepare_pane(item)
    local pane, win = item.tab, item.win
    if pane.view_win ~= win then
      terminal_pane.configure_window(win, "NormalFloat:Normal,WinBar:Normal,WinBarNC:Comment,TabLineFill:Normal")
    end
    if not pane.term then
      pane.client = client
      pane.restore_primary = true
      pty.open(pane)
      terminal_pane.configure_buffer(pane.bufnr)
    end
  end

  tiles = views.create({
    context = function() return current end,
    tabs = function(group) return group.items end,
    insert_after_active = true,
    relayout = function() render() end,
    navigate = navigate,
    bar = function() return bar end,
    prepare_pane = prepare_pane,
    editor = {
      key = function(group) return "tmux:" .. session.id .. ":" .. group.id end,
      active = function(group) return group.active.bufnr end,
    },
    reorder = reorder_panes,
    activate = activate,
    new = new_tab,
    create_key = false,
    cycle_desc = "Next tmux pane",
  })

  bar = bars.create({
    title = function() return session and ("Tmux · " .. session.title) or "Tmux Windows" end,
    cycle_session = cycle_session,
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
    bind = function(buf)
      editor.bind(buf)
      bind_shortcuts(buf)
    end,
  })

  local function render_panel()
    if not current or not current.active then return end
    local layout = geometry()
    local focus = should_focus(focus_on_render)
    local selected = current.active
    for _, pane in ipairs(current.items) do
      if not pane.bufnr or not api.nvim_buf_is_valid(pane.bufnr) then
        pane.term, pane.frame, pane.painted = nil, nil, nil
        prepare_buffer(pane)
      end
    end
    local anchor = tiles:anchor() or tiles:open_float(layout, selected.bufnr, false)
    tiles.active_by_context = {}
    if tiles:reflow(anchor, current, layout, selected, { focus = focus, record = not selection }) then
      if focus then focus_on_render = false end
      if focus_sidebar and bar:visible() then
        focus_sidebar = nil
        bar:focus()
      end
    end
  end

  render = function()
    if rendering then return end
    rendering = true
    local ok, err = pcall(render_panel)
    rendering = false
    if not ok then
      panel.hide()
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
      if pane.bufnr and pane.cwd ~= old_cwd then
        terminal_pane.set_reference_cwd(pane.bufnr, pane.cwd)
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
    bar:invalidate()
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
    elseif tiles:anchor() then
      panel.hide()
    end
    for id, pane in pairs(old) do
      if not listed[id] then
        pane.client = nil
        if pane.bufnr and api.nvim_buf_is_valid(pane.bufnr) then api.nvim_buf_delete(pane.bufnr, { force = true }) end
      end
    end
  end

  refresh = function()
    if not client or refresh_queued or creating or closing_pane then return end
    if refresh_pending then refresh_again = true return end
    local connection = client
    refresh_queued = true
    vim.schedule(function()
      if client ~= connection then return end
      if creating or closing_pane then refresh_queued = false return end
      refresh_queued, refresh_pending = false, true
      local completed_selection = selection and selection.done and selection
      client:request({ "list-panes", "-s", "-t", session.id, "-F", model.format }, function(ok, lines)
        if client ~= connection then return end
        refresh_pending = false
        if ok and not creating and not closing_pane then
          local records = model.read(lines)
          local commands = model.migrate(records)
          if #commands > 0 then
            refresh_pending = true
            batch(commands, function(migrated)
              if client ~= connection then return end
              refresh_pending, refresh_again = false, false
              if migrated then refresh() else panel.hide() end
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

  function panel.hide(closing)
    if not client and not tiles.layout_anchor then return false end
    bar:reset_order()
    local connection, old = client, panes
    client, session, current = nil, nil, nil
    windows, panes = {}, {}
    refresh_queued, refresh_pending, refresh_again = nil, nil, nil
    creating, focus_on_render, selection, closing_pane = nil, nil, nil, nil
    focus_sidebar = nil
    if connection then connection:detach() end
    tiles:hide(closing)
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
    views.show_panel(panel)
    session = target
    client = tmux:attach(target, {
      flags = "ignore-size,pause-after=5",
      ready = function()
        previous_session = target.id
        refresh()
      end,
      output = function(id, bytes)
        pty.receive(panes[id], bytes)
      end,
      event = function(event, payload)
        if event == "session-window-changed" and current then
          local window = payload:match("^%$%d+ (@%d+)")
          if (selection and selection.visible and window == selection.window)
            or (not selection and current.active and window == current.active.window) then return end
        end
        if topology_events[event] then
          refresh()
        elseif event == "pause" then
          local pane = panes[payload]
          if pane then pane.ready = false end
          client:request({ "refresh-client", "-A", payload .. ":continue" }, function(ok)
            if ok and pane then pty.paint(pane, can_paint) end
          end)
        end
      end,
      exit = function(code, message)
        panel.hide()
        if code ~= 0 then vim.notify(message or "tmux client disconnected", vim.log.levels.WARN) end
      end,
    })
  end

  function panel.open()
    local body = geometry().body
    local target = tmux:ensure_session(previous_session, body.width, body.height - 1)
    if target then open(target) end
  end

  tiles:watch(events, {
    hide = panel.hide,
    hide_on_terminal = true,
    suspended = function() return rendering or closing_pane end,
    closing = function() return closing_pane end,
    enter = function(win)
      if rendering or closing_pane then return end
      local pane = panes[vim.b.luanphan_tmux_pane]
      if pane and vim.fn.bufwinid(pane.bufnr) == win and current and current.active ~= pane then activate(pane, true) end
    end,
    companion = function(win)
      return not (valid(win) and vim.w[win].luanphan_view_independent_tile)
        and vim.tbl_contains(tiles.tile_windows or {}, win)
    end,
  })
  api.nvim_create_autocmd("DirChangedPre", { group = events, callback = function() panel.hide() end })
  api.nvim_create_autocmd("User", {
    group = events, pattern = "LuanphanWorktreeSwitchPre", callback = function() panel.hide() end,
  })
  api.nvim_create_autocmd("VimLeavePre", { group = events, callback = function() if client then client:detach() end end })

  return panel
end

return M
