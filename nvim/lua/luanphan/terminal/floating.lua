local M = {}
local api = vim.api
local views = require("luanphan.view_container")
local window = require("luanphan.terminal.window")

local windows = {}
local header_height = 2
local next_window = 0
local current_window, anchor, header
local outer, inner

local function is_open()
  return anchor and api.nvim_win_is_valid(anchor)
end

local function geometry()
  return {
    relative = "editor",
    row = header_height,
    col = 0,
    width = vim.o.columns,
    height = math.max(2, vim.o.lines - vim.o.cmdheight - header_height),
    border = "none",
    zindex = 40,
  }
end

local function save_views()
  for _, win in ipairs(views.group_windows(anchor)) do
    local buf = api.nvim_win_get_buf(win)
    if vim.b[buf].luanphan_floating_terminal then window.save_view(win, buf) end
  end
end

function M.hide()
  if not is_open() then return false end
  save_views()
  return views.close_group(anchor)
end

local function focus(buf)
  local win = vim.fn.bufwinid(buf)
  if win ~= -1 then api.nvim_set_current_win(win) end
end

local function render(group, enter)
  local frame = geometry()
  local header_config = vim.tbl_extend("force", frame, {
    row = frame.row - header_height, height = header_height, focusable = false, style = "minimal",
  })
  local previous = api.nvim_get_current_win()
  local had_focus = is_open() and views.group_anchor(previous) == anchor
  local desired = group.bufnr
  local anchor_buf = is_open() and api.nvim_win_get_buf(anchor)
  local replace_anchor = not vim.iter(group.panes):any(function(pane) return pane.bufnr == anchor_buf end)
  if not is_open() then
    anchor = api.nvim_open_win(group.panes[1].bufnr, false, vim.tbl_extend("force", frame, { style = "minimal" }))
    local buf = api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    header = api.nvim_open_win(buf, false, header_config)
    vim.w[header].luanphan_view_companion_anchor = anchor
    vim.wo[header].winhighlight = "NormalFloat:Normal,WinBar:Normal,WinBarNC:Normal"
  else
    if current_window ~= group then save_views() end
    api.nvim_win_set_config(header, header_config)
    if replace_anchor then api.nvim_win_set_buf(anchor, group.panes[1].bufnr) end
  end
  current_window = group
  local panes = inner:display(anchor, group, frame, "tile")
  if not panes then
    api.nvim_win_set_buf(anchor, desired)
    inner:render(anchor, group, inner:active(group))
    panes = { { win = anchor, opened = true, tab = { bufnr = desired } } }
  end
  for _, pane in ipairs(panes) do
    vim.wo[pane.win].winhighlight = "NormalFloat:Normal,EndOfBuffer:,WinBar:Normal,WinBarNC:Normal,TabLineFill:Normal"
    if pane.opened or (pane.win == anchor and replace_anchor) then window.restore_view(pane.win, pane.tab.bufnr) end
    window.sync_grid(pane.win, pane.tab.bufnr)
  end
  outer:attach(header, desired, group.id)
  if enter or (had_focus and views.group_anchor(api.nvim_get_current_win()) ~= anchor) then
    focus(desired)
  end
  inner:refresh_tile_highlights()
end

local function remove_pane(group, buf)
  local index = vim.iter(group.panes):enumerate():find(function(_, pane) return pane.bufnr == buf end)
  if not index then return end
  local replace_focus = api.nvim_get_current_buf() == buf
  table.remove(group.panes, index)
  local next_pane = group.panes[math.min(index, #group.panes)]
  if group.bufnr == buf and next_pane then group.bufnr = next_pane.bufnr end
  if not next_pane then
    local position = assert(vim.iter(windows):enumerate():find(function(_, item) return item == group end))
    table.remove(windows, position)
    if current_window == group then
      current_window = windows[math.min(position, #windows)]
      if is_open() and not current_window then M.hide() end
    end
  end
  if is_open() and current_window then render(current_window, replace_focus) end
  if api.nvim_buf_is_valid(buf) then api.nvim_buf_delete(buf, { force = true }) end
end

local function new_pane(group)
  if not views.can_tile(geometry(), #group.panes + 1) then
    vim.notify("The floating terminal has no room for another pane", vim.log.levels.WARN)
    return false
  end
  local buf = api.nvim_create_buf(false, true)
  vim.b[buf].luanphan_persist_term = true
  vim.b[buf].luanphan_floating_terminal = true
  local started, job = pcall(api.nvim_buf_call, buf, function()
    return vim.fn.jobstart({ vim.o.shell, "-i" }, {
      term = true,
      cwd = group.cwd,
      on_exit = function()
        vim.schedule(function() remove_pane(group, buf) end)
      end,
    })
  end)
  if not started or job <= 0 then
    api.nvim_buf_delete(buf, { force = true })
    vim.notify("Could not start the floating terminal shell", vim.log.levels.ERROR)
    return false
  end
  require("luanphan.terminal_references").attach(buf, group.cwd)
  table.insert(group.panes, { bufnr = buf, label = "shell", id = "shell:" .. buf })
  group.bufnr = buf
  outer:bind(buf)
  inner:bind_tile_moves(buf, group)
  local opts = { buffer = buf, silent = true }
  for _, key in ipairs({ "<leader>nt", "<leader>fn" }) do
    vim.keymap.set("n", key, function() inner:create(group) end,
      vim.tbl_extend("force", opts, { desc = "New terminal tab" }))
  end
  vim.keymap.set("t", "<C-h>", "<C-h>", opts)
  for _, direction in ipairs({ "h", "j", "k", "l" }) do
    vim.keymap.set("n", "<C-" .. direction .. ">", function()
      local neighbor = views.tile_neighbor(api.nvim_get_current_win(), direction)
      if neighbor then api.nvim_set_current_win(neighbor) end
    end, opts)
  end
  return true
end

local function new_window()
  next_window = next_window + 1
  local group = { id = "window:" .. next_window, title = "Window " .. next_window, cwd = vim.fn.getcwd(), panes = {} }
  if not new_pane(group) then return end
  windows[#windows + 1] = group
  render(group, true)
end

function M.toggle()
  if M.hide() then return end
  require("luanphan.agents.main").hide()
  if current_window then render(current_window, true) else new_window() end
end

outer = views.create({
  context = function() return "floating terminal" end,
  tabs = function() return windows end,
  new = new_window,
  activate = function(group) render(group, true) end,
  create_key = "<leader>nw",
  new_desc = "New terminal window",
  cycle_desc = "Next terminal window",
})

inner = views.create({
  context = function() return current_window end,
  tabs = function(group) return group.panes end,
  reorder = function(panes, group)
    group.panes = panes
    render(group, false)
  end,
  activate = function(pane) focus(pane.bufnr) end,
  new = function(group)
    if new_pane(group) then render(group, true) end
  end,
})

local group = api.nvim_create_augroup("LuanphanFloatingTerminal", { clear = true })
api.nvim_create_autocmd("WinLeave", {
  group = group,
  callback = function(ev)
    if vim.b[ev.buf].luanphan_floating_terminal then window.save_view(api.nvim_get_current_win(), ev.buf) end
  end,
})
api.nvim_create_autocmd("WinEnter", {
  group = group,
  callback = function()
    if not is_open() then return end
    local win = api.nvim_get_current_win()
    if views.group_anchor(win) == anchor then
      current_window.bufnr = api.nvim_win_get_buf(win)
      outer:attach(header, current_window.bufnr, current_window.id)
    elseif api.nvim_win_get_config(win).relative == "" or vim.bo.buftype == "terminal" then
      local previous = anchor
      vim.schedule(function()
        if previous == anchor and is_open() and views.group_anchor(api.nvim_get_current_win()) ~= anchor then M.hide() end
      end)
    end
  end,
})
api.nvim_create_autocmd("WinClosed", {
  group = group,
  callback = function(args)
    if tonumber(args.match) == header and is_open() then views.close_group(anchor, header) end
  end,
})
api.nvim_create_autocmd("VimResized", { group = group, callback = function() if is_open() then render(current_window, false) end end })
local function hide_panel() M.hide() end
api.nvim_create_autocmd("DirChangedPre", { group = group, callback = hide_panel })
api.nvim_create_autocmd("User", { group = group, pattern = "LuanphanWorktreeSwitchPre", callback = hide_panel })

return M
