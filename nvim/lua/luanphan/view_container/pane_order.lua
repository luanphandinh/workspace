local M = {}
local tmux = require("luanphan.view_container.tmux.pane")

function M.get(item)
  if item.bufnr and vim.api.nvim_buf_is_valid(item.bufnr) then
    return vim.b[item.bufnr].luanphan_view_pane_order
  end
  return tonumber(item.pane_order)
end

function M.set(buf, position)
  vim.b[buf].luanphan_view_pane_order = position
end

function M.persist(buf, position)
  M.set(buf, position)
  local pane = tmux.for_buffer(buf)
  if pane and pane.process and pane.process.queue_pane_order then
    pane.process.queue_pane_order(buf, position)
  end
end

function M.sort(items, position)
  if #items < 2 then return end
  position = position or M.get
  local ranks, original, ordered = {}, {}, false
  for index, item in ipairs(items) do
    local rank = position(item)
    ranks[item], original[item] = rank or math.huge, index
    ordered = ordered or rank ~= nil
  end
  if not ordered then return end
  table.sort(items, function(a, b)
    if ranks[a] ~= ranks[b] then return ranks[a] < ranks[b] end
    return original[a] < original[b]
  end)
end

function M.assign(items, apply, position)
  for index, item in ipairs(items) do
    if not position or position(item) ~= index then apply(item, index) end
  end
end

return M
