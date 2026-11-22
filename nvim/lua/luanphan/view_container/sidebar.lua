local M = {}
local api = vim.api
local ns = api.nvim_create_namespace("LuanphanWindowBar")
local status_ns = api.nvim_create_namespace("LuanphanWindowBarStatus")

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

function M.render(bar, groups, active, offsets)
  local lines, rows, selection = {}, {}, nil
  local width = api.nvim_win_get_width(bar.win) - 1
  local number_width = 2
  for _, offset in pairs(offsets) do number_width = math.max(number_width, #tostring(offset)) end
  local number = " %" .. number_width .. "s "
  for index, group in ipairs(groups) do
    local folded = bar.folded[group.id]
    local prefix = folded and "▸ " or " "
    lines[#lines + 1] = prefix .. fit(group.title, width - vim.fn.strdisplaywidth(prefix))
    rows[#rows + 1] = { group = group, groups = groups, index = index }
    for item_index, item in ipairs(group.items) do
      if folded and item.bufnr and item.bufnr == active then selection = #rows end
      if not folded then
        local offset = string.format(number, offsets[item.bufnr] or "")
        local icon = item.icon or ""
        local icon_col = width - vim.fn.strdisplaywidth(icon)
        local status_col = icon_col - (icon == "" and 0 or 2)
        local label_width = bar.opts.status and status_col - #offset - 1 or icon_col - #offset
        local row = {
          group = group, item = item, index = item_index,
          prefix_width = #offset, icon_col = icon_col, label_width = label_width,
        }
        if bar.opts.status and label_width >= 0 and item.bufnr then row.status_col = status_col end
        rows[#rows + 1] = row
        lines[#lines + 1] = offset .. fit(item.label, label_width)
        if item.bufnr and item.bufnr == active then selection = #rows end
      end
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
      api.nvim_buf_set_extmark(buf, ns, index - 1, 0, { line_hl_group = "Directory" })
    else
      api.nvim_buf_set_extmark(buf, ns, index - 1, 0, { end_col = row.prefix_width, hl_group = "Comment" })
      if row.item.icon and row.icon_col >= row.prefix_width then
        api.nvim_buf_set_extmark(buf, ns, index - 1, 0, {
          virt_text = { { row.item.icon, "Comment" } }, virt_text_win_col = row.icon_col, hl_mode = "combine",
        })
      end
    end
  end
  if selection then
    api.nvim_buf_set_extmark(buf, ns, selection - 1, 0, { line_hl_group = "Title" })
  end
  bar.rows = rows
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
