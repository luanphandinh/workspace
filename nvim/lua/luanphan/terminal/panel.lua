local M = {}
local api = vim.api
local views = require("luanphan.view_container")
local editor = require("luanphan.view_container.editor")
local bars = require("luanphan.view_container.window_bar")
local terminal_pane = require("luanphan.view_container.terminal")
local window = require("luanphan.terminal.window")
local settings = require("luanphan.global_settings")

function M.create(opts)
  local panel = {}
  local scopes = {}
  local anchor, dock, current
  local bar, inner, create_bar
  local quitting
  local rendering = false
  local events = api.nvim_create_augroup(opts.augroup, { clear = true })

  local function is_open()
    return anchor and api.nvim_win_is_valid(anchor)
  end

  local function scope_key()
    if not opts.docked then return "" end
    local cwd = vim.fn.getcwd()
    return vim.uv.fs_realpath(cwd) or cwd
  end

  local function scope()
    if is_open() and views.group_anchor(api.nvim_get_current_win()) == anchor then return current.scope end
    local key = scope_key()
    if not scopes[key] then
      local owner = { windows = {}, next_id = 0, cwd = opts.docked and key or nil }
      owner.bar = create_bar(owner)
      scopes[key] = owner
    end
    return scopes[key]
  end

  local function active_window()
    local win = current and vim.fn.bufwinid(current.bufnr)
    return win and win ~= -1 and win or anchor
  end

  local function focus_content()
    local win = active_window()
    if win then api.nvim_set_current_win(win) end
  end

  local function move_from_dock(direction)
    if not dock or not api.nvim_win_is_valid(dock) then return end
    local target = api.nvim_win_call(dock, function() return vim.fn.win_getid(vim.fn.winnr(direction)) end)
    if target ~= dock and api.nvim_win_is_valid(target) then
      vim.cmd.stopinsert()
      api.nvim_set_current_win(target)
    end
  end

  local function navigate(win, direction)
    if views.focus_neighbor(win, direction, api.nvim_set_current_win) then return end
    if inner:navigate_tabs(direction, #current.panes) then return end
    if not bar:focus_towards(direction, true) and opts.docked then move_from_dock(direction) end
  end

  function panel.hide()
    if not is_open() then return false end
    quitting = nil
    current.scope.open = false
    return views.close_group(anchor)
  end

  local function geometry()
    return views.layout(settings.read()[opts.settings], { docked = opts.docked, win = dock, border = "none" })
  end

  local function create_dock()
    local buf = api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    dock = api.nvim_open_win(buf, false, { split = "right", win = -1 })
    vim.wo[dock].winfixbuf = true
    vim.wo[dock].winfixwidth = true
    vim.wo[dock].winbar = ""
    api.nvim_win_set_width(dock, math.min(100, math.floor(vim.o.columns * 0.6)))
  end

  local function prepare_pane(pane)
    local tab, win = pane.tab, pane.win
    bar:attach(tab.bufnr)
    vim.wo[win].winhighlight = "NormalFloat:Normal,EndOfBuffer:,WinBar:Normal,WinBarNC:Normal,TabLineFill:Normal"
    if tab.term then tab.term.window = win end
  end

  local function render_body(group, enter)
    if opts.docked and (not dock or not api.nvim_win_is_valid(dock)) then create_dock() end
    local layout = geometry()
    local desired = group.bufnr
    local original_win = api.nvim_get_current_win()
    local had_focus = is_open() and views.group_anchor(original_win) == anchor
    if not is_open() then
      anchor = views.open_float(layout, desired, false)
      if dock then vim.w[dock].luanphan_view_companion_anchor = anchor end
    end
    current = group
    local active = vim.iter(group.panes):find(function(pane) return pane.bufnr == desired end)
    inner:reflow(anchor, group, layout, active)
    if enter or (had_focus and views.group_anchor(api.nvim_get_current_win()) ~= anchor) then focus_content() end
    if enter then bar.history.record(desired) end
    bar:refresh()
  end

  local function render(group, enter)
    if rendering then return end
    if is_open() and current.scope ~= group.scope then panel.hide() end
    rendering = true
    bar = group.scope.bar
    local ok, err = pcall(render_body, group, enter)
    rendering = false
    if not ok then
      panel.hide()
      error(err)
    end
    group.scope.open = true
  end

  local function activate(pane)
    pane.group.scope.active = pane.group
    pane.group.bufnr = pane.bufnr
    render(pane.group, true)
    return api.nvim_get_current_buf() == pane.bufnr
  end

  local function remove_pane(group, pane, defer)
    local index = vim.iter(group.panes):enumerate():find(function(_, item) return item == pane end)
    if not index then return end
    local requested = quitting == pane
    if requested then quitting = nil end
    local replace_focus = requested or api.nvim_get_current_buf() == pane.bufnr
    local replacement = requested and views.replacement_tab(group.panes, pane.bufnr)
    table.remove(group.panes, index)
    local next_pane = replacement or group.panes[math.min(index, #group.panes)]
    if group.bufnr == pane.bufnr and next_pane then group.bufnr = next_pane.bufnr end
    local owner = group.scope
    if not next_pane then
      local position = vim.iter(owner.windows):enumerate():find(function(_, item) return item == group end)
      table.remove(owner.windows, position)
      if #owner.windows == 0 then owner.next_id = 0 end
      if owner.active == group then owner.active = owner.windows[math.min(position, #owner.windows)] end
    end
    local function reflow()
      if current == group and (is_open() or requested) then
        if owner.active then
          render(owner.active, replace_focus)
        elseif not panel.hide() then
          owner.open = false
        end
      end
      owner.bar:refresh(true)
    end
    if defer then vim.schedule(reflow) else reflow() end
  end

  local function new_pane(group, command)
    if not views.has_room(geometry(), #group.panes + 1) then
      vim.notify("No room for another terminal tile", vim.log.levels.WARN)
      return
    end
    local result = opts.spawn(group.cwd, command)
    if not result then return end
    local buf = result.bufnr
    terminal_pane.track_view(buf, events)
    local pane = { bufnr = buf, id = "shell:" .. buf, label = result.label or "shell", group = group, term = result.term }
    group.panes[#group.panes + 1] = pane
    group.bufnr = buf
    api.nvim_create_autocmd("BufWipeout", {
      buffer = buf, once = true,
      callback = function() remove_pane(group, pane, true) end,
    })
    if opts.close_on_exit then
      terminal_pane.bind_quit(buf, events, function()
        if quitting == pane then return function() end end
        if not window.running(buf) then return end
        quitting = pane
        return function()
          if not window.stop(buf) and quitting == pane then quitting = nil end
        end
      end)
      api.nvim_create_autocmd("TermClose", {
        buffer = buf, once = true,
        callback = function()
          vim.schedule(function()
            remove_pane(group, pane)
            if api.nvim_buf_is_valid(buf) then api.nvim_buf_delete(buf, { force = true }) end
          end)
        end,
      })
    end

    inner:bind_tile_moves(buf, group)
    local bar = group.scope.bar
    bar:map_jumps(buf, false)
    local keys = { buffer = buf, silent = true, nowait = true }
    for _, key in ipairs({ "<leader>nt", "<leader>fn", "<leader>nw" }) do
      vim.keymap.set("n", key, function()
        if key == "<leader>nw" then panel.new_window() else panel.new_tab() end
      end, vim.tbl_extend("force", keys, { desc = key == "<leader>nw" and "New terminal window" or "New terminal tab" }))
    end
    if opts.docked then
      for _, binding in ipairs({ { "<Tab>", 1 }, { "<S-Tab>", -1 } }) do
        vim.keymap.set("n", binding[1], function()
          if #group.scope.windows > 1 then bar:cycle(binding[2]) else inner:cycle(group, binding[2]) end
        end, keys)
      end
    else
      inner:bind(buf, group)
      editor.bind(buf)
    end
    local left = opts.docked and function() move_from_dock("h") end or "<C-h>"
    vim.keymap.set("t", "<C-h>", left, keys)
    for _, direction in ipairs({ "h", "j", "k", "l" }) do
      vim.keymap.set("n", "<C-" .. direction .. ">", function()
        navigate(api.nvim_get_current_win(), direction)
      end, keys)
    end
    return result
  end

  local function open_pane(group, command)
    if not is_open() then opts.on_open() end
    local result = new_pane(group, command)
    if not result then return end
    group.scope.active = group
    render(group, true)
    return result
  end

  function panel.new_window(command)
    local owner = scope()
    owner.next_id = owner.next_id + 1
    local number = owner.next_id
    local group = { id = "window:" .. number, title = "Window " .. number,
      cwd = owner.cwd or vim.fn.getcwd(), panes = {}, scope = owner }
    owner.windows[#owner.windows + 1] = group
    local result = open_pane(group, command)
    if not result then table.remove(owner.windows) end
    return result
  end

  function panel.new_tab(command)
    local group = scope().active
    if not group then return panel.new_window(command) end
    return open_pane(group, command)
  end

  function panel.toggle()
    if panel.hide() then return end
    local group = scope().active
    if not group then return panel.new_window() end
    opts.on_open()
    render(group, true)
  end

  inner = views.create({
    context = function() return current end,
    prepare_pane = prepare_pane,
    layout_bar = function(win, layout) bar:layout(win, layout) end,
    editor = not opts.docked and {
      key = function(group) return group end,
      active = function(group) return group.bufnr end,
      refresh = function() render(current, false) end,
      navigate = navigate,
    } or nil,
    tabs = function(group)
      local items = {}
      for index, pane in ipairs(group.panes) do
        items[index] = vim.tbl_extend("force", pane, {
          label = opts.docked and #group.panes > 1 and (pane.label .. " " .. index) or pane.label,
        })
      end
      return items
    end,
    reorder = function(panes, group)
      local originals = {}
      for _, pane in ipairs(group.panes) do originals[pane.id] = pane end
      group.panes = vim.tbl_map(function(pane) return originals[pane.id] end, panes)
      render(group, false)
    end,
    activate = activate,
    new = panel.new_tab,
    create_key = false,
    cycle_desc = "Next terminal pane",
  })

  function create_bar(owner)
    return bars.create({
      title = "Windows",
      groups = function()
        local groups = {}
        for _, group in ipairs(owner.windows) do
          local items = inner.opts.tabs(group)
          local active
          for _, pane in ipairs(items) do
            pane.label = views.tab_label(pane.bufnr, pane.label)
            if pane.bufnr == group.bufnr then active = pane end
          end
          groups[#groups + 1] = { id = group.id, title = group.title, items = items, active = active, source = group }
        end
        return groups
      end,
      active_window = active_window,
      activate = activate,
      rename_window = function(group, name)
        group.source.title = name
        owner.bar:refresh(true)
      end,
      reorder = function(group, items) inner.opts.reorder(items, group.source) end,
      bind = function(buf)
        if not opts.docked then editor.bind(buf) end
        vim.keymap.set("n", "<leader>nw", panel.new_window, { buffer = buf, desc = "New terminal window" })
        vim.keymap.set("n", "<leader>nt", panel.new_tab, { buffer = buf, desc = "New terminal tab" })
      end,
    })
  end

  api.nvim_create_autocmd("WinEnter", {
    group = events,
    callback = function()
      if rendering or quitting or not is_open() then return end
      local win = api.nvim_get_current_win()
      if views.group_anchor(win) == anchor then
        local buf = api.nvim_win_get_buf(win)
        if vim.bo[buf].buftype == "terminal" then
          current.bufnr = buf
          bar.history.record(buf)
          bar:refresh()
        elseif win == dock then
          vim.schedule(function() if is_open() and api.nvim_get_current_win() == dock then focus_content() end end)
        end
      elseif not opts.docked and (api.nvim_win_get_config(win).relative == "" or vim.bo.buftype == "terminal") then
        local previous = anchor
        vim.schedule(function()
          if not quitting and previous == anchor and is_open()
            and views.group_anchor(api.nvim_get_current_win()) ~= anchor then panel.hide() end
        end)
      end
    end,
  })
  api.nvim_create_autocmd("WinClosed", {
    group = events,
    callback = function(args)
      if quitting then return end
      local win = tonumber(args.match)
      if win ~= anchor and win ~= (bar and bar.win) and win ~= dock then return end
      local closing = anchor
      if current then current.scope.open = false end
      anchor, dock = nil, nil
      if bar then bar.win, bar.anchor = nil, nil end
      if closing then views.close_group(closing, win) end
    end,
  })
  api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    group = events,
    callback = function()
      if not is_open() or rendering then return end
      if vim.v.event.windows and (not dock or not vim.tbl_contains(vim.v.event.windows, dock)) then return end
      render(current, false)
    end,
  })
  api.nvim_create_autocmd("TermRequest", {
    group = events,
    callback = function(ev)
      if not bar or not bar:visible() or bar.style ~= "vertical" or not ev.data then return end
      if ev.data.sequence and ev.data.sequence:match("^\27%][02];") then
        local visible_bar = bar
        vim.schedule(function()
          if visible_bar:visible() and api.nvim_buf_is_valid(ev.buf) then
            visible_bar:update_title(ev.buf, views.tab_label(ev.buf))
          end
        end)
      end
    end,
  })
  local function hide_on_change()
    local owner = current and current.scope
    if panel.hide() and opts.docked then owner.open = true end
  end
  api.nvim_create_autocmd("DirChangedPre", { group = events, callback = hide_on_change })
  api.nvim_create_autocmd("User", {
    group = events, pattern = "LuanphanWorktreeSwitchPre", callback = hide_on_change,
  })
  if opts.docked then
    api.nvim_create_autocmd("DirChanged", {
      group = events,
      callback = function()
        local owner = scopes[scope_key()]
        if not owner or not owner.open then return end
        vim.schedule(function()
          if not is_open() and owner.open and owner.active and scope_key() == owner.cwd then
            render(owner.active, false)
          end
        end)
      end,
    })
  end
  api.nvim_create_autocmd("BufWritePost", {
    group = events,
    callback = function(ev)
      if is_open() and vim.uv.fs_realpath(ev.file) == vim.uv.fs_realpath(settings.config_path()) then
        render(current, false)
      end
    end,
  })
  return panel
end

return M
