local M = {}
local Bar = {}
Bar.__index = Bar

local api = vim.api
local windows = require("luanphan.view_container.window")
local sidebar = require("luanphan.view_container.sidebar")
local tabs = require("luanphan.view_container.tab_render")
local jump_lists = require("luanphan.view_container.jumplist")
local bars = vim.luanphan_window_bars or setmetatable({}, { __mode = "k" })
vim.luanphan_window_bars = bars
local order_save_delay = 300

local function valid(win)
  return win and api.nvim_win_is_valid(win)
end

function M.divide(frame, style, vertical_width)
  local border = frame.border == "none" and 0 or 2
  local body = vim.tbl_extend("force", {}, frame)
  local bar = vim.tbl_extend("force", {}, frame, { border = "none" })
  if style == "horizontal" then
    if frame.height < 3 then return body end
    bar.width, bar.height = body.width + border, 1
    body.row, body.height = body.row + bar.height, body.height - bar.height
  else
    if frame.width < 4 or frame.height < 4 then return body end
    bar.border = "single"
    bar.width = math.max(1, vertical_width - 2)
    bar.height = math.max(2, body.height + border - 2)
    body.col, body.width = body.col + bar.width + 2, body.width - bar.width - 2
  end
  return body, bar
end

function M.float_geometry(frame, layout)
  local border = frame.border == "none" and 0 or 2
  local available = frame.width + border
  local total = math.max(3, math.floor(available * layout.total_width_percent / 100))
  local centered = vim.tbl_extend("force", {}, frame, {
    col = frame.col + math.floor((available - total) / 2),
    width = total - border,
  })
  if layout.window_bar_style == "horizontal" then return M.divide(centered, "horizontal") end
  if layout.window_bar_style ~= "vertical" or total < 6 then return centered end

  local terminal = math.min(total - 3, math.max(3, math.floor(total * layout.terminal_width_percent / 100)))
  local remaining = total - terminal
  local sidebar = remaining
  if layout.terminal_width_percent + layout.sidebar_width_percent < 100 - 1e-9 then
    sidebar = math.min(remaining, math.max(3, math.floor(total * layout.sidebar_width_percent / 100)))
  end
  local body, bar = M.divide(centered, "vertical", sidebar)
  if bar then
    body.col = centered.col + total - terminal
    body.width = terminal - border
  end
  return body, bar
end

function Bar:visible()
  return valid(self.win) and not api.nvim_win_get_config(self.win).hide
end

function Bar:stop_timer()
  if self.timer then vim.fn.timer_stop(self.timer) end
  self.timer = nil
end

function Bar:active()
  local win = self.opts.active_window and self.opts.active_window() or self.anchor
  return valid(win) and api.nvim_win_get_buf(win)
end

function Bar:groups()
  local groups = self.opts.groups()
  if self.opts.load_order and not self.order_loaded then
    self.order_loaded = true
    self.order = self.opts.load_order()
    self.saved_order = self.order
  end
  if not self.order then return groups end
  local order = {}
  for index, id in ipairs(self.order) do order[id] = index end
  for index, group in ipairs(groups) do group.position = order[group.id] or #self.order + index end
  table.sort(groups, function(a, b) return a.position < b.position end)
  return groups
end

function Bar:flush_order()
  if self.order_timer then vim.fn.timer_stop(self.order_timer) end
  self.order_timer = nil
  if self.opts.save_order and self.order and not vim.deep_equal(self.order, self.saved_order)
    and self.opts.save_order(self.order) then
    self.saved_order = self.order
  end
end

function Bar:reset_order()
  self:flush_order()
  self.order, self.saved_order, self.order_loaded = nil, nil, nil
end

local function reorder_visible(previous, groups)
  local ids, visible = {}, {}
  for index, group in ipairs(groups) do ids[index], visible[group.id] = group.id, true end
  local order, next_id = {}, 1
  for _, id in ipairs(previous or {}) do
    if visible[id] then
      order[#order + 1] = ids[next_id]
      next_id = next_id + 1
    else
      order[#order + 1] = id
    end
  end
  return vim.list_extend(order, ids, next_id)
end

function Bar:update_order(groups)
  self.order = reorder_visible(self.order, groups)
  if not self.opts.save_order then return end
  if self.order_timer then vim.fn.timer_stop(self.order_timer) end
  self.order_timer = vim.fn.timer_start(order_save_delay, function() self:flush_order() end)
end

function Bar:focus_content()
  local win = self.opts.active_window and self.opts.active_window() or self.anchor
  if valid(win) then api.nvim_set_current_win(win) end
end

function Bar:select(row, view_mode)
  local item = row and (row.item or row.group.active or row.group.items[1])
  if item then return self.opts.activate(item, view_mode) end
end

function Bar:jump(direction, count, keep_focus)
  local rows = {}
  for _, group in ipairs(self:groups()) do
    for _, item in ipairs(group.items) do
      if item.bufnr then rows[item.bufnr] = { item = item } end
    end
  end
  local win = keep_focus and self.win
  return self.history.jump(direction, count, function(buf) return rows[buf] ~= nil end, function(buf)
    local focused = self:select(rows[buf], true)
    if focused and valid(win) then api.nvim_set_current_win(win) end
    return focused
  end)
end

function Bar:map_jumps(buf, keep_focus)
  for key, direction in pairs({ ["<C-o>"] = -1, ["<C-i>"] = 1 }) do
    vim.keymap.set("n", key, function() self:jump(direction, vim.v.count1, keep_focus) end,
      { buffer = buf, silent = true, nowait = true, desc = "Jump in window bar history" })
  end
end

function Bar:refresh(keep_cursor, groups)
  if not valid(self.win) or not valid(self.anchor) then return end
  local active = self:active()
  groups = groups or self:groups()
  if self.style == "horizontal" then
    self.rows = {}
    for index, group in ipairs(groups) do
      local item = vim.iter(group.items):find(function(candidate) return candidate.bufnr and candidate.bufnr == active end)
      self.rows[index] = { group = group, groups = groups, index = index, active = item }
      if item and not keep_cursor then self.selected = index end
    end
    self.selected = math.max(1, math.min(self.selected, #self.rows))
    tabs.render_windows(self)
    self:animate()
    return
  end
  local live = {}
  for _, group in ipairs(groups) do
    for _, item in ipairs(group.items) do
      if item.bufnr then live[item.bufnr] = true end
    end
  end
  local selected = sidebar.render(self, groups, active, self.history.offsets(live))
  if selected and (not keep_cursor or api.nvim_get_current_win() ~= self.win) then
    api.nvim_win_set_cursor(self.win, { selected, 0 })
  end
  self:animate()
end

function Bar:animate()
  if not self.opts.status or not self:visible() or self.timer then return end
  self.timer = vim.fn.timer_start(130, function()
    if not self:visible() then self:stop_timer() return end
    self.frame = self.frame + 1
    if self.style == "horizontal" then tabs.render_windows(self) else sidebar.statuses(self) end
  end, { ["repeat"] = -1 })
end

function Bar:update_title(buf, label)
  if self.style == "vertical" and valid(self.win) then sidebar.update_title(self, buf, label) end
end

function Bar:focused_row()
  if self.style == "horizontal" then return self.rows[self.selected] end
  return self.rows[api.nvim_win_get_cursor(self.win)[1]]
end

function Bar:rename_window()
  local row = self:focused_row()
  if not row or row.item then return end
  local group, win = row.group, self.win
  vim.ui.input({ prompt = "Window name: ", default = group.title }, function(value)
    local name = vim.trim(value or "")
    if name == "" or name == group.title or name:find("%c") then return end
    if self.win == win and self:visible() then self.opts.rename_window(group, name) end
  end)
end

function Bar:refresh_at(group, item, groups)
  self:refresh(true, groups)
  for index, row in ipairs(self.rows) do
    if row.group.id == group and (row.item and row.item.id) == item then
      if self.style == "vertical" then
        api.nvim_win_set_cursor(self.win, { index, 0 })
      else
        self.selected = index
        tabs.render_windows(self)
      end
      return
    end
  end
end

function Bar:fold(value)
  local row = self:focused_row()
  if not row or self.folded[row.group.id] == value then return end
  self.folded[row.group.id] = value
  self:refresh_at(row.group.id)
end

function Bar:move(delta)
  local row = self:focused_row()
  if not row then return end
  local items, index = row.item and row.group.items or row.groups, row.index
  local target = index + delta
  if row.item then target = (target - 1) % #items + 1 end
  if target == index or not items[target] then return end
  if not row.item and self.opts.save_order and not self.saved_order then
    self.saved_order = vim.tbl_map(function(group) return group.id end, items)
  end
  table.insert(items, target, table.remove(items, index))
  if row.item then
    self.opts.reorder(row.group, items)
  else
    self:update_order(items)
  end
  self:refresh_at(row.group.id, row.item and row.item.id, not row.item and items or nil)
end

function Bar:cycle(step)
  local items, active = {}, self:active()
  local index = 1
  for _, group in ipairs(self:groups()) do
    local item = group.active and group.active.bufnr and group.active
      or vim.iter(group.items):find(function(candidate) return candidate.bufnr end)
    if item then
      items[#items + 1] = item
      if vim.iter(group.items):any(function(candidate) return candidate.bufnr == active end) then
        index = #items
      end
    end
  end
  if #items < 2 then return end
  return self:select({ item = items[(index - 1 + step) % #items + 1] }, true)
end

function Bar:pick_window()
  local groups, active, live = self:groups(), self:active(), {}
  for _, group in ipairs(groups) do
    for _, item in ipairs(group.items) do
      if item.bufnr then live[item.bufnr] = true end
    end
  end
  local recency = self.history.offsets(live)
  local choices, current = {}, nil
  for index, group in ipairs(groups) do
    local rank, focused = -math.huge, false
    for _, item in ipairs(group.items) do
      if item.bufnr then
        rank = math.max(rank, recency[item.bufnr] or -math.huge)
        if item.bufnr == active then focused = true end
      end
    end
    if #group.items > 0 then
      local choice = { id = group.id, display = (focused and "* " or "  ") .. group.title,
        ordinal = group.title, rank = rank, index = index }
      if focused then current = choice else choices[#choices + 1] = choice end
    end
  end
  table.sort(choices, function(a, b)
    if a.rank ~= b.rank then return a.rank > b.rank end
    return a.index < b.index
  end)
  if current then table.insert(choices, math.min(2, #choices + 1), current) end
  if #choices == 0 then
    vim.notify("No windows available", vim.log.levels.INFO)
    return
  end

  local anchor = self.anchor
  local view = require("luanphan.view_container")
  view.select("Switch Window", choices, function(choice)
    if not choice or self.anchor ~= anchor or not valid(anchor) then return end
    local group = vim.iter(self:groups()):find(function(candidate) return candidate.id == choice.id end)
    if group then self:select({ group = group }, true) end
  end, view.compact_picker_opts())
end

local function current_bar()
  local current = windows.group_anchor(api.nvim_get_current_win())
  local available = {}
  for bar in pairs(bars) do
    if bar.anchor == current then return bar end
    if valid(bar.anchor) and api.nvim_win_get_tabpage(bar.anchor) == api.nvim_get_current_tabpage() then
      available[#available + 1] = bar
    end
  end
  if #available == 1 then return available[1] end
end

function M.pick_window()
  local bar = current_bar()
  if bar then return bar:pick_window() end
  vim.notify("Focus an agent or terminal view to switch windows", vim.log.levels.INFO)
end

function M.focus_window(index)
  local bar = current_bar()
  local first_row = bar and bar.rows[1]
  local group = first_row and first_row.groups[index]
  if not group then return end
  vim.cmd.stopinsert()
  return bar:select({ group = group }, true)
end

function Bar:click()
  local mouse = vim.fn.getmousepos()
  if not valid(self.win) or mouse.winid ~= self.win then return "<LeftMouse>" end
  local index = mouse.line
  if self.style == "horizontal" then
    index = vim.iter(self.columns):enumerate():find(function(_, col) return mouse.wincol <= col end)
  end
  local row, win = self.rows[index], self.win
  vim.schedule(function()
    if row and self.win == win and self:visible() then self:select(row) end
  end)
  return ""
end

function Bar:set_hidden(hidden)
  if not valid(self.win) then return end
  if hidden and api.nvim_get_current_win() == self.win then self:focus_content() end
  api.nvim_win_set_config(self.win, { hide = hidden, focusable = not hidden, mouse = not hidden })
  if hidden then self:stop_timer() else self:refresh() end
end

function Bar:focus()
  if not valid(self.win) or windows.group_anchor(api.nvim_get_current_win()) ~= self.anchor then return end
  vim.cmd.stopinsert()
  self:set_hidden(false)
  api.nvim_set_current_win(self.win)
end

function Bar:focus_towards(direction, vertical_only)
  local towards_sidebar = self.style == "vertical" and direction == "h"
  local towards_top_bar = not vertical_only and self.style == "horizontal" and direction == "k"
  if not (towards_sidebar or towards_top_bar) then return false end
  self:focus()
  return true
end

function Bar:attach(buf)
  local opts = { buffer = buf, silent = true, nowait = true }
  vim.keymap.set("n", "<leader>e", function()
    if api.nvim_get_current_win() == self.win then self:focus_content() else self:focus() end
  end, vim.tbl_extend("force", opts, { desc = "Switch focus between window bar and content" }))
  vim.keymap.set("n", "<leader>b", function() self:set_hidden(self:visible()) end,
    vim.tbl_extend("force", opts, { desc = "Toggle window bar" }))
  vim.keymap.set({ "n", "t" }, "<LeftMouse>", function() return self:click() end,
    vim.tbl_extend("force", opts, { expr = true }))
end

function Bar:close()
  local win = self.win
  if valid(self.anchor) then vim.w[self.anchor].luanphan_window_bar = nil end
  self.win, self.anchor, self.rows = nil, nil, {}
  self.rows_by_buffer, self.active_row = nil, nil
  self:stop_timer()
  if valid(win) then api.nvim_win_close(win, true) end
end

function Bar:layout(anchor, layout)
  local frame, style = layout.bar, layout.bar_style
  if not frame then
    self:close()
    self.style = style
    return
  end
  if valid(self.win) and self.anchor == anchor and self.style == style then
    api.nvim_win_set_config(self.win, frame)
    return
  end
  self:close()
  self.anchor, self.style = anchor, style
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = self.opts.filetype or "window-bar"
  self.win = api.nvim_open_win(buf, false, vim.tbl_extend("force", frame, { style = "minimal" }))
  vim.w[self.win].luanphan_view_companion_anchor = anchor
  vim.w[anchor].luanphan_window_bar = self.win
  vim.wo[self.win].wrap = false
  vim.wo[self.win].winfixbuf = true
  if style == "vertical" then
    local win = self.win
    local highlights = "CursorLine:Visual"
    vim.wo[self.win].cursorline = true
    vim.wo[self.win].cursorlineopt = "line"
    vim.wo[self.win].winhighlight = highlights
    vim.wo[self.win].winbar = "%#TabLineFill# " .. self.opts.title
    api.nvim_create_autocmd({ "WinEnter", "WinLeave" }, {
      buffer = buf,
      callback = function(ev)
        if valid(win) then
          vim.wo[win].winhighlight = ev.event == "WinEnter" and highlights .. ",FloatBorder:DiagnosticOk" or highlights
        end
      end,
    })
  else
    vim.wo[self.win].winhighlight = "NormalFloat:TabLineFill"
  end
  self:attach(buf)
  self:map_jumps(buf, true)
  if self.opts.bind then self.opts.bind(buf) end

  local opts = { buffer = buf, silent = true, nowait = true }
  if self.opts.rename_window then
    vim.keymap.set("n", "e", function() self:rename_window() end,
      vim.tbl_extend("force", opts, { desc = "Rename window" }))
  end
  if self.opts.dismiss then
    vim.keymap.set("n", "d", function()
      local row = self:focused_row()
      if row then self.opts.dismiss(row.item or row.group.active) end
    end, opts)
  end
  for _, key in ipairs({ "<CR>", "o" }) do
    vim.keymap.set("n", key, function() self:select(self:focused_row()) end, opts)
  end
  for direction, delta in pairs({ h = -1, l = 1 }) do
    vim.keymap.set("n", direction, function()
      if self.style == "vertical" then
        self:fold(delta < 0 and true or nil)
      elseif #self.rows > 0 then
        self.selected = (self.selected - 1 + delta) % #self.rows + 1
        self:refresh(true)
      end
    end, opts)
  end
  for _, modifier in ipairs({ "C-S", "D-S" }) do
    vim.keymap.set("n", "<" .. modifier .. "-j>", function() self:move(1) end,
      vim.tbl_extend("force", opts, { desc = "Move sidebar item down" }))
    vim.keymap.set("n", "<" .. modifier .. "-k>", function() self:move(-1) end,
      vim.tbl_extend("force", opts, { desc = "Move sidebar item up" }))
  end
  for _, key in ipairs({ "<C-h>", "<C-j>", "<C-k>", "<C-l>" }) do
    local to_content = key == (style == "horizontal" and "<C-j>" or "<C-l>")
    vim.keymap.set("n", key, to_content and function() self:focus_content() end or "<Nop>", opts)
  end
end

function M.create(opts)
  local bar = setmetatable({
    opts = opts, rows = {}, folded = {}, frame = 1, selected = 1,
    history = opts.history or jump_lists.create(),
  }, Bar)
  bars[bar] = true
  return bar
end

api.nvim_create_autocmd("WinEnter", {
  group = api.nvim_create_augroup("LuanphanWindowBarFocus", { clear = true }),
  callback = function()
    local win = api.nvim_get_current_win()
    local anchor = windows.group_anchor(win)
    if not valid(anchor) then return end
    local sidebar_win = vim.w[anchor].luanphan_window_bar
    if not valid(sidebar_win) or sidebar_win == win then return end
    for bar in pairs(bars) do
      if bar.win == sidebar_win and bar.style == "vertical" then
        sidebar.follow(bar, api.nvim_win_get_buf(win))
        return
      end
    end
  end,
})

api.nvim_create_autocmd("VimLeavePre", {
  group = api.nvim_create_augroup("LuanphanWindowBarOrder", { clear = true }),
  callback = function()
    for bar in pairs(bars) do Bar.flush_order(bar) end
  end,
})

return M
