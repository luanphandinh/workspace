local M = {}
local api = vim.api
local editor = require("luanphan.view_container.editor")
local ns = api.nvim_create_namespace("LuanphanWindowBar")
local status_ns = api.nvim_create_namespace("LuanphanWindowBarStatus")
local active_ns = api.nvim_create_namespace("LuanphanWindowBarActive")
local window_title = "LuanphanWindowBarTitle"

local function set_title_highlight()
  local directory = api.nvim_get_hl(0, { name = "Directory", link = false })
  directory.bold = true
  api.nvim_set_hl(0, window_title, directory)
end

set_title_highlight()
api.nvim_create_autocmd("ColorScheme", {
  group = api.nvim_create_augroup("LuanphanWindowBarTitle", { clear = true }),
  callback = set_title_highlight,
})

local function fit(text, width)
  if width < 1 then return "" end
  if vim.fn.strdisplaywidth(text) <= width then return text end
  local characters = width - 1
  local prefix = vim.fn.strcharpart(text, 0, characters, true)
  while vim.fn.strdisplaywidth(prefix) >= width do
    characters = characters - 1
    prefix = vim.fn.strcharpart(text, 0, characters, true)
  end
  return prefix .. "…"
end

function M.statuses(bar)
  if not bar:visible() then return end
  local buf = api.nvim_win_get_buf(bar.win)
  for index, row in ipairs(bar.rows) do
    if row.status_col then
      local glyph, highlight = bar.opts.status(row.item, bar.frame)
      if glyph ~= row.glyph or highlight ~= row.highlight then
        if glyph then
          api.nvim_buf_set_extmark(buf, status_ns, index - 1, 0, {
            id = row.item.bufnr, virt_text = { { glyph, highlight } },
            virt_text_win_col = row.status_col, hl_mode = "combine",
          })
        else
          api.nvim_buf_del_extmark(buf, status_ns, row.item.bufnr)
        end
        row.glyph, row.highlight = glyph, highlight
      end
    end
  end
end

local function mark_active(bar, row)
  local buf = api.nvim_win_get_buf(bar.win)
  if row then
    api.nvim_buf_set_extmark(buf, active_ns, row - 1, 0, { id = 1, line_hl_group = "Title" })
  else
    api.nvim_buf_del_extmark(buf, active_ns, 1)
  end
  bar.active_row = row
end

function M.follow(bar, bufnr, keep_cursor)
  local row = bar.rows_by_buffer and bar.rows_by_buffer[bufnr]
  if not row then return end
  if row ~= bar.active_row then mark_active(bar, row) end
  if not keep_cursor and api.nvim_win_get_cursor(bar.win)[1] ~= row then api.nvim_win_set_cursor(bar.win, { row, 0 }) end
end

local function history_width(offsets)
  local width = 2
  for _, offset in pairs(offsets) do width = math.max(width, #tostring(offset)) end
  return width
end

-- Focus changes only the digits between the two spaces in each row's prefix.
-- Keeping both spaces also keeps the label and highlight extmark boundaries intact.
function M.update_history(bar, offsets)
  local digits = history_width(offsets)
  if digits ~= bar.history_width then return false end
  local buf
  for id in pairs(bar.live_items) do
    local index = bar.rows_by_buffer[id]
    local row = index and bar.rows[index]
    if row and row.item and row.item.bufnr == id and row.offset ~= offsets[id] then
      if not buf then
        buf = api.nvim_win_get_buf(bar.win)
        vim.bo[buf].modifiable = true
      end
      row.offset = offsets[id]
      api.nvim_buf_set_text(buf, index - 1, 1, index - 1, 1 + digits,
        { string.format("%" .. digits .. "s", row.offset or "") })
    end
  end
  if buf then vim.bo[buf].modifiable = false end
  return true
end

function M.render(bar, groups, active, offsets)
  local lines, rows, rows_by_buffer = {}, {}, {}
  local editors = editor.sidebar_items(bar.anchor, groups)
  local width = api.nvim_win_get_width(bar.win) - 1
  local digits = history_width(offsets)
  bar.history_width = digits
  local number = " %" .. digits .. "s "
  for index, group in ipairs(groups) do
    local folded = bar.folded[group.id]
    local prefix = (folded and "▸ " or " ") .. ("[%d] "):format(index)
    lines[#lines + 1] = fit(prefix .. group.title, width)
    rows[#rows + 1] = { group = group, groups = groups, index = index }
    local items = group.items
    if editors[group.id] then
      items = vim.list_slice(items)
      for _, item in ipairs(editors[group.id]) do
        table.insert(items, math.min(item.position or #items + 1, #items + 1), item)
      end
    end
    local item_index = 0
    for _, item in ipairs(items) do
      if not item.separate_window then item_index = item_index + 1 end
      if item.bufnr and item.bufnr == active and not item.separate_window then group.active = item end
      if not folded then
        local offset = string.format(number, offsets[item.bufnr] or "")
        local icon = item.icon or ""
        local icon_col = width - vim.fn.strdisplaywidth(icon)
        local status_col = icon_col - (icon == "" and 0 or 2)
        local label_width = bar.opts.status and status_col - #offset - 1 or icon_col - #offset
        local row = {
          group = group, item = item, index = not item.separate_window and item_index or nil,
          offset = offsets[item.bufnr], prefix_width = #offset, icon_col = icon_col, label_width = label_width,
        }
        if bar.opts.status and label_width >= 0 and item.bufnr and not item.separate_window then
          row.status_col = status_col
        end
        rows[#rows + 1] = row
        lines[#lines + 1] = offset .. fit(item.label, label_width)
      end
      if item.bufnr then rows_by_buffer[item.bufnr] = #rows end
    end
  end
  local buf = api.nvim_win_get_buf(bar.win)
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  api.nvim_buf_clear_namespace(buf, status_ns, 0, -1)
  for index, row in ipairs(rows) do
    if not row.item then
      local heading = { line_hl_group = window_title }
      if row.index > 1 then
        heading.virt_lines = { { { " " } } }
        heading.virt_lines_above = true
      end
      api.nvim_buf_set_extmark(buf, ns, index - 1, 0, heading)
    else
      api.nvim_buf_set_extmark(buf, ns, index - 1, 0, { end_col = row.prefix_width, hl_group = "Comment" })
      if row.item.icon and row.icon_col >= row.prefix_width then
        api.nvim_buf_set_extmark(buf, ns, index - 1, 0, {
          virt_text = { { row.item.icon, "Comment" } }, virt_text_win_col = row.icon_col, hl_mode = "combine",
        })
      end
    end
  end
  local selection = rows_by_buffer[active]
  bar.rows, bar.rows_by_buffer = rows, rows_by_buffer
  mark_active(bar, selection)
  M.statuses(bar)
  return selection
end

function M.update_title(bar, bufnr, label)
  local buf = api.nvim_win_get_buf(bar.win)
  for index, row in ipairs(bar.rows) do
    if row.item and row.item.bufnr == bufnr then
      local line = api.nvim_buf_get_lines(buf, index - 1, index, false)[1]
      vim.bo[buf].modifiable = true
      api.nvim_buf_set_text(buf, index - 1, row.prefix_width, index - 1, #line, { fit(label, row.label_width) })
      vim.bo[buf].modifiable = false
      return
    end
  end
end

return M
