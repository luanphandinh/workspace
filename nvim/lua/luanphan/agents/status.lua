local M = {}

local live_status = {
  idle = true, working = true, done = true, blocked = true, error = true, clear = true,
}

-- Returns true when the status changed, so callers redraw only then.
function M.update(bufnr, status)
  if not live_status[status] or vim.b[bufnr].luanphan_view_status == status then return false end
  vim.b[bufnr].luanphan_view_status = status
  return true
end

function M.from_osc(sequence)
  return sequence:match("^\27%]7501;state=(%a+)")
end

function M.current(bufnr)
  return vim.b[bufnr].luanphan_view_status
end

return M
