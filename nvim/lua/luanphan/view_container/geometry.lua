-- Float geometry for panels: the body window and the window bar beside or above it.
local M = {}

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

function M.layout(settings, opts)
  opts = opts or {}
  local border = opts.border or (settings.display_style == "tile" and "single" or "none")
  local inset = border == "none" and 0 or 2
  local frame = {
    relative = "editor", row = 0, col = 0, width = vim.o.columns - inset,
    height = math.max(opts.min_height or 4, vim.o.lines - vim.o.cmdheight) - inset,
    border = border, zindex = opts.zindex or 40,
  }
  local body, bar
  if opts.docked then
    if opts.win and vim.api.nvim_win_is_valid(opts.win) then
      frame.row, frame.col = unpack(vim.api.nvim_win_get_position(opts.win))
      frame.width = vim.api.nvim_win_get_width(opts.win)
      frame.height = vim.api.nvim_win_get_height(opts.win)
    end
    local sidebar = math.min(42, math.max(3, math.floor(frame.width * 0.3)))
    body, bar = M.divide(frame, settings.window_bar_style, sidebar)
  else
    body, bar = M.float_geometry(frame, settings)
  end
  return { body = body, bar = bar, display_style = settings.display_style, bar_style = settings.window_bar_style }
end

return M
