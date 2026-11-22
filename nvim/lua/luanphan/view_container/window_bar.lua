local M = {}
local Bar = {}
Bar.__index = Bar

local api = vim.api
local windows = require("luanphan.view_container.window")
local sidebar = require("luanphan.view_container.sidebar")
local tabs = require("luanphan.view_container.tab_render")
local jump_lists = require("luanphan.view_container.jumplist")

local function valid(win)
  return win and api.nvim_win_is_valid(win)
end

function M.divide(frame, style, vertical_width)
  local border = frame.border == "none" and 0 or 2
  local body = vim.tbl_extend("force", {}, frame)
  local bar = vim.tbl_extend("force", {}, frame, { border = "none" })
  if style == "horizontal" then
    if frame.height < 4 then return body end
    bar.width, bar.height = body.width + border, 2
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
  if not self.order then return groups end
  local order = {}
  for index, id in ipairs(self.order) do order[id] = index end
  for index, group in ipairs(groups) do group.position = order[group.id] or #self.order + index end
  table.sort(groups, function(a, b) return a.position < b.position end)
  return groups
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

function Bar:refresh(keep_cursor)
  if not valid(self.win) or not valid(self.anchor) then return end
  local active, groups = self:active(), self:groups()
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
  if selected and not keep_cursor then api.nvim_win_set_cursor(self.win, { selected, 0 }) end
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

function Bar:refresh_at(group, item)
  self:refresh(true)
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
  table.insert(items, target, table.remove(items, index))
  if row.item then
    self.opts.reorder(row.group, items)
  else
    self.order = vim.tbl_map(function(group) return group.id end, items)
  end
  self:refresh_at(row.group.id, row.item and row.item.id)
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

function Bar:attach(buf)
  local opts = { buffer = buf, silent = true, nowait = true }
  vim.keymap.set("n", "<leader>e", function() self:focus() end,
    vim.tbl_extend("force", opts, { desc = "Focus window bar" }))
  vim.keymap.set("n", "<leader>b", function() self:set_hidden(self:visible()) end,
    vim.tbl_extend("force", opts, { desc = "Toggle window bar" }))
  vim.keymap.set({ "n", "t" }, "<LeftMouse>", function() return self:click() end,
    vim.tbl_extend("force", opts, { expr = true }))
end

function Bar:close()
  local win = self.win
  if valid(self.anchor) then vim.w[self.anchor].luanphan_window_bar = nil end
  self.win, self.anchor, self.rows = nil, nil, {}
  self:stop_timer()
  if valid(win) then api.nvim_win_close(win, true) end
end

function Bar:layout(anchor, frame, style)
  if not frame then self:close() return end
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
    vim.wo[self.win].cursorline = true
    vim.wo[self.win].cursorlineopt = "line"
    vim.wo[self.win].winhighlight = "CursorLine:Visual"
    vim.wo[self.win].winbar = "%#TabLineFill# " .. self.opts.title
  else
    vim.wo[self.win].winhighlight = "NormalFloat:Normal,WinBar:Normal,WinBarNC:Normal"
  end
  self:attach(buf)
  self:map_jumps(buf, true)
  if self.opts.bind then self.opts.bind(buf) end

  local opts = { buffer = buf, silent = true, nowait = true }
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
  vim.keymap.set("n", "J", function() self:move(1) end, opts)
  vim.keymap.set("n", "K", function() self:move(-1) end, opts)
  vim.keymap.set("n", "<leader>e", function() self:focus_content() end, opts)
  for _, key in ipairs({ "<C-h>", "<C-j>", "<C-k>", "<C-l>" }) do
    local to_content = key == (style == "horizontal" and "<C-j>" or "<C-l>")
    vim.keymap.set("n", key, to_content and function() self:focus_content() end or "<Nop>", opts)
  end
end

function M.create(opts)
  return setmetatable({
    opts = opts, rows = {}, folded = {}, frame = 1, selected = 1,
    history = opts.history or jump_lists.create(),
  }, Bar)
end

return M
