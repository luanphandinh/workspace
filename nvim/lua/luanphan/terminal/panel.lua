local M = {}
local api = vim.api
local views = require("luanphan.view_container")
local bars = require("luanphan.view_container.window_bar")
local window = require("luanphan.terminal.window")
local settings = require("luanphan.global_settings")

function M.create(opts)
  local panel = {}
  local scopes = {}
  local anchor, dock, current, layout
  local bar, inner
  local rendering = false

  local function scope()
    local key = opts.docked and vim.fn.getcwd() or ""
    if not scopes[key] then scopes[key] = { windows = {}, next_id = 0 } end
    return scopes[key]
  end

  local function is_open()
    return anchor and api.nvim_win_is_valid(anchor)
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

  local function save_views()
    if not is_open() then return end
    for _, win in ipairs(views.group_windows(anchor)) do
      local buf = api.nvim_win_get_buf(win)
      if vim.bo[buf].buftype == "terminal" then window.save_view(win, buf) end
    end
  end

  function panel.hide()
    if not is_open() then return false end
    save_views()
    return views.close_group(anchor)
  end

  local function geometry()
    layout = settings.read()[opts.settings]
    local frame = {
      relative = "editor", row = 0, col = 0, width = vim.o.columns,
      height = math.max(4, vim.o.lines - vim.o.cmdheight), border = "none", zindex = 40,
    }
    if dock and api.nvim_win_is_valid(dock) then
      local pos = api.nvim_win_get_position(dock)
      frame.row, frame.col = unpack(pos)
      frame.width, frame.height = api.nvim_win_get_width(dock), api.nvim_win_get_height(dock)
    end
    return bars.divide(frame, layout.window_bar_style, math.min(42, math.max(3, math.floor(frame.width * 0.3))))
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

  local function render_body(group, enter)
    if opts.docked and (not dock or not api.nvim_win_is_valid(dock)) then create_dock() end
    local frame, bar_frame = geometry()
    local desired = group.bufnr
    local original_win = api.nvim_get_current_win()
    local had_focus = is_open() and views.group_anchor(original_win) == anchor
    local previous = is_open() and api.nvim_win_get_buf(anchor)
    if not is_open() then
      anchor = api.nvim_open_win(desired, false, vim.tbl_extend("force", frame, { style = "minimal" }))
      if dock then vim.w[dock].luanphan_view_companion_anchor = anchor end
    end
    current = group
    local panes = inner:display(anchor, group, frame, layout.display_style)
    if not panes then
      api.nvim_win_set_buf(anchor, desired)
      inner.active_by_context[group] = { id = "shell:" .. desired, bufnr = desired }
      inner:render(anchor, group)
      panes = { { win = anchor, opened = desired ~= previous, tab = { bufnr = desired } } }
    end
    for _, pane in ipairs(panes) do
      bar:attach(pane.tab.bufnr)
      vim.wo[pane.win].winhighlight =
        "NormalFloat:Normal,EndOfBuffer:,WinBar:Normal,WinBarNC:Normal,TabLineFill:Normal"
      if pane.opened or (pane.win == anchor and previous ~= pane.tab.bufnr) then
        window.restore_view(pane.win, pane.tab.bufnr)
      end
      if pane.tab.term then pane.tab.term.window = pane.win end
      window.sync_grid(pane.win, pane.tab.bufnr)
    end
    bar:layout(anchor, bar_frame, layout.window_bar_style)
    if enter or (had_focus and views.group_anchor(api.nvim_get_current_win()) ~= anchor) then focus_content() end
    if enter then bar.history.record(desired) end
    inner:refresh_tile_highlights()
    bar:refresh()
  end

  local function render(group, enter)
    if rendering then return end
    rendering = true
    save_views()
    local ok, err = pcall(render_body, group, enter)
    rendering = false
    if not ok then
      panel.hide()
      error(err)
    end
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
    local replace_focus = api.nvim_get_current_buf() == pane.bufnr
    table.remove(group.panes, index)
    local next_pane = group.panes[math.min(index, #group.panes)]
    if group.bufnr == pane.bufnr and next_pane then group.bufnr = next_pane.bufnr end
    local owner = group.scope
    if not next_pane then
      local position = vim.iter(owner.windows):enumerate():find(function(_, item) return item == group end)
      table.remove(owner.windows, position)
      if #owner.windows == 0 then owner.next_id = 0 end
      if owner.active == group then owner.active = owner.windows[math.min(position, #owner.windows)] end
    end
    local function reflow()
      if current == group and is_open() then
        if owner.active then render(owner.active, replace_focus) else panel.hide() end
      end
      bar:refresh(true)
    end
    if defer then vim.schedule(reflow) else reflow() end
  end

  local function new_pane(group, command)
    local frame = geometry()
    if layout.display_style == "tile" and not views.can_tile(frame, #group.panes + 1) then
      vim.notify("No room for another terminal tile", vim.log.levels.WARN)
      return
    end
    local result = opts.spawn(group.cwd, command)
    if not result then return end
    local buf = result.bufnr
    local pane = { bufnr = buf, id = "shell:" .. buf, label = result.label or "shell", group = group, term = result.term }
    group.panes[#group.panes + 1] = pane
    group.bufnr = buf
    api.nvim_create_autocmd("BufWipeout", {
      buffer = buf, once = true,
      callback = function() remove_pane(group, pane, true) end,
    })
    if opts.close_on_exit then
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
    bar:map_jumps(buf, false)
    local keys = { buffer = buf, silent = true, nowait = true }
    for _, key in ipairs({ "<leader>nt", "<leader>fn", "<leader>nw" }) do
      vim.keymap.set("n", key, function()
        if key == "<leader>nw" then panel.new_window() else panel.new_tab() end
      end, vim.tbl_extend("force", keys, { desc = key == "<leader>nw" and "New terminal window" or "New terminal tab" }))
    end
    for _, binding in ipairs({ { "<Tab>", 1 }, { "<S-Tab>", -1 } }) do
      vim.keymap.set("n", binding[1], function()
        if #group.scope.windows > 1 then bar:cycle(binding[2]) else inner:cycle(group, binding[2]) end
      end, keys)
    end
    local left = opts.docked and function() move_from_dock("h") end or "<C-h>"
    vim.keymap.set("t", "<C-h>", left, keys)
    for _, direction in ipairs({ "h", "j", "k", "l" }) do
      vim.keymap.set("n", "<C-" .. direction .. ">", function()
        local neighbor = views.tile_neighbor(api.nvim_get_current_win(), direction)
        if neighbor then
          api.nvim_set_current_win(neighbor)
        elseif layout.window_bar_style == "vertical" and direction == "h" and layout.display_style == "tile" then
          bar:focus()
        elseif layout.display_style == "tabs" and (direction == "h" or direction == "l") and #group.panes > 1 then
          inner:cycle(group, direction == "h" and -1 or 1)
        elseif layout.window_bar_style == "vertical" and direction == "h" then
          bar:focus()
        elseif opts.docked then
          move_from_dock(direction)
        end
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
    local group = { id = "window:" .. number, title = "Window " .. number, cwd = vim.fn.getcwd(), panes = {}, scope = owner }
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
  })

  bar = bars.create({
    title = "Windows",
    groups = function()
      local groups = {}
      for _, group in ipairs(scope().windows) do
        local items = inner:tabs(group)
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
    reorder = function(group, items) inner.opts.reorder(items, group.source) end,
    bind = function(buf)
      vim.keymap.set("n", "<leader>nw", panel.new_window, { buffer = buf, desc = "New terminal window" })
      vim.keymap.set("n", "<leader>nt", panel.new_tab, { buffer = buf, desc = "New terminal tab" })
    end,
  })

  local events = api.nvim_create_augroup(opts.augroup, { clear = true })
  api.nvim_create_autocmd("WinLeave", {
    group = events,
    callback = function(ev)
      if is_open() and views.group_anchor(api.nvim_get_current_win()) == anchor then
        window.save_view(api.nvim_get_current_win(), ev.buf)
      end
    end,
  })
  api.nvim_create_autocmd("WinEnter", {
    group = events,
    callback = function()
      if rendering or not is_open() then return end
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
          if previous == anchor and is_open() and views.group_anchor(api.nvim_get_current_win()) ~= anchor then panel.hide() end
        end)
      end
    end,
  })
  api.nvim_create_autocmd("WinClosed", {
    group = events,
    callback = function(args)
      local win = tonumber(args.match)
      if win ~= anchor and win ~= bar.win and win ~= dock then return end
      local closing = anchor
      anchor, dock = nil, nil
      bar.win, bar.anchor = nil, nil
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
      if not bar:visible() or bar.style ~= "vertical" or not ev.data then return end
      if ev.data.sequence and ev.data.sequence:match("^\27%][02];") then
        vim.schedule(function()
          if api.nvim_buf_is_valid(ev.buf) then bar:update_title(ev.buf, views.tab_label(ev.buf)) end
        end)
      end
    end,
  })
  api.nvim_create_autocmd("DirChangedPre", { group = events, callback = function() panel.hide() end })
  api.nvim_create_autocmd("User", {
    group = events, pattern = "LuanphanWorktreeSwitchPre", callback = function() panel.hide() end,
  })
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
