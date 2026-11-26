-- Live status of a panel pane (idle, working, done, ...), kept in a buffer variable so it
-- survives UI restarts through the backend metadata.
local M = {}

local live_status = {
  idle = true, working = true, done = true, blocked = true, error = true, clear = true,
}
local spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local icons = {
  idle = { "·", "Comment" },
  done = { "✓", "DiagnosticOk" },
  blocked = { "!", "DiagnosticWarn" },
  error = { "!", "DiagnosticError" },
}

-- Returns true when the status changed, so callers redraw only then.
function M.update(bufnr, status)
  if not live_status[status] or vim.b[bufnr].luanphan_view_status == status then return false end
  vim.b[bufnr].luanphan_view_status = status
  return true
end

function M.current(bufnr)
  return vim.b[bufnr].luanphan_view_status
end

-- Programs report their state with `OSC 7501 ; state=<status>`.
function M.from_osc(sequence)
  return sequence:match("^\27%]7501;state=(%a+)")
end

-- Window bar status callback: glyph, highlight, and whether the glyph is animated.
function M.glyph(bufnr, frame)
  local current = M.current(bufnr)
  if current == "working" then return spinner[(frame - 1) % #spinner + 1], "DiagnosticInfo", true end
  local icon = icons[current]
  if icon then return icon[1], icon[2] end
end

return M
